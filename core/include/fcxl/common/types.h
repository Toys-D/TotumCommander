#pragma once

/// @file types.h
/// @brief Common types, enums, and structs used across the core engine

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace fcxl::common {

enum class SortField { Name, Extension, Size, DateModified, DateCreated, Permissions, Owner };
enum class SortDirection { Ascending, Descending };
enum class EntryType { File, Directory, Symlink, Other };
enum class ViewMode { Detailed, Brief, Icons, Thumbnails };
enum class OperationType { Copy, Move, Delete, Rename, Archive, Extract, Search };
enum class ConflictResolution { Overwrite, Skip, Rename, Ask };

struct FileEntry {
    std::filesystem::path path;
    std::string name;
    std::string extension;
    EntryType type = EntryType::File;
    uint64_t size = 0;
    std::chrono::system_clock::time_point date_modified;
    std::chrono::system_clock::time_point date_created;
    bool is_hidden = false;
    bool is_symlink = false;
    /// A Finder alias: a small file carrying a bookmark to another one. Read from the
    /// Finder info in the same bulk call, so it costs no extra syscall.
    bool is_alias = false;
    /// Direct children of a directory, excluding "." and ".."; -1 when nobody asked the
    /// filesystem. Zero means genuinely empty — the panel prints a size instead of <DIR>.
    /// Only the bulk listing fills it, where it costs no extra syscall.
    int64_t entry_count = -1;
    std::string permissions;
    std::string owner;
    std::string group;
};

struct OperationProgress {
    OperationType type;
    std::string source;
    std::string destination;
    uint64_t bytes_total = 0;
    uint64_t bytes_done = 0;
    uint64_t files_total = 0;
    uint64_t files_done = 0;
    bool is_paused = false;
    bool is_cancelled = false;
    [[nodiscard]] double percentage() const {
        if (bytes_total == 0) return 0.0;
        return static_cast<double>(bytes_done) / static_cast<double>(bytes_total) * 100.0;
    }
};

struct VolumeInfo {
    std::string name;
    std::filesystem::path mount_point;
    uint64_t total_bytes = 0;
    uint64_t free_bytes = 0;
    uint64_t available_bytes = 0;
    std::string filesystem_type;
    bool is_removable = false;
    bool is_readonly = false;
};

struct ChecksumResult {
    std::string md5;
    std::string sha1;
    std::string sha256;
};

enum class FileTypeFilter { All, FilesOnly, DirsOnly };

struct SearchFilter {
    std::string name_pattern;
    bool use_regex = false;
    std::string content_pattern;
    uint64_t min_size = 0;
    uint64_t max_size = UINT64_MAX;
    std::chrono::system_clock::time_point date_from;
    std::chrono::system_clock::time_point date_to;
    bool include_hidden = false;
    bool recursive = true;
    FileTypeFilter type_filter = FileTypeFilter::All;
    /// Folder and file names the walk must not enter or report; see search/exclusions.h.
    std::vector<std::string> exclude_patterns;
};

struct DuplicateGroup {
    uint64_t size = 0;
    std::string hash;
    std::vector<std::filesystem::path> files;
};

} // namespace fcxl::common
