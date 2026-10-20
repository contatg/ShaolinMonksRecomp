#include "shaolin_game_trace.h"
#include <android/log.h>
#include <atomic>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <mutex>
#include <string>

#ifndef SHAOLIN_BUILD_REVISION
#define SHAOLIN_BUILD_REVISION "unknown"
#endif

namespace shaolin_android {
namespace {
std::mutex g_lock;
FILE* g_log = nullptr;
std::atomic<uint64_t> g_frames{0};
const auto g_start = std::chrono::steady_clock::now();
}

void TraceInit(const char* absolute_path) {
    std::lock_guard<std::mutex> guard(g_lock);
    if (g_log) { std::fclose(g_log); g_log = nullptr; }
    g_frames = 0;
    if (absolute_path && *absolute_path) g_log = std::fopen(absolute_path, "w");
    __android_log_print(g_log ? ANDROID_LOG_INFO : ANDROID_LOG_ERROR,
                        "ShaolinTrace", "private Xbox trace %s",
                        g_log ? "opened" : "could not open");
    if (g_log) {
        std::fputs("Shaolin GameBoot native trace v2 (no game files)\n", g_log);
        std::fprintf(g_log, "SOURCE_REVISION=%s\n", SHAOLIN_BUILD_REVISION);
        std::fflush(g_log);
    }
}

void Trace(const char* format, ...) {
    char line[1800]{};
    va_list args;
    va_start(args, format);
    std::vsnprintf(line, sizeof(line), format, args);
    va_end(args);
    __android_log_write(ANDROID_LOG_INFO, "ShaolinTrace", line);
    std::lock_guard<std::mutex> guard(g_lock);
    if (!g_log) return;
    const double secs = std::chrono::duration<double>(
        std::chrono::steady_clock::now()-g_start).count();
    std::fprintf(g_log, "[%8.3fs] %s\n", secs, line);
    std::fflush(g_log);
}

uint64_t TraceFrameCount() { return g_frames.load(std::memory_order_relaxed); }

void TracePresent(const char* backend) {
    const uint64_t n = g_frames.fetch_add(1, std::memory_order_relaxed) + 1;
    if (n <= 5 || n % 120 == 0)
        Trace("REAL_XBOX_D3D8_PRESENT backend=%s count=%llu", backend,
              static_cast<unsigned long long>(n));
}
}
