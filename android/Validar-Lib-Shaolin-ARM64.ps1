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
# Android Gradle Plugin sends .so files to app/build/intermediates/cxx,
# OUTSIDE the CMake .cxx ninja build tree. Derive this build's specific
# Gradle output directory from its CMake build hash, avoiding stale libraries.
$buildHash=(Split-Path (Split-Path $build -Parent) -Leaf)
$abi=(Split-Path $build -Leaf)
$gradleOut=Join-Path $PSScriptRoot ("app\build\intermediates\cxx\Debug\" + $buildHash + "\obj\" + $abi)
$expected=Join-Path $gradleOut 'libshaolin_game_link_probe.so'
if(-not (Test-Path -LiteralPath $expected -PathType Leaf)){
  # Gradle sometimes uses a different output root; read the CMake cache.
  $cache=Join-Path $build 'CMakeCache.txt'
  $cacheOutput=''
  if(Test-Path -LiteralPath $cache){
    foreach($line in (Get-Content -LiteralPath $cache)){
      if($line.StartsWith('CMAKE_LIBRARY_OUTPUT_DIRECTORY:PATH=')){
        $cacheOutput=$line.Substring('CMAKE_LIBRARY_OUTPUT_DIRECTORY:PATH='.Length)
        break
      }
    }
  }
  if($cacheOutput){
    $candidate=Join-Path $cacheOutput 'libshaolin_game_link_probe.so'
    if(Test-Path -LiteralPath $candidate -PathType Leaf){$expected=$candidate}
  }
}
if(-not (Test-Path -LiteralPath $expected -PathType Leaf)){
  throw "CMake link succeeded but the library could not be located. Checked: $expected. Please run: Get-ChildItem '.\android\app\build' -Filter 'libshaolin_game_link_probe.so' -Recurse"
}
$so=Get-Item -LiteralPath $expected
# Confirm this is an actual Android ARM64 ELF shared library, not just a
# successful link message. Do not load it or run Xbox guest code here.
$androidHome=if($env:ANDROID_HOME){$env:ANDROID_HOME}else{"$env:LOCALAPPDATA\Android\Sdk"}
$readelf=Join-Path $androidHome 'ndk\28.2.13676358\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-readelf.exe'
if(-not(Test-Path -LiteralPath $readelf)){throw "Cannot verify ELF; llvm-readelf not found: $readelf"}
$header=(& $readelf -h $so.FullName | Out-String)
if($LASTEXITCODE -ne 0 -or -not $header.Contains('AArch64') -or -not $header.Contains('DYN')){
  throw "The generated file is not a valid ARM64 shared ELF library: $($so.FullName)"
}
$sha256=(Get-FileHash -LiteralPath $so.FullName -Algorithm SHA256).Hash
$reportDir=Join-Path $root 'android-local\link'
New-Item -ItemType Directory -Path $reportDir -Force|Out-Null
$report=Join-Path $reportDir 'shaolin-game-native-link-summary.txt'
@(
 'Xbox Shaolin Monks native ARM64 link test completed'
 "File: $($so.FullName)"
 "Bytes: $($so.Length)"
 "SHA256: $sha256"
 "ELF: AArch64 / shared DYN"
 'No unresolved native link dependencies in this test library.'
 'This is not a running game: Xbox boot thread, missing kernel/XDK behavior,'
 'input/audio and the real game Vulkan renderer are not connected to the Android launcher.'
) | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host "SUCCESS: ARM64 native .so linked at $($so.FullName)" -ForegroundColor Green
Write-Host "Report: $report"
Write-Host 'IMPORTANT: Do not install this standalone .so as a game APK.'
