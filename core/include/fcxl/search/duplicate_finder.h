#pragma once
/// @file duplicate_finder.h
#include <functional>
#include <string>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
#include "fcxl/common/types.h"
#include "fcxl/search/exclusions.h"
namespace fcxl::search {
enum class DuplicateStrategy { ByName, BySize, ByHash };
using DuplicateCallback = std::function<void(const common::DuplicateGroup&)>;
/// Called with each directory as the scan enters it — drives the "scanning …" status line,
/// the same one the name and content searches feed.
using ScanProgressCallback = std::function<void(std::string_view current_dir)>;
/// What a duplicates run may be told.
struct DuplicateOptions {
    DuplicateStrategy strategy = DuplicateStrategy::ByHash;
    bool recursive = true;
    /// Dot-names and entries carrying the macOS hidden flag; a hidden directory is not entered.
    /// Off by default — a repository's ".git" is full of identical objects nobody asked about.
    bool include_hidden = false;
    std::vector<std::string> exclude_patterns;
    /// Size and change-date limits; a file outside them is not compared.
    FileLimits limits;
};

/// Finding files that are copies of one another.
///
/// Only real, separate files are compared. A symbolic link is a pointer to a file, not a copy
/// of it, and two hard links are one file under two names: deleting either "duplicate" would
/// free nothing, and in the first case could take the original with it. Of several names of
/// one file, the first in path order stands for all of them.
///
/// The answer comes in a fixed order: the group that wastes the most space first (size times
/// the number of spare copies), then the one with more copies, then by path; inside a group
/// the copies go in path order.
class DuplicateFinder {
public:
    [[nodiscard]] auto find(std::string_view root_path, const DuplicateOptions& options, DuplicateCallback on_found = nullptr, ScanProgressCallback on_scan_dir = nullptr) -> common::Result<std::vector<common::DuplicateGroup>>;
    /// The older, positional form: hidden places are left out.
    [[nodiscard]] auto find(std::string_view root_path, DuplicateStrategy strategy = DuplicateStrategy::ByHash, bool recursive = true, const std::vector<std::string>& exclude_patterns = {}, DuplicateCallback on_found = nullptr, ScanProgressCallback on_scan_dir = nullptr) -> common::Result<std::vector<common::DuplicateGroup>>;
    void cancel();
private:
    bool cancelled_ = false;
};
} // namespace fcxl::search
