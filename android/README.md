# Shaolin Mobiu — Android ARM64 bringup

This branch holds an **Android Vulkan environment test**, not the original Xbox game.
It uses Android Gradle Plugin 8.5.2, SDL3 3.4.16, the Android NDK and the
Vulkan system loader. It builds libmain.so and packages an Android APK.
The native entry point creates an SDL Vulkan window, Vulkan instance and surface,
enumerates devices, and logs the result.

## Build

Use GitHub Actions -> Android ARM64 Vulkan bringup -> Run workflow,
or build inside android/ with Gradle 8.7 after installing Android SDK 34,
NDK 28.2.13676358, CMake 3.31.6, and JDK 17.

No proprietary game files are included or required for this environment test.
This APK **does not run Shaolin Monks**. Vulkan instance/surface creation alone
does not mean the renderer or game works.

## Required integration before a playable build

1. Host-recompile the audited original USA/Europe default.xbe using the pinned SDK.
2. Build and link the generated C++ translations against the ARM64 portable Xbox runtime.
3. Replace desktop-specific file paths, launch dialogs, startup and saves with Android services.
4. Port the existing Shaolin Monks Vulkan backend to Android, including render pass,
   shader compilation, presentation and surface lifecycle.
5. Connect touchscreen/gamepad input and SDL audio without regressing the PC targets.
6. Test cold startup, menu, gameplay, cinematics and saves on actual Vulkan Android hardware.

Do not upload original XBE, proprietary game data or generated game translations to
the public repository or Actions artifacts.

Reference runtime: https://github.com/RanggaCasper/Black-Android
Original game port: https://github.com/OAleex/ShaolinMonksRecomp
