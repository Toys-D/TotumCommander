#pragma once
/// @file hex_viewer.h
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
namespace fcxl::viewer {
struct HexLine { uint64_t offset = 0; std::vector<uint8_t> bytes; std::string ascii; };
class HexViewer {
public:
    [[nodiscard]] auto open(std::string_view path) -> common::Result<void>;
    [[nodiscard]] auto get_lines(uint64_t offset, uint64_t count, uint16_t bytes_per_line = 16) const -> common::Result<std::vector<HexLine>>;
    [[nodiscard]] auto file_size() const -> uint64_t;
    void close();
};
} // namespace fcxl::viewer
