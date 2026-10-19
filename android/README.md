# Shaolin Mobiu — Android ARM64 preview

The **Shaolin Mobiu Preview** is an Android application with a native launcher:
- Custom dark/red/gold mobile interface, game-file selector and about dialog.
- Persisted Android Storage Access Framework permission for selected ISO/XISO/ZIP/XBE files
  or an extracted game folder. The selection stays on-device in private preferences.
- Resolution scale preference (50/75/100%) saved for the future game runtime.
- FPS setting (30/60) forwarded to the current SDL3 Vulkan smoke test.
- A separate landscape SDL3/Vulkan rendering test with visible animated color;
  touching the display changes the displayed color.

**Important:** No Shaolin Monks game code is linked into the current APK. The file picker
does not yet cause Xbox game execution. The "Jogar" entry explains this limitation;
the Vulkan test launches instead through its own button.

## Download APK

Open GitHub Actions / Android ARM64 Shaolin Mobiu preview on branch
`android-arm64-bringup`. Download the most recent successful artifact named
`Shaolin-Mobiu-Launcher-ARM64` and extract `app-debug.apk`.

## Build

The CI workflow builds from `android/` with Gradle 8.7, Android SDK 34,
Android NDK 28.2.13676358, CMake 3.31.6, JDK 17 and SDL3 3.4.16.
The native library is compiled only for ARM64.

Inspect the native Vulkan test log:

```sh
adb logcat -s ShaolinMobiu
```

## Generate Xbox translation locally on Windows

Use your original USA/Europe Xbox `default.xbe`. SHA-256:
`48240902bf4a04eb89376217c529531032d3370749bcce91a194878cc49db74a`.

Install Git, Python, CMake, LLVM/Clang, Visual Studio C++ Build Tools and Ninja.
In PowerShell at the repository root run:

```powershell
powershell -ExecutionPolicy Bypass -File .\android\Preparar-XBE-Android.ps1 -Xbe "C:\Games\Shaolin\default.xbe"
```

This prepares the 128 C++ partitions in the ignored local folder
`android/generated/shaolin`; they are not yet compiled into the APK.
Never upload original Xbox assets, the XBE or locally generated translation to
the public repo, releases, or CI artifacts.

## To reach the playable build

1. Adapt the game-specific XboxXBERecomp runtime and generated function dispatcher to ARM64.
2. Port the existing Shaolin game Vulkan renderer to the Android lifecycle and surface.
3. Connect URI-based disc access, audio, saves, gamepads and touch controls.
4. Validate the menu, cinematics, rendering and real gameplay on physical Android devices.

The PC build on `main` is unaffected.

References: [OAleex/ShaolinMonksRecomp](https://github.com/OAleex/ShaolinMonksRecomp)
and [RanggaCasper/Black-Android](https://github.com/RanggaCasper/Black-Android).
