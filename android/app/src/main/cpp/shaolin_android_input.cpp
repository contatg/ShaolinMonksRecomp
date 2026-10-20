// Android Xbox XInput bridge: ONLY the SDL main thread touches SDL's event
// pump, joystick handles and rumble. Guest Xbox/HLE threads read snapshots.
// Upstream runtime/core/input.cpp calls SDL_PumpEvents() in input::Poll()
// (including an XInitDevices background poller), which asserts
// SDL_IsMainThread() on Android. Preserve Xbox button layout and callbacks.
#include <SDL3/SDL.h>
#include <algorithm>
#include <array>
#include <mutex>
#include "core/input.h"
#include "app/app.h"
#include "shaolin_game_trace.h"

namespace input {
namespace {
std::mutex lock;
std::array<SDL_Gamepad*, 4> pads{};
std::array<Pad, 4> snapshots{};
struct RumbleState {
    uint16_t left = 0;
    uint16_t right = 0;
    bool pending = false;
};
std::array<RumbleState, 4> rumble{};
bool ready = false;

// Called ONLY on SDL's main thread.
void OpenPad(SDL_JoystickID id) {
    for (SDL_Gamepad* pad : pads)
        if (pad && SDL_GetGamepadID(pad) == id) return;
    for (int i = 0; i < 4; ++i) {
        if (pads[i]) continue;
        SDL_Gamepad* pad = SDL_OpenGamepad(id);
        if (!pad) {
            shaolin_android::Trace("ANDROID_INPUT_OPEN_FAILED id=%u: %s",
                                   unsigned(id), SDL_GetError());
            return;
        }
        pads[i] = pad;
        shaolin_android::Trace("ANDROID_INPUT_CONNECTED port=%d", i);
        return;
    }
}

void ClosePad(SDL_JoystickID id) {
    for (int i = 0; i < 4; ++i) {
        if (pads[i] && SDL_GetGamepadID(pads[i]) == id) {
            SDL_CloseGamepad(pads[i]);
            pads[i] = nullptr;
            std::lock_guard<std::mutex> guard(lock);
            snapshots[i] = Pad{};
            rumble[i] = RumbleState{};
            shaolin_android::Trace("ANDROID_INPUT_DISCONNECTED port=%d", i);
        }
    }
}

// Called ONLY on SDL's main thread, after SDL_PollEvent has pumped events.
// No SDL pointers are ever dereferenced by the emulated Xbox threads.
Pad ReadPad(SDL_Gamepad* pad) {
    Pad p{};
    if (!pad || !SDL_GamepadConnected(pad)) return p;
    p.connected = true;
    constexpr SDL_GamepadButton buttons[] = {
        SDL_GAMEPAD_BUTTON_DPAD_UP, SDL_GAMEPAD_BUTTON_DPAD_DOWN,
        SDL_GAMEPAD_BUTTON_DPAD_LEFT, SDL_GAMEPAD_BUTTON_DPAD_RIGHT,
        SDL_GAMEPAD_BUTTON_START, SDL_GAMEPAD_BUTTON_BACK,
        SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_BUTTON_RIGHT_STICK
    };
    for (int i = 0; i < 8; ++i)
        p.buttons |= uint16_t(SDL_GetGamepadButton(pad, buttons[i])) << i;
    // Xbox analog A/B/X/Y/black/white mapping from the pinned SDK.
    constexpr SDL_GamepadButton analog[] = {
        SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_EAST,
        SDL_GAMEPAD_BUTTON_WEST, SDL_GAMEPAD_BUTTON_NORTH,
        SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, SDL_GAMEPAD_BUTTON_LEFT_SHOULDER
    };
    for (int i = 0; i < 6; ++i)
        p.analog[i] = SDL_GetGamepadButton(pad, analog[i]) ? 0xff : 0;
    auto axis = [pad](SDL_GamepadAxis a) { return int(SDL_GetGamepadAxis(pad, a)); };
    p.analog[6] = uint8_t(std::max(axis(SDL_GAMEPAD_AXIS_LEFT_TRIGGER), 0) >> 7);
    p.analog[7] = uint8_t(std::max(axis(SDL_GAMEPAD_AXIS_RIGHT_TRIGGER), 0) >> 7);
    p.lx = int16_t(axis(SDL_GAMEPAD_AXIS_LEFTX));
    p.ly = int16_t(-1 - axis(SDL_GAMEPAD_AXIS_LEFTY));
    p.rx = int16_t(axis(SDL_GAMEPAD_AXIS_RIGHTX));
    p.ry = int16_t(-1 - axis(SDL_GAMEPAD_AXIS_RIGHTY));
    return p;
}
} // namespace

void Init() {
    shaolin_android::Trace("ANDROID_INPUT_INIT SDL_main_thread=%d",
                           SDL_IsMainThread() ? 1 : 0);
    // SDL_INIT_GAMEPAD is already requested by native main on its SDL thread.
    if (!SDL_IsMainThread()) {
        shaolin_android::Trace("ANDROID_INPUT_INIT_REJECT wrong thread");
        return;
    }
    if (!SDL_WasInit(SDL_INIT_GAMEPAD) && !SDL_InitSubSystem(SDL_INIT_GAMEPAD)) {
        shaolin_android::Trace("ANDROID_INPUT_INIT_FAIL %s", SDL_GetError());
        return;
    }
    ready = true;
    int count = 0;
    if (SDL_JoystickID* ids = SDL_GetGamepads(&count)) {
        for (int i = 0; i < count; ++i) OpenPad(ids[i]);
        SDL_free(ids);
    }
    shaolin_android::Trace("ANDROID_INPUT_INIT_OK connected_devices=%d", count);
}

// This receives events ALREADY pumped by SDL_PollEvent in main.cpp; the
// Xbox background XInitDevices poller never calls SDL event APIs again.
void MainThreadEvent(const SDL_Event& event) {
    if (!ready || !SDL_IsMainThread()) return;
    if (event.type == SDL_EVENT_GAMEPAD_ADDED)
        OpenPad(event.gdevice.which);
    else if (event.type == SDL_EVENT_GAMEPAD_REMOVED)
        ClosePad(event.gdevice.which);
}

void MainThreadUpdate() {
    if (!ready || !SDL_IsMainThread()) return;
    std::array<Pad, 4> fresh{};
    for (int i = 0; i < 4; ++i) fresh[i] = ReadPad(pads[i]);
    std::array<RumbleState, 4> commands{};
    {
        std::lock_guard<std::mutex> guard(lock);
        snapshots = fresh;
        commands = rumble;
        for (auto& v : rumble) v.pending = false;
    }
    for (int i = 0; i < 4; ++i) {
        if (commands[i].pending && pads[i])
            SDL_RumbleGamepad(pads[i], commands[i].left, commands[i].right, 250);
    }
}

// Xbox HLE/CPU/background threads only take a short lock and copy a struct.
Pad Poll(int port) {
    Pad result{};
    if (port >= 0 && port < 4) {
        std::lock_guard<std::mutex> guard(lock);
        result = snapshots[port];
    }
    if (app::kGame.pad) app::kGame.pad(port, result);
    return result;
}

void Rumble(int port, uint16_t left, uint16_t right) {
    if (app::kGame.rumble) app::kGame.rumble(port, left, right);
    if (port >= 0 && port < 4) {
        std::lock_guard<std::mutex> guard(lock);
        rumble[port] = {left, right, true};
    }
}
} // namespace input
