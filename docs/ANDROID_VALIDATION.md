# Android validation — 2026-10-20

Runtime revision: `4d0c2f37e475960f39f17fba3de9ccc29b44a5fa`.

[GitHub Actions run](https://github.com/contatg/ShaolinMonksRecomp/actions/runs/39467051880)
completed successfully. The following checks ran on the hosted Ubuntu runner:

| Check | Result | Scope |
| --- | --- | --- |
| Renderer initialization regression | Passed | Failed/null backend is not published; failed candidate is destroyed; successful ownership transfers |
| Public GameBoot compilation | Passed | NDK 28.2.13676358, Android 30, ARM64 objects; kernel, D3D8, Vulkan, GLES and SDL host integration |
| Launcher Java and packaging | Passed | Gradle `assembleDebug`; 37 tasks executed |
| Full private GameBoot link | Not run | Requires the owner's local generated Xbox translation |
| Vulkan boot on the affected phone | Not run | No device connection or current post-SDL crash trace |
| Visible menu and gameplay | Not verified | No captured device evidence for this revision |
| GLES shaders/textures/render targets | Incomplete | Context ownership and vertex submission fixes do not implement the remaining rendering features |
| Device saves, controls, mods and suspend/resume | Not revalidated | Existing code preserved; physical-device testing remains required |

## Evidence and diagnosis

The supplied `shaolin-native-trace.txt` records an earlier failed ISO open.
The supplied process report includes an earlier `EXIT_SELF` with status 0.
The supplied screenshot records the SDL main-thread assertion.
These files predate the last SDL correction and do not establish the cause of
the subsequently reported Vulkan-only crash.

The owner reports that GLES plays audio with no image and Vulkan exits
immediately. Source inspection found that D3D8 continued to use a backend after
its `Init` returned false. The Android adaptation now returns
`D3DERR_NOTAVAILABLE` and reports a graphics failure instead of submitting to
that backend. This corrects the failure path; the next device trace must still
identify which Vulkan initialization stage fails, if any.

The renderer now logs Vulkan device capabilities and initialization stages.
GLES commands run on SDL's thread, use converted vertex input and honor the
assembler's index list. Kernel diagnostics are synchronous, including shutdown
and unsupported relaunch events. Accepted presentation calls are counted after
the API returns; a counter alone is not evidence of a visible game frame.

## Next device validation

Use the existing private checkout and generated sources.
Build with `android/Compilar-APK-Shaolin-ARM64.ps1`.
Capture with `android/Instalar-GameBoot-Coletar-Logs.ps1`.
Confirm the trace's `SOURCE_REVISION` before comparing results.
Capture Vulkan and GLES in separate sessions.
Check visible menu and gameplay separately from audio and presentation counts.

No ISO, XBE, generated game functions, device logs or game APK were published.
The CI object target contains public runtime sources and metadata only.
