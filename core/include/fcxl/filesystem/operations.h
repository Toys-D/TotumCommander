#pragma once
/// @file operations.h
/// @brief File operations: copy, move, delete, rename
#include <filesystem>
#include <functional>
#include <string_view>
#include "fcxl/common/error.h"
#include "fcxl/common/types.h"
namespace fcxl::fs {
using ProgressCallback = std::function<bool(const common::OperationProgress&)>;
class Operations {
public:
    Operations();
    ~Operations();
    [[nodiscard]] auto copy(std::string_view source, std::string_view destination, common::ConflictResolution on_conflict = common::ConflictResolution::Ask, ProgressCallback progress_cb = nullptr) -> common::Result<void>;
    [[nodiscard]] auto move(std::string_view source, std::string_view destination, common::ConflictResolution on_conflict = common::ConflictResolution::Ask, ProgressCallback progress_cb = nullptr) -> common::Result<void>;
    [[nodiscard]] auto trash(std::string_view path) -> common::Result<void>;
    [[nodiscard]] auto remove(std::string_view path, bool recursive = false, ProgressCallback progress_cb = nullptr) -> common::Result<void>;
    [[nodiscard]] auto rename(std::string_view path, std::string_view new_name) -> common::Result<void>;
    [[nodiscard]] auto create_directory(std::string_view path) -> common::Result<void>;
    [[nodiscard]] auto create_directories(std::string_view path) -> common::Result<void>;
};
} // namespace fcxl::fs
