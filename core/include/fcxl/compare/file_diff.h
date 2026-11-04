#pragma once
/// @file file_diff.h
#include <string>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
namespace fcxl::compare {
enum class DiffType { Equal, Added, Removed, Modified };
struct DiffLine { uint64_t line_left = 0; uint64_t line_right = 0; DiffType type; std::string content; };
class FileDiff {
public:
    [[nodiscard]] auto compare(std::string_view file_a, std::string_view file_b) -> common::Result<std::vector<DiffLine>>;
    [[nodiscard]] auto are_identical(std::string_view file_a, std::string_view file_b) -> common::Result<bool>;
};
} // namespace fcxl::compare
