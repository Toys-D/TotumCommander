#pragma once
/// @file file_splitter.h
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
namespace fcxl::tools {

/// Called with (bytes done, bytes total) while a split or join runs.
/// Returning true asks to stop: the partial output is removed and Cancelled is returned.
using ProgressFn = std::function<bool(uint64_t, uint64_t)>;

class FileSplitter {
public:
    [[nodiscard]] auto split(std::string_view path, uint64_t chunk_size, std::string_view output_dir,
                             const ProgressFn& progress = nullptr) -> common::Result<std::vector<std::string>>;
    [[nodiscard]] auto join(const std::vector<std::string>& parts, std::string_view output_path,
                            const ProgressFn& progress = nullptr) -> common::Result<void>;
};
} // namespace fcxl::tools
