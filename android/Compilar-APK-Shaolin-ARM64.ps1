# Local/private Android ARM64 APK containing the user's own statically
# recompiled original Xbox game functions + Xbox dispatch + Krypt Lua.
# Does NOT upload game code to GitHub, install APK, or claim playable gameplay.
[CmdletBinding()]
param([ValidateRange(1,8)][int]$Jobs=2)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$generated = Join-Path $PSScriptRoot 'generated\shaolin'
$mapping = Join-Path $generated 'x86_func_mapping.cpp'
if (-not (Test-Path -LiteralPath $mapping)) {
    throw "Private Xbox game C++ translation missing. Run Compilar-Codigo-Shaolin-ARM64.ps1 with your original XBE first."
}
$partitions=@(Get-ChildItem -LiteralPath $generated -File -Filter 'x86_recomp.*.cpp')
if ($partitions.Count -ne 128) {
    throw "Expected 128 private recomp partitions; found $($partitions.Count)."
}
$gradle = Join-Path $root 'android-local\gradle-8.7\bin\gradle.bat'
if (-not (Test-Path -LiteralPath $gradle)) {
    $cmd=Get-Command gradle.bat -ErrorAction SilentlyContinue
    if ($cmd) { $gradle=$cmd.Source }
    else { throw 'Gradle 8.7 missing. Run Compilar-Codigo-Shaolin-ARM64.ps1 once to install the official Gradle distribution.' }
}
$logDir = Join-Path $root 'android-local\logs'
$output = Join-Path $root 'android-local\output'
New-Item -ItemType Directory -Force -Path $logDir, $output | Out-Null
$log = Join-Path $logDir 'apk-with-recompiled-game.log'
Write-Host 'Building a PRIVATE ARM64 APK with the actual Shaolin guest recompilation.'
Write-Host 'Original 128 C++ partitions will be reused; only changed targets are rebuilt.'
Write-Host 'Public launcher and Krypt manager source code are kept intact.'
Push-Location $PSScriptRoot
try {
    # PS5 converts native stderr into ErrorRecord with preference Stop; use
    # Continue around the actual Gradle process and check its exit code.
    $savedPreference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        & $gradle '--no-daemon' '-PshaolinNativeGame=true' 'assembleDebug' '--stacktrace' 2>&1 |
            ForEach-Object { "$_" } | Tee-Object -FilePath $log
        $exitCode=$LASTEXITCODE
    } finally { $ErrorActionPreference=$savedPreference }
    if ($exitCode -ne 0) {
        throw "Android native APK build failed ($exitCode). Send the first compiler/linker errors from $log."
    }
} finally { Pop-Location }
$apk = Join-Path $PSScriptRoot 'app\build\outputs\apk\debug\app-debug.apk'
if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) {
    throw "Gradle returned success but debug APK not found at $apk"
}
$destination=Join-Path $output 'ShaolinMobiu-ARM64-Recomp-Experimental.apk'
Copy-Item -LiteralPath $apk -Destination $destination -Force
$info=Get-Item -LiteralPath $destination
$hash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
Write-Host "APK generated: $($info.FullName)" -ForegroundColor Green
Write-Host "APK size: $($info.Length) bytes"
Write-Host "SHA256: $hash"
Write-Host "Build log: $log"
Write-Host 'IMPORTANT: This APK links real Xbox recomp and Krypt; gameplay still needs kernel/XDK + game renderer.'
Write-Host 'Install only on your test phone and capture logcat tagged ShaolinXbox.'
