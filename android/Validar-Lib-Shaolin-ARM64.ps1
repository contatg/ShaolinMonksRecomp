# Compile and fully link a PRIVATE Android ARM64 shared library containing
# the static-recompiled Xbox game functions and the genuine Krypt Lua runtime.
# The result is NOT a bootable game and must not replace the launcher.
[CmdletBinding()]
param([ValidateRange(1,8)][int]$Jobs=2)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$guestLink=Join-Path $PSScriptRoot 'Ligar-Codigo-Xbox-ARM64.ps1'
if(!(Test-Path $guestLink)){throw "Missing helper script: $guestLink"}
Write-Host '[1/2] Linking locally generated Shaolin + Xbox runtime + Krypt Lua...'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guestLink
if($LASTEXITCODE -ne 0){throw "Xbox/Krypt relocatable link failed ($LASTEXITCODE)."}
$buildRoot=Join-Path $PSScriptRoot 'app\.cxx\Debug'
$buildNinja=Get-ChildItem $buildRoot -Filter 'build.ninja' -File -Recurse |
  Where-Object {$_.Directory.Name -eq 'arm64-v8a'} |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(!$buildNinja){throw 'ARM64 CMake build.ninja missing.'}
$build=$buildNinja.DirectoryName
Write-Host '[2/2] Performing the Android NDK final shared-library link (--no-undefined)...'
& cmake --build $build --target shaolin_game_link_probe --parallel $Jobs
if($LASTEXITCODE -ne 0){
  throw "Native Android shared link failed ($LASTEXITCODE). Send the FIRST 'undefined symbol:' linker errors."
}
$so=@(Get-ChildItem $build -Recurse -File -Filter 'libshaolin_game_link_probe.so')
if($so.Count -ne 1){throw "Expected one link probe .so, found $($so.Count)"}
$reportDir=Join-Path $root 'android-local\link'
New-Item -ItemType Directory -Path $reportDir -Force|Out-Null
$report=Join-Path $reportDir 'shaolin-game-native-link-summary.txt'
@(
 'Xbox Shaolin Monks native ARM64 link test completed'
 "File: $($so[0].FullName)"
 "Bytes: $($so[0].Length)"
 'No unresolved native link dependencies in this test library.'
 'This is not a running game: Xbox boot thread, missing kernel/XDK behavior,'
 'input/audio and the real game Vulkan renderer are not connected to the Android launcher.'
) | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host "SUCCESS: ARM64 native .so linked at $($so[0].FullName)" -ForegroundColor Green
Write-Host "Report: $report"
Write-Host 'IMPORTANT: Do not install this standalone .so as a game APK.'
