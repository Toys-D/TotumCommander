#include "fcxl/archive/archive_writer.h"

#include <archive.h>
#include <archive_entry.h>

#include "mz.h"
#include "mz_strm.h"
#include "mz_zip.h"
#include "mz_zip_rw.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>

namespace fcxl::archive {
namespace {

namespace stdfs = std::filesystem;

enum class WriterBackend {
    Libarchive,
    Minizip,
};

struct WriterSession {
    WriterBackend backend = WriterBackend::Libarchive;
    struct archive* libarchive_writer = nullptr;
    void* minizip_writer = nullptr;
    std::string archive_path;
    ArchiveFormat format = ArchiveFormat::ZIP;
    int compression_level = -1;
    bool preserve_paths = true;
    ArchiveWriter::ArchiveProgressCallback progress_callback = nullptr;
    int64_t total_uncompressed_bytes = 0;
    int total_files = 0;
};

std::mutex g_writer_mutex;
std::unordered_map<const ArchiveWriter*, WriterSession> g_writer_sessions;
std::atomic_bool g_archive_write_cancelled{false};

auto make_error(common::ErrorCode code, std::string message, std::string path = "") -> common::Error {
    return common::Error::make(code, std::move(message), std::move(path));
}

auto cancelled_error(const std::string& path) -> common::Error {
    return make_error(common::ErrorCode::Cancelled, "Archive operation cancelled", path);
}

auto is_archive_write_cancelled() -> bool {
    return g_archive_write_cancelled.load(std::memory_order_relaxed);
}

auto to_archive_error(const std::string& message,
                      const std::string& path,
                      struct archive* writer = nullptr) -> common::Error {
    std::string details = message;
    if (writer != nullptr) {
        const char* archive_message = archive_error_string(writer);
        if (archive_message != nullptr && archive_message[0] != '\0') {
            details += ": ";
            details += archive_message;
        }
    }
    return make_error(common::ErrorCode::ArchiveError, std::move(details), path);
}

auto minizip_error_to_result(int32_t code,
                             const std::string& operation,
                             const std::string& path) -> common::Error {
    if (code == MZ_PASSWORD_ERROR) {
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

auto normalize_archive_path(std::string_view value) -> std::string {
    std::string normalized(value);
    while (normalized.rfind("./", 0) == 0) {
        normalized.erase(0, 2);
    }
    while (!normalized.empty() && normalized.front() == '/') {
        normalized.erase(normalized.begin());
    }
    std::replace(normalized.begin(), normalized.end(), '\\', '/');
    return normalized;
}

auto join_archive_paths(std::string_view left, std::string_view right) -> std::string {
    if (left.empty()) {
        return normalize_archive_path(right);
    }
    if (right.empty()) {
        return normalize_archive_path(left);
    }

    std::string joined = normalize_archive_path(left);
    if (!joined.empty() && joined.back() != '/') {
        joined.push_back('/');
    }

    joined += normalize_archive_path(right);
    return joined;
}

auto to_directory_entry_name(std::string value) -> std::string {
    std::string normalized = normalize_archive_path(value);
    if (!normalized.empty() && normalized.back() != '/') {
        normalized.push_back('/');
    }
    return normalized;
}

auto writer_session(const ArchiveWriter* self) -> WriterSession* {
    const auto it = g_writer_sessions.find(self);
    if (it == g_writer_sessions.end()) {
        return nullptr;
    }
    return &it->second;
}

auto normalized_total_bytes(int64_t value) -> int64_t {
    return value > 0 ? value : 1;
}

auto normalized_total_files(int value) -> int {
    return value > 0 ? value : 1;
}

auto archive_uncompressed_position(struct archive* writer) -> int64_t {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return archive_position_uncompressed(writer);
#pragma clang diagnostic pop
}

auto archive_compressed_position(struct archive* writer) -> int64_t {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return archive_position_compressed(writer);
#pragma clang diagnostic pop
}

void report_progress_from_libarchive(WriterSession* session,
                                     std::string_view current_file) {
    if (session == nullptr || session->progress_callback == nullptr ||
        session->libarchive_writer == nullptr) {
        return;
    }

    const int64_t uncompressed_position =
        archive_uncompressed_position(session->libarchive_writer);
    const int files_processed = archive_file_count(session->libarchive_writer);
    const int64_t compressed_position =
        archive_compressed_position(session->libarchive_writer);

    const int64_t bytes_read = uncompressed_position >= 0 ? uncompressed_position : 0;
    const int files_done = files_processed >= 0 ? files_processed : 0;

    session->progress_callback(std::string(current_file),
                               bytes_read,
                               normalized_total_bytes(session->total_uncompressed_bytes),
                               files_done,
                               normalized_total_files(session->total_files),
                               compressed_position);
}

void close_libarchive_writer(WriterSession* session) {
    if (session == nullptr || session->libarchive_writer == nullptr) {
        return;
    }
    archive_write_close(session->libarchive_writer);
    archive_write_free(session->libarchive_writer);
    session->libarchive_writer = nullptr;
}

void close_minizip_writer(WriterSession* session) {
    if (session == nullptr || session->minizip_writer == nullptr) {
        return;
    }
    mz_zip_writer_close(session->minizip_writer);
    void* handle = session->minizip_writer;
    mz_zip_writer_delete(&handle);
    session->minizip_writer = nullptr;
}

void close_writer_session(WriterSession* session) {
    if (session == nullptr) {
        return;
    }
    if (session->backend == WriterBackend::Minizip) {
        close_minizip_writer(session);
    } else {
        close_libarchive_writer(session);
    }
}

auto default_compression_level(ArchiveFormat format) -> int {
    switch (format) {
        case ArchiveFormat::ZIP:
            return 6;
        case ArchiveFormat::TAR:
            return 0;
        case ArchiveFormat::TAR_GZ:
        case ArchiveFormat::TAR_XZ:
        case ArchiveFormat::TAR_LZ:
            return 6;
        case ArchiveFormat::TAR_BZ2:
            return 9;    // bzip2's levels are block sizes; 9 is its own tool's default
        case ArchiveFormat::TAR_ZST:
            return 3;    // zstd's design point: near-gzip ratios at several times the speed
        case ArchiveFormat::TAR_LZ4:
            return 1;    // lz4 is about speed; high levels defeat the reason to choose it
        case ArchiveFormat::SevenZip:
            return 5;
        default:
            return 0;
    }
}

auto normalized_compression_level(ArchiveFormat format, int requested_level) -> int {
    if (requested_level < 0) {
        requested_level = default_compression_level(format);
    }

    // zstd and bzip2 have no level 0 — libarchive rejects it rather than storing.
    const int minimum =
        (format == ArchiveFormat::TAR_ZST || format == ArchiveFormat::TAR_BZ2) ? 1 : 0;
    return std::clamp(requested_level, minimum, 9);
}

auto apply_compression_level(struct archive* writer,
                             ArchiveFormat format,
                             int compression_level,
                             const std::string& archive_path) -> common::Result<void> {
    // Plain containers: nothing here compresses, and the generic filter-option call below
    // would fail against a writer that has no filter attached.
    if (format == ArchiveFormat::TAR || format == ArchiveFormat::ISO) {
        return {};
    }

    const std::string level_str = std::to_string(compression_level);
    int status = archive_write_set_filter_option(
        writer, nullptr, "compression-level", level_str.c_str());

    if (status < ARCHIVE_WARN && format == ArchiveFormat::ZIP) {
        status = archive_write_set_format_option(
            writer, "zip", "compression-level", level_str.c_str());
    }
    if (status < ARCHIVE_WARN && format == ArchiveFormat::SevenZip) {
        status = archive_write_set_format_option(
            writer, "7zip", "compression-level", level_str.c_str());
    }

    if (status < ARCHIVE_WARN) {
        return to_archive_error("Failed to set archive compression level", archive_path, writer);
    }

    return {};
}

auto configure_writer(struct archive* writer,
                      ArchiveFormat format,
                      int compression_level,
                      const std::string& archive_path,
                      const std::string& password = "")
    -> common::Result<void> {
    int status = ARCHIVE_OK;

    switch (format) {
        case ArchiveFormat::ZIP:
            status = archive_write_set_format_zip(writer);
            break;
        case ArchiveFormat::TAR:
            status = archive_write_set_format_pax_restricted(writer);
            break;
        case ArchiveFormat::TAR_GZ:
            status = archive_write_set_format_pax_restricted(writer);
            if (status >= ARCHIVE_OK) {
                status = archive_write_add_filter_gzip(writer);
            }
            break;
        case ArchiveFormat::TAR_BZ2:
            status = archive_write_set_format_pax_restricted(writer);
            if (status >= ARCHIVE_OK) {
                status = archive_write_add_filter_bzip2(writer);
            }
            break;
        case ArchiveFormat::TAR_XZ:
            status = archive_write_set_format_pax_restricted(writer);
            if (status >= ARCHIVE_OK) {
                status = archive_write_add_filter_xz(writer);
            }
            break;
        case ArchiveFormat::TAR_ZST:
            status = archive_write_set_format_pax_restricted(writer);
            if (status >= ARCHIVE_OK) {
                status = archive_write_add_filter_zstd(writer);
            }
            break;
        case ArchiveFormat::TAR_LZ:
            status = archive_write_set_format_pax_restricted(writer);
            if (status >= ARCHIVE_OK) {
                status = archive_write_add_filter_lzip(writer);
            }
            break;
        case ArchiveFormat::TAR_LZ4:
            status = archive_write_set_format_pax_restricted(writer);
            if (status >= ARCHIVE_OK) {
                status = archive_write_add_filter_lz4(writer);
            }
            break;
        case ArchiveFormat::ISO:
            status = archive_write_set_format_iso9660(writer);
            break;
        case ArchiveFormat::SevenZip:
            status = archive_write_set_format_by_name(writer, "7zip");
            break;
        default:
            return make_error(common::ErrorCode::NotSupported,
                              "Archive format is not supported for writing",
                              archive_path);
    }

    if (status < ARCHIVE_OK) {
        return to_archive_error("Failed to configure archive format", archive_path, writer);
    }

    const auto level_result =
        apply_compression_level(writer, format, compression_level, archive_path);
    if (!level_result.has_value()) {
        return level_result.error();
    }

    // Password: AES-256, ZIP only. The 7z writer in libarchive cannot encrypt at all, and a
    // password silently ignored would ship an archive the user believes is protected — the
    // caller refuses those formats before ever reaching here.
    if (!password.empty()) {
        status = archive_write_set_options(writer, "zip:encryption=aes256");
        if (status < ARCHIVE_OK) {
            return to_archive_error("Failed to enable archive encryption", archive_path, writer);
        }
        status = archive_write_set_passphrase(writer, password.c_str());
        if (status < ARCHIVE_OK) {
            return to_archive_error("Failed to set archive password", archive_path, writer);
        }
    }

    return {};
}

auto file_time_to_time_t(stdfs::file_time_type file_time) -> std::time_t {
    const auto system_time = std::chrono::time_point_cast<std::chrono::system_clock::duration>(
        file_time - stdfs::file_time_type::clock::now() + std::chrono::system_clock::now());
    return std::chrono::system_clock::to_time_t(system_time);
}

auto configure_minizip_writer(void* writer,
                              int compression_level,
                              const std::string& archive_path) -> common::Result<void> {
    if (writer == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Failed to allocate ZIP writer",
                          archive_path);
    }

    const uint16_t method = compression_level == 0
        ? static_cast<uint16_t>(MZ_COMPRESS_METHOD_STORE)
        : static_cast<uint16_t>(MZ_COMPRESS_METHOD_DEFLATE);
    mz_zip_writer_set_compress_method(writer, method);
    mz_zip_writer_set_compress_level(writer, static_cast<int16_t>(compression_level));
    mz_zip_writer_set_follow_links(writer, 0);
    mz_zip_writer_set_store_links(writer, 0);
    mz_zip_writer_set_zip_cd(writer, 0);
    return {};
}

auto add_directory_entry_libarchive(WriterSession* session,
                                    std::string_view entry_name) -> common::Result<void> {
    if (session == nullptr || session->libarchive_writer == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive writer is not initialized");
    }

    struct archive* writer = session->libarchive_writer;
    const std::string& archive_path = session->archive_path;
    const std::string normalized_name = to_directory_entry_name(std::string(entry_name));
    if (normalized_name.empty()) {
        return {};
    }

    archive_entry* entry = archive_entry_new();
    if (entry == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Failed to allocate archive directory entry",
                          archive_path);
    }

    archive_entry_set_pathname(entry, normalized_name.c_str());
    archive_entry_set_filetype(entry, AE_IFDIR);
    archive_entry_set_perm(entry, 0755);
    archive_entry_set_size(entry, 0);

    const int status = archive_write_header(writer, entry);
    archive_entry_free(entry);

    if (status < ARCHIVE_OK) {
        return to_archive_error("Failed to write directory entry", archive_path, writer);
    }

    report_progress_from_libarchive(session, normalized_name);

    return {};
}

auto add_directory_entry_minizip(void* writer,
                                 const std::string& archive_path,
                                 std::string_view entry_name) -> common::Result<void> {
    const std::string normalized_name = to_directory_entry_name(std::string(entry_name));
    if (normalized_name.empty()) {
        return {};
    }

    mz_zip_file file_info = {};
    file_info.filename = normalized_name.c_str();
    file_info.modified_date = std::time(nullptr);
    file_info.external_fa = (0755u << 16) | 0x10u;
    file_info.zip64 = MZ_ZIP64_AUTO;

    int32_t status = mz_zip_writer_entry_open(writer, &file_info);
    if (status != MZ_OK) {
        return minizip_error_to_result(
            status,
            "Failed to write directory entry",
            archive_path);
    }

    status = mz_zip_writer_entry_close(writer);
    if (status != MZ_OK) {
        return minizip_error_to_result(
            status,
            "Failed to finalize directory entry",
            archive_path);
    }
    return {};
}

auto add_file_entry_libarchive(WriterSession* session,
                               const stdfs::path& file_path,
                               std::string_view archive_entry_path) -> common::Result<void> {
    if (session == nullptr || session->libarchive_writer == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive writer is not initialized");
    }

    struct archive* writer = session->libarchive_writer;
    const std::string& archive_path = session->archive_path;
    std::error_code ec;
    const uintmax_t size = stdfs::file_size(file_path, ec);
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to read source file size",
                          file_path.string());
    }

    std::ifstream input(file_path, std::ios::binary);
    if (!input.is_open()) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to open source file",
                          file_path.string());
    }

    std::string entry_name = normalize_archive_path(archive_entry_path);
    if (entry_name.empty()) {
        entry_name = file_path.filename().string();
    }

    archive_entry* entry = archive_entry_new();
    if (entry == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Failed to allocate archive file entry",
                          archive_path);
    }

    archive_entry_set_pathname(entry, entry_name.c_str());
    archive_entry_set_filetype(entry, AE_IFREG);
    archive_entry_set_perm(entry, 0644);
    archive_entry_set_size(entry, static_cast<la_int64_t>(size));

    const int header_status = archive_write_header(writer, entry);
    archive_entry_free(entry);
    if (header_status < ARCHIVE_OK) {
        return to_archive_error("Failed to write file entry header", archive_path, writer);
    }

    std::array<char, 64 * 1024> buffer{};
    while (input.good()) {
        if (is_archive_write_cancelled()) {
            return cancelled_error(archive_path);
        }
        input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        std::streamsize bytes_read = input.gcount();
        if (bytes_read <= 0) {
            continue;
        }

        const char* current = buffer.data();
        std::streamsize remaining = bytes_read;
        while (remaining > 0) {
            const la_ssize_t written =
                archive_write_data(writer, current, static_cast<size_t>(remaining));
            if (written < 0) {
                return to_archive_error("Failed to write file entry data", archive_path, writer);
            }

            current += written;
            remaining -= written;
            report_progress_from_libarchive(session, entry_name);
        }
    }

    if (!input.eof() && input.fail()) {
        return make_error(common::ErrorCode::IOError,
                          "Failed while reading source file",
                          file_path.string());
    }

    return {};
}

auto add_file_entry_minizip(void* writer,
                            const stdfs::path& file_path,
                            std::string_view archive_entry_path,
                            const std::string& archive_path) -> common::Result<void> {
    std::error_code ec;
    const uintmax_t size = stdfs::file_size(file_path, ec);
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to read source file size",
                          file_path.string());
    }

    std::ifstream input(file_path, std::ios::binary);
    if (!input.is_open()) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to open source file",
                          file_path.string());
    }

    std::string entry_name = normalize_archive_path(archive_entry_path);
    if (entry_name.empty()) {
        entry_name = file_path.filename().string();
    }

    mz_zip_file file_info = {};
    file_info.filename = entry_name.c_str();
    file_info.uncompressed_size = static_cast<int64_t>(size);
    file_info.external_fa = (0644u << 16);
    file_info.zip64 = MZ_ZIP64_AUTO;

    const auto write_time = stdfs::last_write_time(file_path, ec);
    if (!ec) {
        file_info.modified_date = file_time_to_time_t(write_time);
    } else {
        file_info.modified_date = std::time(nullptr);
    }

    int32_t status = mz_zip_writer_entry_open(writer, &file_info);
    if (status != MZ_OK) {
        return minizip_error_to_result(
            status,
            "Failed to write file entry header",
            archive_path);
    }

    std::array<char, 256 * 1024> buffer{};
    while (input.good()) {
        if (is_archive_write_cancelled()) {
            mz_zip_writer_entry_close(writer);
            return cancelled_error(archive_path);
        }

        input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        const std::streamsize bytes_read = input.gcount();
        if (bytes_read <= 0) {
            continue;
        }

        status = mz_zip_writer_entry_write(
            writer,
            buffer.data(),
            static_cast<int32_t>(bytes_read));
        if (status < 0) {
            mz_zip_writer_entry_close(writer);
            return minizip_error_to_result(
                status,
                "Failed to write file entry data",
                archive_path);
        }
    }

    if (!input.eof() && input.fail()) {
        mz_zip_writer_entry_close(writer);
        return make_error(common::ErrorCode::IOError,
                          "Failed while reading source file",
                          file_path.string());
    }

    status = mz_zip_writer_entry_close(writer);
    if (status != MZ_OK) {
        return minizip_error_to_result(
            status,
            "Failed to finalize file entry",
            archive_path);
    }

    return {};
}

}  // namespace

auto ArchiveWriter::create(std::string_view path,
                           ArchiveFormat format,
                           std::string_view password,
                           int compression_level,
                           bool preserve_paths,
                           ArchiveProgressCallback progress_callback,
                           int64_t total_uncompressed_bytes,
                           int total_files) -> common::Result<void> {
    ensure_utf8_ctype();
    if (path.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Archive path cannot be empty");
    }
    // ZIP is the one format the writers can encrypt (AES-256). Everything else refuses
    // loudly: a password taken and ignored would ship an archive the user BELIEVES is
    // protected, which is worse than no password at all.
    if (!password.empty() && format != ArchiveFormat::ZIP) {
        return make_error(common::ErrorCode::NotSupported,
                          "Password protection is only supported for ZIP archives",
                          std::string(path));
    }
    if (!is_writable_archive_format(format)) {
        return make_error(common::ErrorCode::NotSupported,
                          "Archive format is not supported for writing",
                          std::string(path));
    }

    reset_cancelled();
    std::lock_guard<std::mutex> lock(g_writer_mutex);

    if (WriterSession* existing = writer_session(this); existing != nullptr) {
        close_writer_session(existing);
        g_writer_sessions.erase(this);
    }

    const std::string archive_path(path);
    const int normalized_level = normalized_compression_level(format, compression_level);
    const int64_t normalized_total_uncompressed_bytes =
        std::max<int64_t>(total_uncompressed_bytes, 0);
    const int normalized_total_files = std::max(total_files, 0);
    const std::string archive_password(password);
    const bool use_minizip_for_zip =
        format == ArchiveFormat::ZIP && progress_callback == nullptr;

    if (use_minizip_for_zip) {
        void* writer = mz_zip_writer_create();
        if (writer == nullptr) {
            return make_error(common::ErrorCode::ArchiveError,
                              "Failed to allocate archive writer",
                              archive_path);
        }

        const auto config_result = configure_minizip_writer(
            writer,
            normalized_level,
            archive_path);
        if (config_result.has_value() && !archive_password.empty()) {
            // minizip-ng: the password plus AES turns on WinZip AES-256 entry encryption.
            mz_zip_writer_set_password(writer, archive_password.c_str());
            mz_zip_writer_set_aes(writer, 1);
        }
        if (!config_result.has_value()) {
            void* handle = writer;
            mz_zip_writer_delete(&handle);
            return config_result.error();
        }

        const int32_t status = mz_zip_writer_open_file(writer, archive_path.c_str(), 0, 0);
        if (status != MZ_OK) {
            void* handle = writer;
            mz_zip_writer_delete(&handle);
            return minizip_error_to_result(
                status,
                "Failed to open output archive",
                archive_path);
        }

        g_writer_sessions[this] = WriterSession{
            WriterBackend::Minizip,
            nullptr,
            writer,
            archive_path,
            format,
            normalized_level,
            preserve_paths,
            std::move(progress_callback),
            normalized_total_uncompressed_bytes,
            normalized_total_files
        };
        return {};
    }

    struct archive* writer = archive_write_new();
    if (writer == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Failed to allocate archive writer",
                          archive_path);
    }

    const auto configure_result =
        configure_writer(writer, format, normalized_level, archive_path, archive_password);
    if (!configure_result.has_value()) {
        archive_write_free(writer);
        return configure_result.error();
    }

    if (archive_write_open_filename(writer, archive_path.c_str()) < ARCHIVE_OK) {
        const common::Error error =
            to_archive_error("Failed to open output archive", archive_path, writer);
        archive_write_free(writer);
        return error;
    }

    g_writer_sessions[this] = WriterSession{
        WriterBackend::Libarchive,
        writer,
        nullptr,
        archive_path,
        format,
        normalized_level,
        preserve_paths,
        std::move(progress_callback),
        normalized_total_uncompressed_bytes,
        normalized_total_files
    };
    return {};
}

auto ArchiveWriter::add_file(std::string_view file_path,
                             std::string_view archive_path) -> common::Result<void> {
    if (file_path.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Source file path cannot be empty");
    }

    if (is_archive_write_cancelled()) {
        return cancelled_error(std::string(file_path));
    }

    std::lock_guard<std::mutex> lock(g_writer_mutex);
    WriterSession* session = writer_session(this);
    if (session == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive writer is not initialized");
    }
    if (session->backend == WriterBackend::Libarchive && session->libarchive_writer == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive writer is not initialized");
    }
    if (session->backend == WriterBackend::Minizip && session->minizip_writer == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive writer is not initialized");
    }

    const stdfs::path source_path(file_path);
    std::error_code ec;
    if (!stdfs::exists(source_path, ec)) {
        return make_error(common::ErrorCode::NotFound,
                          "Source file does not exist",
                          source_path.string());
    }
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to access source file",
                          source_path.string());
    }
    if (!stdfs::is_regular_file(source_path, ec)) {
        return make_error(common::ErrorCode::NotAFile,
                          "Source path is not a regular file",
                          source_path.string());
    }
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to inspect source file",
                          source_path.string());
    }

    std::string entry_path =
        archive_path.empty() ? source_path.filename().string() : normalize_archive_path(archive_path);
    if (!session->preserve_paths) {
        entry_path = source_path.filename().string();
    }

    if (session->backend == WriterBackend::Minizip) {
        return add_file_entry_minizip(
            session->minizip_writer,
            source_path,
            entry_path,
            session->archive_path);
    }

    return add_file_entry_libarchive(session, source_path, entry_path);
}

auto ArchiveWriter::add_directory(std::string_view dir_path,
                                  std::string_view archive_path) -> common::Result<void> {
    if (dir_path.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Source directory path cannot be empty");
    }

    if (is_archive_write_cancelled()) {
        return cancelled_error(std::string(dir_path));
    }

    std::lock_guard<std::mutex> lock(g_writer_mutex);
    WriterSession* session = writer_session(this);
    if (session == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive writer is not initialized");
    }
    if (session->backend == WriterBackend::Libarchive && session->libarchive_writer == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive writer is not initialized");
    }
    if (session->backend == WriterBackend::Minizip && session->minizip_writer == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive writer is not initialized");
    }

    const stdfs::path source_root(dir_path);
    std::error_code ec;
    if (!stdfs::exists(source_root, ec)) {
        return make_error(common::ErrorCode::NotFound,
                          "Source directory does not exist",
                          source_root.string());
    }
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to access source directory",
                          source_root.string());
    }
    if (!stdfs::is_directory(source_root, ec)) {
        return make_error(common::ErrorCode::NotADirectory,
                          "Source path is not a directory",
                          source_root.string());
    }
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to inspect source directory",
                          source_root.string());
    }

    const auto add_directory_entry = [&](std::string_view entry_name) -> common::Result<void> {
        if (session->backend == WriterBackend::Minizip) {
            return add_directory_entry_minizip(
                session->minizip_writer,
                session->archive_path,
                entry_name);
        }
        return add_directory_entry_libarchive(session, entry_name);
    };

    const auto add_file_entry = [&](const stdfs::path& source,
                                    std::string_view entry_name) -> common::Result<void> {
        if (session->backend == WriterBackend::Minizip) {
            return add_file_entry_minizip(
                session->minizip_writer,
                source,
                entry_name,
                session->archive_path);
        }
        return add_file_entry_libarchive(session, source, entry_name);
    };

    const std::string root_entry = archive_path.empty()
                                       ? normalize_archive_path(source_root.filename().string())
                                       : normalize_archive_path(archive_path);

    if (!session->preserve_paths) {
        stdfs::recursive_directory_iterator flat_iterator(
            source_root, stdfs::directory_options::skip_permission_denied, ec);
        if (ec) {
            return make_error(common::ErrorCode::IOError,
                              "Failed to iterate source directory",
                              source_root.string());
        }

        const stdfs::recursive_directory_iterator flat_end;
        while (flat_iterator != flat_end) {
            if (is_archive_write_cancelled()) {
                return cancelled_error(session->archive_path);
            }

            const stdfs::directory_entry& entry = *flat_iterator;
            const stdfs::path entry_path = entry.path();
            const bool is_regular_file = entry.is_regular_file(ec);
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to inspect directory entry type",
                                  entry_path.string());
            }

            if (is_regular_file) {
                const auto file_result = add_file_entry(
                    entry_path,
                    entry_path.filename().string());
                if (!file_result.has_value()) {
                    return file_result.error();
                }
            }

            flat_iterator.increment(ec);
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to advance directory iterator",
                                  source_root.string());
            }
        }

        return {};
    }

    const auto root_dir_result = add_directory_entry(root_entry);
    if (!root_dir_result.has_value()) {
        return root_dir_result.error();
    }

    stdfs::recursive_directory_iterator iterator(
        source_root, stdfs::directory_options::skip_permission_denied, ec);
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to iterate source directory",
                          source_root.string());
    }

    const stdfs::recursive_directory_iterator end;
    while (iterator != end) {
        if (is_archive_write_cancelled()) {
            return cancelled_error(session->archive_path);
        }
        const stdfs::directory_entry& entry = *iterator;
        const stdfs::path entry_path = entry.path();

        const stdfs::path relative_path = stdfs::relative(entry_path, source_root, ec);
        if (ec) {
            return make_error(common::ErrorCode::IOError,
                              "Failed to compute relative archive path",
                              entry_path.string());
        }

        const std::string archive_entry = join_archive_paths(root_entry, relative_path.generic_string());

        const bool is_directory = entry.is_directory(ec);
        if (ec) {
            return make_error(common::ErrorCode::IOError,
                              "Failed to inspect directory entry",
                              entry_path.string());
        }

        if (is_directory) {
            const auto dir_result = add_directory_entry(archive_entry);
            if (!dir_result.has_value()) {
                return dir_result.error();
            }
        } else {
            const bool is_regular_file = entry.is_regular_file(ec);
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to inspect directory entry type",
                                  entry_path.string());
            }

            if (is_regular_file) {
                const auto file_result = add_file_entry(entry_path, archive_entry);
                if (!file_result.has_value()) {
                    return file_result.error();
                }
            }
        }

        iterator.increment(ec);
        if (ec) {
            return make_error(common::ErrorCode::IOError,
                              "Failed to advance directory iterator",
                              source_root.string());
        }
    }

    return {};
}

auto ArchiveWriter::finalize() -> common::Result<void> {
    std::lock_guard<std::mutex> lock(g_writer_mutex);
    WriterSession* session = writer_session(this);
    if (session == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive writer is not initialized");
    }
    if (session->backend == WriterBackend::Libarchive && session->libarchive_writer == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive writer is not initialized");
    }
    if (session->backend == WriterBackend::Minizip && session->minizip_writer == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Archive writer is not initialized");
    }

    if (is_archive_write_cancelled()) {
        const std::string output_path = session->archive_path;
        close_writer_session(session);
        g_writer_sessions.erase(this);
        // Don't leave a half-written archive behind on cancel.
        std::error_code remove_ec;
        stdfs::remove(stdfs::path(output_path), remove_ec);
        return cancelled_error(output_path);
    }

    if (session->backend == WriterBackend::Minizip) {
        const int32_t status = mz_zip_writer_close(session->minizip_writer);
        void* handle = session->minizip_writer;
        mz_zip_writer_delete(&handle);
        session->minizip_writer = nullptr;
        // Copy the path out BEFORE erasing the session — erase() destroys *session, so reading
        // session->archive_path on the error path afterwards is use-after-free.
        const std::string archive_path_copy = session->archive_path;
        g_writer_sessions.erase(this);
        if (status != MZ_OK) {
            return minizip_error_to_result(
                status,
                "Failed to finalize archive",
                archive_path_copy);
        }
        return {};
    }

    const int close_status = archive_write_close(session->libarchive_writer);
    if (close_status < ARCHIVE_OK) {
        const common::Error error =
            to_archive_error("Failed to finalize archive", session->archive_path, session->libarchive_writer);
        archive_write_free(session->libarchive_writer);
        session->libarchive_writer = nullptr;
        g_writer_sessions.erase(this);
        return error;
    }

    archive_write_free(session->libarchive_writer);
    session->libarchive_writer = nullptr;
    g_writer_sessions.erase(this);
    return {};
}

ArchiveWriter::~ArchiveWriter() {
    std::lock_guard<std::mutex> lock(g_writer_mutex);
    if (WriterSession* session = writer_session(this); session != nullptr) {
        close_writer_session(session);
        g_writer_sessions.erase(this);
    }
}

void ArchiveWriter::cancel_current_operation() {
    g_archive_write_cancelled.store(true, std::memory_order_relaxed);
}

void ArchiveWriter::reset_cancelled() {
    g_archive_write_cancelled.store(false, std::memory_order_relaxed);
}

}  // namespace fcxl::archive
