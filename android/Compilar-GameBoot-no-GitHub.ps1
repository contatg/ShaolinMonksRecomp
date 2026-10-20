# Upload ONLY privately generated C++ from the user's own original XBE
# to a new PRIVATE GitHub repository, configure restricted Actions secrets,
# and trigger a real native ARM64 GameBoot workflow in GitHub Actions.
# No ISO, default.xbe, original assets or unencrypted game APK are uploaded.
# Requires GitHub CLI (gh), Git, and an authenticated GitHub account.
[CmdletBinding()]
param(
    [string]$PrivateRepo = 'contatg/ShaolinMonks-PrivateSources',
    [string]$PublicRepo = 'contatg/ShaolinMonksRecomp'
)
$ErrorActionPreference = 'Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$gen=Join-Path $PSScriptRoot 'generated\shaolin'
if(!(Get-Command gh -ErrorAction SilentlyContinue)){
    throw 'GitHub CLI missing. Install using: winget install --id GitHub.cli -e'
}
if(!(Get-Command git -ErrorAction SilentlyContinue)){
    throw 'Git is required. Install Git for Windows first.'
}
& gh auth status
if($LASTEXITCODE -ne 0){throw 'Log in first: gh auth login'}
$needed=@('x86_func_mapping.cpp','x86_recomp_shared.h','image_symbols.h','mod_routine_targets.h')
$needed+=0..127 | ForEach-Object { "x86_recomp.$_.cpp" }
foreach($file in $needed){
    if(!(Test-Path -LiteralPath (Join-Path $gen $file) -PathType Leaf)){
        throw "Missing private translation: $file. Prepare it from your OWN XBE on this PC."
    }
}
Write-Host "Verified all $($needed.Count) private generated source files (NO ISO/XBE)."
Write-Host 'The next action uploads generated game-derived C++ to a PRIVATE GitHub repo.'
$confirm=Read-Host "Type PRIVADO to authorize this private upload"
if($confirm -cne 'PRIVADO'){throw 'Private upload cancelled.'}

# Use a separate private repo. Never put commercial game translation in the
# public ShaolinMonksRecomp repository, its workflow caches, or its releases.
$privateInfo=@(& gh repo view $PrivateRepo --json isPrivate -q '.isPrivate' 2>$null)
$exists=$LASTEXITCODE -eq 0
if(!$exists){
    Write-Host "Creating separate PRIVATE repository: $PrivateRepo"
    & gh repo create $PrivateRepo --private --description 'Private locally derived Shaolin translation for personal GameBoot builds'
    if($LASTEXITCODE -ne 0){throw 'Cannot create private source repository'}
} elseif(($privateInfo -join '').Trim() -ne 'true'){
    throw "Refusing to upload generated commercial game code: $PrivateRepo is NOT private."
}
$work=Join-Path $root 'android-local\github-private-sources'
if(Test-Path -LiteralPath $work) {
    if(!(Test-Path -LiteralPath (Join-Path $work '.git'))){
        throw "Existing $work is not a Git repository. Move it out of the way first."
    }
    & git -C $work remote -v | Out-Host
    $origin=(& git -C $work remote get-url origin)
    if($LASTEXITCODE -ne 0 -or $origin -notmatch [regex]::Escape(($PrivateRepo -split '/')[1])){
        throw "Existing private checkout remote does not match $PrivateRepo."
    }
    & git -C $work pull --ff-only
    if($LASTEXITCODE -ne 0){throw 'Private checkout has conflicts or cannot pull'}
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $work -Parent) | Out-Null
    & gh repo clone $PrivateRepo $work
    if($LASTEXITCODE -ne 0){throw 'Could not clone separate private source repository'}
}
# Preserve generated names and never copy any commercial disc image, XBE,
# game audio, texture or other files from outside the generated source list.
foreach($file in $needed){
    Copy-Item -LiteralPath (Join-Path $gen $file) -Destination (Join-Path $work $file) -Force
}
& git -C $work add -- @($needed)
if($LASTEXITCODE -ne 0){throw 'Could not stage private generated code'}
& git -C $work diff --cached --quiet
if($LASTEXITCODE -eq 1){
    & git -C $work commit -m 'Update personal generated ARM64 Xbox translation'
    if($LASTEXITCODE -ne 0){throw 'Could not commit private source code'}
    & git -C $work push -u origin HEAD
    if($LASTEXITCODE -ne 0){throw 'Could not push private source code'}
} elseif($LASTEXITCODE -ne 0){
    throw 'Unable to check staged changes'
} else {
    Write-Host 'Private sources are already current.'
}
$privateInfo=@(& gh repo view $PrivateRepo --json isPrivate -q '.isPrivate')
if($LASTEXITCODE -ne 0 -or ($privateInfo -join '').Trim() -ne 'true'){
    throw 'Private repo verification failed; stopping before GitHub Actions secrets.'
}

# Fine-grained PAT: only Contents:read on the private source repo.
# It is entered through a hidden PowerShell prompt; avoid gh command args.
Write-Host 'Provide a fine-grained GitHub token with ONLY Contents: Read on the separate PRIVATE source repo.'
Write-Host 'This token will be stored as an Actions secret in your public port repo.'
$secure=Read-Host 'Fine-grained private-repo read-only token' -AsSecureString
$bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $token=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    if([string]::IsNullOrWhiteSpace($token)){throw 'No private source token supplied'}
    $token | & gh secret set SHAOLIN_PRIVATE_SOURCES_TOKEN --repo $PublicRepo
    if($LASTEXITCODE -ne 0){throw 'Failed to register private read-only source token'}
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    Remove-Variable token -ErrorAction SilentlyContinue
}
$PrivateRepo | & gh secret set SHAOLIN_PRIVATE_SOURCES_REPO --repo $PublicRepo
if($LASTEXITCODE -ne 0){throw 'Could not register private source repository name'}
# 32 random bytes, generated on YOUR PC only and saved under android-local
# (gitignored). Actions uploads an AES256 encrypted archive, never raw APK.
$keyFile=Join-Path $root 'android-local\github-gameboot-archive-password.txt'
if(Test-Path -LiteralPath $keyFile){
    $pass=[IO.File]::ReadAllText($keyFile).Trim()
} else {
    $random=New-Object byte[] 32
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($random) } finally { $rng.Dispose() }
    $pass=[Convert]::ToBase64String($random)
    [IO.File]::WriteAllText($keyFile,$pass,[Text.UTF8Encoding]::new($false))
}
$pass | & gh secret set SHAOLIN_APK_ARCHIVE_PASSWORD --repo $PublicRepo
if($LASTEXITCODE -ne 0){throw 'Could not save encrypted APK password as GitHub secret'}
& gh workflow run android-private-gameboot.yml --repo $PublicRepo --ref android-arm64-bringup
if($LASTEXITCODE -ne 0){throw 'Unable to dispatch full private ARM64 GameBoot workflow'}
Write-Host ''
Write-Host 'PRIVATE GAMEBOOT CLOUD BUILD TRIGGERED!' -ForegroundColor Green
Write-Host "View progress: https://github.com/$PublicRepo/actions/workflows/android-private-gameboot.yml"
Write-Host "AES-256 archive password saved LOCALLY: $keyFile"
Write-Host 'Download encrypted APK artifact after success; decrypt with 7-Zip using your local password.'
