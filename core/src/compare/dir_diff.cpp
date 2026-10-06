#include "fcxl/compare/dir_diff.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "fcxl/compare/file_diff.h"
#include "fcxl/search/name_match.h"

namespace fcxl::compare {
namespace {

// Относительные пути дерева — по составленной (NFC) форме имени. macOS хранит имя в той форме,
// в какой его записали: Finder и всё, что пишет через Cocoa, — разложенной («ё» = «е» + U+0308),
// терминал и другие системы — составленной. Имя на экране одно, байты разные, и при побайтовом
// сравнении один и тот же файл выходил «только слева» плюс «только справа». Значение — путь, как
// он записан на этой стороне: по нему и открывается файл.
using PathsByName = std::map<std::string, std::filesystem::path>;

auto collect_relative_paths(const std::filesystem::path& root) -> common::Result<PathsByName> {
    PathsByName paths;
    std::error_code ec;

    for (auto it = std::filesystem::recursive_directory_iterator(root, ec);
         it != std::filesystem::recursive_directory_iterator(); it.increment(ec)) {
        if (ec) {
            return common::Error::make(common::ErrorCode::IOError,
                                       "Directory traversal error: " + ec.message(),
                                       root.string());
        }
        auto relative = std::filesystem::relative(it->path(), root);
        // Два имени одной формы рядом (бывает только не на APFS) — остаются оба, второе под
        // своими байтами.
        if (!paths.emplace(search::to_composed_form(relative.string()), relative).second) {
            paths.emplace(relative.string(), relative);
        }
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

    // Merge all unique names
    std::set<std::string> all_names;
    for (const auto& [name, _] : paths_a) all_names.insert(name);
    for (const auto& [name, _] : paths_b) all_names.insert(name);

    std::vector<DirDiffEntry> result;
    result.reserve(all_names.size());

    for (const auto& name : all_names) {
        const auto found_a = paths_a.find(name);
        const auto found_b = paths_b.find(name);
        const bool in_a = found_a != paths_a.end();
        const bool in_b = found_b != paths_b.end();

        DirDiffEntry entry;
        // Написание левой стороны: APFS находит файл по любой форме имени, так что этим путём
        // открывается и правый.
        entry.relative_path = in_a ? found_a->second : found_b->second;

        if (in_a && !in_b) {
            entry.status = DirEntryStatus::LeftOnly;
            entry.is_directory = std::filesystem::is_directory(root_a / found_a->second, ec);
        } else if (!in_a && in_b) {
            entry.status = DirEntryStatus::RightOnly;
            entry.is_directory = std::filesystem::is_directory(root_b / found_b->second, ec);
        } else {
            // Both exist — each side opened by its own spelling
            const auto full_a = root_a / found_a->second;
            const auto full_b = root_b / found_b->second;
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
