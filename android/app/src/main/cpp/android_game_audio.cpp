// Actual Xbox DirectSound HLE mixer -> SDL3/Aaudio/OpenSLES on Android.
// The mixer remains the recompiler SDK's real 48kHz software engine.
#include <SDL3/SDL.h>
#include <android/log.h>
#include <audio/audio.h>
#include <functional>
#include <vector>
namespace audio {
namespace {
struct Output {
    std::function<void(float*,uint32_t)> render;
    std::vector<float> samples{std::vector<float>(kRate/100*2)};
};
void SDLCALL Feed(void* userdata, SDL_AudioStream* stream, int additional, int) {
    auto* o=static_cast<Output*>(userdata);
    constexpr uint32_t frames=kRate/100;
    while(additional>0) {
        o->render(o->samples.data(),frames);
        const int bytes=int(o->samples.size()*sizeof(float));
        if(!SDL_PutAudioStreamData(stream,o->samples.data(),bytes)) break;
        additional-=bytes;
    }
}
} // namespace
void StartOutput(std::function<void(float*,uint32_t)> render) {
    if(!SDL_WasInit(SDL_INIT_AUDIO) && !SDL_InitSubSystem(SDL_INIT_AUDIO)) {
        __android_log_print(ANDROID_LOG_ERROR,"ShaolinAudio","SDL audio init: %s",SDL_GetError());
        return;
    }
    static Output output;
    output.render=std::move(render);
    const SDL_AudioSpec spec{SDL_AUDIO_F32,2,int(kRate)};
    SDL_AudioStream* stream=SDL_OpenAudioDeviceStream(
        SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,&spec,Feed,&output);
    if(!stream) {
        __android_log_print(ANDROID_LOG_ERROR,"ShaolinAudio","OpenAudioDeviceStream: %s",SDL_GetError());
        return;
    }
    SDL_ResumeAudioStreamDevice(stream);
    __android_log_print(ANDROID_LOG_INFO,"ShaolinAudio","Xbox DirectSound 48kHz stereo mixer started");
}
} // namespace audio
