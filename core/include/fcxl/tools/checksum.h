#pragma once
/// @file checksum.h
#include <string>
#include <string_view>
#include "fcxl/common/error.h"
#include "fcxl/common/types.h"
namespace fcxl::tools {
class Checksum {
public:
    [[nodiscard]] auto md5(std::string_view path) const -> common::Result<std::string>;
    [[nodiscard]] auto sha1(std::string_view path) const -> common::Result<std::string>;
    [[nodiscard]] auto sha256(std::string_view path) const -> common::Result<std::string>;
    [[nodiscard]] auto compute_all(std::string_view path) const -> common::Result<common::ChecksumResult>;
    [[nodiscard]] auto verify(std::string_view path, std::string_view expected_hash) const -> common::Result<bool>;
};
} // namespace fcxl::tools
