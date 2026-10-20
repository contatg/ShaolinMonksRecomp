// Record uncaught guest/host exceptions without suppressing native tombstones.
// The Android copy of core/log.cpp writes synchronous kernel diagnostics.
#include <android/log.h>
#include "shaolin_game_trace.h"
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>
#include <thread>
#include <unistd.h>

namespace shaolin_android {
void StartXboxLogcat() {
    static std::atomic<bool> started{false};
    if (started.exchange(true)) return;
    // The adapted core logger writes each message directly to Trace().
    // No asynchronous stderr consumer is needed before kernel::_Exit.
    // A guest thread's uncaught C++ exception otherwise terminates Android
    // without necessarily draining stderr. Record the exception directly
    // before triggering the normal native tombstone.
    std::set_terminate([] {
        std::exception_ptr e = std::current_exception();
        if (e) {
            try {
                std::rethrow_exception(e);
            } catch (const std::exception& err) {
                __android_log_print(ANDROID_LOG_FATAL, "ShaolinXboxKernel",
                                    "UNCAUGHT XBOX/HOST EXCEPTION: %s", err.what());
                shaolin_android::Trace("UNCAUGHT_XBOX_EXCEPTION %s", err.what());
            } catch (...) {
                __android_log_write(ANDROID_LOG_FATAL, "ShaolinXboxKernel",
                                    "UNCAUGHT UNKNOWN XBOX/HOST EXCEPTION");
                shaolin_android::Trace("UNCAUGHT_XBOX_EXCEPTION unknown");
            }
        } else {
            __android_log_write(ANDROID_LOG_FATAL, "ShaolinXboxKernel",
                                "std::terminate in Xbox/HLE guest thread");
            shaolin_android::Trace("UNCAUGHT_XBOX_EXCEPTION std::terminate no active exception");
        }
        std::abort();
    });
    __android_log_write(ANDROID_LOG_INFO, "ShaolinXboxKernel",
                        "Synchronous Xbox diagnostics and uncaught exception reporting enabled");
}
} // namespace shaolin_android
