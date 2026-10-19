# Compile the real 128 Shaolin Monks static-recompiled Xbox C++ translation
# into Android ARM64 OBJECT FILES using the user's audited original default.xbe.
# Does not claim gameplay: host kernel/XDK/renderer integration is still required.
# Keeps all proprietary source and generated translations local and ignored by Git.
#
# Run from PowerShell:
#   powershell -ExecutionPolicy Bypass -File .\android\Compilar-Codigo-Shaolin-ARM64.ps1 -Xbe "C:\Games\Shaolin\default.xbe"
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Xbe,
    [ValidateRange(1,8)][int]$Jobs=2,
    [string]$Llvm="C:\Program Files\LLVM"
)
$ErrorActionPreference="Stop"
$root=(Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$android=Join-Path $root "android"
$source=(Resolve-Path -LiteralPath $Xbe).Path
$verify=Join-Path $android "Preparar-XBE-Android.ps1"
if (-not (Test-Path $verify)) { throw "Missing original Xbox recompiler preparer: $verify" }
$gradle=Get-Command gradle -ErrorAction SilentlyContinue
if (-not $gradle) { throw "Gradle 8.7 is required in PATH for the Android build (the APK workflow installs Gradle 8.7 automatically)." }
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) { throw "CMake is not in PATH" }

Write-Host "[1/3] Checking genuine Shaolin Monks XBE and generating C++ privately" -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $verify -Xbe $source -Llvm $Llvm -Jobs $Jobs
if ($LASTEXITCODE -ne 0) { throw "The original Xbox recompiler failed ($LASTEXITCODE)" }

Write-Host "[2/3] Configuring Android ARM64 guest code, plus existing launcher" -ForegroundColor Cyan
Push-Location $android
try {
    & gradle --no-daemon "-PshaolinGuestObjects=true" assembleDebug
    if ($LASTEXITCODE -ne 0) { throw "Gradle Android configuration failed ($LASTEXITCODE)" }
} finally { Pop-Location }

Write-Host "[3/3] Building 128 real guest translation objects (not the full game yet)" -ForegroundColor Cyan
$builds=@(Get-ChildItem -Path (Join-Path $android "app\.cxx\Debug") -Directory -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '[\\/]arm64-v8a$' -and (Test-Path (Join-Path $_.FullName "build.ninja")) })
if ($builds.Count -eq 0) { throw "Android CMake Ninja ARM64 build directory was not created." }
$build=($builds | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
& cmake --build $build --target shaolin_guest_arm64 --parallel $Jobs
if ($LASTEXITCODE -ne 0) { throw "Xbox game ARM64 object compilation failed ($LASTEXITCODE)" }

$objects=@(Get-ChildItem -Path $build -Recurse -File -Filter "*.o" |
    Where-Object { $_.FullName -like "*shaolin_guest_arm64*" })
Write-Host "Compiled $($objects.Count) ARM64 object files" -ForegroundColor Green
if ($objects.Count -lt 129) {
    throw "Expected at least 129 guest translation object files; found $($objects.Count)"
}
Write-Host "Generated game code and ARM64 object files are LOCAL ONLY:"
Write-Host "  $build"
Write-Host "These guest objects cannot yet execute without the Android Xbox kernel/XDK host and Vulkan renderer."
