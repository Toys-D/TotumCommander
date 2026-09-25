#pragma once
/// @file duplicate_finder.h
#include <functional>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
#include "fcxl/common/types.h"
namespace fcxl::search {
enum class DuplicateStrategy { ByName, BySize, ByHash };
using DuplicateCallback = std::function<void(const common::DuplicateGroup&)>;
/// Called with each directory as the scan enters it — drives the "scanning …" status line,
/// the same one the name and content searches feed.
using ScanProgressCallback = std::function<void(std::string_view current_dir)>;
class DuplicateFinder {
public:
    [[nodiscard]] auto find(std::string_view root_path, DuplicateStrategy strategy = DuplicateStrategy::ByHash, bool recursive = true, const std::vector<std::string>& exclude_patterns = {}, DuplicateCallback on_found = nullptr, ScanProgressCallback on_scan_dir = nullptr) -> common::Result<std::vector<common::DuplicateGroup>>;
    void cancel();
private:
    bool cancelled_ = false;
};
} // namespace fcxl::search
