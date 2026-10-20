# Install the first REAL Xbox guest boot APK, open the Android launcher,
# and collect native/Android crash logs WITHOUT uploading the original ISO.
[CmdletBinding()]
param([ValidateRange(15,180)][int]$Seconds=65)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$adb=Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$apk=Join-Path $root 'android-local\output\ShaolinMobiu-ARM64-GameBoot.apk'
if(!(Test-Path -LiteralPath $adb)){throw "adb.exe missing at $adb"}
if(!(Test-Path -LiteralPath $apk)){throw "GameBoot APK missing at $apk. Build with Compilar-APK-Shaolin-ARM64.ps1 first."}
$devices=@(& $adb devices | Select-String -Pattern '\tdevice$')
if($devices.Count -ne 1){throw 'Connect exactly one Android device with USB debugging authorized (adb devices).'}
Write-Host 'Installing private genuine Xbox GameBoot APK...'
& $adb install -r $apk
if($LASTEXITCODE -ne 0){throw 'APK installation failed. Existing app data was not removed.'}
# Preserve full crash + ART + Vulkan diagnostics; tags alone can miss native crashes.
& $adb logcat -c
if($LASTEXITCODE -ne 0){throw 'Unable to clear logcat'}
& $adb shell am start -n 'org.shaolinmobiu/.LauncherActivity'
Write-Host "On phone: choose your original Shaolin ISO (if needed), press PLAY. Capturing $Seconds seconds..."
Start-Sleep -Seconds $Seconds
$dir=Join-Path $root 'android-local\gameboot-logs'
New-Item -Force -ItemType Directory -Path $dir | Out-Null
$all=Join-Path $dir 'android-logcat-full.txt'
& $adb logcat -d -v threadtime | Out-File -FilePath $all -Encoding utf8
if($LASTEXITCODE -ne 0){throw 'adb logcat collection failed'}
$lines=@(Get-Content -LiteralPath $all |
 Select-String -Pattern 'ShaolinXbox|ShaolinMobiu|ShaolinGPU|ShaolinAudio|vulkan:|d3d:|xapi:|audio:|Fatal signal|SIGSEGV|SIGABRT|libmain\.so|DEBUG|AndroidRuntime|libc.*fatal' |
 ForEach-Object { $_.Line })
$filtered=Join-Path $dir 'shaolin-gameboot-errors.txt'
$lines | Set-Content -LiteralPath $filtered -Encoding UTF8
$zip=Join-Path $dir 'Shaolin-GameBoot-Logs.zip'
if(Test-Path $zip){Remove-Item -LiteralPath $zip -Force}
Compress-Archive -LiteralPath $all,$filtered -DestinationPath $zip
Write-Host "GAME BOOT LOGS: $zip" -ForegroundColor Green
Write-Host "Matching lines: $($lines.Count). Send ONLY this ZIP so the native boot crash can be diagnosed."
