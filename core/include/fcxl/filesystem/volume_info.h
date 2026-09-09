#pragma once
/// @file volume_info.h
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
#include "fcxl/common/types.h"
namespace fcxl::fs {
class VolumeInfoProvider {
public:
    [[nodiscard]] auto get_volumes() const -> common::Result<std::vector<common::VolumeInfo>>;
    [[nodiscard]] auto get_volume_for_path(std::string_view path) const -> common::Result<common::VolumeInfo>;
};
} // namespace fcxl::fs
