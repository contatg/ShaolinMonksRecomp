#pragma once
#include <SDL3/SDL.h>
#include <exception>
#include <utility>
#include "shaolin_game_trace.h"

namespace shaolin_android {
// Stack captures stay valid until the SDL callback returns. Never wait for a
// guest/render worker on the SDL event thread while it is dispatching work.
template<class F> bool OnMainThread(F&& function) {
    struct Call {
        F& function;
        std::exception_ptr error;
    } call{function, {}};
    const bool queued = SDL_RunOnMainThread([](void* data) {
        auto& call = *static_cast<Call*>(data);
        try { call.function(); }
        catch (...) { call.error = std::current_exception(); }
    }, &call, true);
    if (!queued) Trace("SDL_MAIN_DISPATCH_FAILED %s", SDL_GetError());
    if (call.error) std::rethrow_exception(call.error);
    return queued;
}
void UpdateGameOutput();
void GameOutputSize(int* width, int* height);
void ReportGraphicsFailure(const char* reason);
bool GraphicsFailed();
}
