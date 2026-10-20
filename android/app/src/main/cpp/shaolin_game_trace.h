#pragma once
#include <cstdint>
namespace shaolin_android {
// Private app-file trace for devices/ROMs that hide native logcat output.
// Trace only game startup stages and GPU activity; never game contents.
void TraceInit(const char* absolute_path);
void Trace(const char* format, ...);
void TracePresent(const char* backend);
uint64_t TraceFrameCount();
}
