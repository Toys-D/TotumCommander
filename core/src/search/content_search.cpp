#include "fcxl/search/content_search.h"

#include "fcxl/search/exclusions.h"

#include <array>
#include <chrono>
#include <fstream>
#include <optional>
#include <regex>
#include <string>
#include <system_error>

namespace fcxl::search {
namespace {

auto map_error_code(const std::error_code& ec,
                    std::string message,
                    const std::filesystem::path& path = std::filesystem::path()) -> common::Error {
    if (!ec) {
        return common::Error::make(common::ErrorCode::Unknown, std::move(message), path.string());
    }

    common::ErrorCode code = common::ErrorCode::IOError;
    switch (static_cast<std::errc>(ec.value())) {
        case std::errc::no_such_file_or_directory:
            code = common::ErrorCode::NotFound;
            break;
        case std::errc::permission_denied:
            code = common::ErrorCode::PermissionDenied;
            break;
        case std::errc::file_exists:
            code = common::ErrorCode::AlreadyExists;
            break;
        case std::errc::not_a_directory:
            code = common::ErrorCode::NotADirectory;
            break;
        case std::errc::invalid_argument:
            code = common::ErrorCode::InvalidArgument;
            break;
        case std::errc::filename_too_long:
            code = common::ErrorCode::NameTooLong;
            break;
        default:
            code = common::ErrorCode::IOError;
            break;
    }

    return common::Error::make(code, std::move(message), path.string());
}

auto is_binary_file(const std::filesystem::path& path) -> bool {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs.is_open()) {
        return true;
    }

    std::array<char, 512> buffer{};
    ifs.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    const std::streamsize bytes_read = ifs.gcount();
    for (std::streamsize index = 0; index < bytes_read; ++index) {
        if (buffer[static_cast<std::size_t>(index)] == '\0') {
            return true;
        }
    }
    return false;
}

}  // namespace

auto ContentSearch::search(std::string_view root_path,
                           std::string_view pattern,
                           bool use_regex,
                           bool recursive,
                           const std::vector<std::string>& exclude_patterns,
                           ContentResultCallback on_found,
                           ScanProgressCallback on_scan_dir)
    -> common::Result<std::vector<ContentMatch>> {
    if (root_path.empty() || pattern.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Root path and pattern cannot be empty");
    }

    const std::filesystem::path root(root_path);
    std::error_code ec;
    const bool exists = std::filesystem::exists(root, ec);
    if (ec) {
        return map_error_code(ec, "Failed to check root path existence", root);
    }
    if (!exists) {
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Root path does not exist",
                                   root.string());
    }

    const bool is_directory = std::filesystem::is_directory(root, ec);
    if (ec) {
        return map_error_code(ec, "Failed to inspect root path type", root);
    }
    if (!is_directory) {
        return common::Error::make(common::ErrorCode::NotADirectory,
                                   "Root path is not a directory",
                                   root.string());
    }

    std::optional<std::regex> compiled_regex;
    if (use_regex) {
        try {
            compiled_regex.emplace(std::string(pattern), std::regex::ECMAScript);
        } catch (const std::regex_error&) {
            return common::Error::make(common::ErrorCode::InvalidArgument,
                                       "Invalid regex pattern",
                                       root.string());
        }
    }

    cancelled_ = false;
    std::vector<ContentMatch> results;

    std::filesystem::recursive_directory_iterator iterator(
        root, std::filesystem::directory_options::skip_permission_denied, ec);
    if (ec) {
        return map_error_code(ec, "Failed to iterate root path", root);
    }

    const std::filesystem::recursive_directory_iterator end;
    while (iterator != end) {
        if (cancelled_) {
            break;
        }

        const std::filesystem::directory_entry& dir_entry = *iterator;
        const std::filesystem::path entry_path = dir_entry.path();

        // Report the directory being entered for the "scanning …" status line.
        if (on_scan_dir) {
            std::error_code dir_ec;
            if (dir_entry.is_directory(dir_ec) && !dir_ec) {
                on_scan_dir(entry_path.string());
            }
        }

        if (!recursive && dir_entry.is_directory(ec) && !ec) {
            iterator.disable_recursion_pending();
        } else if (ec) {
            return map_error_code(ec, "Failed to inspect directory entry", entry_path);
        }

        // Excluded names are never opened, and excluded directories are never entered — the
        // same rule the name search follows, so both modes answer about the same tree.
        if (is_excluded(entry_path.filename().string(), exclude_patterns)) {
            std::error_code dir_ec;
            if (dir_entry.is_directory(dir_ec) && !dir_ec) {
                iterator.disable_recursion_pending();
            }
            iterator.increment(ec);
            if (ec) { ec.clear(); }
            continue;
        }

        const bool regular_file = dir_entry.is_regular_file(ec);
        if (ec) {
            return map_error_code(ec, "Failed to inspect file type", entry_path);
        }

        if (!regular_file || is_binary_file(entry_path)) {
            iterator.increment(ec);
            if (ec) {
                return map_error_code(ec, "Failed to advance search iterator", root);
            }
            continue;
        }

        std::ifstream ifs(entry_path);
        if (!ifs.is_open()) {
            iterator.increment(ec);
            if (ec) {
                return map_error_code(ec, "Failed to advance search iterator", root);
            }
            continue;
        }

        std::string line;
        uint64_t line_number = 0;
        while (!cancelled_ && std::getline(ifs, line)) {
            ++line_number;
            uint64_t column = 0;
            bool matched = false;

            if (use_regex) {
                std::smatch match;
                matched = std::regex_search(line, match, *compiled_regex);
                if (matched) {
                    column = static_cast<uint64_t>(match.position()) + 1;
                }
            } else {
                const std::size_t pos = line.find(pattern);
                if (pos != std::string::npos) {
                    matched = true;
                    column = static_cast<uint64_t>(pos) + 1;
                }
            }

            if (!matched) {
                continue;
            }

            ContentMatch content_match;
            content_match.file = entry_path;
            content_match.line_number = line_number;
            content_match.line_content = line;
            content_match.column = column;

            if (on_found) {
                on_found(content_match);
            }
            results.push_back(std::move(content_match));
        }

        iterator.increment(ec);
        if (ec) {
            return map_error_code(ec, "Failed to advance search iterator", root);
        }
    }

    return results;
}

void ContentSearch::cancel() { cancelled_ = true; }

}  // namespace fcxl::search
