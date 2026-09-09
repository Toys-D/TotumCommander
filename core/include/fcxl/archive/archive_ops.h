#pragma once
/// @file archive_ops.h
#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
#include "fcxl/archive/archive_types.h"
namespace fcxl::archive {
class ArchiveOps {
public:
    using ArchiveProgressCallback =
        std::function<void(const std::string& current_file,
                           int64_t bytes_done,
                           int64_t bytes_total,
                           int files_done,
                           int files_total,
                           int64_t compressed_bytes)>;

    [[nodiscard]] auto test_integrity(std::string_view path) -> common::Result<bool>;
    [[nodiscard]] auto remove_entry(std::string_view archive_path, std::string_view entry_path) -> common::Result<void>;
    [[nodiscard]] auto add_files(std::string_view archive_path,
                                 const std::vector<std::string>& file_paths,
                                 std::string_view base_path,
                                 std::atomic<bool>* cancelled = nullptr,
                                 ArchiveProgressCallback progress_callback = nullptr) -> common::Result<void>;
    [[nodiscard]] auto delete_entries(std::string_view archive_path,
                                      const std::vector<std::string>& entry_paths,
                                      std::atomic<bool>* cancelled = nullptr,
                                      ArchiveProgressCallback progress_callback = nullptr) -> common::Result<void>;
    [[nodiscard]] auto rename_entry(std::string_view archive_path,
                                    std::string_view old_entry_path,
                                    std::string_view new_entry_path,
                                    std::atomic<bool>* cancelled = nullptr,
                                    ArchiveProgressCallback progress_callback = nullptr) -> common::Result<void>;
    [[nodiscard]] auto detect_format(std::string_view path) -> common::Result<ArchiveFormat>;
    static void cancel_current_operation();
    static void reset_cancelled();
};
} // namespace fcxl::archive
