#pragma once
/// @file pty_handler.h
#include <functional>
#include <memory>
#include <string_view>
#include "fcxl/common/error.h"
namespace fcxl::terminal {
using OutputCallback = std::function<void(std::string_view)>;
class PtyHandler {
public:
    PtyHandler();
    ~PtyHandler();
    [[nodiscard]] auto start(std::string_view shell = "/bin/zsh") -> common::Result<void>;
    void stop();
    [[nodiscard]] auto write(std::string_view input) -> common::Result<void>;
    void set_output_callback(OutputCallback callback);
    [[nodiscard]] auto resize(uint16_t cols, uint16_t rows) -> common::Result<void>;
    [[nodiscard]] auto is_running() const -> bool;
    [[nodiscard]] auto change_directory(std::string_view path) -> common::Result<void>;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace fcxl::terminal
