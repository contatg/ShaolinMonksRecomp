# Real relocatable ARM64 link of private Xbox game-code objects + CPU dispatcher.
# Does not change launcher, package executable into APK, or claim gameplay.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildRoot=Join-Path $PSScriptRoot 'app\.cxx\Debug'
$buildNinja=Get-ChildItem $buildRoot -Filter 'build.ninja' -File -Recurse -ErrorAction Stop |
  Where-Object {$_.Directory.Name -eq 'arm64-v8a'} |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(!$buildNinja){throw 'ARM64 build directory missing'}
$build=$buildNinja.Directory.FullName
$guest=@(Get-ChildItem $build -Filter '*.o' -Recurse -File |
  Where-Object {$_.FullName -like '*shaolin_guest_arm64*'} |
  Sort-Object FullName)
$dispatch=@(Get-ChildItem $build -Filter '*.o' -Recurse -File |
  Where-Object {$_.FullName -like '*shaolin_dispatch_arm64*'})
if($guest.Count -lt 129 -or $dispatch.Count -ne 1){
  throw "Missing compiled input: guest=$($guest.Count) dispatcher=$($dispatch.Count)."
}
$androidHome=if($env:ANDROID_HOME){$env:ANDROID_HOME}else{"$env:LOCALAPPDATA\Android\Sdk"}
$bin=Join-Path $androidHome 'ndk\28.2.13676358\toolchains\llvm\prebuilt\windows-x86_64\bin'
$ld=Join-Path $bin 'ld.lld.exe'
$nm=Join-Path $bin 'llvm-nm.exe'
if(!(Test-Path $ld) -or !(Test-Path $nm)){throw "NDK linker or nm is missing under $bin"}
$out=Join-Path $root 'android-local\link'
New-Item -ItemType Directory -Force $out | Out-Null
$combined=Join-Path $out 'shaolin-guest-dispatch-kernel-arm64.o'
# Existing libmain.so preboot already compiles the pinned real memory and log
# implementation. Reuse those objects for a private relocatable Xbox link.
# Do not substitute dummy functions: we need working memory and logging.
$hostObjects=@()
# CMake emits object paths with a drive prefix (e.g. C_/dev/...),
# so filter by the final filename and verify via llvm-nm rather than
# assuming a particular directory nesting such as CMakeFiles/main.dir.
foreach($file in @('memory.cpp.o','log.cpp.o')){
  $candidates=@(Get-ChildItem $build -Filter $file -File -Recurse)
  $match=@($candidates | Where-Object {
    $_.FullName.Contains('main.dir') -and $_.FullName.Contains('XboxXBERecomp')
  })
  if($match.Count -ne 1){
    Write-Host "Found $($candidates.Count) objects named $file; matching main+SDK: $($match.Count)"
    $candidates | ForEach-Object { Write-Host $_.FullName }
    throw "Cannot unambiguously select real SDK host object $file. Please send the paths printed above."
  }
  $hostObjects += $match[0].FullName
}
# Compile only the real Xbox symbol glue (two translation units).
Write-Host 'Building genuine Xbox ordinal lookup and guest-memory binding...'
& cmake --build $build --target shaolin_kernel_symbols_arm64 --parallel 2
if($LASTEXITCODE -ne 0){throw "Kernel symbol compilation failed ($LASTEXITCODE)"}
$kernelSymbols=@(Get-ChildItem $build -Filter '*.o' -Recurse -File |
  Where-Object {$_.FullName.Contains('shaolin_kernel_symbols_arm64.dir')})
if($kernelSymbols.Count -ne 2){
  throw "Expected two Xbox kernel symbol objects, found $($kernelSymbols.Count)."
}
$inputs=@($guest | ForEach-Object {$_.FullName}) + @($dispatch[0].FullName) + $hostObjects +
  @($kernelSymbols | ForEach-Object {$_.FullName})
# Passing inputs via response-file prevents Windows' 32KiB cmd-line limit.
$responseFile=Join-Path $out 'link-inputs.rsp'
$lines=@('-r','-o',('"'+$combined+'"')) + @($inputs|ForEach-Object{'"'+$_+'"'})
[System.IO.File]::WriteAllLines($responseFile,$lines,[System.Text.UTF8Encoding]::new($false))
Write-Host "Linking $($guest.Count) guest objects + dispatcher + memory/log + Xbox ordinals/base (relocatable ARM64)..."
& $ld ('@'+$responseFile)
if($LASTEXITCODE -ne 0){throw "ARM64 ld.lld -r failed (exit $LASTEXITCODE)"}
$defined=Join-Path $out 'shaolin-linked-defined.txt'
$missing=Join-Path $out 'shaolin-linked-undefined.txt'
& $nm --defined-only --demangle $combined | Set-Content -Encoding UTF8 $defined
if($LASTEXITCODE -ne 0){throw 'Could not inspect defined symbols'}
& $nm --undefined-only --demangle $combined | Set-Content -Encoding UTF8 $missing
if($LASTEXITCODE -ne 0){throw 'Could not inspect undefined symbols'}
$definedText=Get-Content $defined
$names=@('x86_kernel','x86_rdtsc','x86_priv','x86_cpuid','x86_icall','x86_trap')
foreach($name in $names){
  if(@($definedText|Where-Object{$_.Contains(' '+$name+'(')}).Count -gt 0){
    Write-Host "RESOLVED $name" -ForegroundColor Green
  } else { Write-Warning "Dispatcher function not found in combined object: $name" }
}
$remaining=@(Get-Content $missing | Sort-Object -Unique)
Write-Host "Linked ARM64 object: $combined"
Write-Host "Still undefined symbols: $($remaining.Count)"`nWrite-Host 'Kernel memory/log and ordinal lookup/base compiled; actual boot/XDK and Krypt routine engine are still missing.'
Write-Host "Report: $missing"
Write-Host "First unresolved symbols:"
$remaining | Select-Object -First 40
Write-Host 'This is a genuine partial link, NOT a runnable APK. Kernel/XDK and Vulkan integration remain.'
