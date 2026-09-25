#pragma once
/// @file exclusions.h
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
} // namespace fcxl::search
