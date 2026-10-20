# Build the actual portable Xbox boot coordinator and file-system runtime.
# Black-mobiu uses kernel::Boot with these SDK sources. No fake stubs.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$buildRoot=Join-Path $PSScriptRoot 'app\.cxx\Debug'
$buildNinja=Get-ChildItem $buildRoot -Filter build.ninja -File -Recurse |
 Where-Object {$_.Directory.Name -eq 'arm64-v8a'} |
 Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(!$buildNinja){throw 'ARM64 CMake build missing'}
$build=$buildNinja.Directory.FullName
Write-Host 'Compiling portable Xbox kernel::Boot and filesystem (real SDK sources)...'
& cmake --build $build --target shaolin_xbox_boot_arm64 --parallel 2
if($LASTEXITCODE -ne 0){throw "Xbox Boot/Filesystem build failed ($LASTEXITCODE): send the first compiler error"}
$objects=@(Get-ChildItem $build -Recurse -Filter '*.o' -File |
  Where-Object {$_.FullName.Contains('shaolin_xbox_boot_arm64.dir')})
if($objects.Count -ne 2){throw "Expected 2 real boot objects; found $($objects.Count)"}
Write-Host 'SUCCESS: original Xbox boot and filesystem compile as Android ARM64 objects.' -ForegroundColor Green
Write-Host 'The boot thread is not yet wired to the SDL window/XDK Vulkan backend.'
