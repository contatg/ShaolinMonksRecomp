// Native Xbox image preboot for Android ARM64.
// Reuses the upstream XDVDFS reader, XBE parser and guest memory map.
// This is genuine game image preparation, but NOT guest-code execution;
// the x86 recompilation dispatch table and game-specific systems remain to be linked.
#include "xbox_bootstrap.h"

#include <android/log.h>
#include <kernel/disc.h>
#include <kernel/memory.h>
#include <xbe/xbe.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

#define XB_INFO(...) __android_log_print(ANDROID_LOG_INFO, "ShaolinXbox", __VA_ARGS__)
#define XB_ERR(...) __android_log_print(ANDROID_LOG_ERROR, "ShaolinXbox", __VA_ARGS__)

namespace shaolin_android {
namespace {
constexpr size_t kMaxXbeBytes = 64u * 1024u * 1024u;
constexpr char kExpectedSha256[] = "48240902bf4a04eb89376217c529531032d3370749bcce91a194878cc49db74a";

// SHA-256 for exact identification of the recompiled game build.
// A mismatched executable must not be loaded as the audited Shaolin image.
constexpr uint32_t kSha256K[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

uint32_t Ror(uint32_t n, unsigned bits) { return (n >> bits) | (n << (32 - bits)); }
std::string Sha256(const std::vector<uint8_t>& bytes) {
    uint32_t hash[8] = {
        0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
        0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
    };
    auto block = [&](const uint8_t* data) {
        uint32_t w[64]{};
        for (int i = 0; i < 16; ++i) {
            w[i] = uint32_t(data[i*4]) << 24 | uint32_t(data[i*4+1]) << 16 |
                   uint32_t(data[i*4+2]) << 8 | uint32_t(data[i*4+3]);
        }
        for (int i = 16; i < 64; ++i) {
            const uint32_t a = Ror(w[i-15],7) ^ Ror(w[i-15],18) ^ (w[i-15] >> 3);
            const uint32_t b = Ror(w[i-2],17) ^ Ror(w[i-2],19) ^ (w[i-2] >> 10);
            w[i] = w[i-16] + a + w[i-7] + b;
        }
        uint32_t a=hash[0],b=hash[1],c=hash[2],d=hash[3],
                 e=hash[4],f=hash[5],g=hash[6],h=hash[7];
        for (int i = 0; i < 64; ++i) {
            const uint32_t S1 = Ror(e,6) ^ Ror(e,11) ^ Ror(e,25);
            const uint32_t ch = (e & f) ^ ((~e) & g);
            const uint32_t t1 = h + S1 + ch + kSha256K[i] + w[i];
            const uint32_t S0 = Ror(a,2) ^ Ror(a,13) ^ Ror(a,22);
            const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            const uint32_t t2 = S0 + maj;
            h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
        }
        const uint32_t end[8] = {a,b,c,d,e,f,g,h};
        for (int i = 0; i < 8; ++i) hash[i] += end[i];
    };
    const size_t full = bytes.size() / 64;
    for (size_t i = 0; i < full; ++i) block(bytes.data() + i*64);
    uint8_t tail[128]{};
    const size_t remain = bytes.size() % 64;
    if (remain) std::memcpy(tail, bytes.data() + full*64, remain);
    tail[remain] = 0x80;
    const uint64_t bits = uint64_t(bytes.size()) * 8;
    const size_t last = (remain >= 56) ? 128 : 64;
    for (size_t i = 0; i < 8; ++i) tail[last - 1 - i] = uint8_t(bits >> (i*8));
    block(tail);
    if (last == 128) block(tail + 64);
    char buffer[65]{};
    for (int i = 0; i < 8; ++i) std::snprintf(buffer + i*8, 9, "%08x", hash[i]);
    return buffer;
}

bool ReadStandaloneXbe(int fd, std::vector<uint8_t>& xbe) {
    struct stat st{};
    if (fstat(fd, &st) != 0) {
        XB_ERR("fstat XBE failed (errno=%d)", errno);
        return false;
    }
    if (st.st_size < 0 || (st.st_size > 0 && uint64_t(st.st_size) > kMaxXbeBytes)) {
        XB_ERR("standalone XBE has invalid size %lld", static_cast<long long>(st.st_size));
        return false;
    }
    size_t off = 0;
    xbe.reserve(st.st_size > 0 ? size_t(st.st_size) : 1024 * 1024);
    uint8_t buffer[64 * 1024];
    while (off < kMaxXbeBytes) {
        size_t len = std::min(sizeof(buffer), kMaxXbeBytes - off);
        ssize_t n = pread(fd, buffer, len, static_cast<off_t>(off));
        if (n < 0) {
            XB_ERR("XBE positional read failed at %zu: errno=%d", off, errno);
            return false;
        }
        if (!n) break;
        xbe.insert(xbe.end(), buffer, buffer + n);
        off += size_t(n);
    }
    if (off == kMaxXbeBytes) {
        uint8_t extra;
        if (pread(fd, &extra, 1, static_cast<off_t>(off)) > 0) {
            XB_ERR("standalone XBE exceeds 64MiB limit");
            return false;
        }
    }
    return xbe.size() >= 0x180;
}

bool ReadGameImage(int source_fd, std::vector<uint8_t>& xbe, std::unique_ptr<kernel::Disc>& disc_for_boot) {
    uint8_t magic[4]{};
    if (pread(source_fd, magic, sizeof magic, 0) != sizeof magic) {
        XB_ERR("Cannot read selected file header (non-seekable provider?)");
        return false;
    }
    if (std::memcmp(magic, "XBEH", 4) == 0) {
        XB_INFO("Standalone Xbox executable selected");
        return ReadStandaloneXbe(source_fd, xbe);
    }
    if (magic[0] == 'P' && magic[1] == 'K') {
        XB_ERR("ZIP game archives require extraction before native game boot");
        return false;
    }

    // Linux /proc/self/fd/N refers to the same Android-granted file, and the
    // upstream Disc::Open reopens it read-only to own the file lifetime.
    // Most local SAF providers expose a seekable regular file this way.
    const std::string fd_path = "/proc/self/fd/" + std::to_string(source_fd);
    auto disc = std::make_unique<kernel::Disc>();
    std::string error;
    if (!disc->Open(fd_path, error)) {
        XB_ERR("XDVDFS cannot open selected disc: %s (SAF provider may be non-seekable)", error.c_str());
        return false;
    }
    const kernel::Disc::Entry* entry = disc->Find("default.xbe");
    if (!entry || entry->dir || entry->size < 0x180 || entry->size > kMaxXbeBytes) {
        XB_ERR("XDVDFS has no valid default.xbe entry");
        return false;
    }
    if (!disc->Load("default.xbe", xbe)) {
        XB_ERR("XDVDFS could not load default.xbe");
        return false;
    }
    XB_INFO("XDVDFS parsed, default.xbe extracted to RAM (%zu bytes)", xbe.size());

    // Keep ownership until the hash and XBE structure have been verified.
    disc_for_boot = std::move(disc);
    return true;
}

uint32_t GetU32(const std::vector<uint8_t>& bytes, size_t at) {
    uint32_t result = 0;
    std::memcpy(&result, bytes.data() + at, 4);
    return result;
}

bool ValidateXbeBounds(const std::vector<uint8_t>& bytes) {
    if (bytes.size() < 0x180 || bytes.size() > kMaxXbeBytes ||
        std::memcmp(bytes.data(), "XBEH", 4)) return false;

    const uint32_t base = GetU32(bytes, 0x104);
    const uint32_t headers = GetU32(bytes, 0x108);
    const uint32_t image_size = GetU32(bytes, 0x10C);
    const uint32_t sec_count = GetU32(bytes, 0x11C);
    const uint32_t sec_address = GetU32(bytes, 0x120);
    const uint32_t lib_count = GetU32(bytes, 0x160);
    const uint32_t lib_address = GetU32(bytes, 0x164);
    const uint32_t cert = GetU32(bytes, 0x118);

    if (base < 0x10000 || headers < 0x180 || headers > bytes.size() ||
        image_size < headers || uint64_t(base) + image_size >= 0x7FFE0000ull ||
        sec_count == 0 || sec_count > 256 || lib_count > 256 ||
        sec_address < base || uint64_t(sec_address - base) + 56ull * sec_count > bytes.size() ||
        (lib_count && (lib_address < base ||
           uint64_t(lib_address - base) + 16ull * lib_count > bytes.size())) ||
        (cert < base || uint64_t(cert - base) + 12 > bytes.size())) {
        return false;
    }
    for (uint32_t i = 0; i < sec_count; ++i) {
        const size_t off = size_t(sec_address - base) + i*56;
        const uint32_t address = GetU32(bytes, off + 4);
        const uint32_t virtual_size = GetU32(bytes, off + 8);
        const uint32_t raw = GetU32(bytes, off + 12);
        const uint32_t raw_size = GetU32(bytes, off + 16);
        const uint32_t name_address = GetU32(bytes, off + 20);
        if (address < base || uint64_t(address) + virtual_size > uint64_t(base) + image_size ||
            raw > bytes.size() || raw_size > bytes.size() - raw ||
            name_address < base || uint64_t(name_address - base) >= bytes.size()) {
            return false;
        }
    }
    return true;
}

} // namespace

bool PrepareXboxImage(int fd, uint32_t* loaded_entry,
                      uint32_t* loaded_kernel_thunk) {
    if (loaded_entry) *loaded_entry = 0;
    if (loaded_kernel_thunk) *loaded_kernel_thunk = 0;
    if (fd < 0) {
        XB_INFO("No Xbox game selected; native preboot skipped");
        return false;
    }
    std::vector<uint8_t> original_xbe;
    std::unique_ptr<kernel::Disc> disc_for_boot;
    if (!ReadGameImage(fd, original_xbe, disc_for_boot)) {
        XB_ERR("PREBOOT FAILED: cannot read the original game executable");
        return false;
    }
    const std::string hash = Sha256(original_xbe);
    if (hash != kExpectedSha256) {
        XB_ERR("PREBOOT FAILED: unsupported Xbox executable SHA256 %s", hash.c_str());
        return false;
    }
    XB_INFO("Original Shaolin Monks Xbox XBE SHA256 confirmed");

    if (!ValidateXbeBounds(original_xbe)) {
        XB_ERR("PREBOOT FAILED: invalid Xbox executable image boundaries");
        return false;
    }
    xbe::Image img;
    std::string error;
    if (!img.Parse(std::move(original_xbe), error)) {
        XB_ERR("PREBOOT FAILED: Xbox XBE parser: %s", error.c_str());
        return false;
    }
    XB_INFO("XBE parsed: entry=%08x, base=%08x, image=%u bytes, sections=%zu, libs=%zu",
            img.entry, img.base, img.image_size, img.sections.size(), img.libraries.size());

    if (!mem::Init()) {
        XB_ERR("PREBOOT FAILED: ARM64 could not reserve 4GiB Xbox guest address space");
        return false;
    }
    uint8_t* const guest = mem::Base();
    mem::ReserveImage(img.base, img.image_size);
    if (!mem::IsCommitted(img.base) ||
        !mem::IsCommitted(img.base + img.image_size - 1)) {
        XB_ERR("PREBOOT FAILED: guest executable image pages not committed");
        return false;
    }
    std::memcpy(guest + img.base, img.file.data(), img.header_size);
    size_t loaded = 0;
    for (const xbe::Section& section : img.sections) {
        if (!(section.flags & xbe::kPreload)) continue;
        const uint32_t count = std::min(section.rsize, section.vsize);
        if (!count) continue;
        std::memcpy(guest + section.va, img.file.data() + section.raw, count);
        ++loaded;
    }
    if (disc_for_boot) {
        kernel::MountDisc(std::move(disc_for_boot));
        XB_INFO("XDVDFS filesystem mounted read-only for future Xbox kernel file access");
    }
    XB_INFO("Xbox guest image loaded: %zu preload sections, entry=0x%08x, guest base=%p",
            loaded, img.entry, static_cast<void*>(guest));
    if (loaded_entry) *loaded_entry = img.entry;
    if (loaded_kernel_thunk) *loaded_kernel_thunk = img.kernel_thunk;
    XB_INFO("PREBOOT READY. Guest x86 code has NOT started; Xbox kernel/XDK services are not initialized.");
    return true;
}

} // namespace shaolin_android
