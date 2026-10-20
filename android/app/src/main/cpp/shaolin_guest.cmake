# Compile the Shaolin Monks static-recompiled Xbox x86 functions to real
# Android ARM64 .o files. Input is generated privately from the user's own
# original default.xbe. No game code is fetched, checked in, or uploaded by CI.
#
# This compile-only milestone deliberately does NOT link the guest code into
# libmain.so: kernel/XDK hooks and the game-specific Android Vulkan renderer
# must be ported first. Failing to link unresolved game entrypoints is safer
# than shipping an APK that falsely claims it can execute the title.
option(SHAOLIN_ENABLE_GUEST_OBJECTS
    "Compile locally generated Shaolin game code into ARM64 objects" OFF)
option(SHAOLIN_EMBED_NATIVE_GUEST
    "Private local APK: embed recomp Xbox functions into SDL main library" OFF)
if(SHAOLIN_EMBED_NATIVE_GUEST AND NOT SHAOLIN_ENABLE_GUEST_OBJECTS)
    message(FATAL_ERROR "Embedding Xbox guest code requires SHAOLIN_ENABLE_GUEST_OBJECTS=ON")
endif()

if(SHAOLIN_ENABLE_GUEST_OBJECTS)
    get_filename_component(SHAOLIN_REPO_ROOT
        "${CMAKE_CURRENT_LIST_DIR}/../../../../.." ABSOLUTE)
    set(SHAOLIN_PRIVATE_GEN "${SHAOLIN_REPO_ROOT}/android/generated/shaolin")
    set(SHAOLIN_GENERATED_SOURCES
        "${SHAOLIN_PRIVATE_GEN}/x86_func_mapping.cpp")
    foreach(part RANGE 127)
        list(APPEND SHAOLIN_GENERATED_SOURCES
            "${SHAOLIN_PRIVATE_GEN}/x86_recomp.${part}.cpp")
    endforeach()
    foreach(src IN LISTS SHAOLIN_GENERATED_SOURCES)
        if(NOT EXISTS "${src}")
            message(FATAL_ERROR
                "No original Xbox translated source: ${src}. "
                "Run android/Preparar-XBE-Android.ps1 on your own default.xbe first.")
        endif()
    endforeach()
    if(NOT EXISTS "${SHAOLIN_PRIVATE_GEN}/x86_recomp_shared.h"
       OR NOT EXISTS "${SHAOLIN_PRIVATE_GEN}/image_symbols.h"
       OR NOT EXISTS "${SHAOLIN_PRIVATE_GEN}/mod_routine_targets.h")
        message(FATAL_ERROR
            "Private generated Xbox headers missing; run the local recompiler.")
    endif()
    if(NOT EXISTS "${SHAOLIN_REPO_ROOT}/src/mods/routine_bridge.h")
        message(FATAL_ERROR "Missing original Shaolin recomp mod routine bridge")
    endif()

    # This intentionally builds .o files only. Linking the full game requires
    # Android implementations of the host-provided Xbox kernel/XDK exports.
    add_library(shaolin_guest_arm64 OBJECT EXCLUDE_FROM_ALL
        ${SHAOLIN_GENERATED_SOURCES})
    target_include_directories(shaolin_guest_arm64 PRIVATE
        "${XBE_SDK}/runtime"
        "${SHAOLIN_PRIVATE_GEN}"
        "${SHAOLIN_REPO_ROOT}/src")
    target_compile_options(shaolin_guest_arm64 PRIVATE
        -O1
        -fno-strict-aliasing
        -fsigned-char
        -Wno-unused-label
        -Wno-unused-variable
        -Wno-parentheses-equality
        -include
        "${SHAOLIN_REPO_ROOT}/src/mods/routine_bridge.h")
    set_target_properties(shaolin_guest_arm64 PROPERTIES
        POSITION_INDEPENDENT_CODE ON)

    # The portable Xbox x86 dispatcher implements kernel calls, guest indirect
    # calls, CPUID, guest TSC and privileged-instruction handling. The upstream
    # dispatch.cpp unnecessarily includes x86intrin.h even though this source
    # uses no host x86 intrinsic. Prepare an Android-specific build copy without
    # modifying or pin-diverging the original XboxXBERecomp checkout.
    set(SHAOLIN_DISPATCH_ORIGINAL "${XBE_SDK}/runtime/cpu/dispatch.cpp")
    if(NOT EXISTS "${SHAOLIN_DISPATCH_ORIGINAL}")
        message(FATAL_ERROR "XboxXBERecomp CPU dispatcher is missing")
    endif()
    file(READ "${SHAOLIN_DISPATCH_ORIGINAL}" SHAOLIN_DISPATCH_SOURCE)
    string(REPLACE "#include <x86intrin.h>"
        "// No x86 host intrinsics are used; this port targets ARM64."
        SHAOLIN_DISPATCH_SOURCE "${SHAOLIN_DISPATCH_SOURCE}")
    set(SHAOLIN_DISPATCH_ANDROID "${CMAKE_CURRENT_BINARY_DIR}/shaolin_dispatch_android.cpp")
    file(WRITE "${SHAOLIN_DISPATCH_ANDROID}" "${SHAOLIN_DISPATCH_SOURCE}")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
        "${SHAOLIN_DISPATCH_ORIGINAL}")
    add_library(shaolin_dispatch_arm64 OBJECT EXCLUDE_FROM_ALL
        "${SHAOLIN_DISPATCH_ANDROID}")
    target_include_directories(shaolin_dispatch_arm64 PRIVATE
        "${XBE_SDK}/runtime" "${SHAOLIN_PRIVATE_GEN}")
    target_compile_options(shaolin_dispatch_arm64 PRIVATE
        -O1 -fno-strict-aliasing -fsigned-char)
    set_target_properties(shaolin_dispatch_arm64 PROPERTIES
        POSITION_INDEPENDENT_CODE ON)
    # Actual public Xbox kernel ordinal names and a guarded guest memory-base
    # binding. Keep this out of libmain.so until boot integration is ready.
    add_library(shaolin_kernel_symbols_arm64 OBJECT EXCLUDE_FROM_ALL
        "${XBE_SDK}/runtime/kernel/ordinals.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/shaolin_kernel_bindings.cpp")
    target_include_directories(shaolin_kernel_symbols_arm64 PRIVATE
        "${XBE_SDK}/runtime" "${SHAOLIN_PRIVATE_GEN}")
    set_target_properties(shaolin_kernel_symbols_arm64 PROPERTIES
        POSITION_INDEPENDENT_CODE ON)
    # Compile the ACTUAL PC Krypt routine engine, not a no-op replacement.
    # The Windows host recompiler's pinned FetchContent already has Lua 5.4.9.
    # This remains an opt-in, local-only build until a full Android guest boot
    # with game files, XDK exports, and renderer is implemented.
    set(SHAOLIN_LOCAL_LUA "${SHAOLIN_REPO_ROOT}/build/release/_deps/shaolin_lua-src/src")
    if(NOT EXISTS "${SHAOLIN_LOCAL_LUA}/lua.h"
       OR NOT EXISTS "${SHAOLIN_LOCAL_LUA}/lapi.c")
        message(FATAL_ERROR
            "Pinned Lua sources missing from ${SHAOLIN_LOCAL_LUA}. "
            "Run android/Preparar-XBE-Android.ps1 first (which configures the PC runtime).")
    endif()
    file(GLOB SHAOLIN_LUA_C_SOURCES CONFIGURE_DEPENDS
        "${SHAOLIN_LOCAL_LUA}/*.c")
    set(SHAOLIN_LUA_RUNTIME_SOURCES "")
    foreach(lua_source IN LISTS SHAOLIN_LUA_C_SOURCES)
        get_filename_component(lua_name "${lua_source}" NAME)
        if(NOT lua_name STREQUAL "lua.c" AND NOT lua_name STREQUAL "luac.c")
            list(APPEND SHAOLIN_LUA_RUNTIME_SOURCES "${lua_source}")
        endif()
    endforeach()
    if(NOT SHAOLIN_LUA_RUNTIME_SOURCES)
        message(FATAL_ERROR "No Lua 5.4.9 runtime C sources found for Android.")
    endif()
    add_library(shaolin_krypt_routines_arm64 OBJECT EXCLUDE_FROM_ALL
        "${SHAOLIN_REPO_ROOT}/src/mods/routines.cpp"
        "${SHAOLIN_REPO_ROOT}/src/mods/runtime.cpp"
        "${SHAOLIN_REPO_ROOT}/src/mods/game_targets.cpp"
        ${SHAOLIN_LUA_RUNTIME_SOURCES})
    target_include_directories(shaolin_krypt_routines_arm64 PRIVATE
        "${SHAOLIN_LOCAL_LUA}" "${SHAOLIN_REPO_ROOT}/src"
        "${XBE_SDK}/runtime" "${SHAOLIN_PRIVATE_GEN}")
    target_compile_options(shaolin_krypt_routines_arm64 PRIVATE
        -O1 -fno-strict-aliasing)
    set_target_properties(shaolin_krypt_routines_arm64 PROPERTIES
        POSITION_INDEPENDENT_CODE ON)

    # Genuine Xbox kernel, object manager, thread scheduler and RTL services.
    # Build as isolated ARM64 objects first: this exposes source-level ARM64
    # incompatibilities without changing the tested launcher binary.
    add_library(shaolin_xbox_kernel_arm64 OBJECT EXCLUDE_FROM_ALL
        "${XBE_SDK}/runtime/kernel/objects.cpp"
        "${XBE_SDK}/runtime/kernel/threads.cpp"
        "${XBE_SDK}/runtime/kernel/rtl.cpp"
        "${XBE_SDK}/runtime/kernel/xboxkrnl.cpp"
        "${XBE_SDK}/runtime/kernel/crypto.cpp")
    target_include_directories(shaolin_xbox_kernel_arm64 PRIVATE
        "${XBE_SDK}/runtime" "${SHAOLIN_PRIVATE_GEN}"
        "${SHAOLIN_REPO_ROOT}/src")
    target_compile_options(shaolin_xbox_kernel_arm64 PRIVATE
        -O1 -fno-strict-aliasing)
    set_target_properties(shaolin_xbox_kernel_arm64 PROPERTIES
        POSITION_INDEPENDENT_CODE ON)

    # Following Black-mobiu's portable SDK boot architecture: compile
    # the actual Xbox boot coordinator and host file service separately.
    # These depend on game-specific graphics/input/host services, so keep
    # them isolated until those dependencies are implemented.
    add_library(shaolin_xbox_boot_arm64 OBJECT EXCLUDE_FROM_ALL
        "${XBE_SDK}/runtime/kernel/boot.cpp"
        "${XBE_SDK}/runtime/kernel/files.cpp")
    target_include_directories(shaolin_xbox_boot_arm64 PRIVATE
        "${XBE_SDK}/runtime" "${SHAOLIN_PRIVATE_GEN}"
        "${SHAOLIN_REPO_ROOT}/src")
    target_compile_options(shaolin_xbox_boot_arm64 PRIVATE
        -O1 -fno-strict-aliasing)
    set_target_properties(shaolin_xbox_boot_arm64 PROPERTIES
        POSITION_INDEPENDENT_CODE ON)

    # Android-specific app metadata for the genuine Xbox boot coordinator,
    # without pulling Windows launcher/controller dependencies into Android.
    add_library(shaolin_android_boot_host_arm64 OBJECT EXCLUDE_FROM_ALL
        "${CMAKE_CURRENT_SOURCE_DIR}/shaolin_android_app.cpp")
    target_include_directories(shaolin_android_boot_host_arm64 PRIVATE
        "${XBE_SDK}/runtime" "${SHAOLIN_PRIVATE_GEN}")
    set_target_properties(shaolin_android_boot_host_arm64 PROPERTIES
        POSITION_INDEPENDENT_CODE ON)

    # Build a genuine Android shared-library link probe with all recompiled
    # guest functions + Xbox CPU dispatch + original Krypt Lua engine.
    # This deliberately has NO game-entry invocation and is NOT packaged into
    # the launcher; the complete kernel/XDK and renderer are not wired yet.
    add_library(shaolin_game_link_probe SHARED EXCLUDE_FROM_ALL
        $<TARGET_OBJECTS:shaolin_guest_arm64>
        $<TARGET_OBJECTS:shaolin_dispatch_arm64>
        $<TARGET_OBJECTS:shaolin_kernel_symbols_arm64>
        $<TARGET_OBJECTS:shaolin_krypt_routines_arm64>
        "${XBE_SDK}/runtime/kernel/memory.cpp"
        "${XBE_SDK}/runtime/core/log.cpp")
    target_include_directories(shaolin_game_link_probe PRIVATE
        "${XBE_SDK}/runtime" "${SHAOLIN_PRIVATE_GEN}" "${SHAOLIN_REPO_ROOT}/src")
    target_compile_options(shaolin_game_link_probe PRIVATE
        -O1 -fno-strict-aliasing)
    target_link_libraries(shaolin_game_link_probe PRIVATE
        ${log-lib} m dl)
    target_link_options(shaolin_game_link_probe PRIVATE
        "-Wl,--no-undefined" "-Wl,-z,max-page-size=16384")
    if(SHAOLIN_EMBED_NATIVE_GUEST)
        # In contrast to the independent link probe, all guest/CPU/Krypt
        # code now lives INSIDE the native SDL main library. Share one real
        # Xbox guest memory manager and logger from the original preboot.
        target_sources(main PRIVATE
            $<TARGET_OBJECTS:shaolin_guest_arm64>
            $<TARGET_OBJECTS:shaolin_dispatch_arm64>
            $<TARGET_OBJECTS:shaolin_kernel_symbols_arm64>
            $<TARGET_OBJECTS:shaolin_krypt_routines_arm64>
            "${CMAKE_CURRENT_SOURCE_DIR}/xbox_game_runtime.cpp")
        target_include_directories(main PRIVATE
            "${SHAOLIN_PRIVATE_GEN}"
            "${SHAOLIN_REPO_ROOT}/src")
        target_compile_definitions(main PRIVATE SHAOLIN_NATIVE_GUEST=1)
        target_link_libraries(main PRIVATE m)
        target_link_options(main PRIVATE "-Wl,--no-undefined")
        message(STATUS
            "Private game APK: 129 Xbox guest objects + CPU dispatcher + Krypt Lua embedded into libmain.so")
    endif()

    # Both object targets are only compiled locally, not packaged into a
    # playable APK before full kernel/XDK and graphics integration.
    message(STATUS
        "Shaolin guest ARM64: 128 recomp partitions + mapping, local/private input.")
endif()
