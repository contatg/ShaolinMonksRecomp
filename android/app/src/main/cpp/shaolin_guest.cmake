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
    # Both object targets are only compiled locally, not packaged into a
    # playable APK before full kernel/XDK and graphics integration.
    message(STATUS
        "Shaolin guest ARM64: 128 recomp partitions + mapping, local/private input.")
endif()
