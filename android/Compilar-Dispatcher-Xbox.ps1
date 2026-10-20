# Compiles only the portable Xbox CPU dispatcher, reusing all 129 existing
# ARM64 guest object files. Keeps game source locally generated and private.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildRoot = Join-Path $PSScriptRoot 'app\.cxx\Debug'
$builds = @(Get-ChildItem $buildRoot -Filter 'build.ninja' -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq 'arm64-v8a' } |
    Sort-Object LastWriteTime -Descending)
if (-not $builds.Count) { throw "Android ARM64 Ninja build not found: $buildRoot" }
$build = $builds[0].Directory.FullName
$generated = Join-Path $PSScriptRoot 'generated\shaolin\x86_func_mapping.cpp'
if (-not (Test-Path $generated)) { throw 'Private original Xbox translation is missing. Do not delete android/generated.' }
Write-Host '[1/2] Configuring Android CPU dispatcher from pinned Xbox runtime...'
# A changed CMake file is picked up automatically by Ninja; rebuild only one
# CPU translation unit. No Java, Vulkan or 128 partitions are rebuilt.
& cmake --build $build --target shaolin_dispatch_arm64 --parallel 2
if ($LASTEXITCODE -ne 0) { throw "Dispatcher ARM64 compile failed ($LASTEXITCODE)" }
$objects = @(Get-ChildItem $build -Recurse -File -Filter '*.o' |
    Where-Object { $_.FullName -like '*shaolin_dispatch_arm64*' })
if (-not $objects.Count) { throw 'No ARM64 dispatcher object produced.' }
$androidSdkHome = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
$nm = Join-Path $androidSdkHome 'ndk\28.2.13676358\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-nm.exe'
if (-not (Test-Path $nm)) { throw "llvm-nm.exe not found: $nm" }
$reportDir = Join-Path $root 'android-local\diagnostico'
New-Item -ItemType Directory -Force $reportDir | Out-Null
$report = Join-Path $reportDir 'shaolin-dispatcher-symbols.txt'
& $nm -g $objects[0].FullName | Out-File $report -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the ARM64 dispatcher symbols.' }
$symbols = Get-Content $report
$check = @('x86_kernel','x86_rdtsc','x86_priv','x86_cpuid','x86_icall','x86_trap')
Write-Host '[2/2] Checking guest CPU dispatch entry points:'
$missing = @()
# Check demangled signatures, not C++ Itanium symbol encodings.
# x86_kernel -> _Z10x86_kernel..., x86_rdtsc -> _Z9x86_rdtscv,
# and llvm-nm prints symbol type T, W or sometimes t.
foreach ($name in $check) {
    $match = @($symbols | Where-Object {
        $_ -match ('\\s[TWt]\\s+_Z[0-9]+' + [regex]::Escape($name) + '(?:[^A-Za-z_]|$)')
    })
    if ($match.Count) { Write-Host "  OK $name" -ForegroundColor Green }
    else { Write-Host "  NOT FOUND $name" -ForegroundColor Yellow; $missing += $name }
}
Write-Host "ARM64 dispatcher: $($objects[0].FullName)"
Write-Host "Symbols report: $report"
if ($missing.Count) {
    Write-Warning 'Some symbols were not recognized. Send the symbol report for an exact diagnostic.'
} else {
    Write-Host 'Portable Xbox CPU dispatcher compiled and its entry points verified.' -ForegroundColor Green
}
Write-Host 'This is not a game boot: kernel, XDK, audio, graphics and disk mounting still need integration.'
