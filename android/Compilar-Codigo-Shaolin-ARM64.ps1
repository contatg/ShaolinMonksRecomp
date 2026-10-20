# Prepare the original Shaolin Monks XBE and compile the 128 recompiled
# translation units as Android ARM64 object files in a *local private* build.
# This does NOT yet link a playable Android Xbox kernel / game renderer.
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\android\Compilar-Codigo-Shaolin-ARM64.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\android\Compilar-Codigo-Shaolin-ARM64.ps1 -Xbe "C:\path\default.xbe"
[CmdletBinding()]
param(
    [string]$Xbe = "",
    [ValidateRange(1, 8)][int]$Jobs = 2,
    [string]$Llvm = "C:\Program Files\LLVM"
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$android = Join-Path $root 'android'
$requiredHash = '48240902bf4a04eb89376217c529531032d3370749bcce91a194878cc49db74a'
$logRoot = Join-Path $root 'android-local\logs'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$log = Join-Path $logRoot 'shaolin-arm64-build.log'
$logStart = (Get-Date).ToUniversalTime().ToString('o')
"Android ARM64 private translation build started $logStart" | Set-Content -LiteralPath $log
function Say([string]$message) { Write-Host $message; Add-Content -LiteralPath $log -Value $message }
function Need([string]$tool) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $tool"
    }
}
function Invoke-Logged([string]$label, [string]$exe, [string[]]$arguments) {
    Say ("RUN: " + $label)
    & $exe @arguments 2>&1 | Tee-Object -FilePath $log -Append
    if ($LASTEXITCODE -ne 0) {
        throw "$label failed (exit $LASTEXITCODE). See $log"
    }
}
try {
    foreach ($tool in @('git', 'python', 'cmake')) { Need $tool }

    # User might have saved their uploaded file as default(2).xbe.
    if ([string]::IsNullOrWhiteSpace($Xbe)) {
        $choices = @(
            "$env:USERPROFILE\Downloads\default(2).xbe",
            "$env:USERPROFILE\Downloads\default.xbe",
            "$env:USERPROFILE\Downloads\default(1).xbe"
        )
        $found = $false
        foreach ($candidate in $choices) {
            if (-not (Test-Path -LiteralPath $candidate)) { continue }
            $sha = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($sha -eq $requiredHash) { $Xbe = $candidate; $found = $true; break }
        }
        if (-not $found) {
            throw "Compatible default.xbe not found under Downloads. Use -Xbe 'FULL_PATH_TO_XBE'. Required SHA256: $requiredHash"
        }
    }
    $xbeFile = (Resolve-Path -LiteralPath $Xbe).Path
    $hash = (Get-FileHash -LiteralPath $xbeFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $requiredHash) { throw "Wrong Xbox executable ($hash). Expected $requiredHash." }
    Say "Compatible Shaolin Monks original Xbox executable SHA256 verified."

    $androidHome = if ($env:ANDROID_HOME) { $env:ANDROID_HOME }
        elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT }
        else { "$env:LOCALAPPDATA\Android\Sdk" }
    $env:ANDROID_HOME = $androidHome
    $env:ANDROID_SDK_ROOT = $androidHome
    $ndkInstalled = Test-Path (Join-Path $androidHome 'ndk\28.2.13676358')
    $cmakeInstalled = Test-Path (Join-Path $androidHome 'cmake\3.31.6')
    $platformInstalled = Test-Path (Join-Path $androidHome 'platforms\android-34')
    if (-not ($ndkInstalled -and $cmakeInstalled -and $platformInstalled)) {
        $toolsDir = Join-Path $androidHome 'cmdline-tools'
        $sdkManagers = @(Get-ChildItem -Path $toolsDir -Filter 'sdkmanager.bat' -Recurse -File -ErrorAction SilentlyContinue)
        if (-not $sdkManagers.Count) {
            throw "Android SDK components missing and sdkmanager.bat not found in $toolsDir. Install Android SDK Command-line Tools from Android Studio."
        }
        Say "Installing missing Android SDK 34, NDK 28.2.13676358 and CMake 3.31.6..."
        Invoke-Logged 'Android SDK install' $sdkManagers[0].FullName @('--install',
            'platforms;android-34','ndk;28.2.13676358','cmake;3.31.6')
        if (-not (Test-Path (Join-Path $androidHome 'ndk\28.2.13676358')) -or
            -not (Test-Path (Join-Path $androidHome 'cmake\3.31.6'))) {
            throw "SDK components remain missing. Accept Android SDK licenses in Android Studio and retry."
        }
    }
    Need java
    if (-not (Test-Path (Join-Path $Llvm 'bin\clang++.exe'))) {
        throw "LLVM is missing from $Llvm. Supply -Llvm 'C:\Program Files\LLVM'."
    }

    # Do not require an administrator or a global Gradle installation.
    $gradle = Get-Command gradle.bat -ErrorAction SilentlyContinue
    if (-not $gradle) {
        $gradleHome = Join-Path $root 'android-local\gradle-8.7'
        $gradleExe = Join-Path $gradleHome 'bin\gradle.bat'
        if (-not (Test-Path $gradleExe)) {
            $zip = Join-Path $root 'android-local\gradle-8.7-bin.zip'
            Say 'Downloading official Gradle 8.7 distribution (one-time).'
            Invoke-WebRequest -Uri 'https://services.gradle.org/distributions/gradle-8.7-bin.zip' -OutFile $zip -ErrorAction Stop
            Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $root 'android-local') -Force
        }
        if (-not (Test-Path $gradleExe)) { throw 'Gradle 8.7 could not be installed.' }
        $gradleCommand = $gradleExe
    } else { $gradleCommand = $gradle.Source }

    Say '[1/3] Generating private original Xbox C++ translation...'
    $prepare = Join-Path $android 'Preparar-XBE-Android.ps1'
    Invoke-Logged 'XboxXBERecomp' 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass',
        '-File',$prepare,'-Xbe',$xbeFile,'-Llvm',$Llvm,'-Jobs',([string]$Jobs))

    # Give the Android build access to exactly the pinned SDK; a junction
    # avoids downloading a second SDK and works without admin privileges.
    $sdkSource = Join-Path $root 'third_party\XboxXBERecomp'
    $sdkAndroid = Join-Path $android 'third_party\XboxXBERecomp'
    if (-not (Test-Path (Join-Path $sdkSource 'runtime\kernel\disc.cpp'))) {
        throw 'Host recompiler SDK checkout was not created.'
    }
    if (-not (Test-Path (Join-Path $sdkAndroid 'runtime\kernel\disc.cpp'))) {
        if (Test-Path -LiteralPath $sdkAndroid) {
            throw "Incomplete Android SDK folder exists at $sdkAndroid; inspect it before retrying."
        }
        New-Item -ItemType Directory -Force -Path (Split-Path $sdkAndroid -Parent) | Out-Null
        New-Item -ItemType Junction -Path $sdkAndroid -Target $sdkSource | Out-Null
    }

    Say '[2/3] Configuring Android NDK and the 128 real C++ translations...'
    Push-Location $android
    try {
        Invoke-Logged 'Gradle Android configure' $gradleCommand @('--no-daemon',
            '-PshaolinGuestObjects=true','assembleDebug','--stacktrace')
    } finally { Pop-Location }

    Say '[3/3] Compiling Xbox guest-code translation units for ARM64...'
    $buildRoot = Join-Path $android 'app\.cxx\Debug'
    if (-not (Test-Path $buildRoot)) { throw 'CMake ARM64 build directory missing.' }
    $buildDirs = @(Get-ChildItem -Path $buildRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'arm64-v8a' -and
                       (Test-Path (Join-Path $_.FullName 'build.ninja')) } |
        Sort-Object LastWriteTime -Descending)
    if (-not $buildDirs.Count) { throw 'No valid Android ARM64 CMake build.ninja was generated.' }
    $build = $buildDirs[0].FullName
    Invoke-Logged 'Compile 128 guest partitions' 'cmake' @('--build',$build,'--target',
        'shaolin_guest_arm64','--parallel',([string]$Jobs))

    $objects = @(Get-ChildItem -Path $build -Recurse -File -Filter '*.o' |
        Where-Object { $_.FullName -like '*shaolin_guest_arm64*' })
    Say "ARM64 game translation object count: $($objects.Count)"
    if ($objects.Count -lt 129) {
        throw "Only $($objects.Count) of at least 129 required objects were built."
    }
    Say "SUCCESS: Xbox executable translated and ARM64 objects compiled locally at $build"
    Say "The Android executable still requires the Xbox kernel, XDK and Vulkan renderer integration. Do not ship it as playable."
} catch {
    Say ("ERROR: " + $_.Exception.Message)
    Write-Host "Share only the compiler error lines from $log; never upload the original Xbox executable."
    throw
}
