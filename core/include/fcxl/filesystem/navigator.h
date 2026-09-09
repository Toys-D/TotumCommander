#pragma once
/// @file navigator.h
/// @brief Directory navigation and listing
#include <filesystem>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
#include "fcxl/common/types.h"
namespace fcxl::fs {
class Navigator {
public:
    Navigator();
    ~Navigator();
    Navigator(const Navigator&) = delete;
    Navigator& operator=(const Navigator&) = delete;
    Navigator(Navigator&&) noexcept = default;
    Navigator& operator=(Navigator&&) noexcept = default;

    [[nodiscard]] auto list_directory(std::string_view path, bool show_hidden = false) const -> common::Result<std::vector<common::FileEntry>>;
    /// @brief Fast macOS directory listing via bulk attributes syscall.
    /// @param path Directory path in UTF-8.
    /// @param show_hidden Include hidden entries (names starting with '.').
    /// @return File entries or error.
    [[nodiscard]] auto list_directory_fast(std::string_view path, bool show_hidden = false) const -> common::Result<std::vector<common::FileEntry>>;
    /// @brief Ultra-fast listing via readdir() only — no stat() calls.
    /// Returns names, paths, types (from d_type), hidden flags.
    /// Size/dates/permissions/owner are empty. For instant display on slow volumes.
    [[nodiscard]] auto list_directory_names_only(std::string_view path, bool show_hidden = false) const -> common::Result<std::vector<common::FileEntry>>;
    void sort_entries(std::vector<common::FileEntry>& entries, common::SortField field = common::SortField::Name, common::SortDirection direction = common::SortDirection::Ascending) const;
    [[nodiscard]] auto filter_entries(const std::vector<common::FileEntry>& entries, std::string_view pattern) const -> std::vector<common::FileEntry>;
    [[nodiscard]] auto parent_path(std::string_view path) const -> common::Result<std::filesystem::path>;
    [[nodiscard]] static auto home_path() -> std::filesystem::path;
    [[nodiscard]] static auto root_path() -> std::filesystem::path;
    [[nodiscard]] auto is_valid_directory(std::string_view path) const -> bool;
    [[nodiscard]] auto calculate_total_size(const std::vector<common::FileEntry>& entries) const -> uint64_t;
};
} // namespace fcxl::fs
