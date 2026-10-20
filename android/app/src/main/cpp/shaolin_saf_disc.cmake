# Android SAF fix: the user already granted a readable descriptor. Some
# Android document providers forbid open("/proc/self/fd/N") even when pread
# on the original descriptor works. Duplicate the granted fd instead.
# Keep the XboxXBERecomp vendor checkout UNMODIFIED.
set(SHAOLIN_DISC_SRC "${XBE_SDK}/runtime/kernel/disc.cpp")
set(SHAOLIN_DISC_HEADER "${XBE_SDK}/runtime/kernel/disc.h")
file(READ "${SHAOLIN_DISC_SRC}" SHAOLIN_DISC_CPP)
file(READ "${SHAOLIN_DISC_HEADER}" SHAOLIN_DISC_H)

set(SHAOLIN_DISC_OPEN_SIGNATURE
    [=[    for (uint64_t base : kPartitions) {]=])
set(SHAOLIN_DISC_OPEN_FD
[=[    return ScanImage(error);
}

// Android SAF: duplicate the existing granted read-only fd. dup() neither
// reopens the content:// URI nor reads/copies the ISO. Disc owns its duplicate
// until the Xbox D: mount is released.
bool Disc::OpenFd(int granted_fd, std::string& error) {
#ifdef _WIN32
    (void)granted_fd;
    error = "OpenFd is only available on POSIX";
    return false;
#else
    if (file_ != -1) {
        error = "the disc is already open";
        return false;
    }
    if (granted_fd < 0) {
        error = "invalid Android document descriptor";
        return false;
    }
    const int own_fd = dup(granted_fd);
    if (own_fd == -1) {
        error = "cannot duplicate Android document descriptor";
        return false;
    }
    file_ = own_fd;
    path_ = "Android SAF ISO";
    return ScanImage(error);
#endif
}

bool Disc::ScanImage(std::string& error) {
    for (uint64_t base : kPartitions) {]=])
string(FIND "${SHAOLIN_DISC_CPP}" "${SHAOLIN_DISC_OPEN_SIGNATURE}" SHAOLIN_DISC_ANCHOR)
if(SHAOLIN_DISC_ANCHOR EQUAL -1)
    message(FATAL_ERROR "Pinned XboxXBERecomp Disc::Open changed, cannot safely patch Android SAF")
endif()
string(REPLACE "${SHAOLIN_DISC_OPEN_SIGNATURE}" "${SHAOLIN_DISC_OPEN_FD}"
       SHAOLIN_DISC_CPP "${SHAOLIN_DISC_CPP}")

set(SHAOLIN_DISC_DECL_OLD
    [=[    bool Open(const std::filesystem::path& path, std::string& error);]=])
set(SHAOLIN_DISC_DECL_NEW
[=[    bool Open(const std::filesystem::path& path, std::string& error);
    // Uses dup() to retain ownership of the Android SAF document fd.
    bool OpenFd(int granted_fd, std::string& error);]=])
string(FIND "${SHAOLIN_DISC_H}" "${SHAOLIN_DISC_DECL_OLD}" SHAOLIN_DECL_ANCHOR)
if(SHAOLIN_DECL_ANCHOR EQUAL -1)
    message(FATAL_ERROR "Pinned XboxXBERecomp disc header changed; check before patching")
endif()
string(REPLACE "${SHAOLIN_DISC_DECL_OLD}" "${SHAOLIN_DISC_DECL_NEW}"
       SHAOLIN_DISC_H "${SHAOLIN_DISC_H}")
set(SHAOLIN_SCAN_PRIVATE_OLD [=[    uint32_t ReadAt(uint64_t at, void* out, uint32_t len) const;]=])
set(SHAOLIN_SCAN_PRIVATE_NEW
[=[    bool ScanImage(std::string& error);
    uint32_t ReadAt(uint64_t at, void* out, uint32_t len) const;]=])
string(FIND "${SHAOLIN_DISC_H}" "${SHAOLIN_SCAN_PRIVATE_OLD}" SHAOLIN_SCAN_ANCHOR)
if(SHAOLIN_SCAN_ANCHOR EQUAL -1)
    message(FATAL_ERROR "Disc::ReadAt changed, cannot safely insert private scanner")
endif()
string(REPLACE "${SHAOLIN_SCAN_PRIVATE_OLD}" "${SHAOLIN_SCAN_PRIVATE_NEW}"
       SHAOLIN_DISC_H "${SHAOLIN_DISC_H}")

set(SHAOLIN_SAF_DISC_OVERLAY "${CMAKE_CURRENT_BINARY_DIR}/shaolin_saf_disc")
file(MAKE_DIRECTORY "${SHAOLIN_SAF_DISC_OVERLAY}/kernel")
shaolin_write_if_changed("${SHAOLIN_SAF_DISC_OVERLAY}/kernel/disc.h" "${SHAOLIN_DISC_H}")
set(SHAOLIN_DISC_ANDROID_CPP "${CMAKE_CURRENT_BINARY_DIR}/shaolin_disc_saf_android.cpp")
shaolin_write_if_changed("${SHAOLIN_DISC_ANDROID_CPP}" "${SHAOLIN_DISC_CPP}")
message(STATUS "Android XDVDFS: direct SAF fd + dup(), no /proc/self/fd reopen and no multi-GB ISO copy")
