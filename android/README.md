# Shaolin Mobiu — Android ARM64 bringup

The Android project builds a native SDL3/Vulkan **presentation smoke test** for ARM64.
The displayed full-screen color should animate in purple. Touch the screen or
press a gamepad button to switch to orange. The app draws into a real Vulkan
swapchain and presents the images. Vulkan startup and rendering still need
confirmation on physical devices.

**This APK does not execute Mortal Kombat: Shaolin Monks.**
The original Xbox runtime, recompiled game code and game-specific graphics
backend are not linked yet. Do not describe this build as playable.

## Build the Android Vulkan test

Run the GitHub Actions workflow
[`Android ARM64 Vulkan bringup`](../.github/workflows/android-arm64-bringup.yml)
on the `android-arm64-bringup` branch, or build in `android/` with Gradle 8.7.
Requirements: Android SDK 34, NDK 28.2.13676358, CMake 3.31.6 and JDK 17.
The workflow produces an artifact named `Shaolin-Mobiu-Vulkan-Test-ARM64`.

Android logs:
```sh
adb logcat -s ShaolinMobiu
```

## Prepare game recompilation locally on Windows

Use the original **USA/Europe Xbox** `default.xbe` from your own copy of
Shaolin Monks. SHA-256 must be
`48240902bf4a04eb89376217c529531032d3370749bcce91a194878cc49db74a`.

Install Git, Python, CMake, LLVM/Clang, Visual Studio C++ build tools and Ninja.
In PowerShell at the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\android\Preparar-XBE-Android.ps1 -Xbe "C:\Games\Shaolin\default.xbe"
```

This script uses the pinned XboxXBERecomp checkout, configures the PC toolchain,
executes the host recompiler and stages **128 generated C++ partitions** plus
the mapping and support headers in `android/generated/shaolin/`. The output
is deliberately excluded from Git. **It is not linked to the current APK.**
The game executable, its translations, ISO and assets must not be added to the
public repository, release archives or CI artifacts.

## Remaining work for a playable native Android port

1. Adapt the XboxXBERecomp runtime and recompiled function dispatch to ARM64.
2. Compile and link the privately generated game translation with the ARM64 runtime.
3. Adapt the existing game-specific Vulkan backend to the Android display lifecycle,
   including the image/surface caches, shader translation and frame presentation.
4. Wire game-file selection, storage, settings, audio, controller/touch input and saves.
5. Test startup, cutscenes, levels and saves on Android devices.

The Vulkan test's purple screen is not evidence of an operational game renderer.

References:
- [Shaolin Monks Recomp](https://github.com/OAleex/ShaolinMonksRecomp)
- [Black-Android](https://github.com/RanggaCasper/Black-Android)
