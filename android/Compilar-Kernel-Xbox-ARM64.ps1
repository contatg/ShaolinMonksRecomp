# Build genuine Xbox kernel services for Android ARM64; no fake stubs.
# Does not overwrite the working launcher or claim playable gameplay.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildRoot=Join-Path $PSScriptRoot 'app\.cxx\Debug'
$buildNinja=Get-ChildItem $buildRoot -Filter 'build.ninja' -File -Recurse |
  Where-Object {$_.Directory.Name -eq 'arm64-v8a'} |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(!$buildNinja){throw 'Android ARM64 CMake build.ninja missing. Run the existing private APK build first.'}
$build=$buildNinja.Directory.FullName
Write-Host 'Compiling REAL Xbox 5849 kernel services: objects, threads, RTL, xboxkrnl...'
& cmake --build $build --target shaolin_xbox_kernel_arm64 --parallel 2
if($LASTEXITCODE -ne 0){throw "Xbox kernel ARM64 source build failed ($LASTEXITCODE). Send the FIRST compiler error."}
$objs=@(Get-ChildItem $build -Recurse -File -Filter '*.o' |
  Where-Object {$_.FullName.Contains('shaolin_xbox_kernel_arm64.dir')})
if($objs.Count -ne 5){throw "Xbox kernel build returned success but found $($objs.Count)/5 objects."}
$dir=Join-Path $root 'android-local\kernel'
New-Item -ItemType Directory -Force $dir|Out-Null
$nm=Join-Path $env:LOCALAPPDATA 'Android\Sdk\ndk\28.2.13676358\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-nm.exe'
if(!(Test-Path $nm)){throw "NDK llvm-nm missing: $nm"}
$report=Join-Path $dir 'xbox-kernel-exported-functions.txt'
$lines=@()
foreach($obj in $objs){$lines+=& $nm --defined-only --demangle $obj.FullName}
$lines|Set-Content -Encoding UTF8 -LiteralPath $report
Write-Host 'SUCCESS: five genuine ARM64 Xbox kernel service source files compiled.' -ForegroundColor Green
Write-Host "Symbols: $report"
Write-Host 'NEXT: link kernel registration and file system into APK, then port Xbox graphics/audio.'
