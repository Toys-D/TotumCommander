#include "fcxl/compare/dir_diff.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <set>
#include <string>
#include <vector>

#include "fcxl/compare/file_diff.h"

namespace fcxl::compare {
namespace {

auto collect_relative_paths(const std::filesystem::path& root)
    -> common::Result<std::set<std::filesystem::path>> {
    std::set<std::filesystem::path> paths;
    std::error_code ec;

    for (auto it = std::filesystem::recursive_directory_iterator(root, ec);
         it != std::filesystem::recursive_directory_iterator(); it.increment(ec)) {
        if (ec) {
            return common::Error::make(common::ErrorCode::IOError,
                                       "Directory traversal error: " + ec.message(),
                                       root.string());
        }
        paths.insert(std::filesystem::relative(it->path(), root));
    }

    return paths;
}

auto files_are_same_size(const std::filesystem::path& a, const std::filesystem::path& b) -> bool {
    std::error_code ec;
    const auto size_a = std::filesystem::file_size(a, ec);
    if (ec) return false;
    const auto size_b = std::filesystem::file_size(b, ec);
    if (ec) return false;
    return size_a == size_b;
}

auto files_have_same_content(const std::filesystem::path& a,
                             const std::filesystem::path& b) -> bool {
    FileDiff diff;
    auto result = diff.are_identical(a.string(), b.string());
    return result.has_value() && result.value();
}

}  // namespace

auto DirDiff::compare(std::string_view dir_a, std::string_view dir_b, bool by_content)
    -> common::Result<std::vector<DirDiffEntry>> {
    const std::filesystem::path root_a(dir_a);
    const std::filesystem::path root_b(dir_b);

    std::error_code ec;
    if (!std::filesystem::is_directory(root_a, ec)) {
        return common::Error::make(common::ErrorCode::NotADirectory,
                                   "Not a directory", root_a.string());
    }
    if (!std::filesystem::is_directory(root_b, ec)) {
        return common::Error::make(common::ErrorCode::NotADirectory,
                                   "Not a directory", root_b.string());
    }

    auto paths_a_result = collect_relative_paths(root_a);
    if (!paths_a_result.has_value()) return paths_a_result.error();

    auto paths_b_result = collect_relative_paths(root_b);
    if (!paths_b_result.has_value()) return paths_b_result.error();

    const auto& paths_a = paths_a_result.value();
    const auto& paths_b = paths_b_result.value();

    // Merge all unique relative paths
    std::set<std::filesystem::path> all_paths;
    all_paths.insert(paths_a.begin(), paths_a.end());
    all_paths.insert(paths_b.begin(), paths_b.end());

    std::vector<DirDiffEntry> result;
    result.reserve(all_paths.size());

    for (const auto& rel : all_paths) {
        const bool in_a = paths_a.count(rel) > 0;
        const bool in_b = paths_b.count(rel) > 0;

        DirDiffEntry entry;
        entry.relative_path = rel;

        if (in_a && !in_b) {
            entry.status = DirEntryStatus::LeftOnly;
            entry.is_directory = std::filesystem::is_directory(root_a / rel, ec);
        } else if (!in_a && in_b) {
            entry.status = DirEntryStatus::RightOnly;
            entry.is_directory = std::filesystem::is_directory(root_b / rel, ec);
        } else {
            // Both exist
            const auto full_a = root_a / rel;
            const auto full_b = root_b / rel;
            entry.is_directory = std::filesystem::is_directory(full_a, ec);

            if (entry.is_directory) {
                entry.status = DirEntryStatus::Same;
            } else if (by_content) {
                entry.status = files_have_same_content(full_a, full_b)
                                   ? DirEntryStatus::Same
                                   : DirEntryStatus::Different;
            } else {
                entry.status = files_are_same_size(full_a, full_b)
                                   ? DirEntryStatus::Same
                                   : DirEntryStatus::Different;
            }
        }

        result.push_back(std::move(entry));
    }

    // Sort: directories first, then by path
    std::sort(result.begin(), result.end(), [](const DirDiffEntry& a, const DirDiffEntry& b) {
        if (a.is_directory != b.is_directory) return a.is_directory;
        return a.relative_path < b.relative_path;
    });

    return result;
}

}  // namespace fcxl::compare
