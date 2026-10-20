// Android equivalents of the Windows/Linux host-facing services required
// by the real Shaolin-specific D3D8->Vulkan port.
#include <SDL3/SDL.h>
#include <app/app.h>
#include <host.h>
#include <runtime_paths.h>
#include <algorithm>
#include <chrono>
#include <thread>
#include <filesystem>
#include <mutex>
#include <atomic>
#include "android_graphics_host.h"

namespace shaolin { Options options{}; }
namespace shaolin_android {
SDL_Window* GameWindow();
static uint32_t render_percent = 75;
static uint32_t fps_cap = 60;
static std::atomic<uint64_t> output_size{(uint64_t(1280) << 32) | 720};
static std::atomic<bool> graphics_failed{false};
void UpdateGameOutput() {
    if (!SDL_IsMainThread()) return;
    int w = 0, h = 0;
    if (auto* window = GameWindow()) SDL_GetWindowSizeInPixels(window, &w, &h);
    output_size.store((uint64_t(std::max(w, 0)) << 32) | uint32_t(std::max(h, 0)));
}
void GameOutputSize(int* width, int* height) {
    const uint64_t size = output_size.load();
    *width = int(size >> 32);
    *height = int(uint32_t(size));
}
void ReportGraphicsFailure(const char* reason) {
    Trace("GRAPHICS_FATAL %s", reason);
    graphics_failed.store(true);
}
bool GraphicsFailed() { return graphics_failed.load(); }
void SetGameRenderPercent(uint32_t v) {
    render_percent = (v==50||v==75||v==100) ? v : 75;
    app::Get().render_percent = render_percent;
}
void SetGameFpsCap(uint32_t v) {
    fps_cap = v == 30 ? 30 : 60;
    app::Get().fps_cap = fps_cap;
}
}
namespace app {
static Settings g_android_settings;
Settings& Get() {
    return g_android_settings;
}
std::recursive_mutex& UiLock() {
    static std::recursive_mutex mutex;
    return mutex;
}
void* Window() { return shaolin_android::GameWindow(); }
Mode Desktop() {
    int w=1280,h=720;
    shaolin_android::GameOutputSize(&w, &h);
    return {static_cast<uint32_t>(std::max(w,1)),static_cast<uint32_t>(std::max(h,1))};
}
Mode Output() { return Desktop(); }
float RenderScale(uint32_t guest_height) {
    if (!guest_height) return 1.f;
    const Mode window = Output();
    const float scale = static_cast<float>(window.height) /
                        static_cast<float>(guest_height) * Get().render_percent / 100.f;
    return std::clamp(scale,0.25f,4.f);
}
// Android creates and shows the game surface before starting the Xbox guest;
// the splash and desktop process-handover paths must not run on mobile.
void SplashFirstFrame() {}
bool HandingOver() { return false; }
void FinishHandover() {}

// Called by real Xbox D3D8 Swap, not by the removed color-test loop.
// Track presentation time per thread and never busy-spin on Android CPUs.
void Pace() {
    using clock = std::chrono::steady_clock;
    thread_local clock::time_point next = clock::now();
    const uint32_t fps = Get().fps_cap;
    const auto now = clock::now();
    if (!fps) { next = now; return; }
    const auto period = std::chrono::nanoseconds(1000000000ull / fps);
    next += period;
    if (next < now - period) next = now;
    if (next > now) std::this_thread::sleep_until(next);
}
} // namespace app
namespace shaolin::paths {
std::filesystem::path Cache() {
    if (char* p = SDL_GetPrefPath("ShaolinMobiu","Xbox")) {
        auto dir = std::filesystem::path(p) / "vulkan_cache";
        SDL_free(p);
        std::error_code ec;
        std::filesystem::create_directories(dir,ec);
        return dir;
    }
    return std::filesystem::path{};
}
} // namespace shaolin::paths
