# Build the audited Shaolin Monks Xbox translation on the Windows host.
# Does not upload the original game or generated translation to GitHub.
# Usage (PowerShell):
#   powershell -ExecutionPolicy Bypass -File .\android\Preparar-XBE-Android.ps1 -Xbe "C:\Games\Shaolin\default.xbe"
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Xbe,
    [string]$Llvm = "C:\Program Files\LLVM",
    [ValidateRange(1, 8)]
    [int]$Jobs = 2
)

$ErrorActionPreference = 'Stop'
$expectedSha256 = "48240902bf4a04eb89376217c529531032d3370749bcce91a194878cc49db74a"
$sdkRevision = "40e9c35451305f09ca9d86f677e4b9c2c37ff26b"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$xbeFile = (Resolve-Path -LiteralPath $Xbe -ErrorAction Stop).Path
$sdk = Join-Path $root "third_party\XboxXBERecomp"
$build = Join-Path $root "build\release"
$generated = Join-Path $build "generated\shaolin"
$androidGenerated = Join-Path $root "android\generated\shaolin"

function Check-NativeCommand {
    param([string]$Description)
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

foreach ($tool in @("git", "python", "cmake")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Missing $tool in PATH."
    }
}
if (-not (Test-Path (Join-Path $Llvm "bin\clang++.exe"))) {
    throw "LLVM Clang was not found at $Llvm"
}
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $xbeFile).Hash.ToLowerInvariant()
if ($hash -ne $expectedSha256) {
    throw "Unsupported default.xbe. Expected SHA256 $expectedSha256, got $hash. Original USA/Europe Xbox executable required."
}
Write-Host "Verified original Shaolin Monks XBE (SHA256 OK)." -ForegroundColor Green

if (-not (Test-Path (Join-Path $sdk "cmake\XbeRecomp.cmake"))) {
    if (Test-Path $sdk) { throw "SDK directory already exists but is incomplete: $sdk" }
    New-Item -ItemType Directory -Path (Split-Path $sdk -Parent) -Force | Out-Null
    & git clone https://github.com/TGP482/XboxXBERecomp.git $sdk
    Check-NativeCommand "SDK clone"
    & git -C $sdk checkout --detach $sdkRevision
    Check-NativeCommand "SDK checkout"
}
$revision = (& git -C $sdk rev-parse HEAD | Out-String).Trim()
Check-NativeCommand "SDK revision read"
if ($revision -ne $sdkRevision) {
    Write-Host "SDK revision $revision differs from pinned $sdkRevision. Fetching pinned commit..." -ForegroundColor Yellow
    & git -C $sdk fetch --no-tags origin $sdkRevision
    Check-NativeCommand "SDK pinned commit fetch"
    & git -C $sdk checkout --detach $sdkRevision
    Check-NativeCommand "SDK pinned commit checkout"
    $revision = (& git -C $sdk rev-parse HEAD | Out-String).Trim()
    Check-NativeCommand "SDK revision read after checkout"
    if ($revision -ne $sdkRevision) {
        throw "Pinned XboxXBERecomp revision could not be selected. Current: $revision"
    }
}
Write-Host "Configuring Windows host recompiler..." -ForegroundColor Cyan
& python (Join-Path $root "tools\build_recomp.py") --xbe $xbeFile --sdk $sdk --llvm $Llvm --jobs $Jobs --configure-only
Check-NativeCommand "Recompiler configuration"

Write-Host "Generating Xbox -> C++ translation and mod bridge (128 partitions)..." -ForegroundColor Cyan
& cmake --build $build --target shaolin_mod_targets --parallel $Jobs
Check-NativeCommand "Xbox C++ recompiler"

$required = @(
    "x86_func_mapping.cpp",
    "x86_recomp_shared.h",
    "image_symbols.h",
    "mod_routine_targets.h"
)
for ($i = 0; $i -lt 128; $i++) {
    $required += "x86_recomp.$i.cpp"
}
$missing = @($required | Where-Object { -not (Test-Path (Join-Path $generated $_)) })
if ($missing.Count -gt 0) {
    throw "Code generation incomplete. Missing: $($missing -join ', ')"
}
New-Item -ItemType Directory -Path $androidGenerated -Force | Out-Null
foreach ($name in $required) {
    Copy-Item -LiteralPath (Join-Path $generated $name) -Destination (Join-Path $androidGenerated $name) -Force
}
# This directory is ignored by Git and must never be added to public sources.
$metadata = @{
    title = "Shaolin Monks USA/Europe"
    source_xbe_sha256 = $hash
    sdk_commit = $revision
    cxx_partitions = 128
    created_utc = [DateTime]::UtcNow.ToString("o")
    note = "Locally generated game translation; do not upload or redistribute."
}
$metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $androidGenerated "local-metadata.json") -Encoding UTF8
Write-Host ""
Write-Host "XBE recompilation completed." -ForegroundColor Green
Write-Host "128 generated C++ partitions and 4 mapping/header files staged at:"
Write-Host "  $androidGenerated"
Write-Host "The Android APK does not use these files yet. Next task: ARM64 runtime integration."
