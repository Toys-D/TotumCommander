#include "fcxl/search/exclusions.h"

#include <fnmatch.h>

#include <algorithm>
#include <cctype>

namespace fcxl::search {
namespace {

auto trim(std::string_view text) -> std::string_view {
    const auto not_space = [](unsigned char c) { return std::isspace(c) == 0; };
    while (!text.empty() && !not_space(static_cast<unsigned char>(text.front()))) {
        text.remove_prefix(1);
    }
    while (!text.empty() && !not_space(static_cast<unsigned char>(text.back()))) {
        text.remove_suffix(1);
    }
    return text;
}

}  // namespace

auto parse_exclusions(std::string_view spec) -> std::vector<std::string> {
    std::vector<std::string> patterns;
    std::size_t start = 0;
    while (start <= spec.size()) {
        // Both separators are accepted: a semicolon is what Total Commander users type, a
        // comma is what everyone else reaches for first.
        const std::size_t hit = spec.find_first_of(";,", start);
        const std::size_t end = hit == std::string_view::npos ? spec.size() : hit;
        const std::string_view piece = trim(spec.substr(start, end - start));
        if (!piece.empty()) {
            patterns.emplace_back(piece);
        }
        if (hit == std::string_view::npos) {
            break;
        }
        start = hit + 1;
    }
    return patterns;
}

auto is_excluded(std::string_view name, const std::vector<std::string>& patterns) -> bool {
    if (patterns.empty()) {
        return false;
    }
    const std::string subject(name);
    return std::any_of(patterns.begin(), patterns.end(), [&subject](const std::string& pattern) {
        return ::fnmatch(pattern.c_str(), subject.c_str(), FNM_CASEFOLD) == 0;
    });
}

}  // namespace fcxl::search
