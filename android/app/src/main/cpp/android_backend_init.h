#pragma once
#include <memory>
#include "gpu/backend.h"

namespace shaolin_android {
// Do not publish a partially initialized backend to the Xbox D3D8 entrypoints.
inline bool InitializeGameBackend(std::unique_ptr<gpu::Backend>& output,
                                  uint32_t width, uint32_t height) {
    auto candidate = gpu::CreateBackend();
    if (!candidate || !candidate->Init(width, height)) return false;
    output = std::move(candidate);
    return true;
}
}
