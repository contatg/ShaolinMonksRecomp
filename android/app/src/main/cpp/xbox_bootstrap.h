#pragma once
#include <cstdint>
#include <vector>

namespace shaolin_android {
// Read, SHA256-check and mount the original ISO for the SDK kernel::Boot.
// Unlike PrepareXboxImage, this does NOT pre-map RAM or initialize the Xbox
// kernel a second time: kernel::Boot owns guest memory and threads.
bool LoadVerifiedXboxForBoot(int fd, std::vector<uint8_t>& xbe);

// First native Xbox stage: inspect the player's original XBE / XDVDFS disc,
// check Shaolin executable SHA-256, parse the Xbox image, and map its sections
// into the XboxXBERecomp guest memory arena. Does NOT dispatch Xbox code yet.
// fd remains owned by the Android SDLActivity and is never closed here.
// Set entry and kernel thunk only after the original XBE is loaded successfully.
bool PrepareXboxImage(int fd, uint32_t* loaded_entry = nullptr,
                      uint32_t* loaded_kernel_thunk = nullptr);
#ifdef SHAOLIN_NATIVE_GUEST
// Verify the generated C++ mappings against the loaded original image.
// This is NOT a request to execute the guest entry until kernel/XDK is ready.
bool InitializeRecompiledGame(uint32_t game_entry, uint32_t game_kernel_thunk);
#endif
}
