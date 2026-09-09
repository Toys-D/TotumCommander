#pragma once
/// @file image_info.h
#include <string>
#include <string_view>
#include "fcxl/common/error.h"
namespace fcxl::viewer {
struct ImageMetadata { uint32_t width = 0; uint32_t height = 0; std::string format; std::string color_space; uint32_t dpi = 0; uint64_t file_size = 0; };
class ImageInfo {
public:
    [[nodiscard]] auto get_metadata(std::string_view path) const -> common::Result<ImageMetadata>;
};
} // namespace fcxl::viewer
