// Forward real XboxXBERecomp core/log.cpp stderr diagnostics to Android
// logcat without modifying pinned SDK sources or suppressing guest crashes.
#include <android/log.h>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <string>
#include <thread>
#include <unistd.h>

namespace shaolin_android {
void StartXboxLogcat() {
    static std::atomic<bool> started{false};
    if (started.exchange(true)) return;
    int fd[2]{};
    if (pipe(fd) != 0) {
        __android_log_print(ANDROID_LOG_ERROR, "ShaolinXboxKernel",
                            "stderr logcat pipe failed: errno=%d", errno);
        return;
    }
    std::fflush(stderr);
    if (dup2(fd[1], STDERR_FILENO) < 0) {
        __android_log_print(ANDROID_LOG_ERROR, "ShaolinXboxKernel",
                            "stderr logcat dup2 failed: errno=%d", errno);
        close(fd[0]);
        close(fd[1]);
        return;
    }
    close(fd[1]);
    setvbuf(stderr, nullptr, _IONBF, 0);
    std::thread([in = fd[0]] {
        char chunk[1024];
        std::string line;
        while (true) {
            const ssize_t n = read(in, chunk, sizeof chunk);
            if (n <= 0) {
                if (n < 0 && errno == EINTR) continue;
                break;
            }
            for (ssize_t i = 0; i < n; ++i) {
                char ch = chunk[i];
                if (ch == '\n' || line.size() >= 4095) {
                    if (!line.empty())
                        __android_log_write(ANDROID_LOG_INFO, "ShaolinXboxKernel", line.c_str());
                    line.clear();
                } else if (ch != '\r') {
                    line.push_back(ch);
                }
            }
        }
        if (!line.empty())
            __android_log_write(ANDROID_LOG_INFO, "ShaolinXboxKernel", line.c_str());
        close(in);
    }).detach();
    __android_log_write(ANDROID_LOG_INFO, "ShaolinXboxKernel",
                        "Xbox kernel/game stderr diagnostics now routed to logcat");
}
} // namespace shaolin_android
