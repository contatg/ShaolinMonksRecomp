// Native Vulkan environment test. The XBE runtime is NOT wired up yet.
// Successful startup proves only SDL3 + Vulkan surface compatibility.
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3/SDL_vulkan.h>
#include <vulkan/vulkan.h>
#include <android/log.h>
#include <vector>
#include <cstdio>

#define SMLOG(...) __android_log_print(ANDROID_LOG_INFO, "ShaolinMobiu", __VA_ARGS__)

int main(int, char**) {
    SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight");
    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMEPAD | SDL_INIT_EVENTS)) {
        SMLOG("SDL init failed: %s", SDL_GetError());
        return 1;
    }
    SDL_Window* window = SDL_CreateWindow("Shaolin Mobiu - Vulkan test", 1280, 720,
                                           SDL_WINDOW_VULKAN | SDL_WINDOW_FULLSCREEN);
    if (!window) {
        SMLOG("Window creation failed: %s", SDL_GetError());
        SDL_Quit();
        return 2;
    }
    Uint32 extension_count = 0;
    const char* const* extensions = SDL_Vulkan_GetInstanceExtensions(&extension_count);
    if (!extensions || extension_count == 0) {
        SMLOG("Vulkan instance extensions unavailable: %s", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 3;
    }
    std::vector<const char*> required(extensions, extensions + extension_count);
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.pApplicationName = "Shaolin Mobiu Vulkan bringup";
    app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo info{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    info.pApplicationInfo = &app;
    info.enabledExtensionCount = static_cast<uint32_t>(required.size());
    info.ppEnabledExtensionNames = required.data();
    VkInstance instance = VK_NULL_HANDLE;
    VkResult result = vkCreateInstance(&info, nullptr, &instance);
    if (result != VK_SUCCESS) {
        SMLOG("vkCreateInstance failed: %d", int(result));
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 4;
    }
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    if (!SDL_Vulkan_CreateSurface(window, instance, nullptr, &surface)) {
        SMLOG("Could not create surface: %s", SDL_GetError());
        vkDestroyInstance(instance, nullptr);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 5;
    }
    uint32_t count = 0;
    vkEnumeratePhysicalDevices(instance, &count, nullptr);
    SMLOG("Vulkan surface initialized; devices=%u. Game runtime NOT loaded.", count);
    bool run = true;
    while (run) {
        SDL_Event event;
        if (SDL_WaitEventTimeout(&event, 100)) {
            if (event.type == SDL_EVENT_QUIT || event.type == SDL_EVENT_TERMINATING ||
                event.type == SDL_EVENT_KEY_DOWN) run = false;
        }
    }
    vkDestroySurfaceKHR(instance, surface, nullptr);
    vkDestroyInstance(instance, nullptr);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
