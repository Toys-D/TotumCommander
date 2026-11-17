#pragma once
/// @file exclusions.h
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>
namespace fcxl::search {
/// Names the walk must not enter or report — "node_modules;.cache;*.tmp" as the user types it.
///
/// A search of a home folder otherwise spends most of its life inside build caches and package
/// directories, and drowns the answer in them: a duplicates run over $HOME returned 662 821
/// files, nearly all of them inside node_modules. Matching a DIRECTORY here also stops the
/// descent, which is where the time is saved — filtering the results afterwards would still
/// have read every one of those directories.
[[nodiscard]] auto parse_exclusions(std::string_view spec) -> std::vector<std::string>;
/// Case-insensitive fnmatch against every pattern; a pattern without a wildcard must match the
/// whole name, so "build" never swallows "rebuild.log".
[[nodiscard]] auto is_excluded(std::string_view name, const std::vector<std::string>& patterns) -> bool;

/// A name that starts with a dot.
[[nodiscard]] auto is_hidden_name(std::string_view name) -> bool;

/// Hidden the way the panels mean it: a dot-name, or the macOS "hidden" flag (UF_HIDDEN) — the
/// thing that keeps ~/Library out of Finder. Every search asks this one question, so that
/// "hidden files: off" leaves out the same things whichever mode is doing the walking — and a
/// hidden DIRECTORY is left out with everything under it.
[[nodiscard]] auto is_hidden_entry(const std::filesystem::path& path) -> bool;

/// Only the flag — for a caller that has already looked at the name.
[[nodiscard]] auto has_hidden_flag(const std::filesystem::path& path) -> bool;

/// Size and change-date limits a walk may be given. The default lets every file through.
///
/// The name search has always had these; the content search and the duplicates run take the
/// same ones, so that "bigger than 10 MB, changed this week" means one thing in every mode.
struct FileLimits {
    uint64_t min_size = 0;
    uint64_t max_size = UINT64_MAX;
    /// The epoch itself means "no limit" on that side.
    std::chrono::system_clock::time_point date_from;
    std::chrono::system_clock::time_point date_to;

    [[nodiscard]] auto is_unlimited() const -> bool;
    [[nodiscard]] auto allows(uint64_t size, std::chrono::system_clock::time_point modified) const
        -> bool;
    /// The same question about a file on disk; a file that cannot be looked at is not let in.
    [[nodiscard]] auto allows(const std::filesystem::path& path) const -> bool;
};

} // namespace fcxl::search
