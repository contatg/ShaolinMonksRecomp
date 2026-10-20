cmake_minimum_required(VERSION 3.22)
project(ShaolinMobiuBringup LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 20)
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
add_library(main SHARED
    main.cpp
    xbox_bootstrap.cpp
    "${SHAOLIN_DISC_ANDROID_CPP}"
    "${XBE_SDK}/runtime/kernel/memory.cpp"
    "${XBE_SDK}/runtime/core/log.cpp")
# Must precede XBE_SDK runtime so bootstrap sees OpenFd and the patched
# Disc object uses the same private layout. Other vendor sources stay intact.
target_include_directories(main BEFORE PRIVATE "${SHAOLIN_SAF_DISC_OVERLAY}")
target_include_directories(main PRIVATE "${XBE_SDK}/runtime")
# Upstream POSIX guest allocator uses ftruncate but does not include unistd.h.
# Inject the Android POSIX declaration only for this source, preserving SDK files.
set_source_files_properties("${XBE_SDK}/runtime/kernel/memory.cpp"
    PROPERTIES COMPILE_OPTIONS "-include;unistd.h")
target_link_libraries(main PRIVATE SDL3::SDL3 ${android-lib} ${log-lib} ${vulkan-lib})
target_link_options(main PRIVATE -Wl,-z,max-page-size=16384)

# Locally generated real Shaolin guest code; never part of the public test APK.
include("${CMAKE_CURRENT_SOURCE_DIR}/shaolin_guest.cmake")
