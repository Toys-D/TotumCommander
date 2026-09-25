#pragma once
/// @file archive_types.h
#include <string>
#include <cstdint>
#include <clocale>
#include <cstring>
#include <mutex>
namespace fcxl::archive {

/// libarchive converts entry names through the process locale (iconv), and a GUI process is
/// born with the "C" locale — no UTF-8. macOS filenames ARE UTF-8, so without this every
/// non-ASCII name fails with "Can't translate pathname" the moment a header is written or a
/// pax/Joliet header is read. Idempotent, called at every archive entry point; LC_CTYPE only,
/// so number formatting everywhere else stays untouched.
inline void ensure_utf8_ctype() {
    static std::once_flag flag;
    std::call_once(flag, [] {
        const char* current = std::setlocale(LC_CTYPE, nullptr);
        if (current == nullptr || std::strstr(current, "UTF-8") == nullptr) {
            if (std::setlocale(LC_CTYPE, "en_US.UTF-8") == nullptr) {
                std::setlocale(LC_CTYPE, "UTF-8");
            }
        }
    });
}
// Appended at the end on purpose: the bridge maps by name, but nothing may reorder cases.
enum class ArchiveFormat { ZIP, TAR, TAR_GZ, TAR_BZ2, TAR_XZ, SevenZip, RAR, DMG, ISO, TAR_ZST, TAR_LZ, TAR_LZ4 };

[[nodiscard]] inline constexpr bool is_writable_archive_format(ArchiveFormat format) {
    switch (format) {
        case ArchiveFormat::ZIP:
        case ArchiveFormat::TAR:
        case ArchiveFormat::TAR_GZ:
        case ArchiveFormat::TAR_BZ2:
        case ArchiveFormat::TAR_XZ:
        case ArchiveFormat::TAR_ZST:
        case ArchiveFormat::TAR_LZ:
        case ArchiveFormat::TAR_LZ4:
        case ArchiveFormat::SevenZip:
        // ISO is writable through libarchive's iso9660 writer. DMG is not: nothing in
        // libarchive reads or writes it, so it stays out until an hdiutil path exists.
        case ArchiveFormat::ISO:
            return true;
        default:
            return false;
    }
}

struct ArchiveEntry {
    std::string path;
    uint64_t compressed_size = 0;
    uint64_t uncompressed_size = 0;
    bool is_directory = false;
    bool is_encrypted = false;
    std::string method;
};
struct ArchiveInfo {
    ArchiveFormat format;
    uint64_t total_size = 0;
    uint64_t total_uncompressed = 0;
    uint64_t entry_count = 0;
    bool is_encrypted = false;
    bool is_multivolume = false;
};
} // namespace fcxl::archive
