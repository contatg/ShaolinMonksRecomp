// Tests ownership at the renderer initialization boundary, without a GPU.
#include <cassert>
#include <memory>
#include "android_backend_init.h"

namespace {
bool succeed = false, return_null = false;
int initialized = 0, destroyed = 0;
class Fake final : public gpu::Backend {
public:
    ~Fake() override { ++destroyed; }
    bool Init(uint32_t w, uint32_t h) override { assert(w == 640 && h == 480); ++initialized; return succeed; }
    void Clear(const gpu::State&, uint32_t, const uint8_t*, uint32_t, uint32_t, float, uint32_t) override {}
    void Draw(const gpu::State&, uint32_t, uint32_t, uint32_t, const uint8_t*) override {}
    void Copy(const gpu::Surface&, const gpu::Surface&, uint32_t, uint32_t, uint32_t) override {}
    void Present(const gpu::Surface&) override {}
    void Sync(uint32_t, uint32_t) override {}
    void SyncLate(uint32_t) override {}
    void Flush() override {}
    void SetGamma(const uint8_t*) override {}
};
}
namespace gpu {
std::unique_ptr<Backend> CreateBackend() {
    if (return_null) return {};
    return std::make_unique<Fake>();
}
}
int main() {
    std::unique_ptr<gpu::Backend> backend;
    assert(!shaolin_android::InitializeGameBackend(backend, 640, 480));
    assert(!backend && initialized == 1 && destroyed == 1);
    return_null = true;
    assert(!shaolin_android::InitializeGameBackend(backend, 640, 480));
    assert(!backend && initialized == 1 && destroyed == 1);
    return_null = false;
    succeed = true;
    assert(shaolin_android::InitializeGameBackend(backend, 640, 480));
    assert(backend && initialized == 2 && destroyed == 1);
    backend.reset();
    assert(destroyed == 2);
}
