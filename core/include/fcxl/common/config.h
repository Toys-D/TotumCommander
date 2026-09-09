#pragma once
/// @file config.h
/// @brief Application configuration management
#include <filesystem>
#include <string>
#include <string_view>
#include <unordered_map>
namespace fcxl::common {
class Config {
public:
    Config();
    ~Config();
    [[nodiscard]] auto load(const std::filesystem::path& path) -> bool;
    [[nodiscard]] auto save(const std::filesystem::path& path) const -> bool;
    [[nodiscard]] auto get_string(std::string_view key, std::string_view default_value = "") const -> std::string;
    [[nodiscard]] auto get_int(std::string_view key, int default_value = 0) const -> int;
    [[nodiscard]] auto get_bool(std::string_view key, bool default_value = false) const -> bool;
    void set_string(std::string_view key, std::string_view value);
    void set_int(std::string_view key, int value);
    void set_bool(std::string_view key, bool value);
private:
    std::unordered_map<std::string, std::string> data_;
};
} // namespace fcxl::common
