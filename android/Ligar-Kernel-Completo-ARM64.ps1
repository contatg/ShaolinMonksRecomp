# Combine Xbox game functions with the actual kernel and boot implementation.
# This is a relocatable link, not a playable APK. Do not include the
# preboot-only shaolin_kernel_bindings.cpp: boot.cpp owns kernel::g_base.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$buildRoot=Join-Path $PSScriptRoot 'app\.cxx\Debug'
$buildNinja=Get-ChildItem $buildRoot -Filter build.ninja -File -Recurse |
 Where-Object { $_.Directory.Name -eq 'arm64-v8a' } |
 Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(!$buildNinja){ throw 'Missing Android ARM64 build.ninja' }
$build=$buildNinja.Directory.FullName
foreach($target in @('shaolin_xbox_kernel_arm64','shaolin_xbox_boot_arm64','shaolin_krypt_routines_arm64','shaolin_guest_arm64','shaolin_dispatch_arm64','shaolin_kernel_symbols_arm64','shaolin_android_boot_host_arm64','main')){
 Write-Host "Building existing target: $target"
 & cmake --build $build --target $target --parallel 2
 if($LASTEXITCODE -ne 0){ throw "Compilation failed at $target ($LASTEXITCODE)" }
}
$all=@(Get-ChildItem $build -Filter '*.o' -File -Recurse)
$targets=@(
  @('shaolin_guest_arm64.dir',129),
  @('shaolin_dispatch_arm64.dir',1),
  @('shaolin_krypt_routines_arm64.dir',30),
  @('shaolin_xbox_kernel_arm64.dir',5),
  @('shaolin_xbox_boot_arm64.dir',2),
  @('shaolin_android_boot_host_arm64.dir',1)
)
$inputs=@()
foreach($pair in $targets){
 $part=@($all | Where-Object { $_.FullName.Contains($pair[0]) })
 if($part.Count -lt [int]$pair[1]){throw "Missing $($pair[0]): $($part.Count) compiled objects"}
 $inputs+=@($part | ForEach-Object { $_.FullName })
}
# Choose the real ordinal translation unit, NOT the preboot binding
# module, because the real boot defines kernel::g_base itself.
$ordinal=@($all | Where-Object {
 $_.FullName.Contains('shaolin_kernel_symbols_arm64.dir') -and $_.Name -eq 'ordinals.cpp.o'
})
if($ordinal.Count -ne 1){throw "Expected one SDK kernel ordinals object, got $($ordinal.Count)"}
$inputs+=$ordinal[0].FullName
foreach($name in @('memory.cpp.o','log.cpp.o','disc.cpp.o')){
 $found=@($all | Where-Object {
   $_.FullName.Contains('main.dir') -and $_.FullName.Contains('XboxXBERecomp') -and $_.Name -eq $name
 })
 if($found.Count -ne 1){throw "Expected one SDK main object $name, got $($found.Count)"}
 $inputs+=$found[0].FullName
}
$ndk=Join-Path $env:LOCALAPPDATA 'Android\Sdk\ndk\28.2.13676358\toolchains\llvm\prebuilt\windows-x86_64\bin'
$ld=Join-Path $ndk 'ld.lld.exe'
$nm=Join-Path $ndk 'llvm-nm.exe'
if(!(Test-Path $ld) -or !(Test-Path $nm)){throw "NDK llvm linker tools missing"}
$out=Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'android-local\full-kernel'
New-Item -ItemType Directory -Force $out|Out-Null
$targetFile=Join-Path $out 'shaolin-guest-actual-kernel-arm64.o'
$parameters=Join-Path $out 'link-inputs.rsp'
$lines=@('-r','-o',('"' + $targetFile + '"'))+@($inputs|ForEach-Object {'"' + $_ + '"'})
[System.IO.File]::WriteAllLines($parameters,$lines,[System.Text.UTF8Encoding]::new($false))
Write-Host "Relocatable-linking $($inputs.Count) REAL ARM64 objects (Xbox guest + kernel + boot)..."
& $ld ('@'+$parameters)
if($LASTEXITCODE -ne 0){throw "ld.lld cannot combine Xbox guest and boot ($LASTEXITCODE). Send the FIRST duplicate-symbol error."}
$missing=Join-Path $out 'undefined-all.txt'
& $nm --undefined-only --demangle $targetFile | Set-Content -LiteralPath $missing -Encoding UTF8
if($LASTEXITCODE -ne 0){throw 'llvm-nm failed'}
$rows=@(Get-Content -LiteralPath $missing)
$missingHostServices=@($rows|Where-Object {
 $_ -match ' U (app::|gpu::|input::|xnet::|kernel::|shaolin::|audio::|snd::|d3d::|logx::|diag::|X86|sub_|x86_)'
}|Sort-Object -Unique)
$hostReport=Join-Path $out 'missing-host-xdk.txt'
$missingHostServices|Set-Content -LiteralPath $hostReport -Encoding UTF8
Write-Host "REAL Xbox kernel + game combined successfully." -ForegroundColor Green
Write-Host "External symbols remaining (includes Android standard libraries): $($rows.Count)"
Write-Host "Missing Xbox/game host services: $($missingHostServices.Count)"
Write-Host "Full report: $missing"
Write-Host "Host XDK report: $hostReport"
$missingHostServices|Select-Object -First 55
Write-Host 'This test deliberately does not boot the Xbox thread or modify the working APK.'
