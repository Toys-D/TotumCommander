#pragma once
/// @file archive_reader.h
#include <atomic>
#include <cstddef>
#include <ctime>
#include <functional>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
#include "fcxl/archive/archive_types.h"
namespace fcxl::archive {
class ArchiveReader {
public:
    using ExtractProgressCallback =
        std::function<void(const std::string& current_file,
                           uint64_t bytes_done,
                           uint64_t bytes_total,
                           int files_done,
                           int files_total)>;

    [[nodiscard]] auto open(std::string_view path, std::string_view password = "") -> common::Result<void>;
    [[nodiscard]] auto list_entries(std::atomic<bool>* cancelled = nullptr) const -> common::Result<std::vector<ArchiveEntry>>;
    [[nodiscard]] auto get_info() const -> common::Result<ArchiveInfo>;
    [[nodiscard]] auto extract_all(std::string_view dest_path,
                                   std::atomic<bool>* cancelled = nullptr) const -> common::Result<void>;
    [[nodiscard]] auto extract_all(std::string_view dest_path,
                                   std::atomic<bool>* cancelled,
                                   ExtractProgressCallback progress_callback) const -> common::Result<void>;
    [[nodiscard]] auto extract_all(std::string_view dest_path,
                                   std::atomic<bool>* cancelled,
                                   bool overwrite_existing,
                                   ExtractProgressCallback progress_callback) const -> common::Result<void>;
    [[nodiscard]] auto extract_entry(std::string_view entry_path, std::string_view dest_path) -> common::Result<void>;
    static void cancel_current_operation();
    static void reset_cancelled();
    [[nodiscard]] static auto debug_data_skip_call_count() -> size_t;
    static void debug_reset_data_skip_call_count();
    void close();

    /// Drops the process-wide cached entry listing. Callers that MUTATE an archive must call
    /// this: the cache is keyed by path+mtime, and mtime has one-second resolution, so a fast
    /// add leaves the cache looking valid and the archive keeps listing its old contents.
    static void invalidate_cached_listing();

private:
    void invalidate_entries_cache() const;

    mutable std::mutex entries_cache_mutex_;
    mutable std::string cached_archive_path_;
    mutable std::vector<ArchiveEntry> cached_entries_;
    mutable std::time_t cached_mtime_ = 0;
    mutable bool has_cached_entries_ = false;
};
} // namespace fcxl::archive
