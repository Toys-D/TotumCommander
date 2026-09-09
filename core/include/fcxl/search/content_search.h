#pragma once
/// @file content_search.h
#include <filesystem>
#include <functional>
#include <string>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
namespace fcxl::search {
struct ContentMatch {
    std::filesystem::path file;
    uint64_t line_number = 0;
    std::string line_content;
    uint64_t column = 0;
};
using ContentResultCallback = std::function<void(const ContentMatch&)>;
/// Called with each directory as the search enters it — drives a "scanning …" status line.
/// Invoked on the search thread; the callee is responsible for throttling / thread-hopping.
using ScanProgressCallback = std::function<void(std::string_view current_dir)>;
class ContentSearch {
public:
    [[nodiscard]] auto search(std::string_view root_path, std::string_view pattern, bool use_regex = false, bool recursive = true, const std::vector<std::string>& exclude_patterns = {}, ContentResultCallback on_found = nullptr, ScanProgressCallback on_scan_dir = nullptr) -> common::Result<std::vector<ContentMatch>>;
    void cancel();
private:
    bool cancelled_ = false;
};
} // namespace fcxl::search
