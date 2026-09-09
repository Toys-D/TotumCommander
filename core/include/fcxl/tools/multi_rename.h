#pragma once
/// @file multi_rename.h
#include <string>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
namespace fcxl::tools {
struct RenameRule { std::string search_pattern; std::string replace_pattern; bool use_regex = false; bool change_case = false; std::string counter_format; };
struct RenamePreview { std::string original; std::string renamed; };
class MultiRename {
public:
    [[nodiscard]] auto preview(const std::vector<std::string>& files, const RenameRule& rule) -> std::vector<RenamePreview>;
    [[nodiscard]] auto execute(const std::vector<std::string>& files, const RenameRule& rule) -> common::Result<void>;
};
} // namespace fcxl::tools
