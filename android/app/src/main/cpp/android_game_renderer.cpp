// Android's Xbox D3D8 -> GLES3 compatibility backend.
// Real XDK Draw/Clear/Present calls reach this backend. This is the
// early GLES fallback, not a claim of pixel-perfect shader emulation.
#include <SDL3/SDL.h>
#include <GLES3/gl3.h>
#include <android/log.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <vector>
#include "gpu/backend.h"
#include "gpu/texture.h"
#include "gpu/vertex.h"
#include "kernel/kernel.h"

#define GPUINFO(...) __android_log_print(ANDROID_LOG_INFO, "ShaolinGPU", __VA_ARGS__)
#define GPUERR(...) __android_log_print(ANDROID_LOG_ERROR, "ShaolinGPU", __VA_ARGS__)
namespace shaolin_android {
static SDL_Window* g_window = nullptr;
static bool g_opengl = false;
void ConfigureGameRenderer(SDL_Window* window, bool opengl) {
    g_window = window;
    g_opengl = opengl;
}
SDL_Window* GameWindow() { return g_window; }
bool UseOpenGL() { return g_opengl; }
}

namespace gpu {
std::unique_ptr<Backend> CreateVulkanBackend();
namespace {
GLuint Compile(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint ok = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char message[1024]{};
        glGetShaderInfoLog(shader, sizeof(message), nullptr, message);
        GPUERR("GLES shader error: %s", message);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}
class OpenGLESBackend final : public Backend {
    SDL_GLContext ctx_ = nullptr;
    GLuint shader_ = 0;
    GLuint vbo_ = 0;
    GLint pos_ = -1, color_ = -1;
    uint32_t w_ = 0, h_ = 0;
    uint64_t draws_ = 0, frames_ = 0;
    std::array<float, 1024> gamma_{};
public:
    ~OpenGLESBackend() override {
        if (ctx_) {
            if (shader_) glDeleteProgram(shader_);
            if (vbo_) glDeleteBuffers(1, &vbo_);
            SDL_GL_DestroyContext(ctx_);
        }
    }
    bool Init(uint32_t w, uint32_t h) override {
        if (!shaolin_android::GameWindow()) return false;
        w_ = w ? w : 640;
        h_ = h ? h : 480;
        ctx_ = SDL_GL_CreateContext(shaolin_android::GameWindow());
        if (!ctx_) {
            GPUERR("GLES3 SDL_GL_CreateContext: %s", SDL_GetError());
            return false;
        }
        SDL_GL_MakeCurrent(shaolin_android::GameWindow(), ctx_);
        SDL_GL_SetSwapInterval(1);
        const char* vs = R"(#version 300 es
precision highp float;
layout(location=0) in vec4 pos;
layout(location=1) in vec4 col;
out vec4 c;
void main() { gl_Position=pos; c=col; })";
        const char* fs = R"(#version 300 es
precision highp float;
in vec4 c;
out vec4 outColor;
void main() { outColor=c; })";
        GLuint v = Compile(GL_VERTEX_SHADER, vs), f = Compile(GL_FRAGMENT_SHADER, fs);
        if (!v || !f) return false;
        shader_ = glCreateProgram();
        glAttachShader(shader_, v); glAttachShader(shader_, f);
        glLinkProgram(shader_);
        glDeleteShader(v); glDeleteShader(f);
        GLint linked = 0;
        glGetProgramiv(shader_, GL_LINK_STATUS, &linked);
        if (!linked) {
            GPUERR("GLES3 program link failed");
            return false;
        }
        glGenBuffers(1, &vbo_);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDisable(GL_CULL_FACE);
        glViewport(0, 0, w_, h_);
        GPUINFO("Real D3D8 OpenGL ES backend initialized for %ux%u guest framebuffer", w_, h_);
        return true;
    }
    void Clear(const State&, uint32_t, const uint8_t*, uint32_t flags,
               uint32_t color, float z, uint32_t stencil) override {
        GLbitfield mask = 0;
        if (flags & kClearTarget) {
            glClearColor(((color>>16)&255)/255.f, ((color>>8)&255)/255.f,
                         (color&255)/255.f, ((color>>24)&255)/255.f);
            mask |= GL_COLOR_BUFFER_BIT;
        }
        if (flags & kClearZ) {
            glClearDepthf(z);
            mask |= GL_DEPTH_BUFFER_BIT;
        }
        if (flags & kClearStencil) {
            glClearStencil(stencil);
            mask |= GL_STENCIL_BUFFER_BIT;
        }
        if (mask) glClear(mask);
    }
    // Minimal software vertex assembly to verify Xbox primitive calls. Full
    // programmable shader, texture stages, render targets and push buffers
    // still need translation. Never invent a frame or animation.
    void Draw(const State& s, uint32_t prim, uint32_t start,
              uint32_t count, const uint8_t* indices) override {
        Assembled a;
        if (!Assemble(s, prim, start, count, indices, a)) return;
        if (!a.pretransformed || a.vertices.empty()) {
            if (++draws_ % 1024 == 1) GPUINFO("GLES guest draw %llu: programmable/non-XYZRHW path pending",
                                              (unsigned long long)draws_);
            return;
        }
        // The converted assembler represents 16 vec4 input registers per vertex.
        const size_t floats_per_vertex = 64;
        if (a.vertices.size() < a.vertex_count * floats_per_vertex) return;
        struct Vertex { float x,y,z,w,r,g,b,alpha; };
        std::vector<Vertex> verts;
        verts.reserve(a.vertex_count);
        for (uint32_t i = 0; i < a.vertex_count; ++i) {
            const float* in = a.vertices.data() + size_t(i) * floats_per_vertex;
            const float x = (in[0] / std::max(1u,w_))*2.f-1.f;
            const float y = 1.f-(in[1] / std::max(1u,h_))*2.f;
            verts.push_back({x,y,0.f,1.f,1.f,1.f,1.f,1.f});
        }
        const GLenum mode = a.topology == Topology::Lines ?
            (a.strip ? GL_LINE_STRIP : GL_LINES) :
            a.topology == Topology::Points ? GL_POINTS :
            (a.strip ? GL_TRIANGLE_STRIP : GL_TRIANGLES);
        glUseProgram(shader_);
        glBindBuffer(GL_ARRAY_BUFFER,vbo_);
        glBufferData(GL_ARRAY_BUFFER,verts.size()*sizeof(Vertex),verts.data(),GL_STREAM_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0,4,GL_FLOAT,GL_FALSE,sizeof(Vertex),nullptr);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1,4,GL_FLOAT,GL_FALSE,sizeof(Vertex),(const void*)(4*sizeof(float)));
        glDrawArrays(mode,0,(GLsizei)verts.size());
        ++draws_;
    }
    void Copy(const Surface& src, const Surface& dst,
              uint32_t n, uint32_t rects, uint32_t points) override {
        if (!CopySurfaceMemory(src,dst,n,rects,points))
            GPUINFO("GLES unsupported guest surface Copy");
    }
    void Present(const Surface&) override {
        if (!ctx_) return;
        if (!SDL_GL_SwapWindow(shaolin_android::GameWindow()))
            GPUERR("GLES SDL_GL_SwapWindow: %s",SDL_GetError());
        if (++frames_%300 == 1)
            GPUINFO("REAL XBOX GLES Present frame=%llu draw_calls=%llu",
                    (unsigned long long)frames_,(unsigned long long)draws_);
    }
    void Sync(uint32_t, uint32_t) override { glFinish(); }
    void SyncLate(uint32_t, uint32_t) = delete;
    void SyncLate(uint32_t) override { glFlush(); }
    void Flush() override { glFlush(); }
    void SetGamma(const uint8_t*) override {}
};
}
std::unique_ptr<Backend> CreateBackend() {
    if (shaolin_android::UseOpenGL()) {
        GPUINFO("Xbox D3D8 host backend selected: OpenGL ES 3");
        return std::make_unique<OpenGLESBackend>();
    }
    GPUINFO("Xbox D3D8 host backend selected: Vulkan (Shaolin Linux port)");
    return CreateVulkanBackend();
}
} // namespace gpu
