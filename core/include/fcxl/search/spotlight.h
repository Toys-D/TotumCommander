#pragma once
/// @file spotlight.h
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
#include "fcxl/common/types.h"
namespace fcxl::search {
class Spotlight {
public:
    [[nodiscard]] auto search(std::string_view query, std::string_view scope_path = "") -> common::Result<std::vector<common::FileEntry>>;
};
} // namespace fcxl::search
