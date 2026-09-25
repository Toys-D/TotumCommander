#include "fcxl/archive/archive_reader.h"

#include <archive.h>
#include <archive_entry.h>

#include "mz.h"
#include "mz_strm.h"
#include "mz_zip.h"
#include "mz_zip_rw.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include <sys/stat.h>

namespace fcxl::archive {
namespace {

namespace stdfs = std::filesystem;

struct ReaderSession {
    std::string path;
    std::string password;
};

std::mutex g_reader_mutex;
std::unordered_map<const ArchiveReader*, ReaderSession> g_reader_sessions;
std::atomic_bool g_archive_cancelled{false};
std::atomic_size_t g_data_skip_call_count{0};

// Global process-level entry cache.
// Survives across ArchiveReader instances (bridge creates a new one per call).
// Single-slot LRU: sufficient for a file manager where one archive is active.
struct GlobalEntriesCache {
    std::string path;
    std::time_t mtime = 0;
    std::vector<ArchiveEntry> entries;
};
std::mutex g_entries_cache_mutex;
std::optional<GlobalEntriesCache> g_entries_cache;

using ArchiveReadPtr = std::unique_ptr<struct archive, decltype(&archive_read_free)>;
using ArchiveWritePtr = std::unique_ptr<struct archive, decltype(&archive_write_free)>;

auto make_error(common::ErrorCode code, std::string message, std::string path = "") -> common::Error {
    return common::Error::make(code, std::move(message), std::move(path));
}

auto cancelled_error(const std::string& path) -> common::Error {
    return make_error(common::ErrorCode::Cancelled, "Archive operation cancelled", path);
}

auto should_cancel(const std::atomic<bool>* cancelled) -> bool {
    if (g_archive_cancelled.load(std::memory_order_relaxed)) {
        return true;
    }
    return cancelled != nullptr && cancelled->load(std::memory_order_relaxed);
}

auto to_result_error(const std::string& message,
                     const std::string& path,
                     struct archive* handle = nullptr) -> common::Error {
    std::string details = message;
    if (handle != nullptr) {
        const char* archive_message = archive_error_string(handle);
        if (archive_message != nullptr && archive_message[0] != '\0') {
            details += ": ";
            details += archive_message;
        }
    }
    return make_error(common::ErrorCode::ArchiveError, std::move(details), path);
}

auto normalize_entry_path(std::string_view raw_path) -> std::string {
    std::string normalized(raw_path);

    while (normalized.rfind("./", 0) == 0) {
        normalized.erase(0, 2);
    }
    while (!normalized.empty() && normalized.front() == '/') {
        normalized.erase(normalized.begin());
    }

    return normalized;
}

auto trim_trailing_slash(std::string value) -> std::string {
    while (!value.empty() && value.back() == '/') {
        value.pop_back();
    }
    return value;
}

// Цель извлечения — это и сама запись, и всё, что лежит под ней: панель просит
// «docs», имея в виду папку с содержимым. Сравнение по каталогу, не по буквам —
// «docs2» и «docs.txt» не родня «docs».
auto entry_belongs_to_target(std::string_view comparable_entry, std::string_view target) -> bool {
    if (target.empty()) {
        return false;
    }
    if (comparable_entry == target) {
        return true;
    }
    return comparable_entry.size() > target.size() &&
        comparable_entry.compare(0, target.size(), target) == 0 &&
        comparable_entry[target.size()] == '/';
}

auto lowercase_copy(std::string value) -> std::string {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

auto format_hint_from_extension(const std::string& path) -> std::optional<ArchiveFormat> {
    const std::string lower = lowercase_copy(path);

    if (lower.size() >= 7 && lower.rfind(".tar.gz") == lower.size() - 7) {
        return ArchiveFormat::TAR_GZ;
    }
    if (lower.size() >= 4 && lower.rfind(".tgz") == lower.size() - 4) {
        return ArchiveFormat::TAR_GZ;
    }
    if (lower.size() >= 8 && lower.rfind(".tar.bz2") == lower.size() - 8) {
        return ArchiveFormat::TAR_BZ2;
    }
    if (lower.size() >= 5 && lower.rfind(".tbz2") == lower.size() - 5) {
        return ArchiveFormat::TAR_BZ2;
    }
    if (lower.size() >= 7 && lower.rfind(".tar.xz") == lower.size() - 7) {
        return ArchiveFormat::TAR_XZ;
    }
    if (lower.size() >= 4 && lower.rfind(".txz") == lower.size() - 4) {
        return ArchiveFormat::TAR_XZ;
    }
    if (lower.size() >= 4 && lower.rfind(".zip") == lower.size() - 4) {
        return ArchiveFormat::ZIP;
    }
    if (lower.size() >= 4 && lower.rfind(".tar") == lower.size() - 4) {
        return ArchiveFormat::TAR;
    }
    if (lower.size() >= 3 && lower.rfind(".gz") == lower.size() - 3) {
        return ArchiveFormat::TAR_GZ;
    }
    if (lower.size() >= 4 && lower.rfind(".bz2") == lower.size() - 4) {
        return ArchiveFormat::TAR_BZ2;
    }
    if (lower.size() >= 3 && lower.rfind(".xz") == lower.size() - 3) {
        return ArchiveFormat::TAR_XZ;
    }
    if (lower.size() >= 3 && lower.rfind(".7z") == lower.size() - 3) {
        return ArchiveFormat::SevenZip;
    }
    if (lower.size() >= 4 && lower.rfind(".rar") == lower.size() - 4) {
        return ArchiveFormat::RAR;
    }
    if (lower.size() >= 5 && lower.rfind(".tzst") == lower.size() - 5) {
        return ArchiveFormat::TAR_ZST;
    }
    if (lower.size() >= 4 && lower.rfind(".zst") == lower.size() - 4) {
        return ArchiveFormat::TAR_ZST;
    }
    if (lower.size() >= 4 && lower.rfind(".tlz") == lower.size() - 4) {
        return ArchiveFormat::TAR_LZ;
    }
    if (lower.size() >= 4 && lower.rfind(".lz4") == lower.size() - 4) {
        return ArchiveFormat::TAR_LZ4;
    }
    // AFTER .lz4: ".lz" is its suffix, and suffix matching would claim every lz4 file.
    if (lower.size() >= 3 && lower.rfind(".lz") == lower.size() - 3) {
        return ArchiveFormat::TAR_LZ;
    }
    if (lower.size() >= 4 && lower.rfind(".iso") == lower.size() - 4) {
        return ArchiveFormat::ISO;
    }

    return std::nullopt;
}

auto detect_magic_format(const std::array<unsigned char, 512>& header,
                         std::size_t bytes_read) -> std::optional<ArchiveFormat> {
    if (bytes_read >= 4 && header[0] == 'P' && header[1] == 'K' &&
        ((header[2] == 0x03 && header[3] == 0x04) ||
         (header[2] == 0x05 && header[3] == 0x06) ||
         (header[2] == 0x07 && header[3] == 0x08))) {
        return ArchiveFormat::ZIP;
    }

    if (bytes_read >= 2 && header[0] == 0x1F && header[1] == 0x8B) {
        return ArchiveFormat::TAR_GZ;
    }

    if (bytes_read >= 2 && header[0] == 'B' && header[1] == 'Z') {
        return ArchiveFormat::TAR_BZ2;
    }

    if (bytes_read >= 6 && header[0] == 0xFD && header[1] == '7' && header[2] == 'z' &&
        header[3] == 'X' && header[4] == 'Z') {
        return ArchiveFormat::TAR_XZ;
    }

    if (bytes_read >= 6 && header[0] == '7' && header[1] == 'z' && header[2] == 0xBC &&
        header[3] == 0xAF && header[4] == 0x27 && header[5] == 0x1C) {
        return ArchiveFormat::SevenZip;
    }

    if (bytes_read >= 4 && header[0] == 'R' && header[1] == 'a' &&
        header[2] == 'r' && header[3] == '!') {
        return ArchiveFormat::RAR;
    }

    if (bytes_read >= 262 && header[257] == 'u' && header[258] == 's' &&
        header[259] == 't' && header[260] == 'a' && header[261] == 'r') {
        return ArchiveFormat::TAR;
    }

    if (bytes_read >= 4 && header[0] == 0x28 && header[1] == 0xB5 &&
        header[2] == 0x2F && header[3] == 0xFD) {
        return ArchiveFormat::TAR_ZST;
    }

    if (bytes_read >= 4 && header[0] == 0x04 && header[1] == 0x22 &&
        header[2] == 0x4D && header[3] == 0x18) {
        return ArchiveFormat::TAR_LZ4;
    }

    if (bytes_read >= 4 && header[0] == 'L' && header[1] == 'Z' &&
        header[2] == 'I' && header[3] == 'P') {
        return ArchiveFormat::TAR_LZ;
    }

    return std::nullopt;
}

namespace {
/// ISO9660 keeps its "CD001" signature at byte 32769 (sector 16 of 2048 + 1) — far past the
/// 512-byte header every other format is recognised by. Probed separately, and only when the
/// ordinary magic scan found nothing, so no other format pays for the extra read.
auto looks_like_iso9660(const std::string& path) -> bool {
    std::ifstream input(path, std::ios::binary);
    if (!input.is_open()) {
        return false;
    }
    input.seekg(32769, std::ios::beg);
    std::array<char, 5> signature{};
    input.read(signature.data(), static_cast<std::streamsize>(signature.size()));
    if (input.gcount() != static_cast<std::streamsize>(signature.size())) {
        return false;
    }
    return signature[0] == 'C' && signature[1] == 'D' && signature[2] == '0' &&
           signature[3] == '0' && signature[4] == '1';
}
}  // namespace

auto validate_archive_signature(const std::string& path) -> common::Result<void> {
    std::ifstream input(path, std::ios::binary);
    if (!input.is_open()) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to open archive for signature check",
                          path);
    }

    std::array<unsigned char, 512> header{};
    input.read(reinterpret_cast<char*>(header.data()), static_cast<std::streamsize>(header.size()));
    const std::streamsize read_bytes = input.gcount();
    if (read_bytes <= 0) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Unknown or corrupted archive format",
                          path);
    }

    auto detected = detect_magic_format(header, static_cast<std::size_t>(read_bytes));
    if (!detected.has_value() && looks_like_iso9660(path)) {
        detected = ArchiveFormat::ISO;
    }
    if (!detected.has_value()) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Unknown or corrupted archive format",
                          path);
    }

    const auto hint = format_hint_from_extension(path);
    if (hint.has_value() && hint.value() != detected.value()) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Unknown or corrupted archive format",
                          path);
    }

    return {};
}

auto file_time_to_time_t(stdfs::file_time_type file_time) -> std::time_t {
    const auto system_time = std::chrono::time_point_cast<std::chrono::system_clock::duration>(
        file_time - stdfs::file_time_type::clock::now() + std::chrono::system_clock::now());
    return std::chrono::system_clock::to_time_t(system_time);
}

auto archive_mtime(const std::string& path) -> common::Result<std::time_t> {
    std::error_code ec;
    const auto write_time = stdfs::last_write_time(stdfs::path(path), ec);
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to read archive modification time",
                          path);
    }
    return file_time_to_time_t(write_time);
}

auto configure_reader(struct archive* reader, const std::string& password, const std::string& path)
    -> common::Result<void> {
    if (archive_read_support_filter_all(reader) < ARCHIVE_OK) {
        return to_result_error("Failed to enable archive filters", path, reader);
    }
    if (archive_read_support_format_all(reader) < ARCHIVE_OK) {
        return to_result_error("Failed to enable archive formats", path, reader);
    }
    if (!password.empty() && archive_read_add_passphrase(reader, password.c_str()) < ARCHIVE_OK) {
        return to_result_error("Failed to set archive password", path, reader);
    }

    return {};
}

auto open_archive_reader(const std::string& path, const std::string& password)
    -> common::Result<ArchiveReadPtr> {
    ArchiveReadPtr reader(archive_read_new(), &archive_read_free);
    if (!reader) {
        return make_error(common::ErrorCode::ArchiveError, "Failed to allocate archive reader", path);
    }

    const auto configure_result = configure_reader(reader.get(), password, path);
    if (!configure_result.has_value()) {
        return configure_result.error();
    }

    if (archive_read_open_filename(reader.get(), path.c_str(), 10240) < ARCHIVE_OK) {
        return to_result_error("Failed to open archive", path, reader.get());
    }

    return reader;
}

auto current_reader_session(const ArchiveReader* self) -> std::optional<ReaderSession> {
    std::lock_guard<std::mutex> lock(g_reader_mutex);
    const auto it = g_reader_sessions.find(self);
    if (it == g_reader_sessions.end()) {
        return std::nullopt;
    }
    return it->second;
}

auto format_from_handle(struct archive* reader) -> ArchiveFormat {
    const int base_format = archive_format(reader) & ARCHIVE_FORMAT_BASE_MASK;
    const int first_filter = archive_filter_code(reader, 0);

    if (base_format == ARCHIVE_FORMAT_ZIP) {
        return ArchiveFormat::ZIP;
    }
    if (base_format == ARCHIVE_FORMAT_7ZIP) {
        return ArchiveFormat::SevenZip;
    }
#ifdef ARCHIVE_FORMAT_RAR
#ifdef ARCHIVE_FORMAT_RAR_V5
    if (base_format == ARCHIVE_FORMAT_RAR || base_format == ARCHIVE_FORMAT_RAR_V5) {
#else
    if (base_format == ARCHIVE_FORMAT_RAR) {
#endif
        return ArchiveFormat::RAR;
    }
#endif
    if (base_format == ARCHIVE_FORMAT_ISO9660) {
        return ArchiveFormat::ISO;
    }
    if (base_format == ARCHIVE_FORMAT_TAR) {
        switch (first_filter) {
            case ARCHIVE_FILTER_GZIP:  return ArchiveFormat::TAR_GZ;
            case ARCHIVE_FILTER_BZIP2: return ArchiveFormat::TAR_BZ2;
            case ARCHIVE_FILTER_XZ:    return ArchiveFormat::TAR_XZ;
            case ARCHIVE_FILTER_ZSTD:  return ArchiveFormat::TAR_ZST;
            case ARCHIVE_FILTER_LZIP:  return ArchiveFormat::TAR_LZ;
            case ARCHIVE_FILTER_LZ4:   return ArchiveFormat::TAR_LZ4;
            default:                   return ArchiveFormat::TAR;
        }
    }

    switch (first_filter) {
        case ARCHIVE_FILTER_GZIP:  return ArchiveFormat::TAR_GZ;
        case ARCHIVE_FILTER_BZIP2: return ArchiveFormat::TAR_BZ2;
        case ARCHIVE_FILTER_XZ:    return ArchiveFormat::TAR_XZ;
        case ARCHIVE_FILTER_ZSTD:  return ArchiveFormat::TAR_ZST;
        case ARCHIVE_FILTER_LZIP:  return ArchiveFormat::TAR_LZ;
        case ARCHIVE_FILTER_LZ4:   return ArchiveFormat::TAR_LZ4;
        default:                   return ArchiveFormat::TAR;
    }
}

// ─── Fast ZIP Central Directory reader ───────────────────────────────────────
// Reads ONLY the Central Directory block at the end of the ZIP file.
// No compressed data is touched, so a 4 GB archive with 500 000 entries
// opens in the same time as a 4 KB archive.

template <typename T>
static T zip_le(const uint8_t* p) noexcept {
    T v = 0;
    for (std::size_t i = 0; i < sizeof(T); ++i)
        v |= static_cast<T>(p[i]) << (i * 8u);
    return v;
}

static constexpr uint32_t kEOCDSig    = 0x06054b50u;  // PK\x05\x06
static constexpr uint32_t kLoc64Sig   = 0x07064b50u;  // PK\x06\x07
static constexpr uint64_t kEOCD64Sig  = 0x06064b50u;  // PK\x06\x06
static constexpr uint32_t kCDSig      = 0x02014b50u;  // PK\x01\x02
static constexpr uint16_t kFlagEncr   = 0x0001u;
static constexpr uint16_t kZip64Tag   = 0x0001u;

static bool has_zip_extension(const std::string& path) {
    if (path.size() < 4) return false;
    const std::string lower = lowercase_copy(path);
    return lower.rfind(".zip") == lower.size() - 4;
}

auto read_zip_central_directory(const std::string& path)
    -> common::Result<std::vector<ArchiveEntry>> {

    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f.is_open())
        return make_error(common::ErrorCode::IOError, "Cannot open ZIP file", path);

    const auto file_size = static_cast<uint64_t>(f.tellg());
    if (file_size < 22)
        return make_error(common::ErrorCode::ArchiveError, "File too small to be a ZIP", path);

    // ── 1. Find EOCD (scan last 65 558 bytes backwards) ──────────────────────
    const uint64_t tail_size = std::min(file_size, uint64_t{65536 + 22});
    std::vector<uint8_t> tail(tail_size);
    f.seekg(static_cast<std::streamoff>(file_size - tail_size));
    f.read(reinterpret_cast<char*>(tail.data()), static_cast<std::streamsize>(tail_size));
    if (!f)
        return make_error(common::ErrorCode::IOError, "Failed to read ZIP tail", path);

    int64_t eocd_pos = -1;
    for (int64_t i = static_cast<int64_t>(tail_size) - 22; i >= 0; --i) {
        if (zip_le<uint32_t>(tail.data() + i) != kEOCDSig) continue;
        const uint16_t cmt = zip_le<uint16_t>(tail.data() + i + 20);
        if (static_cast<uint64_t>(i) + 22u + cmt == tail_size) {
            eocd_pos = i;
            break;
        }
    }
    // Fallback: accept first PK\x05\x06 found (handles some edge cases)
    if (eocd_pos < 0) {
        for (int64_t i = static_cast<int64_t>(tail_size) - 22; i >= 0; --i) {
            if (zip_le<uint32_t>(tail.data() + i) == kEOCDSig) { eocd_pos = i; break; }
        }
    }
    if (eocd_pos < 0)
        return make_error(common::ErrorCode::ArchiveError, "EOCD not found – not a valid ZIP", path);

    const uint8_t* eocd = tail.data() + eocd_pos;
    uint64_t cd_entries = zip_le<uint16_t>(eocd + 10);
    uint64_t cd_size    = zip_le<uint32_t>(eocd + 12);
    uint64_t cd_offset  = zip_le<uint32_t>(eocd + 16);

    // ── 2. Resolve ZIP64 extensions ──────────────────────────────────────────
    if (cd_entries == 0xFFFFu || cd_size == 0xFFFFFFFFu || cd_offset == 0xFFFFFFFFu) {
        const uint64_t eocd_abs = (file_size - tail_size) + static_cast<uint64_t>(eocd_pos);
        if (eocd_abs >= 20) {
            uint8_t loc[20];
            f.seekg(static_cast<std::streamoff>(eocd_abs - 20));
            f.read(reinterpret_cast<char*>(loc), 20);
            if (f && zip_le<uint32_t>(loc) == kLoc64Sig) {
                const uint64_t z64_abs = zip_le<uint64_t>(loc + 8);
                uint8_t z64[56];
                f.seekg(static_cast<std::streamoff>(z64_abs));
                f.read(reinterpret_cast<char*>(z64), 56);
                if (f && zip_le<uint32_t>(z64) == static_cast<uint32_t>(kEOCD64Sig)) {
                    cd_entries = zip_le<uint64_t>(z64 + 32);
                    cd_size    = zip_le<uint64_t>(z64 + 40);
                    cd_offset  = zip_le<uint64_t>(z64 + 48);
                }
            }
        }
    }

    // ── 3. Read Central Directory block in one pass ───────────────────────────
    if (cd_size == 0 || cd_offset + cd_size > file_size)
        return make_error(common::ErrorCode::ArchiveError,
                          "Invalid central directory location", path);

    std::vector<uint8_t> cd(cd_size);
    f.seekg(static_cast<std::streamoff>(cd_offset));
    f.read(reinterpret_cast<char*>(cd.data()), static_cast<std::streamsize>(cd_size));
    if (!f)
        return make_error(common::ErrorCode::IOError, "Failed to read central directory", path);
    f.close();

    // ── 4. Parse entries ──────────────────────────────────────────────────────
    std::vector<ArchiveEntry> entries;
    entries.reserve(std::min(cd_entries, uint64_t{2'000'000}));

    std::size_t pos = 0;
    while (pos + 46 <= cd_size) {
        if (zip_le<uint32_t>(cd.data() + pos) != kCDSig) break;

        const uint16_t flags     = zip_le<uint16_t>(cd.data() + pos + 8);
        const uint16_t method    = zip_le<uint16_t>(cd.data() + pos + 10);
        const uint32_t comp32    = zip_le<uint32_t>(cd.data() + pos + 20);
        const uint32_t uncomp32  = zip_le<uint32_t>(cd.data() + pos + 24);
        const uint16_t fname_len = zip_le<uint16_t>(cd.data() + pos + 28);
        const uint16_t extra_len = zip_le<uint16_t>(cd.data() + pos + 30);
        const uint16_t cmt_len   = zip_le<uint16_t>(cd.data() + pos + 32);
        const uint32_t ext_attr  = zip_le<uint32_t>(cd.data() + pos + 38);

        const std::size_t rec_size = 46u + fname_len + extra_len + cmt_len;
        if (pos + rec_size > cd_size) break;

        // Raw name (need trailing slash before normalisation for dir detection)
        const std::string raw(reinterpret_cast<const char*>(cd.data() + pos + 46), fname_len);

        // Directory: trailing slash OR Unix S_IFDIR in upper 16 bits of ext_attr
        bool is_dir = (!raw.empty() && raw.back() == '/');
        if (!is_dir) {
            const uint16_t unix_mode = static_cast<uint16_t>(ext_attr >> 16);
            if (unix_mode != 0) is_dir = S_ISDIR(unix_mode);
        }

        // Resolve ZIP64 sizes (extra field tag 0x0001)
        uint64_t comp_size   = comp32;
        uint64_t uncomp_size = uncomp32;
        if (comp32 == 0xFFFFFFFFu || uncomp32 == 0xFFFFFFFFu) {
            const uint8_t* ex     = cd.data() + pos + 46 + fname_len;
            const uint8_t* ex_end = ex + extra_len;
            while (ex + 4 <= ex_end) {
                const uint16_t tag  = zip_le<uint16_t>(ex);
                const uint16_t size = zip_le<uint16_t>(ex + 2);
                if (tag == kZip64Tag) {
                    const uint8_t* z = ex + 4;
                    if (uncomp32 == 0xFFFFFFFFu && z + 8 <= ex_end) { uncomp_size = zip_le<uint64_t>(z); z += 8; }
                    if (comp32   == 0xFFFFFFFFu && z + 8 <= ex_end) { comp_size   = zip_le<uint64_t>(z); }
                    break;
                }
                ex += 4 + size;
            }
        }

        if (!raw.empty()) {
            ArchiveEntry entry;
            entry.path             = normalize_entry_path(raw);
            entry.compressed_size  = comp_size;
            entry.uncompressed_size = uncomp_size;
            entry.is_directory     = is_dir;
            entry.is_encrypted     = (flags & kFlagEncr) != 0;
            entry.method           = method == 0 ? "Stored"
                                   : method == 8 ? "Deflated"
                                   :               "Compressed";
            entries.push_back(std::move(entry));
        }
        pos += rec_size;
    }

    return entries;
}

auto normalize_zip_entry_path(std::string_view raw_path) -> std::string {
    std::string normalized(raw_path);
    std::replace(normalized.begin(), normalized.end(), '\\', '/');
    return normalize_entry_path(normalized);
}

auto has_unsafe_entry_components(std::string_view entry_path) -> bool {
    if (entry_path.empty()) {
        return false;
    }

    const std::filesystem::path path(entry_path);
    for (const auto& component : path) {
        if (component == "..") {
            return true;
        }
    }
    return false;
}

auto minizip_error_to_result(int32_t code,
                             const std::string& operation,
                             const std::string& path,
                             bool encrypted_entry = false) -> common::Error {
    if (code == MZ_PASSWORD_ERROR) {
        return make_error(common::ErrorCode::PermissionDenied,
                          operation + " failed: password required or invalid password",
                          path);
    }
    // An AES entry read with no password (or the wrong one) does not always announce itself:
    // the stream simply fails to decode and minizip answers MZ_DATA_ERROR. Reported as "data
    // error" that hid the ONE useful fact — the archive wants a password — and the UI never
    // knew to ask for one.
    if (encrypted_entry && (code == MZ_DATA_ERROR || code == MZ_CRC_ERROR)) {
        return make_error(common::ErrorCode::PermissionDenied,
                          operation + " failed: password required or invalid password",
                          path);
    }
    if (code == MZ_EXIST_ERROR || code == MZ_END_OF_LIST) {
        return make_error(common::ErrorCode::NotFound,
                          operation + " failed: entry not found",
                          path);
    }
    if (code == MZ_OPEN_ERROR || code == MZ_READ_ERROR || code == MZ_WRITE_ERROR) {
        return make_error(common::ErrorCode::IOError,
                          operation + " failed with I/O error",
                          path);
    }
    return make_error(common::ErrorCode::ArchiveError,
                      operation + " failed with minizip error " + std::to_string(code),
                      path);
}

auto mz_file_write_callback(void* stream, const void* buf, int32_t len) -> int32_t {
    if (stream == nullptr || buf == nullptr || len < 0) {
        return MZ_PARAM_ERROR;
    }
    if (len == 0) {
        return 0;
    }

    auto* file = static_cast<std::FILE*>(stream);
    const size_t written =
        std::fwrite(buf, 1, static_cast<size_t>(len), file);
    if (written != static_cast<size_t>(len)) {
        return MZ_WRITE_ERROR;
    }
    return static_cast<int32_t>(written);
}

auto extract_single_zip_entry_with_minizip(
    const ReaderSession& session,
    std::string_view destination,
    std::string_view target_entry,
    std::atomic<bool>* cancelled,
    bool overwrite_existing,
    const ArchiveReader::ExtractProgressCallback& progress_callback = {})
    -> common::Result<void> {
    if (destination.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Destination path cannot be empty",
                          session.path);
    }

    const std::string normalized_target = trim_trailing_slash(
        normalize_zip_entry_path(target_entry));
    if (normalized_target.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Entry path cannot be empty",
                          session.path);
    }

    if (has_unsafe_entry_components(normalized_target)) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Unsafe entry path in archive",
                          normalized_target);
    }

    const stdfs::path destination_root(destination);
    std::error_code ec;
    stdfs::create_directories(destination_root, ec);
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to create destination directory",
                          destination_root.string());
    }

    struct MinizipReaderGuard {
        void* handle = nullptr;
        ~MinizipReaderGuard() {
            if (handle != nullptr) {
                mz_zip_reader_close(handle);
                mz_zip_reader_delete(&handle);
            }
        }
    } reader;

    reader.handle = mz_zip_reader_create();
    if (reader.handle == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Failed to allocate minizip reader",
                          session.path);
    }

    int32_t mz_status = mz_zip_reader_open_file(reader.handle, session.path.c_str());
    if (mz_status != MZ_OK) {
        return minizip_error_to_result(mz_status, "Open ZIP", session.path);
    }
    if (!session.password.empty()) {
        mz_zip_reader_set_password(reader.handle, session.password.c_str());
    }

    // Итоги — по всем записям под целью: папка выходит целиком, и ход показывают по ней.
    uint64_t total_bytes = 0;
    int files_total = 0;
    const auto list_result = read_zip_central_directory(session.path);
    if (list_result.has_value()) {
        for (const auto& entry : list_result.value()) {
            const std::string comparable = trim_trailing_slash(normalize_zip_entry_path(entry.path));
            if (entry_belongs_to_target(comparable, normalized_target) && !entry.is_directory) {
                total_bytes += entry.uncompressed_size;
                ++files_total;
            }
        }
    }
    files_total = std::max(files_total, 1);

    mz_status = mz_zip_reader_goto_first_entry(reader.handle);
    if (mz_status == MZ_END_OF_LIST) {
        return make_error(common::ErrorCode::NotFound,
                          "Archive entry not found",
                          normalized_target);
    }
    if (mz_status != MZ_OK) {
        return minizip_error_to_result(mz_status, "Iterate ZIP entries", session.path);
    }

    bool found_target = false;
    uint64_t bytes_done = 0;
    int files_done = 0;

    for (;;) {
        if (should_cancel(cancelled)) {
            return cancelled_error(session.path);
        }

        mz_zip_file* file_info = nullptr;
        mz_status = mz_zip_reader_entry_get_info(reader.handle, &file_info);
        if (mz_status != MZ_OK || file_info == nullptr) {
            return minizip_error_to_result(mz_status, "Read ZIP entry info", session.path);
        }

        const std::string entry_path = normalize_zip_entry_path(file_info->filename == nullptr
                                                                    ? ""
                                                                    : file_info->filename);
        const std::string comparable_entry = trim_trailing_slash(entry_path);

        if (entry_belongs_to_target(comparable_entry, normalized_target)) {
            found_target = true;

            if (has_unsafe_entry_components(entry_path)) {
                return make_error(common::ErrorCode::InvalidArgument,
                                  "Unsafe entry path in archive",
                                  entry_path);
            }

            const stdfs::path output_path = destination_root / stdfs::path(entry_path);
            stdfs::create_directories(output_path.parent_path(), ec);
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to create output directory",
                                  output_path.parent_path().string());
            }

            const bool is_directory = mz_zip_reader_entry_is_dir(reader.handle) == MZ_OK;
            const bool is_the_target_itself = comparable_entry == normalized_target;
            if (is_directory) {
                // Запись-каталог — только папка на диске; её файлы идут отдельными записями
                // дальше по списку, поэтому здесь не выходим.
                stdfs::create_directories(output_path, ec);
                if (ec) {
                    return make_error(common::ErrorCode::IOError,
                                      "Failed to create output directory",
                                      output_path.string());
                }
            } else if (!overwrite_existing && stdfs::exists(output_path, ec)) {
                if (ec) {
                    return make_error(common::ErrorCode::IOError,
                                      "Failed to inspect output path",
                                      output_path.string());
                }
                ++files_done;
                if (progress_callback) {
                    progress_callback(entry_path, bytes_done, std::max<uint64_t>(total_bytes, 1),
                                      files_done, files_total);
                }
            } else {
                std::FILE* output = std::fopen(output_path.string().c_str(), "wb");
                if (output == nullptr) {
                    return make_error(common::ErrorCode::IOError,
                                      "Failed to open output file for writing",
                                      output_path.string());
                }

                const uint64_t entry_size =
                    static_cast<uint64_t>(std::max<int64_t>(0, file_info->uncompressed_size));
                const uint64_t entry_started_at = bytes_done;
                const uint64_t planned_total = std::max<uint64_t>(total_bytes, entry_started_at + entry_size);

                if (progress_callback) {
                    progress_callback(entry_path, bytes_done, std::max<uint64_t>(planned_total, 1),
                                      files_done, files_total);
                }

                for (;;) {
                    if (should_cancel(cancelled)) {
                        std::fclose(output);
                        return cancelled_error(session.path);
                    }

                    mz_status = mz_zip_reader_entry_save_process(
                        reader.handle,
                        output,
                        mz_file_write_callback);
                    if (mz_status == MZ_END_OF_STREAM) {
                        break;
                    }
                    if (mz_status < 0) {
                        std::fclose(output);
                        return minizip_error_to_result(
                            mz_status,
                            "Extract ZIP entry",
                            entry_path,
                            file_info != nullptr && (file_info->flag & MZ_ZIP_FLAG_ENCRYPTED) != 0);
                    }

                    bytes_done += static_cast<uint64_t>(mz_status);
                    if (progress_callback) {
                        progress_callback(
                            entry_path,
                            bytes_done,
                            std::max<uint64_t>(planned_total, bytes_done),
                            files_done,
                            files_total);
                    }
                }

                if (std::fclose(output) != 0) {
                    return make_error(common::ErrorCode::IOError,
                                      "Failed to flush output file",
                                      output_path.string());
                }

                bytes_done = std::max(bytes_done, entry_started_at + entry_size);
                ++files_done;
                if (progress_callback) {
                    progress_callback(entry_path, bytes_done,
                                      std::max<uint64_t>(planned_total, bytes_done),
                                      files_done, files_total);
                }
            }

            // Одиночный файл — дальше искать нечего. Папка же продолжается следующими записями.
            if (is_the_target_itself && !is_directory) {
                break;
            }
        }

        mz_status = mz_zip_reader_goto_next_entry(reader.handle);
        if (mz_status == MZ_END_OF_LIST) {
            break;
        }
        if (mz_status != MZ_OK) {
            return minizip_error_to_result(mz_status, "Iterate ZIP entries", session.path);
        }
    }

    if (!found_target) {
        return make_error(common::ErrorCode::NotFound,
                          "Archive entry not found",
                          normalized_target);
    }

    return {};
}

auto extract_all_zip_entries_with_minizip(
    const ReaderSession& session,
    std::string_view destination,
    std::atomic<bool>* cancelled,
    bool overwrite_existing,
    const ArchiveReader::ExtractProgressCallback& progress_callback = {})
    -> common::Result<void> {
    if (destination.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Destination path cannot be empty",
                          session.path);
    }

    const stdfs::path destination_root(destination);
    std::error_code ec;
    stdfs::create_directories(destination_root, ec);
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to create destination directory",
                          destination_root.string());
    }

    uint64_t bytes_total = 0;
    int files_total = 0;
    const auto list_result = read_zip_central_directory(session.path);
    if (list_result.has_value()) {
        for (const auto& entry : list_result.value()) {
            if (!entry.is_directory) {
                ++files_total;
                bytes_total += entry.uncompressed_size;
            }
        }
    }

    struct MinizipReaderGuard {
        void* handle = nullptr;
        ~MinizipReaderGuard() {
            if (handle != nullptr) {
                mz_zip_reader_close(handle);
                mz_zip_reader_delete(&handle);
            }
        }
    } reader;

    reader.handle = mz_zip_reader_create();
    if (reader.handle == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Failed to allocate minizip reader",
                          session.path);
    }

    int32_t mz_status = mz_zip_reader_open_file(reader.handle, session.path.c_str());
    if (mz_status != MZ_OK) {
        return minizip_error_to_result(mz_status, "Open ZIP", session.path);
    }
    if (!session.password.empty()) {
        mz_zip_reader_set_password(reader.handle, session.password.c_str());
    }

    mz_status = mz_zip_reader_goto_first_entry(reader.handle);
    if (mz_status == MZ_END_OF_LIST) {
        return {};
    }
    if (mz_status != MZ_OK) {
        return minizip_error_to_result(mz_status, "Iterate ZIP entries", session.path);
    }

    uint64_t bytes_done = 0;
    int files_done = 0;

    for (;;) {
        if (should_cancel(cancelled)) {
            return cancelled_error(session.path);
        }

        mz_zip_file* file_info = nullptr;
        mz_status = mz_zip_reader_entry_get_info(reader.handle, &file_info);
        if (mz_status != MZ_OK || file_info == nullptr) {
            return minizip_error_to_result(mz_status, "Read ZIP entry info", session.path);
        }

        const std::string entry_path = normalize_zip_entry_path(file_info->filename == nullptr
                                                                    ? ""
                                                                    : file_info->filename);
        if (!entry_path.empty()) {
            if (has_unsafe_entry_components(entry_path)) {
                return make_error(common::ErrorCode::InvalidArgument,
                                  "Unsafe entry path in archive",
                                  entry_path);
            }

            const stdfs::path output_path = destination_root / stdfs::path(entry_path);
            stdfs::create_directories(output_path.parent_path(), ec);
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to create output directory",
                                  output_path.parent_path().string());
            }

            const bool is_directory = mz_zip_reader_entry_is_dir(reader.handle) == MZ_OK;
            if (is_directory) {
                stdfs::create_directories(output_path, ec);
                if (ec) {
                    return make_error(common::ErrorCode::IOError,
                                      "Failed to create output directory",
                                      output_path.string());
                }
            } else {
                bool shouldExtractFile = true;
                if (!overwrite_existing && stdfs::exists(output_path, ec)) {
                    if (ec) {
                        return make_error(common::ErrorCode::IOError,
                                          "Failed to inspect output path",
                                          output_path.string());
                    }
                    shouldExtractFile = false;
                    ++files_done;
                    if (progress_callback) {
                        progress_callback(
                            entry_path,
                            bytes_done,
                            std::max(bytes_total, bytes_done),
                            files_done,
                            std::max(files_total, files_done));
                    }
                }

                if (shouldExtractFile) {
                    std::FILE* output = std::fopen(output_path.string().c_str(), "wb");
                    if (output == nullptr) {
                        return make_error(common::ErrorCode::IOError,
                                          "Failed to open output file for writing",
                                          output_path.string());
                    }

                    for (;;) {
                        if (should_cancel(cancelled)) {
                            std::fclose(output);
                            return cancelled_error(session.path);
                        }

                        mz_status = mz_zip_reader_entry_save_process(
                            reader.handle,
                            output,
                            mz_file_write_callback);
                        if (mz_status == MZ_END_OF_STREAM) {
                            break;
                        }
                        if (mz_status < 0) {
                            std::fclose(output);
                            return minizip_error_to_result(
                                mz_status,
                                "Extract ZIP entry",
                                entry_path,
                                file_info != nullptr && (file_info->flag & MZ_ZIP_FLAG_ENCRYPTED) != 0);
                        }

                        bytes_done += static_cast<uint64_t>(mz_status);
                        if (progress_callback) {
                            progress_callback(
                                entry_path,
                                bytes_done,
                                std::max(bytes_total, bytes_done),
                                files_done,
                                std::max(files_total, files_done));
                        }
                    }

                    if (std::fclose(output) != 0) {
                        return make_error(common::ErrorCode::IOError,
                                          "Failed to flush output file",
                                          output_path.string());
                    }

                    ++files_done;
                    if (progress_callback) {
                        progress_callback(
                            entry_path,
                            bytes_done,
                            std::max(bytes_total, bytes_done),
                            files_done,
                            std::max(files_total, files_done));
                    }
                }
            }
        }

        mz_status = mz_zip_reader_goto_next_entry(reader.handle);
        if (mz_status == MZ_END_OF_LIST) {
            break;
        }
        if (mz_status != MZ_OK) {
            return minizip_error_to_result(mz_status, "Iterate ZIP entries", session.path);
        }
    }

    if (progress_callback) {
        const uint64_t final_bytes = std::max(bytes_total, bytes_done);
        const int final_files = std::max(files_total, files_done);
        progress_callback("Done", final_bytes, final_bytes, final_files, final_files);
    }
    return {};
}

// ─── End of fast ZIP reader ───────────────────────────────────────────────────

auto skip_entry_data(struct archive* reader) -> int {
    g_data_skip_call_count.fetch_add(1, std::memory_order_relaxed);
    return archive_read_data_skip(reader);
}

auto archive_uncompressed_position(struct archive* reader) -> int64_t {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return archive_position_uncompressed(reader);
#pragma clang diagnostic pop
}

auto copy_data(struct archive* source,
               struct archive* destination,
               const std::atomic<bool>* cancelled,
               const std::function<void()>& on_progress = {}) -> int {
    const void* buffer = nullptr;
    size_t size = 0;
    la_int64_t offset = 0;

    for (;;) {
        if (should_cancel(cancelled)) {
            return ARCHIVE_FATAL;
        }
        const int read_status = archive_read_data_block(source, &buffer, &size, &offset);
        if (read_status == ARCHIVE_EOF) {
            return ARCHIVE_OK;
        }
        if (read_status < ARCHIVE_WARN) {
            return read_status;
        }

        const int write_status = archive_write_data_block(destination, buffer, size, offset);
        if (write_status < ARCHIVE_WARN) {
            return write_status;
        }

        if (on_progress) {
            on_progress();
        }
    }
}

auto is_warning_status(int status) -> bool {
    return status == ARCHIVE_WARN;
}

auto extract_entries(const ReaderSession& session,
                     std::string_view destination,
                     const std::optional<std::string>& target_entry,
                     std::atomic<bool>* cancelled,
                     bool overwrite_existing,
                     const ArchiveReader::ExtractProgressCallback& progress_callback = {})
    -> common::Result<void> {
    if (destination.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Destination path cannot be empty",
                          session.path);
    }

    std::error_code ec;
    stdfs::path destination_root(destination);
    stdfs::create_directories(destination_root, ec);
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to create destination directory",
                          destination_root.string());
    }
    // Resolve symlinks in the destination itself (e.g. macOS /tmp and /var/folders
    // live behind the /var -> /private/var symlink). We rewrite each entry to an
    // absolute path under destination_root and extract with ARCHIVE_EXTRACT_SECURE_SYMLINKS,
    // which walks every path component and refuses to descend through a symlink. Without
    // this, extracting anywhere under /var or /tmp fails with "Cannot extract through
    // symlink". Canonicalising the already-created root removes those pre-existing
    // symlink components while still protecting against symlinks created mid-extraction.
    if (auto canonical_root = stdfs::canonical(destination_root, ec); !ec) {
        destination_root = canonical_root;
    }

    if (has_zip_extension(session.path)) {
        if (target_entry.has_value()) {
            return extract_single_zip_entry_with_minizip(
                session,
                destination,
                *target_entry,
                cancelled,
                overwrite_existing,
                progress_callback);
        }
        return extract_all_zip_entries_with_minizip(
            session,
            destination,
            cancelled,
            overwrite_existing,
            progress_callback);
    }

    auto reader_result = open_archive_reader(session.path, session.password);
    if (!reader_result.has_value()) {
        return reader_result.error();
    }
    ArchiveReadPtr reader = std::move(reader_result.value());

    ArchiveWritePtr writer(archive_write_disk_new(), &archive_write_free);
    if (!writer) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Failed to allocate extraction writer",
                          session.path);
    }

    int extract_options = ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM |
        ARCHIVE_EXTRACT_ACL | ARCHIVE_EXTRACT_FFLAGS |
        // Hardened set for untrusted archives: block ".." traversal and escapes
        // through a symlink an earlier entry created. We deliberately rewrite every
        // entry's pathname to an absolute path under destination_root before writing
        // (see archive_entry_set_pathname below), so ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS
        // must NOT be set — modern libarchive would reject that legitimate destination
        // with "Path is absolute". Malicious *archive-side* absolute paths are already
        // neutralised by normalize_entry_path(), which strips any leading "/".
        ARCHIVE_EXTRACT_SECURE_NODOTDOT |
        ARCHIVE_EXTRACT_SECURE_SYMLINKS;
    if (!overwrite_existing) {
        extract_options |= ARCHIVE_EXTRACT_NO_OVERWRITE;
    }
    archive_write_disk_set_options(writer.get(), extract_options);
    archive_write_disk_set_standard_lookup(writer.get());

    const std::string normalized_target =
        target_entry.has_value() ? trim_trailing_slash(normalize_entry_path(*target_entry)) : "";
    bool found_target = !target_entry.has_value();
    uint64_t bytes_done = 0;
    uint64_t bytes_total = 0;
    int files_done = 0;
    int files_total = 0;

    const auto report_progress = [&](const std::string& current_file, bool use_archive_positions) {
        if (!progress_callback) {
            return;
        }

        uint64_t reported_bytes_done = bytes_done;
        int reported_files_done = files_done;

        if (use_archive_positions) {
            const int64_t archive_bytes_done = archive_uncompressed_position(reader.get());
            if (archive_bytes_done >= 0) {
                reported_bytes_done = std::max<uint64_t>(
                    reported_bytes_done,
                    static_cast<uint64_t>(archive_bytes_done));
            }

            const int archive_files_done = archive_file_count(reader.get());
            if (archive_files_done >= 0) {
                reported_files_done = std::max(reported_files_done, archive_files_done);
            }
        }

        progress_callback(current_file,
                          reported_bytes_done,
                          std::max(bytes_total, reported_bytes_done),
                          reported_files_done,
                          std::max(files_total, reported_files_done));
    };

    archive_entry* entry = nullptr;
    for (;;) {
        if (should_cancel(cancelled)) {
            return cancelled_error(session.path);
        }

        const int status = archive_read_next_header(reader.get(), &entry);
        if (status == ARCHIVE_EOF) {
            break;
        }
        if (status == ARCHIVE_FATAL || status < ARCHIVE_WARN) {
            return to_result_error("Failed to iterate archive entries", session.path, reader.get());
        }
        if (is_warning_status(status)) {
            continue;
        }

        const char* raw_entry_path = archive_entry_pathname(entry);
        const std::string entry_path = normalize_entry_path(raw_entry_path == nullptr ? "" : raw_entry_path);
        if (entry_path.empty()) {
            const int skip_status = skip_entry_data(reader.get());
            if (skip_status < ARCHIVE_WARN) {
                return to_result_error("Failed to skip archive entry data", session.path, reader.get());
            }
            continue;
        }

        const std::string comparable_entry = trim_trailing_slash(entry_path);
        if (target_entry.has_value() && !entry_belongs_to_target(comparable_entry, normalized_target)) {
            const int skip_status = skip_entry_data(reader.get());
            if (skip_status < ARCHIVE_WARN) {
                return to_result_error("Failed to skip archive entry data", session.path, reader.get());
            }
            continue;
        }

        found_target = true;

        const la_int64_t raw_size = archive_entry_size(entry);
        const uint64_t entry_size = raw_size > 0 ? static_cast<uint64_t>(raw_size) : 0;
        const mode_t mode = archive_entry_filetype(entry);
        const bool is_directory =
            mode == AE_IFDIR || (!entry_path.empty() && entry_path.back() == '/');
        if (!is_directory) {
            ++files_total;
            bytes_total += entry_size;
            report_progress(entry_path, false);
        }

        if (should_cancel(cancelled)) {
            return cancelled_error(session.path);
        }

        const stdfs::path output_path = destination_root / stdfs::path(entry_path);
        stdfs::create_directories(output_path.parent_path(), ec);
        if (ec) {
            return make_error(common::ErrorCode::IOError,
                              "Failed to create output directory",
                              output_path.parent_path().string());
        }

        const std::string output_path_string = output_path.string();
        archive_entry_set_pathname(entry, output_path_string.c_str());

        const int header_status = archive_write_header(writer.get(), entry);
        if (header_status < ARCHIVE_WARN) {
            return to_result_error("Failed to write extracted entry header", output_path_string, writer.get());
        }

        if (entry_size > 0) {
            const int copy_status = copy_data(
                reader.get(),
                writer.get(),
                cancelled,
                [&report_progress, &entry_path]() {
                    report_progress(entry_path, true);
                });
            if (should_cancel(cancelled)) {
                return cancelled_error(session.path);
            }
            if (copy_status < ARCHIVE_WARN) {
                return to_result_error("Failed to extract archive entry data", output_path_string, reader.get());
            }
        }

        const int finish_status = archive_write_finish_entry(writer.get());
        if (finish_status < ARCHIVE_WARN) {
            return to_result_error("Failed to finalize extracted entry", output_path_string, writer.get());
        }

        if (!is_directory) {
            ++files_done;
            bytes_done += entry_size;
            report_progress(entry_path, true);
        }

        // Одиночный файл — дальше искать нечего. Папка же продолжается следующими записями.
        if (target_entry.has_value() && !is_directory && comparable_entry == normalized_target) {
            break;
        }
    }

    if (should_cancel(cancelled)) {
        return cancelled_error(session.path);
    }

    if (!found_target) {
        return make_error(common::ErrorCode::NotFound,
                          "Archive entry not found",
                          normalized_target);
    }

    if (progress_callback && !target_entry.has_value()) {
        report_progress("Done", true);
    }

    return {};
}

}  // namespace

auto ArchiveReader::open(std::string_view path, std::string_view password) -> common::Result<void> {
    ensure_utf8_ctype();
    invalidate_entries_cache();

    if (path.empty()) {
        return make_error(common::ErrorCode::InvalidArgument, "Archive path cannot be empty");
    }

    const stdfs::path archive_path(path);
    std::error_code ec;
    if (!stdfs::exists(archive_path, ec)) {
        return make_error(common::ErrorCode::NotFound, "Archive does not exist", archive_path.string());
    }
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to access archive path",
                          archive_path.string());
    }
    if (!stdfs::is_regular_file(archive_path, ec)) {
        return make_error(common::ErrorCode::NotAFile,
                          "Path is not a regular file",
                          archive_path.string());
    }
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to inspect archive path",
                          archive_path.string());
    }

    const std::string archive_path_string = archive_path.string();
    const std::string password_string(password);
    reset_cancelled();

    const auto validation_result = validate_archive_signature(archive_path_string);
    if (!validation_result.has_value()) {
        return validation_result.error();
    }

    const auto reader_result = open_archive_reader(archive_path_string, password_string);
    if (!reader_result.has_value()) {
        return reader_result.error();
    }

    {
        std::lock_guard<std::mutex> lock(g_reader_mutex);
        g_reader_sessions[this] = ReaderSession{archive_path_string, password_string};
    }

    return {};
}

auto ArchiveReader::list_entries(std::atomic<bool>* cancelled) const
    -> common::Result<std::vector<ArchiveEntry>> {
    const auto session = current_reader_session(this);
    if (!session.has_value()) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive is not opened");
    }

    const auto mtime_result = archive_mtime(session->path);
    if (!mtime_result.has_value()) {
        return mtime_result.error();
    }
    const std::time_t current_mtime = mtime_result.value();

    // ── Check global process-level cache (survives across bridge calls) ────────
    {
        std::lock_guard<std::mutex> lock(g_entries_cache_mutex);
        if (g_entries_cache.has_value() &&
            g_entries_cache->path  == session->path &&
            g_entries_cache->mtime == current_mtime) {
            return g_entries_cache->entries;
        }
    }

    // ── Check per-instance cache (fast path when same reader is reused) ───────
    {
        std::lock_guard<std::mutex> lock(entries_cache_mutex_);
        if (has_cached_entries_ &&
            cached_archive_path_ == session->path &&
            cached_mtime_ == current_mtime) {
            return cached_entries_;
        }
    }

    // ── Fast path for ZIP archives ────────────────────────────────────────────
    // Reads the Central Directory directly (at the end of the file) without
    // touching any compressed data.  Falls back to the libarchive streaming
    // path if the fast reader fails (corrupted/non-standard ZIPs).
    if (has_zip_extension(session->path)) {
        auto zip_result = read_zip_central_directory(session->path);
        if (zip_result.has_value()) {
            {
                std::lock_guard<std::mutex> lock(g_entries_cache_mutex);
                g_entries_cache = GlobalEntriesCache{session->path, current_mtime, zip_result.value()};
            }
            {
                std::lock_guard<std::mutex> lock(entries_cache_mutex_);
                cached_archive_path_ = session->path;
                cached_entries_      = zip_result.value();
                cached_mtime_        = current_mtime;
                has_cached_entries_  = true;
            }
            return zip_result;
        }
        // Fall through to libarchive for damaged/unusual ZIPs
    }

    // ── Generic libarchive streaming path (TAR, 7z, RAR, …) ──────────────────
    auto reader_result = open_archive_reader(session->path, session->password);
    if (!reader_result.has_value()) {
        return reader_result.error();
    }
    ArchiveReadPtr reader = std::move(reader_result.value());

    std::vector<ArchiveEntry> entries;

    archive_entry* raw_entry = nullptr;
    for (;;) {
        if (should_cancel(cancelled)) {
            return cancelled_error(session->path);
        }

        const int status = archive_read_next_header(reader.get(), &raw_entry);
        if (status == ARCHIVE_EOF) {
            break;
        }
        if (status == ARCHIVE_FATAL || status < ARCHIVE_WARN) {
            return to_result_error("Failed to list archive entries", session->path, reader.get());
        }
        if (is_warning_status(status)) {
            continue;
        }

        const char* raw_path = archive_entry_pathname(raw_entry);
        const std::string path = normalize_entry_path(raw_path == nullptr ? "" : raw_path);
        if (path.empty()) {
            const int skip_status = skip_entry_data(reader.get());
            if (skip_status < ARCHIVE_WARN) {
                return to_result_error("Failed to skip archive entry data", session->path, reader.get());
            }
            continue;
        }

        ArchiveEntry entry;
        entry.path = path;

        const la_int64_t raw_size = archive_entry_size(raw_entry);
        entry.uncompressed_size = raw_size > 0 ? static_cast<uint64_t>(raw_size) : 0;
        entry.compressed_size = entry.uncompressed_size;

        const mode_t mode = archive_entry_filetype(raw_entry);
        entry.is_directory = mode == AE_IFDIR || (!entry.path.empty() && entry.path.back() == '/');
        entry.is_encrypted = archive_entry_is_encrypted(raw_entry) > 0;

        const char* method = archive_format_name(reader.get());
        entry.method = method == nullptr ? "" : method;

        entries.push_back(std::move(entry));

        const int skip_status = skip_entry_data(reader.get());
        if (skip_status < ARCHIVE_WARN) {
            return to_result_error("Failed to skip archive entry data", session->path, reader.get());
        }
    }

    if (should_cancel(cancelled)) {
        return cancelled_error(session->path);
    }

    {
        std::lock_guard<std::mutex> lock(g_entries_cache_mutex);
        g_entries_cache = GlobalEntriesCache{session->path, current_mtime, entries};
    }
    {
        std::lock_guard<std::mutex> lock(entries_cache_mutex_);
        cached_archive_path_ = session->path;
        cached_entries_ = entries;
        cached_mtime_ = current_mtime;
        has_cached_entries_ = true;
    }

    return entries;
}

auto ArchiveReader::get_info() const -> common::Result<ArchiveInfo> {
    const auto session = current_reader_session(this);
    if (!session.has_value()) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive is not opened");
    }

    auto reader_result = open_archive_reader(session->path, session->password);
    if (!reader_result.has_value()) {
        return reader_result.error();
    }
    ArchiveReadPtr reader = std::move(reader_result.value());

    ArchiveInfo info;
    info.format = format_from_handle(reader.get());

    archive_entry* raw_entry = nullptr;
    for (;;) {
        if (should_cancel(nullptr)) {
            return cancelled_error(session->path);
        }

        const int status = archive_read_next_header(reader.get(), &raw_entry);
        if (status == ARCHIVE_EOF) {
            break;
        }
        if (status == ARCHIVE_FATAL || status < ARCHIVE_WARN) {
            return to_result_error("Failed to read archive metadata", session->path, reader.get());
        }
        if (is_warning_status(status)) {
            continue;
        }

        const la_int64_t raw_size = archive_entry_size(raw_entry);
        const uint64_t entry_size = raw_size > 0 ? static_cast<uint64_t>(raw_size) : 0;

        ++info.entry_count;
        info.total_uncompressed += entry_size;
        info.total_size += entry_size;
        info.is_encrypted = info.is_encrypted || (archive_entry_is_encrypted(raw_entry) > 0);

        const int skip_status = skip_entry_data(reader.get());
        if (skip_status < ARCHIVE_WARN) {
            return to_result_error("Failed to skip archive entry data", session->path, reader.get());
        }
    }

    if (should_cancel(nullptr)) {
        return cancelled_error(session->path);
    }

    return info;
}

auto ArchiveReader::extract_all(std::string_view dest_path,
                                std::atomic<bool>* cancelled) const -> common::Result<void> {
    const auto session = current_reader_session(this);
    if (!session.has_value()) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive is not opened");
    }

    return extract_entries(*session, dest_path, std::nullopt, cancelled, true, {});
}

auto ArchiveReader::extract_all(std::string_view dest_path,
                                std::atomic<bool>* cancelled,
                                ExtractProgressCallback progress_callback) const
    -> common::Result<void> {
    const auto session = current_reader_session(this);
    if (!session.has_value()) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive is not opened");
    }

    return extract_entries(*session, dest_path, std::nullopt, cancelled, true, progress_callback);
}

auto ArchiveReader::extract_all(std::string_view dest_path,
                                std::atomic<bool>* cancelled,
                                bool overwrite_existing,
                                ExtractProgressCallback progress_callback) const
    -> common::Result<void> {
    const auto session = current_reader_session(this);
    if (!session.has_value()) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive is not opened");
    }

    return extract_entries(
        *session,
        dest_path,
        std::nullopt,
        cancelled,
        overwrite_existing,
        progress_callback);
}

auto ArchiveReader::extract_entry(std::string_view entry_path,
                                  std::string_view dest_path) -> common::Result<void> {
    const auto session = current_reader_session(this);
    if (!session.has_value()) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive is not opened");
    }

    if (entry_path.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Entry path cannot be empty",
                          session->path);
    }

    return extract_entries(*session, dest_path, std::string(entry_path), nullptr, true);
}

void ArchiveReader::cancel_current_operation() {
    g_archive_cancelled.store(true, std::memory_order_relaxed);
}

void ArchiveReader::reset_cancelled() {
    g_archive_cancelled.store(false, std::memory_order_relaxed);
}

auto ArchiveReader::debug_data_skip_call_count() -> size_t {
    return g_data_skip_call_count.load(std::memory_order_relaxed);
}

void ArchiveReader::debug_reset_data_skip_call_count() {
    g_data_skip_call_count.store(0, std::memory_order_relaxed);
}

void ArchiveReader::close() {
    invalidate_entries_cache();

    std::lock_guard<std::mutex> lock(g_reader_mutex);
    g_reader_sessions.erase(this);
}

void ArchiveReader::invalidate_cached_listing() {
    std::lock_guard<std::mutex> lock(g_entries_cache_mutex);
    g_entries_cache.reset();
}

void ArchiveReader::invalidate_entries_cache() const {
    std::lock_guard<std::mutex> lock(entries_cache_mutex_);
    cached_archive_path_.clear();
    cached_entries_.clear();
    cached_mtime_ = 0;
    has_cached_entries_ = false;
}

}  // namespace fcxl::archive
