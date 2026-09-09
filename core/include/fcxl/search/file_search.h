#pragma once
/// @file file_search.h
#include <functional>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
#include "fcxl/common/types.h"
namespace fcxl::search {
using SearchResultCallback = std::function<void(const common::FileEntry&)>;
/// Called with each directory as the search enters it — drives a "scanning …" status line.
/// Invoked on the search thread; the callee is responsible for throttling / thread-hopping.
using ScanProgressCallback = std::function<void(std::string_view current_dir)>;
class FileSearch {
public:
    [[nodiscard]] auto search(std::string_view root_path, const common::SearchFilter& filter, SearchResultCallback on_found = nullptr, ScanProgressCallback on_scan_dir = nullptr) -> common::Result<std::vector<common::FileEntry>>;
    void cancel();
    [[nodiscard]] auto is_searching() const -> bool;
private:
    bool cancelled_ = false;
};
} // namespace fcxl::search
