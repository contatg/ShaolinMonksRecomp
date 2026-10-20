# Local/private Android ARM64 APK containing the user's own statically
# recompiled original Xbox guest, full kernel and real game Boot.
# Keeps all proprietary game code private; renderer compatibility is not assumed.
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
# Android Gradle Plugin cannot infer SDK from a previously configured
# CMake cache. Set both environment variables and a project-local property.
# local.properties is kept on this PC only; never upload SDK locations.
$sdkCandidates=@()
if($env:ANDROID_HOME){$sdkCandidates+= $env:ANDROID_HOME}
if($env:ANDROID_SDK_ROOT){$sdkCandidates+= $env:ANDROID_SDK_ROOT}
$sdkCandidates+= (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
$androidSdkHome=$null
foreach($candidate in $sdkCandidates){
    if(-not $candidate){continue}
    $ndk=Join-Path $candidate 'ndk\28.2.13676358'
    $platform=Join-Path $candidate 'platforms\android-34'
    if((Test-Path -LiteralPath $ndk -PathType Container) -and
       (Test-Path -LiteralPath $platform -PathType Container)){
        $androidSdkHome=(Resolve-Path -LiteralPath $candidate).Path
        break
    }
}
if(-not $androidSdkHome){
    throw 'Android SDK with NDK 28.2.13676358 and platform android-34 not found. Install these in Android Studio SDK Manager.'
}
$env:ANDROID_HOME=$androidSdkHome
$env:ANDROID_SDK_ROOT=$androidSdkHome
# Escape Windows path separators for Java's .properties file reader.
$sdkProp=$androidSdkHome.Replace('\','/').Replace(':','\:')
$localProps=Join-Path $PSScriptRoot 'local.properties'
[System.IO.File]::WriteAllText(
    $localProps,
    "sdk.dir=$sdkProp" + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false))
Write-Host "Android SDK configured locally: $androidSdkHome"

Write-Host 'Building PRIVATE ARM64 APK with genuine Xbox kernel::Boot and actual game entry thread.'
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
        # Gradle's last 100 lines are Java stack frames, not the NDK failure.
        # Surface original clang/CMake/ninja errors so we can fix the actual
        # D3D8/Vulkan/GLES compile without another blind rebuild.
        $diagnostics = @(
            Get-Content -LiteralPath $log |
            Where-Object {
                $_ -match '(?i)(?:fatal error:|\\berror:|FAILED: CMakeFiles|CMake Error|undefined symbol:|ninja: error:|error: linker command failed)' -and
                $_ -notmatch 'gradle\\.api|org\\.gradle|System\\.Management\\.Automation|Execution failed for task'
            } |
            Select-Object -Unique -First 35
        )
        $errorFile = Join-Path $logDir 'gameboot-native-errors.txt'
        if ($diagnostics.Count) {
            $diagnostics | Set-Content -LiteralPath $errorFile -Encoding UTF8
            Write-Host '===== REAL NDK / CMAKE BUILD ERRORS =====' -ForegroundColor Yellow
            $diagnostics | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
        }
        throw "Android game APK build failed ($exitCode). Send $errorFile (or first compiler errors from $log)."
    }
} finally { Pop-Location }
$apk = Join-Path $PSScriptRoot 'app\build\outputs\apk\debug\app-debug.apk'
if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) {
    throw "Gradle returned success but debug APK not found at $apk"
}
$destination=Join-Path $output 'ShaolinMobiu-ARM64-GameBoot.apk'
Copy-Item -LiteralPath $apk -Destination $destination -Force
# Verify Gradle actually packaged the game's native SDL library, rather than
# reporting a successful but launcher-only Android APK.
Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
$archive=[System.IO.Compression.ZipFile]::OpenRead($destination)
try {
    $nativeEntry=@($archive.Entries | Where-Object {
        $_.FullName -eq 'lib/arm64-v8a/libmain.so'
    })
    if($nativeEntry.Count -ne 1 -or $nativeEntry[0].Length -lt 1000000) {
        throw 'APK does not contain a plausible private ARM64 libmain.so. Check shaolinNativeGame CMake flag.'
    }
    Write-Host "Verified APK contains ARM64 SDL/game libmain.so ($($nativeEntry[0].Length) bytes)."
} finally {
    $archive.Dispose()
}
$info=Get-Item -LiteralPath $destination
$hash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
Write-Host "APK generated: $($info.FullName)" -ForegroundColor Green
Write-Host "APK size: $($info.Length) bytes"
Write-Host "SHA256: $hash"
Write-Host "Build log: $log"
Write-Host 'REAL GAME BOOT enabled; D3D8 Vulkan / GLES code linked. On-device gameplay and visuals are NOT yet verified.'
Write-Host 'Install on your test phone, select your ORIGINAL ISO and press Play; capture the first guest errors.'
Write-Host 'Kernel log tag: ShaolinXboxKernel (plus ShaolinXbox, ShaolinMobiu and Android crash logs).'
