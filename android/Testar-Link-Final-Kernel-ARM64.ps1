# Probe all real Xbox kernel+boot objects against Android C++/system libs.
# This creates a separate diagnostic .so; it does not change the working APK.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$fullDir=Join-Path $root 'android-local\full-kernel'
$obj=Join-Path $fullDir 'shaolin-guest-actual-kernel-arm64.o'
if(-not(Test-Path -LiteralPath $obj)){throw 'Run Ligar-Kernel-Completo-ARM64.ps1 first.'}
$ndk=Join-Path $env:LOCALAPPDATA 'Android\Sdk\ndk\28.2.13676358\toolchains\llvm\prebuilt\windows-x86_64\bin'
$clang=Join-Path $ndk 'clang++.exe'
$nm=Join-Path $ndk 'llvm-nm.exe'
if(!(Test-Path $clang)){throw "NDK clang++ not found: $clang"}
$so=Join-Path $fullDir 'libshaolin_kernel_final_probe.so'
$log=Join-Path $fullDir 'final-link-errors.txt'
$argsArray=@('--target=aarch64-linux-android24','-shared','-fPIC',
 '-Wl,--no-undefined','-Wl,-z,max-page-size=16384',
 '-o', $so, $obj, '-llog','-landroid','-lm','-ldl')
Write-Host 'Testing final Android linker on genuine 176-object Xbox kernel/boot bundle...'
# Use the NDK clang++ driver, so libc++ and Android platform symbols are
# resolved correctly. Capture native stdout/stderr without aborting PS5.
$old=$ErrorActionPreference
try{
 $ErrorActionPreference='Continue'
 & $clang @argsArray 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $log
 $code=$LASTEXITCODE
}finally{$ErrorActionPreference=$old}
if($code -ne 0){
 Write-Host 'Expected: final link exposed missing implementation dependencies.' -ForegroundColor Yellow
 Write-Host "All linker diagnostics: $log"
 Get-Content -LiteralPath $log | Select-Object -First 45
 Write-Host 'This diagnostic does NOT alter the APK.'
 exit 2
}
if(!(Test-Path -LiteralPath $so)){throw 'Link reported success but produced no shared library.'}
Write-Host "SUCCESS: complete Xbox kernel bundle linked to real ARM64 Android .so: $so" -ForegroundColor Green
Write-Host 'Gameplay still requires valid game data mounting, XDK renderer and audio.'
