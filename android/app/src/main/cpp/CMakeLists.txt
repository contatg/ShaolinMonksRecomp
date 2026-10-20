cmake_minimum_required(VERSION 3.22)
project(ShaolinMobiuBringup LANGUAGES C CXX)
option(SHAOLIN_RUNTIME_COMPILE_CHECK "Compile public GameBoot sources without game code or APK" OFF)
if(SHAOLIN_RUNTIME_COMPILE_CHECK AND SHAOLIN_EMBED_NATIVE_GUEST)
    message(FATAL_ERROR "Compile-only validation cannot embed private game code")
endif()
set(CMAKE_CXX_STANDARD 20)
# Avoid rewriting generated Android vendor adaptations on every Git commit.
# Rewriting unchanged .cpp files makes Ninja needlessly recompile them.
function(shaolin_write_if_changed path content)
    if(EXISTS "${path}")
        file(READ "${path}" old_content)
        if("${old_content}" STREQUAL "${content}")
            return()
        endif()
    endif()
    file(WRITE "${path}" "${content}")
endfunction()

set(SDL_SHARED ON CACHE BOOL "" FORCE)
set(SDL_STATIC OFF CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_RENDER OFF CACHE BOOL "" FORCE)
set(SDL_GPU OFF CACHE BOOL "" FORCE)
set(SDL_CAMERA OFF CACHE BOOL "" FORCE)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/SDL"
                 "${CMAKE_CURRENT_BINARY_DIR}/SDL" EXCLUDE_FROM_ALL)
find_library(android-lib android REQUIRED)
find_library(log-lib log REQUIRED)
find_library(vulkan-lib vulkan REQUIRED)
set(XBE_SDK "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/XboxXBERecomp")
if(NOT EXISTS "${XBE_SDK}/runtime/kernel/disc.cpp")
    message(FATAL_ERROR "Pinned XboxXBERecomp runtime not found. Fetch it before configuring Android.")
endif()
include("${CMAKE_CURRENT_SOURCE_DIR}/shaolin_saf_disc.cmake")
include("${CMAKE_CURRENT_SOURCE_DIR}/shaolin_runtime_safety.cmake")
set(SHAOLIN_LOG_CPP "${XBE_SDK}/runtime/core/log.cpp")
if(SHAOLIN_EMBED_NATIVE_GUEST OR SHAOLIN_RUNTIME_COMPILE_CHECK)
    shaolin_prepare_android_log(SHAOLIN_LOG_CPP)
endif()
if(SHAOLIN_RUNTIME_COMPILE_CHECK)
    add_library(main OBJECT)
else()
    add_library(main SHARED)
endif()
target_sources(main PRIVATE
    main.cpp
    xbox_bootstrap.cpp
    "${SHAOLIN_DISC_ANDROID_CPP}"
    "${XBE_SDK}/runtime/kernel/memory.cpp"
    "${SHAOLIN_LOG_CPP}")
# Must precede XBE_SDK runtime so bootstrap sees OpenFd and the patched
# Disc object uses the same private layout. Other vendor sources stay intact.
target_include_directories(main BEFORE PRIVATE "${SHAOLIN_SAF_DISC_OVERLAY}")
target_include_directories(main PRIVATE "${XBE_SDK}/runtime" "${CMAKE_CURRENT_SOURCE_DIR}")
set(SHAOLIN_BUILD_REVISION "unknown" CACHE STRING "Source revision for device traces")
# Build revision is only used in the native diagnostic trace. Attaching it
# to the whole main target invalidated every D3D8/Vulkan/GLES C++ object
# whenever the Git commit changed, even for a one-line edit.
set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/shaolin_game_trace.cpp"
    PROPERTIES COMPILE_DEFINITIONS "SHAOLIN_BUILD_REVISION=\"${SHAOLIN_BUILD_REVISION}\"")
# Upstream POSIX guest allocator uses ftruncate but does not include unistd.h.
# Inject the Android POSIX declaration only for this source, preserving SDK files.
set_source_files_properties("${XBE_SDK}/runtime/kernel/memory.cpp"
    PROPERTIES COMPILE_OPTIONS "-include;unistd.h")
target_link_libraries(main PRIVATE SDL3::SDL3 ${android-lib} ${log-lib} ${vulkan-lib})
target_link_options(main PRIVATE -Wl,-z,max-page-size=16384)

# Locally generated real Shaolin guest code; never part of the public test APK.
if(SHAOLIN_RUNTIME_COMPILE_CHECK)
    get_filename_component(SHAOLIN_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
    if(NOT EXISTS "${SHAOLIN_CHECK_HEADERS}/image_symbols.h")
        message(FATAL_ERROR "Public compile-check metadata headers are missing")
    endif()
    shaolin_prepare_android_boot(SHAOLIN_ANDROID_BOOT_CPP)
    target_sources(main PRIVATE
        "${SHAOLIN_ANDROID_BOOT_CPP}"
        "${CMAKE_CURRENT_SOURCE_DIR}/android_log_redirect.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/shaolin_game_trace.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/shaolin_android_app.cpp"
        "${XBE_SDK}/runtime/kernel/threads.cpp"
        "${XBE_SDK}/runtime/kernel/objects.cpp"
        "${XBE_SDK}/runtime/kernel/files.cpp"
        "${XBE_SDK}/runtime/kernel/rtl.cpp"
        "${XBE_SDK}/runtime/kernel/xboxkrnl.cpp"
        "${XBE_SDK}/runtime/kernel/crypto.cpp")
    target_include_directories(main PRIVATE "${SHAOLIN_CHECK_HEADERS}" "${SHAOLIN_REPO_ROOT}/src")
    target_compile_definitions(main PRIVATE SHAOLIN_NATIVE_GUEST=1 SHAOLIN_REAL_GAME_BOOT=1)
    include("${CMAKE_CURRENT_SOURCE_DIR}/shaolin_game_graphics.cmake")
else()
    include("${CMAKE_CURRENT_SOURCE_DIR}/shaolin_guest.cmake")
endif()
