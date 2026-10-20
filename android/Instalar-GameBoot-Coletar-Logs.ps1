# Install LOCAL private GameBoot APK and capture deterministic app-private native
# logs. Some MIUI builds suppress app logcat: run-as reads the debug APK's
# internal trace without root, ROM extraction, or broad-storage access.
[CmdletBinding()]
param([ValidateRange(15,180)][int]$Seconds=75, [switch]$SkipInstall)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$adb=Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$apk=Join-Path $root 'android-local\output\ShaolinMobiu-ARM64-GameBoot.apk'
$package='org.shaolinmobiu'
if(!(Test-Path -LiteralPath $adb)){throw "adb.exe missing at $adb"}
if(!$SkipInstall -and !(Test-Path -LiteralPath $apk)){throw "GameBoot APK missing at $apk. Compile the private APK first."}
$devices=@(& $adb devices | Select-String -Pattern '\tdevice$')
if($devices.Count -ne 1){throw 'Connect exactly one authorized Android device (adb devices).'}
$dir=Join-Path $root ('android-local\gameboot-logs\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -Force -ItemType Directory -Path $dir | Out-Null
if (!$SkipInstall) {
    Write-Host 'Installing PRIVATE Xbox GameBoot APK without deleting app data or ISO permission...'
    & $adb install -r $apk
    if($LASTEXITCODE -ne 0){throw 'APK installation failed; original app data preserved.'}
}
& $adb logcat -c
$activityOutput=@(& $adb shell am start -n "$package/.LauncherActivity")
$activityOutput | ForEach-Object {Write-Host $_}
if($LASTEXITCODE -ne 0 -or (($activityOutput -join ' ') -match '(?i)Error:|does not exist|permission denial')){
    throw 'Launcher Activity did not start. Check package ID and installation.'
}
Write-Host "PHONE: select ORIGINAL Shaolin ISO and press PLAY; capturing $Seconds seconds..."
Start-Sleep -Seconds $Seconds
# Read app-owned breadcrumbs directly; this is our primary diagnostic source.
$trace=Join-Path $dir 'shaolin-native-trace.txt'
$savedPref=$ErrorActionPreference
try {
    $ErrorActionPreference='Continue'
    $traceLines=@(& $adb exec-out run-as $package cat files/shaolin-native-trace.txt 2>&1 | ForEach-Object {"$_"})
    $traceExit=$LASTEXITCODE
} finally {
    $ErrorActionPreference=$savedPref
}
if($traceExit -ne 0 -or !$traceLines.Count){
    @('PRIVATE TRACE NOT READABLE: app may not have started, or Android run-as denied access.',
      'Try: adb shell run-as org.shaolinmobiu ls files',
      'DETAILS:') + $traceLines | Set-Content -LiteralPath $trace -Encoding UTF8
} else {
    $traceLines | Set-Content -LiteralPath $trace -Encoding UTF8
}
Write-Host "Private Xbox trace: $trace"
# Check whether the ACTUAL game process remains active, rather than
# assuming a black surface means a running guest thread.
$status=Join-Path $dir 'shaolin-android-process.txt'
$savedPref=$ErrorActionPreference
try {
    $ErrorActionPreference='Continue'
    @(
        '=== INSTALLED DEBUG APK ==='
        (& $adb shell pm path $package)
        '=== ACTIVITY START RESULT ==='
        $activityOutput
        '=== LAUNCHER PROCESS PID ==='
        (& $adb shell pidof $package)
        '=== GAME PROCESS PID ==='
        (& $adb shell pidof "${package}:game")
        '=== DEVICE AND HOST PAGE SIZE ==='
        (& $adb shell getprop ro.product.model)
        (& $adb shell getprop ro.build.version.release)
        (& $adb shell getconf PAGE_SIZE)
        '=== FOREGROUND ACTIVITY ==='
        (& $adb shell dumpsys activity activities | Select-String -Pattern 'mResumedActivity|topResumedActivity|org.shaolinmobiu' | Select-Object -First 35 | ForEach-Object { "$_" })
        '=== ANDROID PROCESS EXIT REASONS ==='
        (& $adb shell dumpsys activity exit-info $package)
    ) | Out-File -FilePath $status -Encoding utf8
} finally { $ErrorActionPreference=$savedPref }
# Keep only app/game and crash-relevant messages. Unlike a full phone
# logcat dump, this does not upload unrelated apps' logs by default.
$filtered=Join-Path $dir 'shaolin-gameboot-errors.txt'
$savedPref=$ErrorActionPreference
try {
    $ErrorActionPreference='Continue'
    $lines=@(& $adb logcat -d -b main -b system -b crash -v threadtime 2>&1 |
        Select-String -Pattern 'ShaolinXbox|ShaolinMobiu|ShaolinTrace|ShaolinGPU|ShaolinAudio|org\.shaolinmobiu|libmain\.so|Fatal signal|AndroidRuntime|linker.*libmain|vulkan:|d3d:|xapi:' |
        ForEach-Object { $_.Line })
    $lines | Set-Content -LiteralPath $filtered -Encoding UTF8
} finally { $ErrorActionPreference=$savedPref }
$zip=Join-Path $dir 'Shaolin-GameBoot-Logs.zip'
if(Test-Path -LiteralPath $zip){Remove-Item -LiteralPath $zip -Force}
Compress-Archive -LiteralPath $trace,$status,$filtered -DestinationPath $zip
Write-Host "Captured game boot evidence: $zip" -ForegroundColor Green
Write-Host 'Send this ZIP. It includes ISO/boot progress, real GPU frame count, app process/exit state and filtered crash logs.'
