#pragma once
/// @file attributes.h
/// @brief File permissions, ownership, extended attributes
#include <string>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
namespace fcxl::fs {
class Attributes {
public:
    [[nodiscard]] auto get_permissions(std::string_view path) const -> common::Result<std::string>;
    [[nodiscard]] auto set_permissions(std::string_view path, std::string_view mode) -> common::Result<void>;
    [[nodiscard]] auto get_owner(std::string_view path) const -> common::Result<std::string>;
    [[nodiscard]] auto set_owner(std::string_view path, std::string_view owner, std::string_view group) -> common::Result<void>;
    [[nodiscard]] auto get_xattr(std::string_view path, std::string_view name) const -> common::Result<std::string>;
    [[nodiscard]] auto set_xattr(std::string_view path, std::string_view name, std::string_view value) -> common::Result<void>;
    [[nodiscard]] auto remove_xattr(std::string_view path, std::string_view name) -> common::Result<void>;
    [[nodiscard]] auto list_xattrs(std::string_view path) const -> common::Result<std::vector<std::string>>;
};
} // namespace fcxl::fs
