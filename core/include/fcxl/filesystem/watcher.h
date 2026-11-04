#pragma once
/// @file watcher.h
/// @brief FSEvents wrapper for monitoring file system changes
#include <filesystem>
#include <functional>
#include <memory>
#include <string_view>
#include "fcxl/common/error.h"
namespace fcxl::fs {
enum class WatchEvent { Created, Modified, Deleted, Renamed };
using WatchCallback = std::function<void(const std::filesystem::path&, WatchEvent)>;
class Watcher {
public:
    Watcher();
    ~Watcher();
    [[nodiscard]] auto watch(std::string_view path, WatchCallback callback) -> common::Result<void>;
    void stop();
    [[nodiscard]] auto is_watching() const -> bool;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace fcxl::fs
