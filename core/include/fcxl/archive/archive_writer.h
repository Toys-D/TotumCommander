#pragma once
/// @file archive_writer.h
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>
#include "fcxl/common/error.h"
#include "fcxl/archive/archive_types.h"
namespace fcxl::archive {
class ArchiveWriter {
public:
    using ArchiveProgressCallback =
        std::function<void(const std::string& current_file,
                           int64_t bytes_read,
                           int64_t bytes_total,
                           int files_done,
                           int files_total,
                           int64_t compressed_bytes)>;

    ~ArchiveWriter();
    [[nodiscard]] auto create(std::string_view path,
                              ArchiveFormat format,
                              std::string_view password = "",
                              int compression_level = -1,
                              bool preserve_paths = true,
                              ArchiveProgressCallback progress_callback = nullptr,
                              int64_t total_uncompressed_bytes = 0,
                              int total_files = 0) -> common::Result<void>;
    [[nodiscard]] auto add_file(std::string_view file_path, std::string_view archive_path = "") -> common::Result<void>;
    [[nodiscard]] auto add_directory(std::string_view dir_path, std::string_view archive_path = "") -> common::Result<void>;
    [[nodiscard]] auto finalize() -> common::Result<void>;
    static void cancel_current_operation();
    static void reset_cancelled();
};
} // namespace fcxl::archive
