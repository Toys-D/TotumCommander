#include "fcxl/common/config.h"

namespace fcxl::common {

Config::Config() = default;
Config::~Config() = default;

auto Config::load(const std::filesystem::path& /*path*/) -> bool { return false; /* TODO: JSON */ }
auto Config::save(const std::filesystem::path& /*path*/) const -> bool { return false; /* TODO: JSON */ }

auto Config::get_string(std::string_view key, std::string_view default_value) const -> std::string {
    auto it = data_.find(std::string(key));
    return it != data_.end() ? it->second : std::string(default_value);
}

auto Config::get_int(std::string_view key, int default_value) const -> int {
    auto it = data_.find(std::string(key));
    if (it == data_.end()) return default_value;
    try { return std::stoi(it->second); } catch (...) { return default_value; }
}

auto Config::get_bool(std::string_view key, bool default_value) const -> bool {
    auto it = data_.find(std::string(key));
    if (it == data_.end()) return default_value;
    return it->second == "true" || it->second == "1";
}

void Config::set_string(std::string_view key, std::string_view value) { data_[std::string(key)] = std::string(value); }
void Config::set_int(std::string_view key, int value) { data_[std::string(key)] = std::to_string(value); }
void Config::set_bool(std::string_view key, bool value) { data_[std::string(key)] = value ? "true" : "false"; }

} // namespace fcxl::common
