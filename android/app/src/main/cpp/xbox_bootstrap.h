#pragma once

namespace shaolin_android {
// First native Xbox stage: inspect the player's original XBE / XDVDFS disc,
// check Shaolin executable SHA-256, parse the Xbox image, and map its sections
// into the XboxXBERecomp guest memory arena. Does NOT dispatch Xbox code yet.
// fd remains owned by the Android SDLActivity and is never closed here.
bool PrepareXboxImage(int fd);
}
