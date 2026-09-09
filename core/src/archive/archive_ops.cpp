#include "fcxl/archive/archive_ops.h"

#include <archive.h>
#include <copyfile.h>
#include <archive_entry.h>

#include "fcxl/archive/archive_reader.h"
#include "fcxl/archive/archive_writer.h"

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
#include <filesystem>
#include <fstream>
#include <functional>
#include <limits>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>
#include <vector>

namespace fcxl::archive {
namespace {

namespace stdfs = std::filesystem;

using ArchiveReadPtr = std::unique_ptr<struct archive, decltype(&archive_read_free)>;

std::atomic_bool g_archive_ops_cancelled{false};

auto make_error(common::ErrorCode code, std::string message, std::string path = "") -> common::Error {
    return common::Error::make(code, std::move(message), std::move(path));
}

auto cancelled_error(const std::string& path) -> common::Error {
    return make_error(common::ErrorCode::Cancelled, "Archive operation cancelled", path);
}

auto should_cancel(const std::atomic<bool>* cancelled) -> bool {
    if (g_archive_ops_cancelled.load(std::memory_order_relaxed)) {
        return true;
    }
    return cancelled != nullptr && cancelled->load(std::memory_order_relaxed);
}

auto to_archive_error(const std::string& message,
                      const std::string& path,
                      struct archive* reader = nullptr) -> common::Error {
    std::string details = message;
    if (reader != nullptr) {
        const char* archive_message = archive_error_string(reader);
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

auto normalize_archive_path(std::string_view raw_path, bool trim_trailing_slash = true) -> std::string {
    std::string normalized(raw_path);

    while (normalized.rfind("./", 0) == 0) {
        normalized.erase(0, 2);
    }
    while (!normalized.empty() && normalized.front() == '/') {
        normalized.erase(normalized.begin());
    }

    std::replace(normalized.begin(), normalized.end(), '\\', '/');

    if (trim_trailing_slash) {
        while (!normalized.empty() && normalized.back() == '/') {
            normalized.pop_back();
        }
    }

    return normalized;
}

auto to_directory_entry_name(std::string value) -> std::string {
    std::string normalized = normalize_archive_path(value, false);
    if (!normalized.empty() && normalized.back() != '/') {
        normalized.push_back('/');
    }
    return normalized;
}

auto join_archive_paths(std::string_view left, std::string_view right) -> std::string {
    const std::string left_normalized = normalize_archive_path(left);
    const std::string right_normalized = normalize_archive_path(right);

    if (left_normalized.empty()) {
        return right_normalized;
    }
    if (right_normalized.empty()) {
        return left_normalized;
    }

    std::string joined = left_normalized;
    joined.push_back('/');
    joined += right_normalized;
    return joined;
}

auto is_same_or_child(std::string_view candidate, std::string_view root) -> bool {
    if (root.empty()) {
        return false;
    }
    if (candidate == root) {
        return true;
    }
    if (candidate.size() <= root.size()) {
        return false;
    }
    return candidate.compare(0, root.size(), root) == 0 && candidate[root.size()] == '/';
}

auto configure_reader(struct archive* reader, const std::string& path) -> common::Result<void> {
    if (archive_read_support_filter_all(reader) < ARCHIVE_OK) {
        return to_archive_error("Failed to enable archive filters", path, reader);
    }
    if (archive_read_support_format_all(reader) < ARCHIVE_OK) {
        return to_archive_error("Failed to enable archive formats", path, reader);
    }
    return {};
}

auto open_reader(std::string_view path) -> common::Result<ArchiveReadPtr> {
    if (path.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Archive path cannot be empty");
    }

    const stdfs::path archive_path(path);
    std::error_code ec;
    if (!stdfs::exists(archive_path, ec)) {
        return make_error(common::ErrorCode::NotFound,
                          "Archive does not exist",
                          archive_path.string());
    }
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to access archive path",
                          archive_path.string());
    }

    ArchiveReadPtr reader(archive_read_new(), &archive_read_free);
    if (!reader) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Failed to allocate archive reader",
                          archive_path.string());
    }

    const auto configure_result = configure_reader(reader.get(), archive_path.string());
    if (!configure_result.has_value()) {
        return configure_result.error();
    }

    if (archive_read_open_filename(reader.get(), archive_path.c_str(), 10240) < ARCHIVE_OK) {
        return to_archive_error("Failed to open archive", archive_path.string(), reader.get());
    }

    return reader;
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

auto consume_entry_data(struct archive* reader) -> bool {
    const void* buffer = nullptr;
    size_t size = 0;
    la_int64_t offset = 0;

    for (;;) {
        const int status = archive_read_data_block(reader, &buffer, &size, &offset);
        if (status == ARCHIVE_EOF) {
            return true;
        }
        if (status == ARCHIVE_WARN) {
            continue;
        }
        if (status < ARCHIVE_WARN) {
            return false;
        }
    }
}

auto make_temp_path(std::string_view archive_path, std::string_view suffix) -> std::string {
    const auto stamp = std::to_string(
        std::chrono::steady_clock::now().time_since_epoch().count());
    return std::string(archive_path) + "." + std::string(suffix) + "." + stamp + ".tmp";
}

auto directory_file_totals(const stdfs::path& root,
                          const std::atomic<bool>* cancelled = nullptr)
    -> common::Result<std::pair<int64_t, int>> {
    std::error_code ec;
    int64_t bytes_total = 0;
    int files_total = 0;

    stdfs::recursive_directory_iterator it(
        root,
        stdfs::directory_options::skip_permission_denied,
        ec);
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to iterate temporary directory",
                          root.string());
    }

    const stdfs::recursive_directory_iterator end;
    while (it != end) {
        if (should_cancel(cancelled)) {
            return cancelled_error(root.string());
        }

        const stdfs::directory_entry& entry = *it;
        if (entry.is_regular_file(ec)) {
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to inspect temporary file",
                                  entry.path().string());
            }
            const uintmax_t file_size = entry.file_size(ec);
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to read temporary file size",
                                  entry.path().string());
            }
            if (file_size > static_cast<uintmax_t>(std::numeric_limits<int64_t>::max()) - bytes_total) {
                return make_error(common::ErrorCode::InvalidArgument,
                                  "Temporary archive content is too large",
                                  entry.path().string());
            }
            bytes_total += static_cast<int64_t>(file_size);
            files_total += 1;
        }

        it.increment(ec);
        if (ec) {
            return make_error(common::ErrorCode::IOError,
                              "Failed to advance temporary directory iterator",
                              root.string());
        }
    }

    return std::make_pair(bytes_total, files_total);
}

auto copy_file_content(const stdfs::path& source,
                       const stdfs::path& destination,
                       const std::atomic<bool>* cancelled) -> common::Result<void> {
    std::ifstream input(source, std::ios::binary);
    if (!input.is_open()) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to open source file",
                          source.string());
    }

    std::ofstream output(destination, std::ios::binary | std::ios::trunc);
    if (!output.is_open()) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to open destination file",
                          destination.string());
    }

    std::array<char, 256 * 1024> buffer{};
    while (input.good()) {
        if (should_cancel(cancelled)) {
            return cancelled_error(source.string());
        }

        input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        const std::streamsize read_size = input.gcount();
        if (read_size <= 0) {
            continue;
        }

        output.write(buffer.data(), read_size);
        if (!output.good()) {
            return make_error(common::ErrorCode::IOError,
                              "Failed while writing destination file",
                              destination.string());
        }
    }

    if (!input.eof() && input.fail()) {
        return make_error(common::ErrorCode::IOError,
                          "Failed while reading source file",
                          source.string());
    }

    return {};
}

auto copy_path_recursive(const stdfs::path& source,
                         const stdfs::path& destination,
                         const std::atomic<bool>* cancelled) -> common::Result<void> {
    std::error_code ec;
    if (!stdfs::exists(source, ec)) {
        return make_error(common::ErrorCode::NotFound,
                          "Source path does not exist",
                          source.string());
    }
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to inspect source path",
                          source.string());
    }

    if (stdfs::is_regular_file(source, ec)) {
        if (ec) {
            return make_error(common::ErrorCode::IOError,
                              "Failed to inspect source file",
                              source.string());
        }
        stdfs::create_directories(destination.parent_path(), ec);
        if (ec) {
            return make_error(common::ErrorCode::IOError,
                              "Failed to create destination directory",
                              destination.parent_path().string());
        }
        return copy_file_content(source, destination, cancelled);
    }

    if (stdfs::is_directory(source, ec)) {
        if (ec) {
            return make_error(common::ErrorCode::IOError,
                              "Failed to inspect source directory",
                              source.string());
        }

        stdfs::create_directories(destination, ec);
        if (ec) {
            return make_error(common::ErrorCode::IOError,
                              "Failed to create destination directory",
                              destination.string());
        }

        stdfs::recursive_directory_iterator it(
            source,
            stdfs::directory_options::skip_permission_denied,
            ec);
        if (ec) {
            return make_error(common::ErrorCode::IOError,
                              "Failed to iterate source directory",
                              source.string());
        }

        const stdfs::recursive_directory_iterator end;
        while (it != end) {
            if (should_cancel(cancelled)) {
                return cancelled_error(source.string());
            }

            const stdfs::directory_entry& entry = *it;
            const stdfs::path relative_path = stdfs::relative(entry.path(), source, ec);
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to compute relative path",
                                  entry.path().string());
            }

            const stdfs::path target_path = destination / relative_path;
            if (entry.is_directory(ec)) {
                if (ec) {
                    return make_error(common::ErrorCode::IOError,
                                      "Failed to inspect directory entry",
                                      entry.path().string());
                }
                stdfs::create_directories(target_path, ec);
                if (ec) {
                    return make_error(common::ErrorCode::IOError,
                                      "Failed to create target directory",
                                      target_path.string());
                }
            } else if (entry.is_regular_file(ec)) {
                if (ec) {
                    return make_error(common::ErrorCode::IOError,
                                      "Failed to inspect file entry",
                                      entry.path().string());
                }
                const auto copy_result = copy_file_content(entry.path(), target_path, cancelled);
                if (!copy_result.has_value()) {
                    return copy_result.error();
                }
            }

            it.increment(ec);
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to advance source iterator",
                                  source.string());
            }
        }

        return {};
    }

    return make_error(common::ErrorCode::NotSupported,
                      "Only regular files and directories are supported",
                      source.string());
}

struct ZipAddPlan {
    struct FileItem {
        std::string source_path;
        std::string archive_entry;
        int64_t size = 0;
    };

    std::vector<std::string> directories;
    std::vector<FileItem> files;
    int64_t bytes_total = 0;
};

auto gather_zip_add_plan(const std::vector<std::string>& paths,
                         std::string_view base_path,
                         const std::atomic<bool>* cancelled)
    -> common::Result<ZipAddPlan> {
    ZipAddPlan plan;
    std::set<std::string> seen_directories;
    std::error_code ec;

    const std::string normalized_base = normalize_archive_path(base_path);

    for (const std::string& raw_source : paths) {
        if (should_cancel(cancelled)) {
            return cancelled_error(raw_source);
        }

        const stdfs::path source_path(raw_source);
        if (!stdfs::exists(source_path, ec)) {
            return make_error(common::ErrorCode::NotFound,
                              "Source path does not exist",
                              source_path.string());
        }
        if (ec) {
            return make_error(common::ErrorCode::IOError,
                              "Failed to inspect source path",
                              source_path.string());
        }

        const std::string source_name = source_path.filename().string();
        const std::string archive_root = join_archive_paths(normalized_base, source_name);

        if (stdfs::is_regular_file(source_path, ec)) {
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to inspect source file",
                                  source_path.string());
            }
            const uintmax_t file_size = stdfs::file_size(source_path, ec);
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to read source file size",
                                  source_path.string());
            }
            plan.files.push_back(ZipAddPlan::FileItem{
                source_path.string(),
                archive_root,
                static_cast<int64_t>(file_size)
            });
            plan.bytes_total += static_cast<int64_t>(file_size);
            continue;
        }

        if (!stdfs::is_directory(source_path, ec)) {
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to inspect source directory",
                                  source_path.string());
            }
            return make_error(common::ErrorCode::NotSupported,
                              "Source path type is not supported",
                              source_path.string());
        }

        const std::string root_directory = to_directory_entry_name(archive_root);
        if (!root_directory.empty() && seen_directories.insert(root_directory).second) {
            plan.directories.push_back(root_directory);
        }

        stdfs::recursive_directory_iterator it(
            source_path,
            stdfs::directory_options::skip_permission_denied,
            ec);
        if (ec) {
            return make_error(common::ErrorCode::IOError,
                              "Failed to iterate source directory",
                              source_path.string());
        }

        const stdfs::recursive_directory_iterator end;
        while (it != end) {
            if (should_cancel(cancelled)) {
                return cancelled_error(source_path.string());
            }

            const stdfs::directory_entry& entry = *it;
            const stdfs::path relative = stdfs::relative(entry.path(), source_path, ec);
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to compute relative path",
                                  entry.path().string());
            }

            if (entry.is_directory(ec)) {
                if (ec) {
                    return make_error(common::ErrorCode::IOError,
                                      "Failed to inspect source directory entry",
                                      entry.path().string());
                }
                const std::string dir_entry = to_directory_entry_name(
                    join_archive_paths(archive_root, relative.generic_string()));
                if (!dir_entry.empty() && seen_directories.insert(dir_entry).second) {
                    plan.directories.push_back(dir_entry);
                }
            } else if (entry.is_regular_file(ec)) {
                if (ec) {
                    return make_error(common::ErrorCode::IOError,
                                      "Failed to inspect source file entry",
                                      entry.path().string());
                }
                const uintmax_t file_size = entry.file_size(ec);
                if (ec) {
                    return make_error(common::ErrorCode::IOError,
                                      "Failed to read source file size",
                                      entry.path().string());
                }
                const std::string entry_path =
                    join_archive_paths(archive_root, relative.generic_string());
                plan.files.push_back(ZipAddPlan::FileItem{
                    entry.path().string(),
                    entry_path,
                    static_cast<int64_t>(file_size)
                });
                plan.bytes_total += static_cast<int64_t>(file_size);
            }

            it.increment(ec);
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to advance source iterator",
                                  source_path.string());
            }
        }
    }

    return plan;
}

auto add_zip_directory_entry(void* writer,
                             const std::string& archive_entry,
                             const std::string& archive_path) -> common::Result<void> {
    mz_zip_file file_info = {};
    file_info.filename = archive_entry.c_str();
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

struct ZipProgressContext {
    ArchiveOps::ArchiveProgressCallback progress_callback = nullptr;
    const std::atomic<bool>* cancelled = nullptr;
    int64_t total_bytes = 0;
    int total_files = 0;
    int64_t base_bytes_done = 0;
    int base_files_done = 0;
    int64_t current_file_bytes = 0;
    std::string current_file;
};

int32_t zip_writer_progress_cb(void* /*handle*/,
                               void* userdata,
                               mz_zip_file* /*file_info*/,
                               int64_t position) {
    ZipProgressContext* context = static_cast<ZipProgressContext*>(userdata);
    if (context == nullptr) {
        return MZ_OK;
    }

    if (should_cancel(context->cancelled)) {
        return MZ_INTERNAL_ERROR;
    }

    if (!context->progress_callback) {
        return MZ_OK;
    }

    const int64_t current_position = std::clamp<int64_t>(position, 0, context->current_file_bytes);
    const int64_t bytes_done = std::clamp<int64_t>(
        context->base_bytes_done + current_position,
        0,
        std::max<int64_t>(context->total_bytes, 1));

    context->progress_callback(
        context->current_file,
        bytes_done,
        std::max<int64_t>(context->total_bytes, 1),
        context->base_files_done,
        std::max(context->total_files, 1),
        -1);

    return MZ_OK;
}

/// Appends straight into `archive_path`. NOT safe on its own — see the wrapper below.
auto zip_append_files_in_place(const std::string& archive_path,
                               const std::vector<std::string>& file_paths,
                               std::string_view base_path,
                               const std::atomic<bool>* cancelled,
                               ArchiveOps::ArchiveProgressCallback progress_callback)
    -> common::Result<void> {
    const auto plan_result = gather_zip_add_plan(file_paths, base_path, cancelled);
    if (!plan_result.has_value()) {
        return plan_result.error();
    }
    const ZipAddPlan plan = plan_result.value();

    void* writer = mz_zip_writer_create();
    if (writer == nullptr) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Failed to allocate ZIP writer",
                          archive_path);
    }

    auto delete_writer = [&]() {
        if (writer != nullptr) {
            void* handle = writer;
            mz_zip_writer_delete(&handle);
            writer = nullptr;
        }
    };

    mz_zip_writer_set_compress_method(writer, static_cast<uint16_t>(MZ_COMPRESS_METHOD_DEFLATE));
    mz_zip_writer_set_compress_level(writer, 6);
    mz_zip_writer_set_follow_links(writer, 0);
    mz_zip_writer_set_store_links(writer, 0);

    ZipProgressContext progress_context;
    progress_context.progress_callback = std::move(progress_callback);
    progress_context.cancelled = cancelled;
    progress_context.total_bytes = std::max<int64_t>(plan.bytes_total, 1);
    progress_context.total_files = static_cast<int>(plan.directories.size() + plan.files.size());

    if (progress_context.progress_callback != nullptr) {
        mz_zip_writer_set_progress_cb(writer, &progress_context, zip_writer_progress_cb);
        mz_zip_writer_set_progress_interval(writer, 120);
    }

    int32_t status = mz_zip_writer_open_file(writer, archive_path.c_str(), 0, 1);
    if (status != MZ_OK) {
        delete_writer();
        return minizip_error_to_result(status, "Failed to open archive for append", archive_path);
    }

    int files_done = 0;
    int64_t bytes_done = 0;

    for (const std::string& directory_entry : plan.directories) {
        if (should_cancel(cancelled)) {
            mz_zip_writer_close(writer);
            delete_writer();
            return cancelled_error(archive_path);
        }

        const auto dir_result = add_zip_directory_entry(writer, directory_entry, archive_path);
        if (!dir_result.has_value()) {
            mz_zip_writer_close(writer);
            delete_writer();
            return dir_result.error();
        }

        files_done += 1;
        if (progress_context.progress_callback != nullptr) {
            progress_context.progress_callback(
                directory_entry,
                bytes_done,
                progress_context.total_bytes,
                files_done,
                std::max(progress_context.total_files, 1),
                -1);
        }
    }

    for (const ZipAddPlan::FileItem& file_item : plan.files) {
        if (should_cancel(cancelled)) {
            mz_zip_writer_close(writer);
            delete_writer();
            return cancelled_error(archive_path);
        }

        progress_context.current_file = file_item.archive_entry;
        progress_context.current_file_bytes = std::max<int64_t>(file_item.size, 0);
        progress_context.base_bytes_done = bytes_done;
        progress_context.base_files_done = files_done;

        status = mz_zip_writer_add_file(writer,
                                        file_item.source_path.c_str(),
                                        file_item.archive_entry.c_str());
        if (status != MZ_OK) {
            const bool cancelled_now = should_cancel(cancelled);
            mz_zip_writer_close(writer);
            delete_writer();
            if (cancelled_now) {
                return cancelled_error(archive_path);
            }
            return minizip_error_to_result(status, "Failed to append file to ZIP", archive_path);
        }

        bytes_done += std::max<int64_t>(file_item.size, 0);
        files_done += 1;
        if (progress_context.progress_callback != nullptr) {
            progress_context.progress_callback(
                file_item.archive_entry,
                std::clamp<int64_t>(bytes_done, 0, progress_context.total_bytes),
                progress_context.total_bytes,
                files_done,
                std::max(progress_context.total_files, 1),
                -1);
        }
    }

    status = mz_zip_writer_close(writer);
    delete_writer();
    if (status != MZ_OK) {
        return minizip_error_to_result(status, "Failed to finalize ZIP append", archive_path);
    }

    return {};
}

auto zip_entry_count(void* reader) -> int {
    void* zip_handle = nullptr;
    if (mz_zip_reader_get_zip_handle(reader, &zip_handle) != MZ_OK || zip_handle == nullptr) {
        return 0;
    }
    uint64_t count = 0;
    if (mz_zip_get_number_entry(zip_handle, &count) != MZ_OK) {
        return 0;
    }
    if (count > static_cast<uint64_t>(std::numeric_limits<int>::max())) {
        return std::numeric_limits<int>::max();
    }
    return static_cast<int>(count);
}

auto zip_copy_entry_with_info(void* writer,
                              void* reader,
                              mz_zip_file* file_info) -> int32_t {
    if (writer == nullptr || reader == nullptr || file_info == nullptr) {
        return MZ_PARAM_ERROR;
    }

    void* reader_zip_handle = nullptr;
    void* writer_zip_handle = nullptr;
    mz_zip_reader_get_zip_handle(reader, &reader_zip_handle);
    mz_zip_writer_get_zip_handle(writer, &writer_zip_handle);

    if (reader_zip_handle == nullptr || writer_zip_handle == nullptr) {
        return MZ_PARAM_ERROR;
    }

    int32_t err = mz_zip_entry_read_open(reader_zip_handle, 1, nullptr);
    if (err != MZ_OK) {
        return err;
    }

    uint8_t original_raw = 0;
    mz_zip_writer_get_raw(writer, &original_raw);
    mz_zip_writer_set_raw(writer, 1);

    int64_t compressed_size = 0;
    int64_t uncompressed_size = 0;
    uint32_t crc32 = 0;

    err = mz_zip_writer_entry_open(writer, file_info);
    if (err == MZ_OK &&
        mz_zip_attrib_is_dir(file_info->external_fa, file_info->version_madeby) != MZ_OK) {
        err = mz_zip_writer_add(writer, reader_zip_handle, mz_zip_entry_read);
    }

    if (err == MZ_OK) {
        err = mz_zip_entry_read_close(reader_zip_handle, &crc32, &compressed_size, &uncompressed_size);
        if (err == MZ_OK) {
            err = mz_zip_entry_write_close(writer_zip_handle, crc32, compressed_size, uncompressed_size);
        }
    }

    if (mz_zip_entry_is_open(reader_zip_handle) == MZ_OK) {
        mz_zip_entry_close(reader_zip_handle);
    }
    if (mz_zip_entry_is_open(writer_zip_handle) == MZ_OK) {
        mz_zip_entry_close(writer_zip_handle);
    }

    mz_zip_writer_set_raw(writer, original_raw);
    return err;
}

/// Append via a temp copy and swap it in at the very end — the identical protection
/// zip_delete_entries and zip_rename_entry below already give themselves. Appending was the
/// one zip mutation still writing into the user's file: minizip's append mode overwrites the
/// archive's central directory the moment the first entry is written and only rebuilds it on
/// close, so ANY interruption (cancel, crash, power loss) left the archive with no directory
/// at all — unopenable, everything inside it lost. There is no atomic in-place append in any
/// zip library; staging a copy and renaming is what every file manager does.
auto zip_append_files(const std::string& archive_path,
                      const std::vector<std::string>& file_paths,
                      std::string_view base_path,
                      const std::atomic<bool>* cancelled,
                      ArchiveOps::ArchiveProgressCallback progress_callback)
    -> common::Result<void> {
    const std::string temp_path = make_temp_path(archive_path, "add");
    std::error_code ec;

    // COPYFILE_CLONE: on APFS this is an instant copy-on-write clone costing no extra space;
    // on other filesystems it degrades to a normal copy.
    if (copyfile(archive_path.c_str(), temp_path.c_str(), nullptr,
                 COPYFILE_CLONE | COPYFILE_ALL) != 0) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to stage a working copy of the archive",
                          archive_path);
    }

    auto result = zip_append_files_in_place(temp_path, file_paths, base_path,
                                            cancelled, std::move(progress_callback));

    // A cancel raised WHILE a single file was being written cannot stop minizip: it throws
    // away whatever its progress callback returns (mz_zip_rw.c calls progress_cb and ignores
    // the result), so the write runs to completion and reports success. Our cancel check only
    // ever bit BETWEEN files — which is no help at all when the user is adding one big file,
    // and is exactly why a cancelled file still turned up in the archive.
    //
    // Honour the cancel here instead: the staged copy is discarded and the user's archive is
    // left exactly as it was. The write itself still finishes first (wasted work on the temp),
    // but the promise the user cares about — "cancel means it is not in there" — holds.
    if (!result.has_value() || should_cancel(cancelled)) {
        stdfs::remove(stdfs::path(temp_path), ec);   // original never touched
        return result.has_value() ? common::Result<void>(cancelled_error(archive_path)) : result;
    }

    stdfs::rename(stdfs::path(temp_path), stdfs::path(archive_path), ec);
    if (ec) {
        stdfs::remove(stdfs::path(temp_path), ec);
        return make_error(common::ErrorCode::IOError,
                          "Failed to replace original archive",
                          archive_path);
    }

    // COPYFILE_ALL cloned the original's timestamps onto the staging copy, so the archive
    // would come out of the swap claiming it was never modified. The reader caches its entry
    // list by path+mtime, so it would keep serving the OLD listing forever — the file really
    // is inside, but nothing ever shows it. Stamp the archive as modified now.
    stdfs::last_write_time(stdfs::path(archive_path),
                           stdfs::file_time_type::clock::now(), ec);
    return {};
}

auto zip_delete_entries(const std::string& archive_path,
                        const std::vector<std::string>& entry_paths,
                        const std::atomic<bool>* cancelled,
                        ArchiveOps::ArchiveProgressCallback progress_callback)
    -> common::Result<void> {
    std::unordered_set<std::string> targets;
    for (const std::string& raw : entry_paths) {
        const std::string normalized = normalize_archive_path(raw);
        if (!normalized.empty()) {
            targets.insert(normalized);
        }
    }

    if (targets.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "No archive entries were provided for deletion",
                          archive_path);
    }

    const std::string temp_path = make_temp_path(archive_path, "erase");

    void* reader = mz_zip_reader_create();
    void* writer = mz_zip_writer_create();
    if (reader == nullptr || writer == nullptr) {
        if (reader != nullptr) {
            void* handle = reader;
            mz_zip_reader_delete(&handle);
        }
        if (writer != nullptr) {
            void* handle = writer;
            mz_zip_writer_delete(&handle);
        }
        return make_error(common::ErrorCode::ArchiveError,
                          "Failed to allocate ZIP reader/writer",
                          archive_path);
    }

    auto cleanup = [&]() {
        if (reader != nullptr) {
            mz_zip_reader_close(reader);
            void* handle = reader;
            mz_zip_reader_delete(&handle);
            reader = nullptr;
        }
        if (writer != nullptr) {
            mz_zip_writer_close(writer);
            void* handle = writer;
            mz_zip_writer_delete(&handle);
            writer = nullptr;
        }
        std::error_code ec;
        stdfs::remove(stdfs::path(temp_path), ec);
    };

    int32_t status = mz_zip_reader_open_file(reader, archive_path.c_str());
    if (status != MZ_OK) {
        cleanup();
        return minizip_error_to_result(status, "Failed to open ZIP for reading", archive_path);
    }

    status = mz_zip_writer_open_file(writer, temp_path.c_str(), 0, 0);
    if (status != MZ_OK) {
        cleanup();
        return minizip_error_to_result(status, "Failed to open temporary ZIP", temp_path);
    }

    int total_entries = zip_entry_count(reader);
    total_entries = std::max(total_entries, 1);
    int processed_entries = 0;
    int removed_entries = 0;

    status = mz_zip_reader_goto_first_entry(reader);
    while (status == MZ_OK) {
        if (should_cancel(cancelled)) {
            cleanup();
            return cancelled_error(archive_path);
        }

        mz_zip_file* file_info = nullptr;
        status = mz_zip_reader_entry_get_info(reader, &file_info);
        if (status != MZ_OK || file_info == nullptr || file_info->filename == nullptr) {
            cleanup();
            return minizip_error_to_result(status, "Failed to get ZIP entry info", archive_path);
        }

        const std::string current_entry = normalize_archive_path(file_info->filename);
        bool should_remove_entry = false;
        for (const std::string& target : targets) {
            if (is_same_or_child(current_entry, target)) {
                should_remove_entry = true;
                break;
            }
        }

        if (should_remove_entry) {
            removed_entries += 1;
        } else {
            status = mz_zip_writer_copy_from_reader(writer, reader);
            if (status != MZ_OK) {
                cleanup();
                return minizip_error_to_result(status, "Failed to copy ZIP entry", archive_path);
            }
        }

        processed_entries += 1;
        if (progress_callback != nullptr) {
            progress_callback(
                current_entry,
                processed_entries,
                total_entries,
                processed_entries,
                total_entries,
                -1);
        }

        status = mz_zip_reader_goto_next_entry(reader);
    }

    if (status != MZ_END_OF_LIST) {
        cleanup();
        return minizip_error_to_result(status, "Failed to iterate ZIP entries", archive_path);
    }

    if (removed_entries == 0) {
        cleanup();
        return make_error(common::ErrorCode::NotFound,
                          "Entry not found in archive",
                          archive_path);
    }

    // All entries removed — mz_zip_writer_close hangs on empty ZIP,
    // so create a minimal empty ZIP file directly.
    if (removed_entries == processed_entries) {
        cleanup(); // closes reader/writer, removes temp_path

        // Minimal empty ZIP: end-of-central-directory record (22 bytes)
        static const uint8_t empty_zip[] = {
            0x50, 0x4B, 0x05, 0x06,   // EOCD signature
            0x00, 0x00,               // disk number
            0x00, 0x00,               // disk with CD
            0x00, 0x00,               // entries on this disk
            0x00, 0x00,               // total entries
            0x00, 0x00, 0x00, 0x00,   // CD size
            0x00, 0x00, 0x00, 0x00,   // CD offset
            0x00, 0x00                // comment length
        };

        std::ofstream out(archive_path, std::ios::binary | std::ios::trunc);
        if (!out.is_open()) {
            return make_error(common::ErrorCode::IOError,
                              "Failed to create empty archive",
                              archive_path);
        }
        out.write(reinterpret_cast<const char*>(empty_zip), sizeof(empty_zip));
        out.close();

        if (progress_callback != nullptr) {
            progress_callback(
                "Готово",
                total_entries,
                total_entries,
                total_entries,
                total_entries,
                -1);
        }

        return {};
    }

    uint8_t zip_cd = 0;
    mz_zip_reader_get_zip_cd(reader, &zip_cd);
    mz_zip_writer_set_zip_cd(writer, zip_cd);

    const int32_t close_reader_status = mz_zip_reader_close(reader);
    void* reader_handle = reader;
    mz_zip_reader_delete(&reader_handle);
    reader = nullptr;

    const int32_t close_writer_status = mz_zip_writer_close(writer);
    void* writer_handle = writer;
    mz_zip_writer_delete(&writer_handle);
    writer = nullptr;

    if (close_reader_status != MZ_OK || close_writer_status != MZ_OK) {
        std::error_code ec;
        stdfs::remove(stdfs::path(temp_path), ec);
        return minizip_error_to_result(close_writer_status != MZ_OK ? close_writer_status : close_reader_status,
                                       "Failed to finalize ZIP rewrite",
                                       archive_path);
    }

    std::error_code ec;
    stdfs::rename(stdfs::path(temp_path), stdfs::path(archive_path), ec);
    if (ec) {
        stdfs::remove(stdfs::path(temp_path), ec);
        return make_error(common::ErrorCode::IOError,
                          "Failed to replace original archive",
                          archive_path);
    }

    if (progress_callback != nullptr) {
        progress_callback(
            "Готово",
            total_entries,
            total_entries,
            total_entries,
            total_entries,
            -1);
    }

    return {};
}

auto zip_rename_entry(const std::string& archive_path,
                      std::string_view old_entry_path,
                      std::string_view new_entry_path,
                      const std::atomic<bool>* cancelled,
                      ArchiveOps::ArchiveProgressCallback progress_callback)
    -> common::Result<void> {
    const std::string old_entry = normalize_archive_path(old_entry_path);
    const std::string new_entry = normalize_archive_path(new_entry_path);

    if (old_entry.empty() || new_entry.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Old and new archive entry paths must be non-empty",
                          archive_path);
    }
    if (old_entry == new_entry) {
        return {};
    }

    const std::string temp_path = make_temp_path(archive_path, "rename");

    void* reader = mz_zip_reader_create();
    void* writer = mz_zip_writer_create();
    if (reader == nullptr || writer == nullptr) {
        if (reader != nullptr) {
            void* handle = reader;
            mz_zip_reader_delete(&handle);
        }
        if (writer != nullptr) {
            void* handle = writer;
            mz_zip_writer_delete(&handle);
        }
        return make_error(common::ErrorCode::ArchiveError,
                          "Failed to allocate ZIP reader/writer",
                          archive_path);
    }

    auto cleanup = [&]() {
        if (reader != nullptr) {
            mz_zip_reader_close(reader);
            void* handle = reader;
            mz_zip_reader_delete(&handle);
            reader = nullptr;
        }
        if (writer != nullptr) {
            mz_zip_writer_close(writer);
            void* handle = writer;
            mz_zip_writer_delete(&handle);
            writer = nullptr;
        }
        std::error_code ec;
        stdfs::remove(stdfs::path(temp_path), ec);
    };

    int32_t status = mz_zip_reader_open_file(reader, archive_path.c_str());
    if (status != MZ_OK) {
        cleanup();
        return minizip_error_to_result(status, "Failed to open ZIP for reading", archive_path);
    }

    status = mz_zip_writer_open_file(writer, temp_path.c_str(), 0, 0);
    if (status != MZ_OK) {
        cleanup();
        return minizip_error_to_result(status, "Failed to open temporary ZIP", temp_path);
    }

    int total_entries = zip_entry_count(reader);
    total_entries = std::max(total_entries, 1);
    int processed_entries = 0;
    bool renamed_any = false;

    status = mz_zip_reader_goto_first_entry(reader);
    while (status == MZ_OK) {
        if (should_cancel(cancelled)) {
            cleanup();
            return cancelled_error(archive_path);
        }

        mz_zip_file* file_info = nullptr;
        status = mz_zip_reader_entry_get_info(reader, &file_info);
        if (status != MZ_OK || file_info == nullptr || file_info->filename == nullptr) {
            cleanup();
            return minizip_error_to_result(status, "Failed to get ZIP entry info", archive_path);
        }

        const std::string current_entry = normalize_archive_path(file_info->filename);
        std::string renamed_entry;

        mz_zip_file modified_info = *file_info;
        mz_zip_file* info_to_write = file_info;

        if (is_same_or_child(current_entry, old_entry)) {
            renamed_entry = new_entry;
            if (current_entry.size() > old_entry.size()) {
                renamed_entry += current_entry.substr(old_entry.size());
            }
            renamed_entry = normalize_archive_path(renamed_entry, false);
            const std::string original_name = file_info->filename != nullptr ? file_info->filename : "";
            const bool is_directory_entry = !original_name.empty() && original_name.back() == '/';
            if (is_directory_entry && !renamed_entry.empty() && renamed_entry.back() != '/') {
                renamed_entry.push_back('/');
            }
            if (renamed_entry.empty()) {
                cleanup();
                return make_error(common::ErrorCode::InvalidArgument,
                                  "Renamed archive entry path is empty",
                                  archive_path);
            }
            modified_info.filename = renamed_entry.c_str();
            info_to_write = &modified_info;
            renamed_any = true;
        }

        status = zip_copy_entry_with_info(writer, reader, info_to_write);
        if (status != MZ_OK) {
            cleanup();
            if (should_cancel(cancelled)) {
                return cancelled_error(archive_path);
            }
            return minizip_error_to_result(status, "Failed to copy ZIP entry", archive_path);
        }

        processed_entries += 1;
        if (progress_callback != nullptr) {
            progress_callback(
                renamed_entry.empty() ? current_entry : renamed_entry,
                processed_entries,
                total_entries,
                processed_entries,
                total_entries,
                -1);
        }

        status = mz_zip_reader_goto_next_entry(reader);
    }

    if (status != MZ_END_OF_LIST) {
        cleanup();
        return minizip_error_to_result(status, "Failed to iterate ZIP entries", archive_path);
    }

    if (!renamed_any) {
        cleanup();
        return make_error(common::ErrorCode::NotFound,
                          "Entry not found in archive",
                          archive_path);
    }

    uint8_t zip_cd = 0;
    mz_zip_reader_get_zip_cd(reader, &zip_cd);
    mz_zip_writer_set_zip_cd(writer, zip_cd);

    const int32_t close_reader_status = mz_zip_reader_close(reader);
    void* reader_handle = reader;
    mz_zip_reader_delete(&reader_handle);
    reader = nullptr;

    const int32_t close_writer_status = mz_zip_writer_close(writer);
    void* writer_handle = writer;
    mz_zip_writer_delete(&writer_handle);
    writer = nullptr;

    if (close_reader_status != MZ_OK || close_writer_status != MZ_OK) {
        std::error_code ec;
        stdfs::remove(stdfs::path(temp_path), ec);
        return minizip_error_to_result(close_writer_status != MZ_OK ? close_writer_status : close_reader_status,
                                       "Failed to finalize ZIP rewrite",
                                       archive_path);
    }

    std::error_code ec;
    stdfs::rename(stdfs::path(temp_path), stdfs::path(archive_path), ec);
    if (ec) {
        stdfs::remove(stdfs::path(temp_path), ec);
        return make_error(common::ErrorCode::IOError,
                          "Failed to replace original archive",
                          archive_path);
    }

    if (progress_callback != nullptr) {
        progress_callback(
            "Готово",
            total_entries,
            total_entries,
            total_entries,
            total_entries,
            -1);
    }

    return {};
}

auto add_directory_children_to_writer(ArchiveWriter* writer,
                                      const stdfs::path& root,
                                      const std::atomic<bool>* cancelled)
    -> common::Result<void> {
    std::error_code ec;
    stdfs::directory_iterator it(root, stdfs::directory_options::skip_permission_denied, ec);
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to iterate temporary directory",
                          root.string());
    }

    const stdfs::directory_iterator end;
    while (it != end) {
        if (should_cancel(cancelled)) {
            return cancelled_error(root.string());
        }

        const stdfs::directory_entry& entry = *it;
        const std::string archive_name = entry.path().filename().generic_string();

        if (entry.is_directory(ec)) {
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to inspect temporary directory entry",
                                  entry.path().string());
            }
            const auto result = writer->add_directory(entry.path().string(), archive_name);
            if (!result.has_value()) {
                return result.error();
            }
        } else if (entry.is_regular_file(ec)) {
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to inspect temporary file entry",
                                  entry.path().string());
            }
            const auto result = writer->add_file(entry.path().string(), archive_name);
            if (!result.has_value()) {
                return result.error();
            }
        }

        it.increment(ec);
        if (ec) {
            return make_error(common::ErrorCode::IOError,
                              "Failed to advance temporary directory iterator",
                              root.string());
        }
    }

    return {};
}

auto full_rebuild_archive(const std::string& archive_path,
                          ArchiveFormat format,
                          const std::function<common::Result<void>(const stdfs::path&)>& mutate_temp_dir,
                          const std::atomic<bool>* cancelled,
                          ArchiveOps::ArchiveProgressCallback progress_callback)
    -> common::Result<void> {
    const std::string temp_dir_path = make_temp_path(archive_path, "workdir");
    const std::string temp_archive_path = make_temp_path(archive_path, "rebuild");

    const stdfs::path temp_dir(temp_dir_path);
    const stdfs::path temp_archive(temp_archive_path);

    std::error_code ec;
    stdfs::create_directories(temp_dir, ec);
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to create temporary directory",
                          temp_dir.string());
    }

    auto cleanup = [&]() {
        std::error_code remove_ec;
        stdfs::remove_all(temp_dir, remove_ec);
        stdfs::remove(temp_archive, remove_ec);
    };

    if (progress_callback != nullptr) {
        progress_callback("Распаковка архива...", 0, 1, 0, 1, -1);
    }

    // Phase 1: Extract existing archive to temp directory (with progress)
    ArchiveReader reader;
    auto open_result = reader.open(archive_path);
    if (!open_result.has_value()) {
        cleanup();
        return open_result.error();
    }

    ArchiveReader::ExtractProgressCallback extract_progress = nullptr;
    if (progress_callback != nullptr) {
        extract_progress = [&progress_callback](const std::string& current_file,
                                                 uint64_t bytes_done,
                                                 uint64_t bytes_total,
                                                 int files_done,
                                                 int files_total) {
            progress_callback(current_file,
                              static_cast<int64_t>(bytes_done),
                              static_cast<int64_t>(bytes_total),
                              files_done,
                              files_total,
                              -1);
        };
    }

    auto extract_result = reader.extract_all(temp_dir.string(), const_cast<std::atomic<bool>*>(cancelled), true, extract_progress);
    reader.close();
    if (!extract_result.has_value()) {
        cleanup();
        return extract_result.error();
    }

    if (should_cancel(cancelled)) {
        cleanup();
        return cancelled_error(archive_path);
    }

    // Phase 2: Apply mutation (add/delete/rename files)
    if (progress_callback != nullptr) {
        progress_callback("Применение изменений...", 0, 1, 0, 1, -1);
    }

    const auto mutation_result = mutate_temp_dir(temp_dir);
    if (!mutation_result.has_value()) {
        cleanup();
        return mutation_result.error();
    }

    if (should_cancel(cancelled)) {
        cleanup();
        return cancelled_error(archive_path);
    }

    // Phase 3: Calculate totals for repack
    if (progress_callback != nullptr) {
        progress_callback("Подсчёт файлов...", 0, 1, 0, 1, -1);
    }

    const auto totals_result = directory_file_totals(temp_dir, cancelled);
    if (!totals_result.has_value()) {
        cleanup();
        return totals_result.error();
    }

    const int64_t bytes_total = std::max<int64_t>(totals_result.value().first, 1);
    const int files_total = std::max(totals_result.value().second, 1);

    // Phase 4: Repack archive (with progress)
    if (progress_callback != nullptr) {
        progress_callback("Упаковка архива...", 0, bytes_total, 0, files_total, -1);
    }

    ArchiveWriter writer;
    auto create_result = writer.create(
        temp_archive.string(),
        format,
        "",
        -1,
        true,
        progress_callback,
        bytes_total,
        files_total);
    if (!create_result.has_value()) {
        cleanup();
        return create_result.error();
    }

    const auto add_result = add_directory_children_to_writer(&writer, temp_dir, cancelled);
    if (!add_result.has_value()) {
        cleanup();
        return add_result.error();
    }

    if (should_cancel(cancelled)) {
        ArchiveWriter::cancel_current_operation();
        (void)writer.finalize();
        cleanup();
        return cancelled_error(archive_path);
    }

    auto finalize_result = writer.finalize();
    if (!finalize_result.has_value()) {
        cleanup();
        return finalize_result.error();
    }

    std::error_code rename_ec;
    stdfs::rename(temp_archive, stdfs::path(archive_path), rename_ec);
    if (rename_ec) {
        cleanup();
        return make_error(common::ErrorCode::IOError,
                          "Failed to replace original archive",
                          archive_path);
    }

    cleanup();
    return {};
}

}  // namespace

// Forward declaration — add_files/delete_entries guard against ".." path traversal with this
// before its definition further down (same fcxl::archive scope, not the anonymous namespace).
auto has_dotdot_component(std::string_view path) -> bool;

// A ZIP that lost its tail — the central directory — still reads entry by entry: without
// the directory libarchive falls back to its streaming reader, which takes the end of the
// file for the end of the archive and reports nothing wrong (measured: bsdtar lists a zip
// cut in half, exit 0). unzip and Python call that archive corrupt, and so must this check.
// Not through minizip — it quietly REBUILDS a missing directory from the local headers — but
// the way they do it: the end-of-central-directory record must sit in the file's tail, within
// the longest comment a zip may carry.
auto zip_has_central_directory(const std::string& archive_path) -> bool {
    std::ifstream in(archive_path, std::ios::binary | std::ios::ate);
    if (!in) {
        return false;
    }
    const auto size = static_cast<std::size_t>(in.tellg());
    constexpr std::size_t kEocdSize = 22;
    constexpr std::size_t kMaxComment = 65535;
    if (size < kEocdSize) {
        return false;
    }
    const std::size_t tail = std::min(size, kEocdSize + kMaxComment);
    std::string bytes(tail, '\0');
    in.seekg(static_cast<std::streamoff>(size - tail));
    in.read(bytes.data(), static_cast<std::streamsize>(tail));
    static constexpr char kSignature[] = {'P', 'K', 0x05, 0x06};
    return bytes.find(std::string_view(kSignature, sizeof(kSignature))) != std::string::npos;
}

auto ArchiveOps::test_integrity(std::string_view path) -> common::Result<bool> {
    ensure_utf8_ctype();
    auto reader_result = open_reader(path);
    if (!reader_result.has_value()) {
        return reader_result.error();
    }
    ArchiveReadPtr reader = std::move(reader_result.value());

    archive_entry* entry = nullptr;
    bool is_zip = false;
    for (;;) {
        const int status = archive_read_next_header(reader.get(), &entry);
        if (status == ARCHIVE_EOF) {
            return is_zip ? zip_has_central_directory(std::string(path)) : true;
        }
        if (status == ARCHIVE_WARN) {
            continue;
        }
        if (status < ARCHIVE_WARN) {
            return false;
        }
        // Known only once a header has been read.
        is_zip = (archive_format(reader.get()) & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_ZIP;

        if (!consume_entry_data(reader.get())) {
            return false;
        }
    }
}

auto ArchiveOps::remove_entry(std::string_view archive_path,
                              std::string_view entry_path) -> common::Result<void> {
    return delete_entries(archive_path, {std::string(entry_path)}, nullptr, nullptr);
}

// Normalized names already present in a ZIP's central directory. Used to detect
// collisions before append — minizip's append mode would otherwise create a
// duplicate entry instead of replacing.
auto zip_existing_entry_names(const std::string& archive_path)
    -> std::unordered_set<std::string> {
    std::unordered_set<std::string> names;
    void* reader = mz_zip_reader_create();
    if (reader == nullptr) {
        return names;
    }
    if (mz_zip_reader_open_file(reader, archive_path.c_str()) == MZ_OK) {
        int32_t status = mz_zip_reader_goto_first_entry(reader);
        while (status == MZ_OK) {
            mz_zip_file* file_info = nullptr;
            if (mz_zip_reader_entry_get_info(reader, &file_info) == MZ_OK
                && file_info != nullptr && file_info->filename != nullptr) {
                names.insert(normalize_archive_path(file_info->filename));
            }
            status = mz_zip_reader_goto_next_entry(reader);
        }
        mz_zip_reader_close(reader);
    }
    void* handle = reader;
    mz_zip_reader_delete(&handle);
    return names;
}

auto ArchiveOps::add_files(std::string_view archive_path,
                           const std::vector<std::string>& file_paths,
                           std::string_view base_path,
                           std::atomic<bool>* cancelled,
                           ArchiveProgressCallback progress_callback) -> common::Result<void> {
    if (archive_path.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Archive path cannot be empty");
    }
    if (file_paths.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "No source files were provided",
                          std::string(archive_path));
    }

    const auto format_result = detect_format(archive_path);
    if (!format_result.has_value()) {
        return format_result.error();
    }

    const ArchiveFormat format = format_result.value();
    if (format == ArchiveFormat::ZIP) {
        // minizip's append mode adds a SECOND record for a name that already
        // exists instead of replacing it (duplicate central-directory entries,
        // inconsistent listings). If any incoming file collides with an existing
        // entry, delete those entries first (rebuild), then append.
        const auto plan = gather_zip_add_plan(file_paths, base_path, cancelled);
        if (plan.has_value()) {
            const auto existing = zip_existing_entry_names(std::string(archive_path));
            if (!existing.empty()) {
                std::vector<std::string> collisions;
                std::unordered_set<std::string> seen;
                for (const auto& file_item : plan.value().files) {
                    const std::string normalized = normalize_archive_path(file_item.archive_entry);
                    if (existing.count(normalized) != 0 && seen.insert(normalized).second) {
                        collisions.push_back(normalized);
                    }
                }
                if (!collisions.empty()) {
                    auto del = zip_delete_entries(std::string(archive_path), collisions,
                                                  cancelled, nullptr);
                    if (!del.has_value()) {
                        return del.error();
                    }
                }
            }
        }
        return zip_append_files(
            std::string(archive_path),
            file_paths,
            base_path,
            cancelled,
            std::move(progress_callback));
    }

    if (format != ArchiveFormat::TAR && format != ArchiveFormat::TAR_GZ &&
        format != ArchiveFormat::TAR_BZ2 && format != ArchiveFormat::TAR_XZ &&
        format != ArchiveFormat::TAR_ZST && format != ArchiveFormat::TAR_LZ &&
        format != ArchiveFormat::TAR_LZ4 && format != ArchiveFormat::SevenZip) {
        return make_error(common::ErrorCode::NotSupported,
                          "Archive format is not supported for adding files",
                          std::string(archive_path));
    }

    const std::string normalized_base = normalize_archive_path(base_path);
    // Reject a base path that would escape the temp dir during rebuild (ZipSlip). Defense in
    // depth behind Swift-side validation; matches the rename path's guard.
    if (has_dotdot_component(normalized_base)) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Archive entry path must not contain '..'",
                          std::string(archive_path));
    }
    return full_rebuild_archive(
        std::string(archive_path),
        format,
        [&](const stdfs::path& temp_dir) -> common::Result<void> {
            for (const std::string& raw_source : file_paths) {
                if (should_cancel(cancelled)) {
                    return cancelled_error(std::string(archive_path));
                }

                const stdfs::path source_path(raw_source);
                const stdfs::path destination_dir = temp_dir / normalized_base;
                const stdfs::path destination_path = destination_dir / source_path.filename();

                std::error_code remove_ec;
                stdfs::remove_all(destination_path, remove_ec);

                const auto copy_result = copy_path_recursive(source_path, destination_path, cancelled);
                if (!copy_result.has_value()) {
                    return copy_result.error();
                }
            }
            return {};
        },
        cancelled,
        std::move(progress_callback));
}

auto ArchiveOps::delete_entries(std::string_view archive_path,
                                const std::vector<std::string>& entry_paths,
                                std::atomic<bool>* cancelled,
                                ArchiveProgressCallback progress_callback) -> common::Result<void> {
    if (archive_path.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Archive path cannot be empty");
    }
    if (entry_paths.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "No archive entries were provided for deletion",
                          std::string(archive_path));
    }

    const auto format_result = detect_format(archive_path);
    if (!format_result.has_value()) {
        return format_result.error();
    }

    const ArchiveFormat format = format_result.value();
    if (format == ArchiveFormat::ZIP) {
        return zip_delete_entries(
            std::string(archive_path),
            entry_paths,
            cancelled,
            std::move(progress_callback));
    }

    if (format != ArchiveFormat::TAR && format != ArchiveFormat::TAR_GZ &&
        format != ArchiveFormat::TAR_BZ2 && format != ArchiveFormat::TAR_XZ &&
        format != ArchiveFormat::TAR_ZST && format != ArchiveFormat::TAR_LZ &&
        format != ArchiveFormat::TAR_LZ4 && format != ArchiveFormat::SevenZip) {
        return make_error(common::ErrorCode::NotSupported,
                          "Archive format is not supported for deleting entries",
                          std::string(archive_path));
    }

    std::unordered_set<std::string> normalized_targets;
    for (const std::string& raw : entry_paths) {
        const std::string normalized = normalize_archive_path(raw);
        if (!normalized.empty()) {
            normalized_targets.insert(normalized);
        }
    }

    return full_rebuild_archive(
        std::string(archive_path),
        format,
        [&](const stdfs::path& temp_dir) -> common::Result<void> {
            int removed_entries = 0;
            for (const std::string& target : normalized_targets) {
                if (should_cancel(cancelled)) {
                    return cancelled_error(std::string(archive_path));
                }
                // Reject a ".." entry name so remove_all can't escape the temp dir (ZipSlip).
                if (has_dotdot_component(target)) {
                    return make_error(common::ErrorCode::InvalidArgument,
                                      "Archive entry path must not contain '..'",
                                      std::string(archive_path));
                }

                std::error_code ec;
                const stdfs::path absolute_target = temp_dir / target;
                if (stdfs::exists(absolute_target, ec)) {
                    stdfs::remove_all(absolute_target, ec);
                    if (ec) {
                        return make_error(common::ErrorCode::IOError,
                                          "Failed to remove archive entry",
                                          absolute_target.string());
                    }
                    removed_entries += 1;
                }
            }

            if (removed_entries == 0) {
                return make_error(common::ErrorCode::NotFound,
                                  "Entry not found in archive",
                                  std::string(archive_path));
            }

            return {};
        },
        cancelled,
        std::move(progress_callback));
}

// True if a normalized ('/'-separated, no leading slash) path has a ".."
// component. normalize_archive_path strips leading "/" and "./" but not interior
// "..", so the rebuild path (temp_dir / normalized_new) could otherwise escape
// the temp dir. Defense-in-depth behind the Swift-side name validation.
auto has_dotdot_component(std::string_view path) -> bool {
    size_t start = 0;
    while (start <= path.size()) {
        const size_t slash = path.find('/', start);
        const std::string_view component = (slash == std::string_view::npos)
            ? path.substr(start)
            : path.substr(start, slash - start);
        if (component == "..") {
            return true;
        }
        if (slash == std::string_view::npos) {
            break;
        }
        start = slash + 1;
    }
    return false;
}

auto ArchiveOps::rename_entry(std::string_view archive_path,
                              std::string_view old_entry_path,
                              std::string_view new_entry_path,
                              std::atomic<bool>* cancelled,
                              ArchiveProgressCallback progress_callback) -> common::Result<void> {
    if (archive_path.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Archive path cannot be empty");
    }

    const std::string normalized_old = normalize_archive_path(old_entry_path);
    const std::string normalized_new = normalize_archive_path(new_entry_path);

    if (normalized_old.empty() || normalized_new.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Old and new archive entry paths must be non-empty",
                          std::string(archive_path));
    }

    if (has_dotdot_component(normalized_old) || has_dotdot_component(normalized_new)) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Archive entry path must not contain '..'",
                          std::string(archive_path));
    }

    if (normalized_old == normalized_new) {
        return {};
    }

    const auto format_result = detect_format(archive_path);
    if (!format_result.has_value()) {
        return format_result.error();
    }

    const ArchiveFormat format = format_result.value();
    if (format == ArchiveFormat::ZIP) {
        return zip_rename_entry(
            std::string(archive_path),
            normalized_old,
            normalized_new,
            cancelled,
            std::move(progress_callback));
    }

    if (format != ArchiveFormat::TAR && format != ArchiveFormat::TAR_GZ &&
        format != ArchiveFormat::TAR_BZ2 && format != ArchiveFormat::TAR_XZ &&
        format != ArchiveFormat::TAR_ZST && format != ArchiveFormat::TAR_LZ &&
        format != ArchiveFormat::TAR_LZ4 && format != ArchiveFormat::SevenZip) {
        return make_error(common::ErrorCode::NotSupported,
                          "Archive format is not supported for renaming entries",
                          std::string(archive_path));
    }

    return full_rebuild_archive(
        std::string(archive_path),
        format,
        [&](const stdfs::path& temp_dir) -> common::Result<void> {
            if (should_cancel(cancelled)) {
                return cancelled_error(std::string(archive_path));
            }

            const stdfs::path absolute_old = temp_dir / normalized_old;
            const stdfs::path absolute_new = temp_dir / normalized_new;

            std::error_code ec;
            if (!stdfs::exists(absolute_old, ec)) {
                return make_error(common::ErrorCode::NotFound,
                                  "Entry not found in archive",
                                  std::string(archive_path));
            }
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to inspect archive entry",
                                  absolute_old.string());
            }

            if (stdfs::exists(absolute_new, ec)) {
                return make_error(common::ErrorCode::AlreadyExists,
                                  "Destination entry already exists",
                                  absolute_new.string());
            }

            stdfs::create_directories(absolute_new.parent_path(), ec);
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to create destination directory",
                                  absolute_new.parent_path().string());
            }

            stdfs::rename(absolute_old, absolute_new, ec);
            if (ec) {
                return make_error(common::ErrorCode::IOError,
                                  "Failed to rename archive entry",
                                  absolute_old.string());
            }

            return {};
        },
        cancelled,
        std::move(progress_callback));
}

auto ArchiveOps::detect_format(std::string_view path) -> common::Result<ArchiveFormat> {
    ensure_utf8_ctype();
    if (path.empty()) {
        return make_error(common::ErrorCode::InvalidArgument,
                          "Archive path cannot be empty");
    }

    const stdfs::path archive_path(path);
    std::error_code ec;
    if (!stdfs::exists(archive_path, ec)) {
        return make_error(common::ErrorCode::NotFound,
                          "Archive does not exist",
                          archive_path.string());
    }
    if (ec) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to access archive path",
                          archive_path.string());
    }

    std::ifstream input(archive_path, std::ios::binary);
    if (!input.is_open()) {
        return make_error(common::ErrorCode::IOError,
                          "Failed to open archive",
                          archive_path.string());
    }

    std::array<unsigned char, 512> header{};
    input.read(reinterpret_cast<char*>(header.data()), static_cast<std::streamsize>(header.size()));
    const std::streamsize read_bytes = input.gcount();
    if (read_bytes <= 0) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Unknown or corrupted archive format",
                          archive_path.string());
    }

    auto detected = detect_magic_format(header, static_cast<std::size_t>(read_bytes));
    if (!detected.has_value()) {
        // ISO9660's "CD001" sits at byte 32769 — past this header. Cheap to check, and only
        // reached when nothing else matched.
        std::ifstream iso_probe(archive_path, std::ios::binary);
        std::array<char, 5> iso_sig{};
        iso_probe.seekg(32769, std::ios::beg);
        iso_probe.read(iso_sig.data(), static_cast<std::streamsize>(iso_sig.size()));
        if (iso_probe.gcount() == static_cast<std::streamsize>(iso_sig.size()) &&
            iso_sig[0] == 'C' && iso_sig[1] == 'D' && iso_sig[2] == '0' &&
            iso_sig[3] == '0' && iso_sig[4] == '1') {
            detected = ArchiveFormat::ISO;
        }
    }
    if (!detected.has_value()) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Unknown or corrupted archive format",
                          archive_path.string());
    }

    const auto hint = format_hint_from_extension(archive_path.string());
    if (hint.has_value() && hint.value() != detected.value()) {
        return make_error(common::ErrorCode::ArchiveError,
                          "Unknown or corrupted archive format",
                          archive_path.string());
    }

    return detected.value();
}

void ArchiveOps::cancel_current_operation() {
    g_archive_ops_cancelled.store(true, std::memory_order_relaxed);
}

void ArchiveOps::reset_cancelled() {
    g_archive_ops_cancelled.store(false, std::memory_order_relaxed);
}

}  // namespace fcxl::archive
