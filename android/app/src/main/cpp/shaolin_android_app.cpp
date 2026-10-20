// Minimal genuine Android host metadata required by the XboxXBERecomp
// kernel boot. The Windows game's callbacks cannot be used unchanged
// because they reference a desktop window and ImGui renderer.
#include <app/app.h>

namespace app {
const GameInfo kGame{
    .title = L"Shaolin Monks Recomp",
    .short_title = L"Shaolin Monks Recomp",
    .name = L"ShaolinMobiu",
    .log = "shaolin-mobiu",
    .settings = "settings.toml",
    .splash = L"shaolin-mobiu",
    .missing = L"Select your original Xbox game.",
    .images = {{"default.xbe", "ShaolinMobiu"}},
    .options = {},
    .load = nullptr,
    .save = nullptr,
    .init = nullptr,
    .loaded = nullptr,
    .window = nullptr,
    .message = nullptr,
    .ui = nullptr,
    .pad = nullptr,
    .rumble = nullptr,
};

// The Android launcher is landscape by default; Xbox title reports
// widescreen until the actual guest renderer controls display modes.
bool Widescreen() { return true; }
} // namespace app
