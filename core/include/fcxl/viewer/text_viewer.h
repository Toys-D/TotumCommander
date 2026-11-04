#pragma once
/// @file text_viewer.h
#include <string>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
namespace fcxl::viewer {
class TextViewer {
public:
    [[nodiscard]] auto open(std::string_view path) -> common::Result<void>;
    [[nodiscard]] auto get_lines(uint64_t from, uint64_t count) const -> common::Result<std::vector<std::string>>;
    [[nodiscard]] auto total_lines() const -> uint64_t;
    [[nodiscard]] auto detected_encoding() const -> std::string;
    [[nodiscard]] auto detect_language() const -> std::string;
    void close();
};
} // namespace fcxl::viewer
