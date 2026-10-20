# Real Xbox D3D8 host calls -> Shaolin's portable GPU API.
# Android Vulkan uses the SHAOLIN-specific Linux renderer (not the Black
# renderer with its different game symbols); OpenGL ES is an early fallback.
# Opt-in PRIVATE game build only: never distribute generated Xbox sources.
include(FetchContent)
set(GLSLANG_TESTS OFF CACHE BOOL "" FORCE)
set(GLSLANG_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(ENABLE_GLSLANG_BINARIES OFF CACHE BOOL "" FORCE)
set(ENABLE_SPVREMAPPER OFF CACHE BOOL "" FORCE)
set(ENABLE_OPT OFF CACHE BOOL "" FORCE)
set(ENABLE_HLSL ON CACHE BOOL "" FORCE)
set(BUILD_EXTERNAL OFF CACHE BOOL "" FORCE)
FetchContent_Declare(glslang
    GIT_REPOSITORY https://github.com/KhronosGroup/glslang.git
    GIT_TAG 8a85691a0740d390761a1008b4696f57facd02c4)
FetchContent_Declare(shaolin_android_imgui
    GIT_REPOSITORY https://github.com/ocornut/imgui.git
    GIT_TAG v1.91.0)
FetchContent_MakeAvailable(glslang shaolin_android_imgui)

set(SHAOLIN_ADAPTED "${SHAOLIN_REPO_ROOT}/build/release/adapted")
foreach(f d3d8.cpp vertex.cpp shaders.cpp render_thread.cpp)
    if(NOT EXISTS "${SHAOLIN_ADAPTED}/${f}")
        message(FATAL_ERROR
            "Missing SHAOLIN-SPECIFIC XDK graphics adaptation ${SHAOLIN_ADAPTED}/${f}. Configure the native PC project first.")
    endif()
endforeach()
# ARM64 has no SSE4.1. The pinned Linux render thread contains an
# x86-only 16-byte state comparison. Replace precisely that function with
# equivalent std::memcmp, preserving the rest of its threading/ordering.
file(READ "${SHAOLIN_ADAPTED}/render_thread.cpp" SHAOLIN_RENDER_THREAD)
string(REPLACE "#include <smmintrin.h>" "// portable ARM64 state comparison"
       SHAOLIN_RENDER_THREAD "${SHAOLIN_RENDER_THREAD}")
string(FIND "${SHAOLIN_RENDER_THREAD}" "bool Same(const uint8_t* a, const uint8_t* b, size_t n) {" SHAOLIN_SAME_BEGIN)
string(FIND "${SHAOLIN_RENDER_THREAD}" "using Clock = std::chrono::steady_clock;" SHAOLIN_SAME_END)
if(SHAOLIN_SAME_BEGIN EQUAL -1 OR SHAOLIN_SAME_END EQUAL -1 OR
   SHAOLIN_SAME_END LESS SHAOLIN_SAME_BEGIN)
    message(FATAL_ERROR "Cannot port pinned SSE render state comparison to ARM64")
endif()
string(SUBSTRING "${SHAOLIN_RENDER_THREAD}" 0 ${SHAOLIN_SAME_BEGIN} SHAOLIN_PREFIX)
string(SUBSTRING "${SHAOLIN_RENDER_THREAD}" ${SHAOLIN_SAME_END} -1 SHAOLIN_SUFFIX)
set(SHAOLIN_RENDER_THREAD
  "${SHAOLIN_PREFIX}bool Same(const uint8_t* a, const uint8_t* b, size_t n) { return std::memcmp(a,b,n)==0; }\\n\\n${SHAOLIN_SUFFIX}")
set(SHAOLIN_ARM64_RENDER_THREAD "${CMAKE_CURRENT_BINARY_DIR}/shaolin_render_thread_arm64.cpp")
file(WRITE "${SHAOLIN_ARM64_RENDER_THREAD}" "${SHAOLIN_RENDER_THREAD}")

find_library(shaolin_gles3 GLESv3 REQUIRED)
find_library(shaolin_egl EGL REQUIRED)

set(SHAOLIN_VK "${SHAOLIN_REPO_ROOT}/src/linux/vk")
target_sources(main PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/android_game_renderer.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/android_game_host.cpp"
    "${SHAOLIN_ADAPTED}/d3d8.cpp"
    "${SHAOLIN_ADAPTED}/vertex.cpp"
    "${SHAOLIN_ADAPTED}/shaders.cpp"
    "${SHAOLIN_ARM64_RENDER_THREAD}"
    "${XBE_SDK}/runtime/gpu/texture.cpp"
    "${XBE_SDK}/runtime/xdk/xapi.cpp"
    "${XBE_SDK}/runtime/core/input.cpp"
    "${SHAOLIN_REPO_ROOT}/src/raster_compat.cpp"
    "${SHAOLIN_VK}/vk_api.cpp"
    "${SHAOLIN_VK}/vk_shader.cpp"
    "${SHAOLIN_VK}/vk_backend.cpp"
    "${SHAOLIN_VK}/bc_decode.cpp"
    "${shaolin_android_imgui_SOURCE_DIR}/imgui.cpp"
    "${shaolin_android_imgui_SOURCE_DIR}/imgui_draw.cpp"
    "${shaolin_android_imgui_SOURCE_DIR}/imgui_tables.cpp"
    "${shaolin_android_imgui_SOURCE_DIR}/imgui_widgets.cpp"
    "${shaolin_android_imgui_SOURCE_DIR}/backends/imgui_impl_vulkan.cpp")

target_include_directories(main PRIVATE
    "${SHAOLIN_REPO_ROOT}/src"
    "${SHAOLIN_REPO_ROOT}/src/linux/compat"
    "${shaolin_android_imgui_SOURCE_DIR}"
    "${glslang_SOURCE_DIR}")
foreach(vulkan_source
    "${SHAOLIN_VK}/vk_api.cpp"
    "${SHAOLIN_VK}/vk_backend.cpp"
    "${shaolin_android_imgui_SOURCE_DIR}/backends/imgui_impl_vulkan.cpp")
    set_source_files_properties("${vulkan_source}"
        PROPERTIES COMPILE_DEFINITIONS "VK_NO_PROTOTYPES;IMGUI_IMPL_VULKAN_NO_PROTOTYPES")
endforeach()
set_source_files_properties("${SHAOLIN_VK}/vk_shader.cpp"
    PROPERTIES COMPILE_DEFINITIONS "ENABLE_HLSL=1")
target_link_libraries(main PRIVATE
    ${shaolin_gles3} ${shaolin_egl}
    glslang::glslang glslang::glslang-default-resource-limits)
message(STATUS "Native GAME renderer enabled: actual D3D8 HLE + Shaolin Vulkan renderer + GLES3 backend (not animated test)")
