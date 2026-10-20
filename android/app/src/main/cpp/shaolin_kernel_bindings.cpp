#include <cstdint>
#include "kernel/memory.h"
#include "kernel/kernel.h"

// Android's game image is initialized by the Android boot coordinator.
// Keep this actual 32-bit guest memory pointer in the shared Xbox namespace.
// Before executing guest functions, Boot must call BindGuestBase().
namespace kernel {
uint8_t* g_base = nullptr;
}

namespace shaolin_android {
bool BindGuestBase() {
    uint8_t* base = mem::Base();
    if (!base) return false;
    kernel::g_base = base;
    return true;
}
void UnbindGuestBase() { kernel::g_base = nullptr; }
}
