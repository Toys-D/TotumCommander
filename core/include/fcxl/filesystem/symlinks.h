#pragma once
/// @file symlinks.h
#include <filesystem>
#include <string_view>
#include "fcxl/common/error.h"
namespace fcxl::fs {
class Symlinks {
public:
    [[nodiscard]] auto create_symlink(std::string_view target, std::string_view link_path) -> common::Result<void>;
    [[nodiscard]] auto create_hardlink(std::string_view target, std::string_view link_path) -> common::Result<void>;
    [[nodiscard]] auto create_alias(std::string_view target, std::string_view alias_path) -> common::Result<void>;
    [[nodiscard]] auto read_symlink(std::string_view link_path) const -> common::Result<std::filesystem::path>;
    [[nodiscard]] auto is_symlink(std::string_view path) const -> bool;
    [[nodiscard]] auto is_alias(std::string_view path) const -> bool;
    [[nodiscard]] auto resolve_alias(std::string_view alias_path) const -> common::Result<std::filesystem::path>;
};
} // namespace fcxl::fs
