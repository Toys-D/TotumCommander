#pragma once
/// @file sync.h
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
#include "fcxl/compare/dir_diff.h"
namespace fcxl::compare {
enum class SyncDirection { LeftToRight, RightToLeft, Both };
class Sync {
public:
    [[nodiscard]] auto synchronize(std::string_view dir_a, std::string_view dir_b, SyncDirection direction = SyncDirection::Both) -> common::Result<void>;
    [[nodiscard]] auto preview(std::string_view dir_a, std::string_view dir_b, SyncDirection direction = SyncDirection::Both) -> common::Result<std::vector<DirDiffEntry>>;
};
} // namespace fcxl::compare
