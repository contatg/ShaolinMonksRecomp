# Android-only copies of pinned SDK files. Fail if an upstream anchor changes.
function(shaolin_replace_once variable before after)
    string(FIND "${${variable}}" "${before}" first)
    if(first EQUAL -1)
        message(FATAL_ERROR "Missing Android runtime adaptation: ${before}")
    endif()
    string(LENGTH "${before}" count)
    math(EXPR tail_start "${first} + ${count}")
    string(SUBSTRING "${${variable}}" ${tail_start} -1 tail)
    string(FIND "${tail}" "${before}" duplicate)
    if(NOT duplicate EQUAL -1)
        message(FATAL_ERROR "Ambiguous Android runtime adaptation: ${before}")
    endif()
    string(REPLACE "${before}" "${after}" updated "${${variable}}")
    set(${variable} "${updated}" PARENT_SCOPE)
endfunction()

function(shaolin_prepare_android_log output)
    file(READ "${XBE_SDK}/runtime/core/log.cpp" source)
    # A pipe-reader thread can lose the final message when kernel::_Exit runs.
    shaolin_replace_once(source
        "    std::fwrite(line, 1, size_t(n), stderr);"
        "    std::fwrite(line, 1, size_t(n), stderr);\n    shaolin_android::Trace(\"XBOX_KERNEL %s\", line);")
    set(path "${CMAKE_CURRENT_BINARY_DIR}/shaolin_log_android.cpp")
    shaolin_write_if_changed("${path}" "#include \"shaolin_game_trace.h\"\n${source}")
    set(${output} "${path}" PARENT_SCOPE)
endfunction()

function(shaolin_prepare_android_boot output)
    file(READ "${XBE_SDK}/runtime/kernel/boot.cpp" source)
    shaolin_replace_once(source
        "void Shutdown(int code) {"
        "void Shutdown(int code) {\n    shaolin_android::Trace(\"KERNEL_SHUTDOWN code=%d\", code);")
    shaolin_replace_once(source
        "#else\n    char self[4096] = {};"
        "#elif defined(__ANDROID__)\n    shaolin_android::Trace(\"KERNEL_RELAUNCH_UNSUPPORTED %s\", exe);\n    Shutdown(6);\n#else\n    char self[4096] = {};")
    set(path "${CMAKE_CURRENT_BINARY_DIR}/shaolin_boot_android.cpp")
    shaolin_write_if_changed("${path}" "#include \"shaolin_game_trace.h\"\n${source}")
    set(${output} "${path}" PARENT_SCOPE)
endfunction()

function(shaolin_prepare_android_d3d adapted output)
    file(READ "${adapted}" source)
    shaolin_replace_once(source
        "        g_backend = gpu::CreateBackend();\n        if (!g_backend->Init(w, h)) LOGE(\"d3d: renderer init failed\");"
        "        if (!shaolin_android::InitializeGameBackend(g_backend, w, h)) {\n            LOGE(\"d3d: renderer init failed; device was not created\");\n            if (a[5]) W32(a[5], 0);\n            W32(kDevicePtr, 0);\n            shaolin_android::ReportGraphicsFailure(\"D3D8 renderer initialization failed\");\n            return 0x8876086Au; // D3DERR_NOTAVAILABLE\n        }")
    set(path "${CMAKE_CURRENT_BINARY_DIR}/shaolin_d3d8_android.cpp")
    shaolin_write_if_changed("${path}" "#include \"android_backend_init.h\"\n#include \"android_graphics_host.h\"\n${source}")
    set(${output} "${path}" PARENT_SCOPE)
endfunction()
