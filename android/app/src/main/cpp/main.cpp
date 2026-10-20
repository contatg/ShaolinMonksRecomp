// Android SDL3/Vulkan presentation bringup.
// This is a visible renderer test, NOT an executable Xbox game port.
// No proprietary game data or generated Xbox code is linked in this build.
#include "xbox_bootstrap.h"
#ifdef SHAOLIN_REAL_GAME_BOOT
#include <kernel/kernel.h>
#include <string>
namespace shaolin_android { void StartXboxLogcat(); }
#endif
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3/SDL_vulkan.h>
#include <android/log.h>
#include <vulkan/vulkan.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <cerrno>
#include <sys/stat.h>
#include <unistd.h>
#include <cstring>
#include <vector>

#define SMLOG(...) __android_log_print(ANDROID_LOG_INFO, "ShaolinMobiu", __VA_ARGS__)
#define SMERR(...) __android_log_print(ANDROID_LOG_ERROR, "ShaolinMobiu", __VA_ARGS__)


// Inspect the original selected Xbox source through the descriptor opened by
// Android's Storage Access Framework. No file is copied, changed or embedded.
// Actual game execution is not implemented in this preview yet.
void ProbeXboxSource(int fd) {
    if (fd < 0) return;
    struct stat st{};
    if (fstat(fd, &st) != 0) {
        SMERR("Game source fstat failed (errno=%d)", errno);
        return;
    }
    SMLOG("Game source FD=%d, reported size=%lld bytes", fd, (long long)st.st_size);

    unsigned char prefix[20]{};
    const ssize_t bytes = pread(fd, prefix, sizeof(prefix), 0);
    if (bytes < 0) {
        SMERR("Game source does not support positional read (errno=%d); provider may be streaming", errno);
        return;
    }
    if (bytes >= 4 && std::memcmp(prefix, "XBEH", 4) == 0) {
        SMLOG("Detected original Xbox XBE header. SHA256 must be validated in launcher.");
        return;
    }
    if (bytes >= 4 && prefix[0] == 'P' && prefix[1] == 'K' &&
        ((prefix[2] == 3 && prefix[3] == 4) ||
         (prefix[2] == 5 && prefix[3] == 6))) {
        SMLOG("Detected ZIP signature. Xbox game archive import not yet implemented.");
        return;
    }
    static constexpr unsigned char dvd_magic[] = "MICROSOFT*XBOX*MEDIA";
    static constexpr off_t bases[] = {0, 0x18300000, 0x0FD90000, 0x02080000};
    for (off_t base : bases) {
        unsigned char volume[sizeof(dvd_magic) - 1]{};
        const ssize_t len = pread(fd, volume, sizeof(volume), base + 32 * 2048);
        if (len == sizeof(volume) && std::memcmp(volume, dvd_magic, sizeof(volume)) == 0) {
            SMLOG("Detected Xbox XDVDFS disc image at partition offset %lld",
                  (long long)base);
            SMLOG("Disc source is now accessible to native code without duplicating its data.");
            return;
        }
    }
    SMERR("Selected file is not a recognized XBE, ZIP or XDVDFS image.");
}

namespace {

bool VkOk(VkResult result, const char* operation) {
    if (result == VK_SUCCESS) return true;
    SMERR("%s failed (VkResult=%d)", operation, int(result));
    return false;
}

struct Renderer {
    SDL_Window* window = nullptr;
    VkInstance instance = VK_NULL_HANDLE;
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    uint32_t queue_family = UINT32_MAX;
    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    VkFormat format = VK_FORMAT_UNDEFINED;
    VkExtent2D extent{};
    std::vector<VkImage> images;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE;
    VkSemaphore acquired = VK_NULL_HANDLE;
    VkSemaphore finished = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;

    ~Renderer() { Shutdown(); }

    void DestroySwapchain() {
        if (device && swapchain) vkDestroySwapchainKHR(device, swapchain, nullptr);
        swapchain = VK_NULL_HANDLE;
        images.clear();
    }

    void Shutdown() {
        if (device) vkDeviceWaitIdle(device);
        DestroySwapchain();
        if (device) {
            if (fence) vkDestroyFence(device, fence, nullptr);
            if (finished) vkDestroySemaphore(device, finished, nullptr);
            if (acquired) vkDestroySemaphore(device, acquired, nullptr);
            if (pool) vkDestroyCommandPool(device, pool, nullptr);
            vkDestroyDevice(device, nullptr);
        }
        device = VK_NULL_HANDLE;
        if (instance && surface) vkDestroySurfaceKHR(instance, surface, nullptr);
        surface = VK_NULL_HANDLE;
        if (instance) vkDestroyInstance(instance, nullptr);
        instance = VK_NULL_HANDLE;
    }

    bool SupportsSwapchain(VkPhysicalDevice candidate) {
        uint32_t count = 0;
        if (vkEnumerateDeviceExtensionProperties(candidate, nullptr, &count, nullptr) != VK_SUCCESS) return false;
        std::vector<VkExtensionProperties> extensions(count);
        if (vkEnumerateDeviceExtensionProperties(candidate, nullptr, &count, extensions.data()) != VK_SUCCESS)
            return false;
        for (const auto& ext : extensions)
            if (!std::strcmp(ext.extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME)) return true;
        return false;
    }

    bool CreateSwapchain() {
        VkSurfaceCapabilitiesKHR caps{};
        if (!VkOk(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, surface, &caps),
                  "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")) return false;
        if (!(caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT)) {
            SMERR("Android Vulkan swapchain does not support TRANSFER_DST; test renderer needs fallback");
            return false;
        }
        uint32_t count = 0;
        if (!VkOk(vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &count, nullptr),
                  "vkGetPhysicalDeviceSurfaceFormatsKHR") || !count) return false;
        std::vector<VkSurfaceFormatKHR> formats(count);
        if (!VkOk(vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &count, formats.data()),
                  "vkGetPhysicalDeviceSurfaceFormatsKHR")) return false;
        VkSurfaceFormatKHR chosen = formats[0];
        for (const auto& item : formats) {
            if ((item.format == VK_FORMAT_B8G8R8A8_UNORM || item.format == VK_FORMAT_R8G8B8A8_UNORM) &&
                item.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                chosen = item;
                break;
            }
        }
        format = chosen.format;
        if (caps.currentExtent.width != UINT32_MAX) {
            extent = caps.currentExtent;
        } else {
            int width = 0;
            int height = 0;
            SDL_GetWindowSizeInPixels(window, &width, &height);
            extent.width = std::clamp<uint32_t>(std::max(width, 1), caps.minImageExtent.width, caps.maxImageExtent.width);
            extent.height = std::clamp<uint32_t>(std::max(height, 1), caps.minImageExtent.height, caps.maxImageExtent.height);
        }
        if (!extent.width || !extent.height) return false;

        uint32_t image_count = std::max(caps.minImageCount, 2u);
        if (caps.maxImageCount && image_count > caps.maxImageCount) image_count = caps.maxImageCount;
        VkCompositeAlphaFlagBitsKHR alpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        if (!(caps.supportedCompositeAlpha & alpha)) {
            const VkCompositeAlphaFlagBitsKHR options[] = {
                VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
                VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
                VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR
            };
            for (auto option : options) {
                if (caps.supportedCompositeAlpha & option) {
                    alpha = option;
                    break;
                }
            }
        }
        VkSwapchainCreateInfoKHR create{VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
        create.surface = surface;
        create.minImageCount = image_count;
        create.imageFormat = format;
        create.imageColorSpace = chosen.colorSpace;
        create.imageExtent = extent;
        create.imageArrayLayers = 1;
        create.imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        create.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
        create.preTransform = caps.currentTransform;
        create.compositeAlpha = alpha;
        create.presentMode = VK_PRESENT_MODE_FIFO_KHR;
        create.clipped = VK_TRUE;
        if (!VkOk(vkCreateSwapchainKHR(device, &create, nullptr, &swapchain), "vkCreateSwapchainKHR"))
            return false;
        if (!VkOk(vkGetSwapchainImagesKHR(device, swapchain, &image_count, nullptr),
                  "vkGetSwapchainImagesKHR (count)")) return false;
        images.resize(image_count);
        if (!VkOk(vkGetSwapchainImagesKHR(device, swapchain, &image_count, images.data()),
                  "vkGetSwapchainImagesKHR (images)")) return false;
        SMLOG("Swapchain %ux%u, format=%d, images=%u", extent.width, extent.height,
              int(format), image_count);
        return true;
    }

    bool RecreateSwapchain() {
        if (!VkOk(vkDeviceWaitIdle(device), "vkDeviceWaitIdle (recreate)")) return false;
        DestroySwapchain();
        return CreateSwapchain();
    }

    bool Init(SDL_Window* sdl_window) {
        window = sdl_window;
        if (!SDL_Vulkan_LoadLibrary(nullptr)) {
            SMERR("SDL_Vulkan_LoadLibrary: %s", SDL_GetError());
            return false;
        }
        uint32_t extension_count = 0;
        const char* const* extensions = SDL_Vulkan_GetInstanceExtensions(&extension_count);
        if (!extensions || !extension_count) {
            SMERR("SDL_Vulkan_GetInstanceExtensions: %s", SDL_GetError());
            return false;
        }
        VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
        app.pApplicationName = "Shaolin Mobiu Renderer Test";
        app.apiVersion = VK_API_VERSION_1_1;
        VkInstanceCreateInfo create{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        create.pApplicationInfo = &app;
        create.enabledExtensionCount = extension_count;
        create.ppEnabledExtensionNames = extensions;
        if (!VkOk(vkCreateInstance(&create, nullptr, &instance), "vkCreateInstance")) return false;
        if (!SDL_Vulkan_CreateSurface(window, instance, nullptr, &surface)) {
            SMERR("SDL_Vulkan_CreateSurface: %s", SDL_GetError());
            return false;
        }
        uint32_t device_count = 0;
        if (!VkOk(vkEnumeratePhysicalDevices(instance, &device_count, nullptr),
                  "vkEnumeratePhysicalDevices") || !device_count) {
            SMERR("No Vulkan physical device found");
            return false;
        }
        std::vector<VkPhysicalDevice> devices(device_count);
        if (!VkOk(vkEnumeratePhysicalDevices(instance, &device_count, devices.data()),
                  "vkEnumeratePhysicalDevices (devices)")) return false;
        for (VkPhysicalDevice candidate : devices) {
            if (!SupportsSwapchain(candidate)) continue;
            uint32_t families = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(candidate, &families, nullptr);
            std::vector<VkQueueFamilyProperties> properties(families);
            vkGetPhysicalDeviceQueueFamilyProperties(candidate, &families, properties.data());
            for (uint32_t family = 0; family < families; ++family) {
                VkBool32 present = VK_FALSE;
                if (vkGetPhysicalDeviceSurfaceSupportKHR(candidate, family, surface, &present) == VK_SUCCESS &&
                    present && (properties[family].queueFlags & VK_QUEUE_GRAPHICS_BIT)) {
                    physical = candidate;
                    queue_family = family;
                    break;
                }
            }
            if (physical) break;
        }
        if (!physical) {
            SMERR("No Vulkan graphics + presentation queue supporting VK_KHR_swapchain");
            return false;
        }
        VkPhysicalDeviceProperties properties{};
        vkGetPhysicalDeviceProperties(physical, &properties);
        SMLOG("Vulkan GPU: %s; version %u.%u", properties.deviceName,
              VK_VERSION_MAJOR(properties.apiVersion), VK_VERSION_MINOR(properties.apiVersion));

        float priority = 1.0f;
        VkDeviceQueueCreateInfo q{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        q.queueFamilyIndex = queue_family;
        q.queueCount = 1;
        q.pQueuePriorities = &priority;
        const char* device_extensions[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
        VkDeviceCreateInfo d{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
        d.queueCreateInfoCount = 1;
        d.pQueueCreateInfos = &q;
        d.enabledExtensionCount = 1;
        d.ppEnabledExtensionNames = device_extensions;
        if (!VkOk(vkCreateDevice(physical, &d, nullptr, &device), "vkCreateDevice")) return false;
        vkGetDeviceQueue(device, queue_family, 0, &queue);

        VkCommandPoolCreateInfo pool_info{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
        pool_info.queueFamilyIndex = queue_family;
        pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        if (!VkOk(vkCreateCommandPool(device, &pool_info, nullptr, &pool), "vkCreateCommandPool"))
            return false;
        VkCommandBufferAllocateInfo alloc{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        alloc.commandPool = pool;
        alloc.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc.commandBufferCount = 1;
        if (!VkOk(vkAllocateCommandBuffers(device, &alloc, &command), "vkAllocateCommandBuffers"))
            return false;

        VkSemaphoreCreateInfo sem{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        VkFenceCreateInfo fi{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        fi.flags = VK_FENCE_CREATE_SIGNALED_BIT;
        if (!VkOk(vkCreateSemaphore(device, &sem, nullptr, &acquired), "vkCreateSemaphore (acquire)") ||
            !VkOk(vkCreateSemaphore(device, &sem, nullptr, &finished), "vkCreateSemaphore (render)") ||
            !VkOk(vkCreateFence(device, &fi, nullptr, &fence), "vkCreateFence"))
            return false;
        return CreateSwapchain();
    }

    // Submit a real Vulkan clear operation and PRESENT it to the phone display.
    bool Frame(float seconds, bool alternative) {
        if (!VkOk(vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_MAX), "vkWaitForFences"))
            return false;
        uint32_t image_index = 0;
        const VkResult acquired_result =
            vkAcquireNextImageKHR(device, swapchain, UINT64_MAX, acquired, VK_NULL_HANDLE, &image_index);
        if (acquired_result == VK_ERROR_OUT_OF_DATE_KHR) return RecreateSwapchain();
        if (acquired_result != VK_SUCCESS && acquired_result != VK_SUBOPTIMAL_KHR)
            return VkOk(acquired_result, "vkAcquireNextImageKHR");
        if (!VkOk(vkResetCommandBuffer(command, 0), "vkResetCommandBuffer"))
            return false;

        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        if (!VkOk(vkBeginCommandBuffer(command, &begin), "vkBeginCommandBuffer")) return false;
        VkImageMemoryBarrier before{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        before.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        before.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED; // previous contents are discarded each frame
        before.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        before.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        before.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        before.image = images[image_index];
        before.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        before.subresourceRange.levelCount = 1;
        before.subresourceRange.layerCount = 1;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                             VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &before);
        const float wave = 0.5f + 0.5f * std::sin(seconds * 1.8f);
        VkClearColorValue color{};
        color.float32[0] = alternative ? 0.95f : 0.20f + 0.15f * wave;
        color.float32[1] = alternative ? 0.30f + 0.2f * wave : 0.05f;
        color.float32[2] = alternative ? 0.02f : 0.65f + 0.25f * wave;
        color.float32[3] = 1.0f;
        VkImageSubresourceRange range{};
        range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        range.levelCount = 1;
        range.layerCount = 1;
        vkCmdClearColorImage(command, images[image_index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                             &color, 1, &range);
        VkImageMemoryBarrier after{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        after.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        after.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        after.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        after.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        after.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        after.image = images[image_index];
        after.subresourceRange = range;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                             0, 0, nullptr, 0, nullptr, 1, &after);
        if (!VkOk(vkEndCommandBuffer(command), "vkEndCommandBuffer")) return false;
        const VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
        submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = &acquired;
        submit.pWaitDstStageMask = &stage;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &command;
        submit.signalSemaphoreCount = 1;
        submit.pSignalSemaphores = &finished;
        if (!VkOk(vkResetFences(device, 1, &fence), "vkResetFences")) return false;
        if (!VkOk(vkQueueSubmit(queue, 1, &submit, fence), "vkQueueSubmit")) return false;
        VkPresentInfoKHR present{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
        present.waitSemaphoreCount = 1;
        present.pWaitSemaphores = &finished;
        present.swapchainCount = 1;
        present.pSwapchains = &swapchain;
        present.pImageIndices = &image_index;
        VkResult p = vkQueuePresentKHR(queue, &present);
        if (p == VK_ERROR_OUT_OF_DATE_KHR || p == VK_SUBOPTIMAL_KHR ||
            acquired_result == VK_SUBOPTIMAL_KHR) return RecreateSwapchain();
        return VkOk(p, "vkQueuePresentKHR");
    }
};

} // namespace

int main(int argc, char** argv) {
    int fps_limit = 60;
    int render_preference = 75;
    int source_fd = -1;
    for (int i = 1; i + 1 < argc; ++i) {
        if (!std::strcmp(argv[i], "--fps")) {
            int input = std::atoi(argv[++i]);
            fps_limit = input == 30 ? 30 : 60;
        } else if (!std::strcmp(argv[i], "--scale")) {
            int input = std::atoi(argv[++i]);
            if (input == 50 || input == 75 || input == 100) render_preference = input;
        } else if (!std::strcmp(argv[i], "--game-fd")) {
            const int fd = std::atoi(argv[++i]);
            if (fd >= 0 && fd < 1048576) source_fd = fd;
        }
    }
    SMLOG("Launcher preferences: FPS=%d (active), future game scale=%d%% (not yet applied)",
          fps_limit, render_preference);
    ProbeXboxSource(source_fd);
#ifdef SHAOLIN_REAL_GAME_BOOT
    // Do NOT call PrepareXboxImage: the real Xbox kernel::Boot owns memory,
    // patching import thunks, guest threads and host kernel initialization.
    // The same original ISO is verified and mounted as the Xbox D: drive.
    std::vector<uint8_t> verified_xbe;
    bool xbox_image_ready = false;
    if (source_fd >= 0) {
        xbox_image_ready = shaolin_android::LoadVerifiedXboxForBoot(source_fd, verified_xbe);
        if (!xbox_image_ready)
            SMERR("GAME BOOT: ISO verification / D: mount failed");
    } else {
        SMERR("GAME BOOT: no original ISO selected in launcher");
    }
#else
    if (source_fd >= 0) {
        uint32_t original_entry = 0, original_kernel_thunk = 0;
        if (!shaolin_android::PrepareXboxImage(source_fd, &original_entry, &original_kernel_thunk))
            SMERR("Xbox preboot failed");
    }
#endif
    SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight");
    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMEPAD | SDL_INIT_EVENTS)) {
        SMERR("SDL_Init: %s", SDL_GetError());
        return 1;
    }
    SDL_Window* window = SDL_CreateWindow("Shaolin Monks - Xbox ARM64 Boot", 0, 0,
                                           SDL_WINDOW_VULKAN | SDL_WINDOW_FULLSCREEN |
                                           SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (!window) {
        SMERR("SDL_CreateWindow: %s", SDL_GetError());
        SDL_Quit();
        return 2;
    }
    // Start Xbox CPU boot independently of graphics. If a device's Vulkan
    // swapchain fails, the real boot still runs and produces useful logs.
#ifdef SHAOLIN_REAL_GAME_BOOT
    if (xbox_image_ready) {
        shaolin_android::StartXboxLogcat();
        const char* pref = SDL_GetPrefPath("ShaolinMobiu", "Xbox");
        if (!pref || !*pref) {
            SMERR("GAME BOOT: app-private writable data directory unavailable");
        } else {
            const std::string data_dir(pref);
            SMLOG("GAME BOOT: invoking REAL kernel::Boot with original Xbox XBE and mounted D: ISO");
            // Guest threads execute independently from SDL's window thread.
            // kernel::Boot returns after scheduling the first guest CPU entry.
            if (!kernel::Boot(std::move(verified_xbe), "default.xbe",
                              data_dir + "/disc", data_dir + "/hdd")) {
                SMERR("GAME BOOT FAILED: kernel::Boot returned false; inspect ShaolinXboxKernel");
            } else {
                SMLOG("GAME BOOT STARTED: Xbox guest entry thread launched; inspect ShaolinXboxKernel");
            }
        }
    }
#endif

    int result = 0;
    {
        Renderer renderer;
        if (!renderer.Init(window)) {
            SMERR("Android Vulkan presentation failed. Check ShaolinXboxKernel for independently started Xbox guest thread.");
            result = 3;
        } else {
#ifndef SHAOLIN_REAL_GAME_BOOT
            SMLOG("Launcher renderer initialized; no Xbox code in public APK.");
#endif
            const Uint64 started = SDL_GetTicks();
            bool alive = true;
            bool foreground = true;
            bool orange = false;
            while (alive) {
                SDL_Event e;
                while (SDL_PollEvent(&e)) {
                    switch (e.type) {
                        case SDL_EVENT_QUIT:
                        case SDL_EVENT_TERMINATING:
                            alive = false;
                            break;
                        case SDL_EVENT_WILL_ENTER_BACKGROUND:
                            foreground = false;
                            break;
                        case SDL_EVENT_DID_ENTER_FOREGROUND:
                            foreground = true;
                            break;
                        case SDL_EVENT_FINGER_DOWN:
                        case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
                            orange = !orange;
                            SMLOG("SDL input event; Xbox controller/XAPI mapping not yet connected");
                            break;
                        case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
                            if (foreground && !renderer.RecreateSwapchain()) alive = false;
                            break;
                    }
                }
                if (!alive) break;
                if (!foreground) {
                    SDL_Delay(80);
                    continue;
                }
                const float seconds = float(SDL_GetTicks() - started) / 1000.0f;
                if (!renderer.Frame(seconds, orange)) {
                    SMERR("Vulkan rendering/presentation failed");
                    result = 4;
                    break;
                }
                SDL_Delay(fps_limit == 30 ? 33 : 16);
            }
        }
    }
    SDL_DestroyWindow(window);
    SDL_Quit();
    return result;
}
