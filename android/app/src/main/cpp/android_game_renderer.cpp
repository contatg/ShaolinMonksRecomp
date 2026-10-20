// Android's Xbox D3D8 -> GLES3 compatibility backend.
// Real XDK Draw/Clear/Present calls reach this backend. This is the
// early GLES fallback, not a claim of pixel-perfect shader emulation.
#include <SDL3/SDL.h>
#include <GLES3/gl3.h>
#include <android/log.h>
#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstring>
#include <limits>
#include <cstdint>
#include <dxgiformat.h>
#include <memory>
#include <vector>
#include "gpu/backend.h"
#include "gpu/texture.h"
#include "gpu/vertex.h"
#include "linux/vk/bc_decode.h"
#include "kernel/kernel.h"
#include "shaolin_game_trace.h"
#include "android_graphics_host.h"

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
// XboxXBERecomp uses RAW vertex buffers by default (XBE_RAW_VERTICES=1).
// The old Android fallback only read Assembled::vertices, which is EMPTY for
// almost all raw draws, so GL swapped frames without ever drawing geometry.
// Decode the pinned SDK's DXGI-format vertex description directly, copying
// unaligned bytes safely and bounding each read by the buffer's byte count.
bool ReadXboxVertexRegister(const Assembled& a, uint32_t vertex, unsigned reg, float dst[4]) {
    if (reg >= 16 || !(a.regs & (1u << reg)) || vertex >= a.vertex_count)
        return false;
    // Leave caller defaults untouched for attributes the XBE did not bind.
    dst[0] = dst[1] = dst[2] = 0.f;
    dst[3] = 1.f;
    const VertexElement& e = a.elements[reg];
    if (e.buffer >= a.buffer_count || e.buffer >= a.buffers.size()) return false;
    const VertexBuffer& b = a.buffers[e.buffer];
    if (!b.src || b.stride == 0) return false;
    const uint64_t off = uint64_t(vertex) * b.stride + e.offset;
    if (off > b.bytes) return false;
    auto readable = [&](size_t bytes) { return off <= b.bytes && bytes <= b.bytes - off; };
    const uint8_t* p = b.src + off;
    auto copyFloats = [&](unsigned n) {
        if (!readable(size_t(n) * sizeof(float))) return false;
        std::memcpy(dst, p, size_t(n) * sizeof(float));
        return true;
    };
    switch (static_cast<DXGI_FORMAT>(e.format)) {
        case DXGI_FORMAT_R32_FLOAT: return copyFloats(1);
        case DXGI_FORMAT_R32G32_FLOAT: return copyFloats(2);
        case DXGI_FORMAT_R32G32B32_FLOAT: return copyFloats(3);
        case DXGI_FORMAT_R32G32B32A32_FLOAT: return copyFloats(4);
        case DXGI_FORMAT_B8G8R8A8_UNORM:
            if (!readable(4)) return false;
            dst[0] = p[2] / 255.f; dst[1] = p[1] / 255.f;
            dst[2] = p[0] / 255.f; dst[3] = p[3] / 255.f;
            return true;
        case DXGI_FORMAT_R8G8B8A8_UNORM:
            if (!readable(4)) return false;
            for (int k = 0; k < 4; ++k) dst[k] = p[k] / 255.f;
            return true;
        case DXGI_FORMAT_R16G16B16A16_SNORM:
        case DXGI_FORMAT_R16G16B16A16_SINT:
        case DXGI_FORMAT_R16G16_SNORM:
        case DXGI_FORMAT_R16G16_SINT:
        case DXGI_FORMAT_R16_SNORM:
        case DXGI_FORMAT_R16_SINT: {
            const unsigned n = (e.format == DXGI_FORMAT_R16_SNORM ||
                                e.format == DXGI_FORMAT_R16_SINT) ? 1 :
                               (e.format == DXGI_FORMAT_R16G16_SNORM ||
                                e.format == DXGI_FORMAT_R16G16_SINT) ? 2 : 4;
            if (!readable(n * 2)) return false;
            const bool normalized = e.format == DXGI_FORMAT_R16_SNORM ||
                                    e.format == DXGI_FORMAT_R16G16_SNORM ||
                                    e.format == DXGI_FORMAT_R16G16B16A16_SNORM;
            for (unsigned k = 0; k < n; ++k) {
                int16_t sample = 0;
                std::memcpy(&sample, p + k * 2, sizeof sample);
                dst[k] = normalized ? std::max(float(sample) / 32767.f, -1.f) : float(sample);
            }
            return true;
        }
        default: return false;
    }
}

class OpenGLESBackend final : public Backend {
    SDL_GLContext ctx_ = nullptr;
    GLuint shader_ = 0;
    GLuint vbo_ = 0;
    GLuint ebo_ = 0;
    GLuint tex_ = 0;
    GLint tex_enabled_ = -1;
    uint32_t cached_header_ = 0;
    uint32_t cached_data_ = 0;
    uint64_t cached_epoch_ = 0;
    uint64_t textured_draws_ = 0;
    GLint pos_ = -1, color_ = -1;
    uint32_t w_ = 0, h_ = 0;
    uint64_t draws_ = 0, frames_ = 0, skipped_shaders_ = 0, skipped_formats_ = 0, raw_draws_ = 0;
    std::array<float, 1024> gamma_{};
public:
    ~OpenGLESBackend() override {
        if (ctx_) {
            if (shader_) glDeleteProgram(shader_);
            if (vbo_) glDeleteBuffers(1, &vbo_);
            if (ebo_) glDeleteBuffers(1, &ebo_);
            if (tex_) glDeleteTextures(1, &tex_);
            SDL_GL_DestroyContext(ctx_);
        }
    }
    bool Init(uint32_t w, uint32_t h) override {
        shaolin_android::Trace("GLES_BACKEND_INIT_BEGIN %ux%u", w, h);
        if (!shaolin_android::GameWindow()) {
            shaolin_android::Trace("GLES_BACKEND_INIT_FAIL no SDL game window");
            return false;
        }
        w_ = w ? w : 640;
        h_ = h ? h : 480;
        ctx_ = SDL_GL_CreateContext(shaolin_android::GameWindow());
        if (!ctx_) {
            GPUERR("GLES3 SDL_GL_CreateContext: %s", SDL_GetError());
            shaolin_android::Trace("GLES_BACKEND_INIT_FAIL SDL_GL_CreateContext: %s", SDL_GetError());
            return false;
        }
        if (!SDL_GL_MakeCurrent(shaolin_android::GameWindow(), ctx_)) {
            shaolin_android::Trace("GLES_BACKEND_INIT_FAIL MakeCurrent: %s", SDL_GetError());
            return false;
        }
        SDL_GL_SetSwapInterval(1);
        const char* vs = R"(#version 300 es
precision highp float;
layout(location=0) in vec4 pos;
layout(location=1) in vec4 col;
layout(location=2) in vec2 uv;
out vec4 c;
out vec2 t;
void main() { gl_Position=pos; c=col; t=uv; })";
        const char* fs = R"(#version 300 es
precision highp float;
in vec4 c;
in vec2 t;
uniform sampler2D image;
uniform int texEnabled;
out vec4 outColor;
void main() { outColor=c*(texEnabled != 0 ? texture(image,t) : vec4(1.0)); })";
        GLuint v = Compile(GL_VERTEX_SHADER, vs), f = Compile(GL_FRAGMENT_SHADER, fs);
        if (!v || !f) {
            if (v) glDeleteShader(v);
            if (f) glDeleteShader(f);
            return false;
        }
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
        tex_enabled_ = glGetUniformLocation(shader_, "texEnabled");
        glUseProgram(shader_);
        glUniform1i(glGetUniformLocation(shader_, "image"), 0);
        glGenBuffers(1, &vbo_);
        glGenBuffers(1, &ebo_);
        glGenTextures(1, &tex_);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, tex_);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDisable(GL_CULL_FACE);
        int output_w = 0, output_h = 0;
        shaolin_android::GameOutputSize(&output_w, &output_h);
        glViewport(0, 0, output_w, output_h);
        GPUINFO("Real D3D8 OpenGL ES backend initialized for %ux%u guest framebuffer", w_, h_);
        shaolin_android::Trace("GLES_BACKEND_INIT_OK %ux%u", w_, h_);
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
    // Black Mobiu's Vulkan path decodes Xbox textures from guest memory.
    // Reuse the same shared texture decoder for GLES; the previous fallback
    // unconditionally multiplied by white and therefore showed white quads.
    // This starts with the primary 2D stage only; programmable combiners,
    // render-to-texture and 3D vertex shaders still need the Vulkan backend.
    bool BindXboxTexture(uint32_t header) {
        if (!header || !tex_) return false;
        TextureDesc desc{};
        if (!Describe(header, desc)) return false;
        if (desc.width == 0 || desc.height == 0 ||
            desc.width > 2048 || desc.height > 2048 || desc.depth != 1 ||
            !desc.data || desc.cube || desc.levels > 15) return false;
        const FormatInfo& fmt = Format(desc.format);
        if (fmt.host != Host::BGRA8 && fmt.host != Host::BC1 &&
            fmt.host != Host::BC2 && fmt.host != Host::BC3) return false;
        const uint32_t total = TotalSize(desc);
        if (total == 0 || total > 32u * 1024u * 1024u) return false;

        const uint64_t epoch = DirtyEpoch(desc.data);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, tex_);
        if (cached_header_ == header && cached_data_ == desc.data && cached_epoch_ == epoch)
            return true;

        const uint8_t* guest = static_cast<const uint8_t*>(kernel::HostPtr(desc.data));
        if (!guest) return false;
        std::vector<uint8_t> bytes;
        uint32_t src_pitch = 0;
        DecodeLevel(desc, 0, 0, guest, nullptr, bytes, src_pitch);
        if (bytes.empty()) return false;
        if (fmt.compressed) {
            std::vector<uint8_t> expanded;
            uint32_t expanded_pitch = 0;
            const int bc = fmt.host == Host::BC1 ? 1 : fmt.host == Host::BC2 ? 2 : 3;
            vkbc::Decode(bc, bytes.data(), src_pitch, desc.width, desc.height,
                         1, expanded, expanded_pitch);
            bytes.swap(expanded);
            src_pitch = expanded_pitch;
        }
        // Decoder output is BGRA, and GLES3 guarantees RGBA8, not BGRA_EXT.
        // Crop the padded final BC block so GL_UNPACK_ALIGNMENT never reads
        // outside the Xbox texture.
        const size_t width_bytes = size_t(desc.width) * 4;
        if (src_pitch < width_bytes || bytes.size() < size_t(src_pitch) * desc.height)
            return false;
        std::vector<uint8_t> rgba(width_bytes * desc.height);
        for (uint32_t y = 0; y < desc.height; ++y) {
            const uint8_t* row = bytes.data() + size_t(y) * src_pitch;
            uint8_t* dst = rgba.data() + size_t(y) * width_bytes;
            for (uint32_t x = 0; x < desc.width; ++x) {
                dst[x * 4 + 0] = row[x * 4 + 2];
                dst[x * 4 + 1] = row[x * 4 + 1];
                dst[x * 4 + 2] = row[x * 4 + 0];
                dst[x * 4 + 3] = row[x * 4 + 3];
            }
        }
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, GLsizei(desc.width), GLsizei(desc.height),
                     0, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
        const GLenum status = glGetError();
        if (status != GL_NO_ERROR) {
            shaolin_android::Trace("GLES_TEXTURE_UPLOAD_FAILED err=%u fmt=%u",
                                   unsigned(status), desc.format);
            cached_header_ = 0;
            return false;
        }
        cached_header_ = header;
        cached_data_ = desc.data;
        cached_epoch_ = epoch;
        shaolin_android::Trace("GLES_XBOX_TEXTURE_UPLOADED %ux%u format=%u bc=%d",
                               desc.width, desc.height, desc.format, fmt.compressed ? 1 : 0);
        return true;
    }
    // Xbox FVF XYZRHW position/colour path. Use both the SDK's raw and
    // converted vertex layouts and preserve their primitive indices. The
    // programmable vertex microcode path is not approximated here: Vulkan
    // already has a full translator and must be used for 3D gameplay.
    void Draw(const State& s, uint32_t prim, uint32_t start,
              uint32_t count, const uint8_t* indices) override {
        Assembled a;
        if (!Assemble(s, prim, start, count, indices, a)) return;
        if (!a.pretransformed) {
            if (++skipped_shaders_ <= 3 || skipped_shaders_ % 1024 == 0)
                shaolin_android::Trace("GLES_NEEDS_PROGRAMMABLE_XBOX_VERTEX_SHADER skipped=%llu handle=%08X",
                    static_cast<unsigned long long>(skipped_shaders_), s.vs_handle);
            return;
        }
        if (!a.vertex_count || a.vertex_count > 65536) return;
        struct Vertex { float x,y,z,w,r,g,b,alpha,u,v; };
        const bool has_texture = s.textures[0] && BindXboxTexture(s.textures[0]);
        std::vector<Vertex> verts;
        verts.reserve(a.vertex_count);
        for (uint32_t i = 0; i < a.vertex_count; ++i) {
            float pos[4]{0.f,0.f,0.f,1.f}, colour[4]{1.f,1.f,1.f,1.f};
            if (!ReadXboxVertexRegister(a, i, 0, pos)) {
                if (++skipped_formats_ <= 3 || skipped_formats_ % 1024 == 0)
                    shaolin_android::Trace("GLES_UNREADABLE_XBOX_VERTEX reg0 format=%u raw=%d",
                        unsigned(a.elements[0].format), a.vertices.empty() ? 1 : 0);
                return;
            }
            float diffuse[4]{1.f,1.f,1.f,1.f};
            if (ReadXboxVertexRegister(a, i, 3, diffuse))
                std::copy(diffuse, diffuse+4, colour);
            // XYZRHW arrives in Xbox backbuffer pixel coordinates. Normalize
            // against the guest viewport, NOT the Android output size.
            const float x = (pos[0] / float(std::max(1u,w_))) * 2.f - 1.f;
            const float y = 1.f - (pos[1] / float(std::max(1u,h_))) * 2.f;
            // Z is 0..1 on Xbox; GLES clip Z uses -1..1.
            const float z = std::clamp(pos[2],0.f,1.f) * 2.f - 1.f;
            float uv[4]{0.f,0.f,0.f,1.f};
            const bool has_uv = ReadXboxVertexRegister(a, i, 9, uv);
            verts.push_back({x,y,z,1.f,colour[0],colour[1],colour[2],colour[3],
                             has_uv ? uv[0] : 0.f, has_uv ? uv[1] : 0.f});
        }
        const GLenum mode = a.topology == Topology::Lines ?
            (a.strip ? GL_LINE_STRIP : GL_LINES) :
            a.topology == Topology::Points ? GL_POINTS :
            (a.strip ? GL_TRIANGLE_STRIP : GL_TRIANGLES);
        std::vector<uint32_t> order;
        if (!a.indices.empty()) {
            order = a.indices;
        } else if (a.index_src && a.index_count) {
            if (a.index_count > 393216) return;
            order.reserve(a.index_count);
            for (uint32_t i = 0; i < a.index_count; ++i) {
                uint32_t id = 0;
                if (a.index16) {
                    uint16_t small = 0;
                    std::memcpy(&small, static_cast<const uint8_t*>(a.index_src) + size_t(i) * 2, 2);
                    id = small;
                } else {
                    std::memcpy(&id, static_cast<const uint8_t*>(a.index_src) + size_t(i) * 4, 4);
                }
                const int64_t fixed = int64_t(id) + a.base_vertex;
                if (fixed < 0 || fixed >= int64_t(a.vertex_count)) return;
                order.push_back(uint32_t(fixed));
            }
        }
        if (!order.empty()) {
            if (order.size() > 393216) return;
            for (uint32_t v : order) if (v >= a.vertex_count) return;
        }
        // Use the same GL context the Android main event thread created.
        glUseProgram(shader_);
        glUniform1i(tex_enabled_, has_texture ? 1 : 0);
        int output_w = 0, output_h = 0;
        shaolin_android::GameOutputSize(&output_w, &output_h);
        glViewport(0, 0, std::max(1, output_w), std::max(1, output_h));
        glBindBuffer(GL_ARRAY_BUFFER,vbo_);
        glBufferData(GL_ARRAY_BUFFER,verts.size()*sizeof(Vertex),verts.data(),GL_STREAM_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0,4,GL_FLOAT,GL_FALSE,sizeof(Vertex),nullptr);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1,4,GL_FLOAT,GL_FALSE,sizeof(Vertex),(const void*)(4*sizeof(float)));
        glEnableVertexAttribArray(2);
        glVertexAttribPointer(2,2,GL_FLOAT,GL_FALSE,sizeof(Vertex),(const void*)(8*sizeof(float)));
        if (!order.empty()) {
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo_);
            glBufferData(GL_ELEMENT_ARRAY_BUFFER, order.size()*sizeof(uint32_t),order.data(),GL_STREAM_DRAW);
            glDrawElements(mode,GLsizei(order.size()),GL_UNSIGNED_INT,nullptr);
        } else {
            glDrawArrays(mode,0,GLsizei(std::min<size_t>(verts.size(),a.draw_count ? a.draw_count : verts.size())));
        }
        ++draws_;
        if (has_texture) ++textured_draws_;
        if (a.vertices.empty()) ++raw_draws_;
        if (draws_ <= 3 || draws_ % 300 == 0)
            shaolin_android::Trace("GLES_XBOX_DRAW_SUBMITTED total=%llu raw=%llu textured=%llu vertices=%u indices=%zu",
                static_cast<unsigned long long>(draws_),
                static_cast<unsigned long long>(raw_draws_),
                static_cast<unsigned long long>(textured_draws_),
                a.vertex_count,order.size());
    }
    void Copy(const Surface& src, const Surface& dst,
              uint32_t n, uint32_t rects, uint32_t points) override {
        if (!CopySurfaceMemory(src,dst,n,rects,points))
            GPUINFO("GLES unsupported guest surface Copy");
    }
    void Present(const Surface&) override {
        if (!ctx_) return;
        if (!SDL_GL_SwapWindow(shaolin_android::GameWindow())) {
            GPUERR("GLES SDL_GL_SwapWindow: %s",SDL_GetError());
            shaolin_android::Trace("GLES_PRESENT_FAILED %s", SDL_GetError());
            return;
        }
        shaolin_android::TracePresent("GLES3");
        if (++frames_%300 == 1)
            GPUINFO("REAL XBOX GLES Present frame=%llu draw_calls=%llu",
                    (unsigned long long)frames_,(unsigned long long)draws_);
    }
    void Sync(uint32_t, uint32_t) override { glFinish(); }
    void SyncLate(uint32_t) override { glFlush(); }
    void Flush() override { glFlush(); }
    void SetGamma(const uint8_t*) override {}
};

// The Xbox thread initializes the backend, then the render worker draws.
// A GL context cannot remain current on the first thread while the second
// issues commands. Keep all GLES work, including destruction, on SDL's thread.
class MainThreadBackend final : public Backend {
    std::unique_ptr<Backend> inner_;
    template<class F> bool Run(F&& f) {
        if (shaolin_android::OnMainThread(std::forward<F>(f))) return true;
        shaolin_android::ReportGraphicsFailure("Cannot dispatch GLES work to SDL");
        return false;
    }
public:
    explicit MainThreadBackend(std::unique_ptr<Backend> inner) : inner_(std::move(inner)) {}
    ~MainThreadBackend() override {
        if (inner_ && !Run([&] { inner_.reset(); })) {
            // The SDL queue is gone. Never delete a context on a guest thread.
            (void)inner_.release();
        }
    }
    bool Init(uint32_t w, uint32_t h) override {
        bool ok = false;
        return Run([&] { ok = inner_->Init(w, h); }) && ok;
    }
    void Clear(const State& s, uint32_t count, const uint8_t* rects, uint32_t flags,
               uint32_t color, float z, uint32_t stencil) override {
        Run([&] { inner_->Clear(s, count, rects, flags, color, z, stencil); });
    }
    void Draw(const State& s, uint32_t prim, uint32_t start, uint32_t count, const uint8_t* indices) override {
        Run([&] { inner_->Draw(s, prim, start, count, indices); });
    }
    void Copy(const Surface& src, const Surface& dst, uint32_t n, uint32_t rects, uint32_t points) override {
        Run([&] { inner_->Copy(src, dst, n, rects, points); });
    }
    void Present(const Surface& front) override { Run([&] { inner_->Present(front); }); }
    void Sync(uint32_t va, uint32_t size) override { Run([&] { inner_->Sync(va, size); }); }
    void SyncLate(uint32_t va) override { Run([&] { inner_->SyncLate(va); }); }
    void Flush() override { Run([&] { inner_->Flush(); }); }
    void SetGamma(const uint8_t* ramp) override { Run([&] { inner_->SetGamma(ramp); }); }
};
}
std::unique_ptr<Backend> CreateBackend() {
    if (shaolin_android::UseOpenGL()) {
        GPUINFO("Xbox D3D8 host backend selected: OpenGL ES 3");
        shaolin_android::Trace("XBOX_D3D8_CREATE_BACKEND GLES3");
        return std::make_unique<MainThreadBackend>(std::make_unique<OpenGLESBackend>());
    }
    GPUINFO("Xbox D3D8 host backend selected: Vulkan (Shaolin Linux port)");
    shaolin_android::Trace("XBOX_D3D8_CREATE_BACKEND Vulkan");
    return CreateVulkanBackend();
}
} // namespace gpu
