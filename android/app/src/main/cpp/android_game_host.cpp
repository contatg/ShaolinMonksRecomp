// Android equivalents of the Windows/Linux host-facing services required
// by the real Shaolin-specific D3D8->Vulkan port.
#include <SDL3/SDL.h>
#include <app/app.h>
#include <host.h>
#include <runtime_paths.h>
#include <algorithm>
#include <filesystem>
#include <mutex>

namespace shaolin { Options options{}; }
namespace shaolin_android {
SDL_Window* GameWindow();
static uint32_t render_percent = 75;
void SetGameRenderPercent(uint32_t v) { render_percent = (v==50||v==75||v==100) ? v : 75; }
}
namespace app {
static Settings g_android_settings;
Settings& Get() {
    g_android_settings.render_percent = shaolin_android::render_percent;
    return g_android_settings;
}
std::recursive_mutex& UiLock() {
    static std::recursive_mutex mutex;
    return mutex;
}
void* Window() { return shaolin_android::GameWindow(); }
Mode Desktop() {
    int w=1280,h=720;
    if (auto* window = shaolin_android::GameWindow()) SDL_GetWindowSizeInPixels(window,&w,&h);
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
} // namespace app
namespace shaolin::paths {
std::filesystem::path Cache() {
    if (const char* p = SDL_GetPrefPath("ShaolinMobiu","Xbox")) {
        auto dir = std::filesystem::path(p) / "vulkan_cache";
        std::error_code ec;
        std::filesystem::create_directories(dir,ec);
        return dir;
    }
    return std::filesystem::path{};
}
} // namespace shaolin::paths
