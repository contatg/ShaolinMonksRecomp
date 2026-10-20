# Diagnostico do proximo passo do port: simbolos ARM64 sem implementacao.
# Consome os 129 .o ja compilados; NAO recompila nem altera o launcher.
[CmdletBinding()]
param([int]$Top=100)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$debug=Join-Path $PSScriptRoot 'app\.cxx\Debug'
if(!(Test-Path $debug)){throw "Build ARM64 nao encontrado em $debug. Compile as 129 unidades primeiro."}
$build=Get-ChildItem $debug -Filter 'build.ninja' -File -Recurse |
    Where-Object { $_.Directory.Name -eq 'arm64-v8a' } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(!$build){throw 'Nao encontrei build.ninja da arquitetura arm64-v8a.'}
$objects=@(Get-ChildItem $build.DirectoryName -Filter '*.o' -File -Recurse |
    Where-Object {$_.FullName -like '*shaolin_guest_arm64*'})
if($objects.Count -lt 129){throw "Esperado >=129 objetos ARM64, encontrados: $($objects.Count)."}
$androidSdkHome=if($env:ANDROID_HOME){$env:ANDROID_HOME}else{"$env:LOCALAPPDATA\Android\Sdk"}
$llvm=Join-Path $androidSdkHome 'ndk\28.2.13676358\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-nm.exe'
if(!(Test-Path $llvm)){throw "llvm-nm nao encontrado: $llvm"}
$outDir=Join-Path $root 'android-local\diagnostico'
New-Item -ItemType Directory -Force -Path $outDir|Out-Null
$defined=New-Object 'System.Collections.Generic.HashSet[string]'
$undefined=New-Object 'System.Collections.Generic.HashSet[string]'
$counts=@{}
foreach($o in $objects){
    $symbols=& $llvm -g $o.FullName
    if($LASTEXITCODE -ne 0){throw "llvm-nm falhou em $($o.FullName)"}
    foreach($line in $symbols){
        if($line -match '^\s*(?:[0-9a-fA-F]+\s+)?([A-Za-z])\s+(\S+)'){
            $kind=$Matches[1];$name=$Matches[2]
            if($kind -eq 'U'){
                [void]$undefined.Add($name)
                if(!$counts.ContainsKey($name)){$counts[$name]=0}
                $counts[$name]++
            }elseif($kind -match '[A-TV-Z]'){
                [void]$defined.Add($name)
            }
        }
    }
}
$missing=@($undefined|Where-Object {-not $defined.Contains($_)}|Sort-Object)
$list=@($missing | ForEach-Object {
    [pscustomobject]@{Symbol=$_;References=$counts[$_]}
} | Sort-Object References -Descending)
$csv=Join-Path $outDir 'shaolin-symbols-unresolved.csv'
$list|Export-Csv -NoTypeInformation -Encoding UTF8 $csv
$txt=Join-Path $outDir 'shaolin-symbols-summary.txt'
@(
"SHAOLIN Android ARM64 - guest translations linkage audit"
"Objects: $($objects.Count)"
"Guest-defined symbols: $($defined.Count)"
"Guest-external symbols: $($undefined.Count)"
"Unresolved against guest-only objects: $($missing.Count)"
"These names may be provided by kernel/XDK, platform, C++ runtime, or mods."
"Some are expected to be strong host overrides; this is not a linker failure."
"Next host sources: runtime/cpu/dispatch.cpp, runtime/kernel/{boot,threads,xboxkrnl,files}.cpp"
"Game-host sources: adapted/{boot,d3d8,xapi,dsound,files}.cpp; src/linux/vk/"
""
"Most frequently referenced guest-external symbols:"
) + @($list | Select-Object -First $Top | ForEach-Object {"$($_.References) $($_.Symbol)"}) |
    Set-Content -LiteralPath $txt -Encoding UTF8
Write-Host "Diagnosticados $($objects.Count) objetos ARM64 sem recompilar."
Write-Host "Simbolos externos pendentes: $($missing.Count)"
Write-Host "Relatorio: $txt"
Write-Host "Planilha: $csv"
Get-Content $txt | Select-Object -Last ([Math]::Min($Top,20))
