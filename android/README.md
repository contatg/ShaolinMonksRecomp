# Shaolin Monks Recomp — Android ARM64

The Android launcher keeps game selection, graphics preferences and the Krypt
mod manager. A private GameBoot build links the owner's translated Xbox code,
kernel services and the Vulkan/GLES backends. Game execution uses a separate
Android process so a native failure does not terminate the launcher.

Vulkan uses the maintained Shaolin renderer. It requires Vulkan 1.2, timeline
semaphores and dynamic rendering (core in 1.3 or the KHR extension).
Capability and initialization failures are recorded before D3D device creation
fails. A failed renderer is never submitted to the render worker.

GLES remains incomplete: it handles pretransformed primitives, clear and swap.
Programmable shaders, textures and render targets are not fully implemented.
Audio or successful buffer swaps do not prove that the game is visible.

## Continue an existing private build

Keep the private translation and SDK already prepared on this computer.
Use the current `android-arm64-bringup` checkout.

```powershell
powershell -ExecutionPolicy Bypass -File .\android\Compilar-APK-Shaolin-ARM64.ps1
powershell -ExecutionPolicy Bypass -File .\android\Instalar-GameBoot-Coletar-Logs.ps1
```

Select the original ISO and press Play during capture.
Test Vulkan first.
Run a separate capture after choosing GLES to compare the two backends.
Use `-SkipInstall` on the collector to inspect the installed APK without replacing it.

The private APK is written to
`android-local/output/ShaolinMobiu-ARM64-GameBoot.apk`.
The trace contains the source revision used by the build.
A successful build is not a device or gameplay test.

## Diagnostics

Each capture uses a new timestamped directory below
`android-local/gameboot-logs/`. The ZIP contains the private native trace,
filtered Android logs and process exit information.

Relevant trace events:

| Event | Evidence |
| --- | --- |
| `ISO_LOAD_DONE success=1` | Original XBE was read and verified |
| `KERNEL_BOOT_RETURNED_TRUE` | Guest thread was scheduled |
| `VULKAN_DEVICE` | Reported GPU API and extension capabilities |
| `VULKAN_INIT_STAGE` | Completed or failed initialization stage |
| `GRAPHICS_FATAL` | Renderer initialization failed |
| `KERNEL_SHUTDOWN` | Kernel requested a process exit |
| `REAL_XBOX_D3D8_PRESENT` | The graphics API accepted a presentation |

Presentation counts do not prove visible or correct frames.
Kernel messages are written synchronously so an immediate process exit cannot
outrun a background stderr reader.
Native signals are still handled by Android; they are not suppressed.

## Automated checks

The Android Actions workflow runs a renderer initialization ownership regression,
compiles public GameBoot/kernel/D3D/Vulkan/GLES sources to ARM64 objects, and
checks launcher packaging. Public ABI headers come from the checked-in config
and pinned SDK metadata. No original game is read or translated in CI.
The object check does not link a playable game and uploads no APK.

Use a physical device and the private build to verify initialization, visible
menu, input, cinematics, gameplay, audio, suspend/resume, saves and enabled mods.
Record these results separately from compile checks.

Original ISO/XBE files, generated game translation, saves and device logs must
stay outside public source and CI artifacts.
