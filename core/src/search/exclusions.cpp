#include "fcxl/search/exclusions.h"

#include <fnmatch.h>
#include <sys/stat.h>

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


auto is_hidden_name(std::string_view name) -> bool {
    return !name.empty() && name.front() == '.';
}

auto has_hidden_flag(const std::filesystem::path& path) -> bool {
    // lstat, not stat: a link is hidden or not by its own flag, not by its target's.
    struct stat info {};
    return ::lstat(path.c_str(), &info) == 0 && (info.st_flags & UF_HIDDEN) != 0;
}

auto is_hidden_entry(const std::filesystem::path& path) -> bool {
    return is_hidden_name(path.filename().string()) || has_hidden_flag(path);
}

auto FileLimits::is_unlimited() const -> bool {
    const std::chrono::system_clock::time_point none{};
    return min_size == 0 && max_size == UINT64_MAX && date_from == none && date_to == none;
}

auto FileLimits::allows(uint64_t size, std::chrono::system_clock::time_point modified) const
    -> bool {
    const std::chrono::system_clock::time_point none{};
    if (size < min_size || size > max_size) {
        return false;
    }
    if (date_from != none && modified < date_from) {
        return false;
    }
    return date_to == none || modified <= date_to;
}

auto FileLimits::allows(const std::filesystem::path& path) const -> bool {
    if (is_unlimited()) {
        return true;
    }
    // stat, not lstat: the limits are about the file that will be read.
    struct stat info {};
    if (::stat(path.c_str(), &info) != 0) {
        return false;
    }
    const auto modified = std::chrono::system_clock::from_time_t(info.st_mtimespec.tv_sec);
    return allows(static_cast<uint64_t>(info.st_size), modified);
}

}  // namespace fcxl::search
