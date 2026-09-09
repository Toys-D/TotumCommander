#include "fcxl/search/file_search.h"

#include "fcxl/search/exclusions.h"

#include <algorithm>
#include <chrono>
#include <mutex>
#include <optional>
#include <regex>
#include <string>
#include <system_error>
#include <unordered_set>

#include "fcxl/search/name_match.h"

namespace fcxl::search {
namespace {

std::mutex g_state_mutex;
std::unordered_set<const FileSearch*> g_active_searches;

auto set_searching_state(const FileSearch* search, bool searching) -> void {
    std::lock_guard<std::mutex> lock(g_state_mutex);
    if (searching) {
        g_active_searches.insert(search);
    } else {
        g_active_searches.erase(search);
    }
}

auto is_searching_state(const FileSearch* search) -> bool {
    std::lock_guard<std::mutex> lock(g_state_mutex);
    return g_active_searches.find(search) != g_active_searches.end();
}

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

auto is_hidden_name(std::string_view name) -> bool {
    return !name.empty() && name.front() == '.';
}

auto to_system_clock_time(std::filesystem::file_time_type file_time)
    -> std::chrono::system_clock::time_point {
    const auto file_now = std::filesystem::file_time_type::clock::now();
    const auto system_now = std::chrono::system_clock::now();
    return std::chrono::time_point_cast<std::chrono::system_clock::duration>(
        file_time - file_now + system_now);
}

auto permissions_to_string(std::filesystem::perms perms) -> std::string {
    auto rwx = [perms](std::filesystem::perms r,
                       std::filesystem::perms w,
                       std::filesystem::perms x) -> std::string {
        std::string result;
        result.reserve(3);
        result.push_back((perms & r) != std::filesystem::perms::none ? 'r' : '-');
        result.push_back((perms & w) != std::filesystem::perms::none ? 'w' : '-');
        result.push_back((perms & x) != std::filesystem::perms::none ? 'x' : '-');
        return result;
    };

    std::string value;
    value.reserve(9);
    value += rwx(std::filesystem::perms::owner_read,
                 std::filesystem::perms::owner_write,
                 std::filesystem::perms::owner_exec);
    value += rwx(std::filesystem::perms::group_read,
                 std::filesystem::perms::group_write,
                 std::filesystem::perms::group_exec);
    value += rwx(std::filesystem::perms::others_read,
                 std::filesystem::perms::others_write,
                 std::filesystem::perms::others_exec);
    return value;
}

auto has_date_from_filter(const common::SearchFilter& filter) -> bool {
    return filter.date_from.time_since_epoch() != std::chrono::system_clock::duration::zero();
}

auto has_date_to_filter(const common::SearchFilter& filter) -> bool {
    return filter.date_to.time_since_epoch() != std::chrono::system_clock::duration::zero();
}

/// A mask with no wildcard in it is a piece of a name rather than a whole one, and is wrapped on
/// both sides: typing "отчёт" has always meant "…отчёт…".
auto make_name_mask(const std::string& pattern) -> NameMask {
    const bool has_wildcard = pattern.find('*') != std::string::npos ||
                              pattern.find('?') != std::string::npos;
    return NameMask(has_wildcard ? pattern : "*" + pattern + "*");
}

auto matches_pattern(const std::string& name,
                     const common::SearchFilter& filter,
                     const std::regex* compiled_regex,
                     const NameMask* name_mask) -> bool {
    if (filter.name_pattern.empty()) {
        return true;
    }

    if (filter.use_regex) {
        if (compiled_regex == nullptr) {
            return false;
        }
        // The pattern was composed when it was compiled; the name has to meet it in the same
        // form, since the one the file system holds is whichever the writer happened to use.
        const std::string composed = to_composed_form(name);
        return std::regex_search(composed, *compiled_regex);
    }

    return name_mask != nullptr && name_mask->matches(name);
}

auto advance_iterator_ignoring_errors(std::filesystem::recursive_directory_iterator& iterator,
                                      std::error_code& ec) -> void {
    ec.clear();
    iterator.increment(ec);
    if (ec) {
        ec.clear();
    }
}

}  // namespace

auto FileSearch::search(std::string_view root_path,
                        const common::SearchFilter& filter,
                        SearchResultCallback on_found,
                        ScanProgressCallback on_scan_dir)
    -> common::Result<std::vector<common::FileEntry>> {
    if (root_path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Root path cannot be empty");
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
    std::optional<NameMask> name_mask;
    if (filter.use_regex && !filter.name_pattern.empty()) {
        try {
            compiled_regex.emplace(to_composed_form(filter.name_pattern), std::regex::ECMAScript);
        } catch (const std::regex_error&) {
            return common::Error::make(common::ErrorCode::InvalidArgument,
                                       "Invalid regex pattern",
                                       root.string());
        }
    } else if (!filter.name_pattern.empty()) {
        // Worked out once: every name in the tree is matched against the same mask.
        name_mask.emplace(make_name_mask(filter.name_pattern));
    }

    cancelled_ = false;
    set_searching_state(this, true);
    struct SearchStateGuard {
        explicit SearchStateGuard(const FileSearch* search) : search_(search) {}
        ~SearchStateGuard() {
            set_searching_state(search_, false);
            const_cast<FileSearch*>(search_)->cancelled_ = false;
        }
        const FileSearch* search_;
    } guard(this);

    std::vector<common::FileEntry> results;
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
        const std::string name = entry_path.filename().string();

        const bool is_directory_entry = dir_entry.is_directory(ec);
        if (ec) {
            advance_iterator_ignoring_errors(iterator, ec);
            continue;
        }

        // Report the directory being entered so the UI can show a "scanning …" status.
        if (is_directory_entry && on_scan_dir) {
            on_scan_dir(entry_path.string());
        }

        if (!filter.recursive && is_directory_entry) {
            iterator.disable_recursion_pending();
        }

        // An excluded name is skipped — and an excluded DIRECTORY is never entered, which is
        // where the time goes: a home folder is mostly build caches, and reading them only to
        // throw the results away is the slow way to get the same answer.
        if (is_excluded(name, filter.exclude_patterns)) {
            if (is_directory_entry) {
                iterator.disable_recursion_pending();
            }
            advance_iterator_ignoring_errors(iterator, ec);
            continue;
        }

        const bool hidden = is_hidden_name(name);
        if (!filter.include_hidden && hidden) {
            advance_iterator_ignoring_errors(iterator, ec);
            continue;
        }

        const bool is_regular_file = dir_entry.is_regular_file(ec);
        if (ec) {
            advance_iterator_ignoring_errors(iterator, ec);
            continue;
        }

        // Apply type filter
        if (filter.type_filter == common::FileTypeFilter::FilesOnly && !is_regular_file) {
            advance_iterator_ignoring_errors(iterator, ec);
            continue;
        }
        if (filter.type_filter == common::FileTypeFilter::DirsOnly && !is_directory_entry) {
            advance_iterator_ignoring_errors(iterator, ec);
            continue;
        }
        if (filter.type_filter == common::FileTypeFilter::All && !is_regular_file && !is_directory_entry) {
            advance_iterator_ignoring_errors(iterator, ec);
            continue;
        }

        if (!matches_pattern(name,
                             filter,
                             compiled_regex ? &compiled_regex.value() : nullptr,
                             name_mask ? &name_mask.value() : nullptr)) {
            advance_iterator_ignoring_errors(iterator, ec);
            continue;
        }

        uint64_t size = 0;
        if (is_regular_file) {
            size = static_cast<uint64_t>(dir_entry.file_size(ec));
            if (ec) {
                ec.clear();
                size = 0;
            }
            // Only apply size filter to regular files
            if (size < filter.min_size || size > filter.max_size) {
                advance_iterator_ignoring_errors(iterator, ec);
                continue;
            }
        }

        const auto modified_file_time = dir_entry.last_write_time(ec);
        if (ec) {
            advance_iterator_ignoring_errors(iterator, ec);
            continue;
        }
        const auto modified_time = to_system_clock_time(modified_file_time);

        if (has_date_from_filter(filter) && modified_time < filter.date_from) {
            advance_iterator_ignoring_errors(iterator, ec);
            continue;
        }
        if (has_date_to_filter(filter) && modified_time > filter.date_to) {
            advance_iterator_ignoring_errors(iterator, ec);
            continue;
        }

        const std::filesystem::file_status status = dir_entry.symlink_status(ec);
        if (ec) {
            advance_iterator_ignoring_errors(iterator, ec);
            continue;
        }

        common::FileEntry entry;
        entry.path = entry_path;
        entry.name = name;
        entry.extension = entry_path.extension().string();
        entry.type = is_directory_entry ? common::EntryType::Directory : common::EntryType::File;
        entry.size = size;
        entry.date_modified = modified_time;
        entry.date_created = modified_time;
        entry.is_hidden = hidden;
        entry.is_symlink = std::filesystem::is_symlink(status);
        entry.permissions = permissions_to_string(status.permissions());
        entry.owner.clear();
        entry.group.clear();

        if (on_found) {
            on_found(entry);
        }
        results.push_back(std::move(entry));

        advance_iterator_ignoring_errors(iterator, ec);
    }

    // Sort: directories first, then by name
    std::sort(results.begin(), results.end(), [](const common::FileEntry& a, const common::FileEntry& b) {
        if (a.type != b.type) {
            return a.type == common::EntryType::Directory;
        }
        return a.name < b.name;
    });

    return results;
}

void FileSearch::cancel() { cancelled_ = true; }

auto FileSearch::is_searching() const -> bool { return is_searching_state(this); }

}  // namespace fcxl::search
