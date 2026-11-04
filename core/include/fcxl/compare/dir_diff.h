#pragma once
/// @file dir_diff.h
#include <filesystem>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
namespace fcxl::compare {
enum class DirEntryStatus { Same, Different, LeftOnly, RightOnly };
struct DirDiffEntry { std::filesystem::path relative_path; DirEntryStatus status; bool is_directory = false; };
class DirDiff {
public:
    [[nodiscard]] auto compare(std::string_view dir_a, std::string_view dir_b, bool by_content = false) -> common::Result<std::vector<DirDiffEntry>>;
};
} // namespace fcxl::compare
