// First connection between a verified, loaded original Xbox image and the
// *actual* 129-unit static recompilation embedded into Android libmain.so.
// No fake kernel export or dummy gameplay is provided. Running game threads
// needs a correctly registered Xbox kernel/XDK and working game GPU backend.
#include <android/log.h>
#include <cstdint>
#include <cpu/x86_context.h>
#include <kernel/kernel.h>
#include <kernel/memory.h>

namespace dispatch {
void Init();
X86Func* Find(uint32_t guest);
}

namespace shaolin_android {

bool BindGuestBase();

bool InitializeRecompiledGame(uint32_t game_entry, uint32_t game_kernel_thunk) {
    if (!mem::Base()) {
        __android_log_print(ANDROID_LOG_ERROR, "ShaolinXbox",
                            "RECOMP BOOT ERROR: Xbox RAM is not mapped");
        return false;
    }
    if (game_entry != X86EntryPoint ||
        game_entry < X86CodeBase || game_entry >= X86CodeEnd ||
        game_kernel_thunk != X86KernelThunk) {
        __android_log_print(ANDROID_LOG_ERROR, "ShaolinXbox",
                            "RECOMP BOOT ERROR: original XBE entry %08x / thunk %08x "
                            "does not match generated game %08x / %08x",
                            game_entry, game_kernel_thunk, X86EntryPoint, X86KernelThunk);
        return false;
    }
    if (!mem::IsCommitted(game_entry)) {
        __android_log_print(ANDROID_LOG_ERROR, "ShaolinXbox",
                            "RECOMP BOOT ERROR: original Xbox entry %08x is not mapped",
                            game_entry);
        return false;
    }
    if (!BindGuestBase()) {
        __android_log_print(ANDROID_LOG_ERROR, "ShaolinXbox",
                            "RECOMP BOOT ERROR: cannot bind guest kernel memory base");
        return false;
    }

    // This initializes the REAL generated-function dispatcher and allows us
    // to verify that the Xbox entry really exists among the recompiled code.
    dispatch::Init();
    if (!dispatch::Find(game_entry)) {
        __android_log_print(ANDROID_LOG_ERROR, "ShaolinXbox",
                            "RECOMP BOOT ERROR: generated function mapping has no entry %08x",
                            game_entry);
        return false;
    }

    // The XBE's original import table is still untouched: kernel exports and
    // XDK service initialization must happen before rewriting this table and
    // starting a guest thread. Inspect it safely and report the next blocker.
    uint32_t imports = 0, out_of_range = 0;
    bool terminated = false;
    if (game_kernel_thunk >= X86ImageBase &&
        game_kernel_thunk < X86ImageEnd) {
        for (uint32_t slot = 0; slot < 1024; ++slot) {
            const uint64_t address = uint64_t(game_kernel_thunk) + uint64_t(slot) * 4;
            if (address + 4 > X86ImageEnd || !mem::IsCommitted(uint32_t(address))) break;
            const uint32_t value = kernel::R32(uint32_t(address));
            if (value == 0) {
                terminated = true;
                break;
            }
            const uint32_t ordinal = value & 0x7fffffffu;
            if (ordinal >= 400) ++out_of_range;
            ++imports;
        }
    }
    __android_log_print(ANDROID_LOG_INFO, "ShaolinXbox",
                        "RECOMP READY: loaded and matched original Xbox entry=%08x, "
                        "code=[%08x..%08x), import thunk=%08x, imports=%u, "
                        "out-of-range=%u, terminated=%s",
                        game_entry, X86CodeBase, X86CodeEnd, game_kernel_thunk,
                        imports, out_of_range, terminated ? "yes" : "no");
    if (!terminated || out_of_range) {
        __android_log_print(ANDROID_LOG_ERROR, "ShaolinXbox",
                            "RECOMP BOOT BLOCKED: invalid/unmapped Xbox kernel thunk table");
        return false;
    }
    __android_log_print(ANDROID_LOG_INFO, "ShaolinXbox",
                        "RECOMP DISPATCH VERIFIED. Guest thread NOT started: "
                        "Xbox kernel exports, XDK video/audio and native game "
                        "Vulkan renderer still require Android integration.");
    return true;
}
}  // namespace shaolin_android
