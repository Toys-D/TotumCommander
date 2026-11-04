#include "fcxl/filesystem/symlinks.h"

#include <cerrno>
#include <string>
#include <system_error>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>
#endif

namespace fcxl::fs {
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

#ifdef __APPLE__
/// RAII wrapper for CFTypeRef
struct CFRelease_Guard {
    CFTypeRef ref;
    ~CFRelease_Guard() {
        if (ref != nullptr) CFRelease(ref);
    }
};
#endif

}  // namespace

auto Symlinks::create_symlink(std::string_view target, std::string_view link_path)
    -> common::Result<void> {
    if (target.empty() || link_path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Target and link_path cannot be empty");
    }

    std::error_code ec;
    const std::filesystem::path target_path(target);
    const std::filesystem::path link(link_path);

    const bool exists = std::filesystem::exists(target_path, ec);
    if (ec) {
        return map_error_code(ec, "Failed to check target existence", target_path);
    }
    if (!exists) {
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Target does not exist",
                                   target_path.string());
    }

    std::filesystem::create_symlink(target_path, link, ec);
    if (ec) {
        return map_error_code(ec, "Failed to create symlink", link);
    }

    return common::Result<void>();
}

auto Symlinks::create_hardlink(std::string_view target, std::string_view link_path)
    -> common::Result<void> {
    if (target.empty() || link_path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Target and link_path cannot be empty");
    }

    std::error_code ec;
    const std::filesystem::path target_path(target);
    const std::filesystem::path link(link_path);

    const bool exists = std::filesystem::exists(target_path, ec);
    if (ec) {
        return map_error_code(ec, "Failed to check target existence", target_path);
    }
    if (!exists) {
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Target does not exist",
                                   target_path.string());
    }

    std::filesystem::create_hard_link(target_path, link, ec);
    if (ec) {
        return map_error_code(ec, "Failed to create hardlink", link);
    }

    return common::Result<void>();
}

auto Symlinks::create_alias(std::string_view target, std::string_view alias_path)
    -> common::Result<void> {
#ifdef __APPLE__
    if (target.empty() || alias_path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Target and alias_path cannot be empty");
    }

    const std::string target_str(target);
    const std::string alias_str(alias_path);

    // Create CFURL for the target
    CFURLRef target_url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(target_str.c_str()),
        static_cast<CFIndex>(target_str.size()),
        false);
    if (target_url == nullptr) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Failed to create URL for target", target_str);
    }
    CFRelease_Guard target_guard{target_url};

    // Create bookmark data (this is the macOS alias mechanism)
    CFErrorRef cf_error = nullptr;
    CFDataRef bookmark = CFURLCreateBookmarkData(
        kCFAllocatorDefault,
        target_url,
        kCFURLBookmarkCreationSuitableForBookmarkFile,
        nullptr,  // resourcePropertiesToInclude
        nullptr,  // relativeToURL
        &cf_error);

    if (bookmark == nullptr) {
        if (cf_error != nullptr) {
            CFRelease(cf_error);
        }
        return common::Error::make(common::ErrorCode::IOError,
                                   "Failed to create bookmark data", target_str);
    }
    CFRelease_Guard bookmark_guard{bookmark};

    // Create CFURL for the alias file destination
    CFURLRef alias_url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(alias_str.c_str()),
        static_cast<CFIndex>(alias_str.size()),
        false);
    if (alias_url == nullptr) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Failed to create URL for alias path", alias_str);
    }
    CFRelease_Guard alias_guard{alias_url};

    // Write the bookmark file (macOS alias)
    CFErrorRef write_error = nullptr;
    Boolean ok = CFURLWriteBookmarkDataToFile(bookmark, alias_url, 0, &write_error);
    if (!ok) {
        if (write_error != nullptr) {
            CFRelease(write_error);
        }
        return common::Error::make(common::ErrorCode::IOError,
                                   "Failed to write alias file", alias_str);
    }

    return common::Result<void>();
#else
    (void)target;
    (void)alias_path;
    return common::Error::make(common::ErrorCode::NotSupported,
                               "Alias creation is only supported on macOS");
#endif
}

auto Symlinks::read_symlink(std::string_view link_path) const
    -> common::Result<std::filesystem::path> {
    if (link_path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "link_path cannot be empty");
    }

    std::error_code ec;
    const std::filesystem::path link(link_path);

    const auto status = std::filesystem::symlink_status(link, ec);
    if (ec) {
        return map_error_code(ec, "Failed to get link status", link);
    }
    if (!std::filesystem::is_symlink(status)) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Path is not a symlink",
                                   link.string());
    }

    const std::filesystem::path resolved_target = std::filesystem::read_symlink(link, ec);
    if (ec) {
        return map_error_code(ec, "Failed to read symlink", link);
    }

    return resolved_target;
}

auto Symlinks::is_symlink(std::string_view path) const -> bool {
    if (path.empty()) {
        return false;
    }

    std::error_code ec;
    const auto status = std::filesystem::symlink_status(std::filesystem::path(path), ec);
    return !ec && std::filesystem::is_symlink(status);
}

auto Symlinks::is_alias(std::string_view path) const -> bool {
#ifdef __APPLE__
    if (path.empty()) {
        return false;
    }

    const std::string path_str(path);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(path_str.c_str()),
        static_cast<CFIndex>(path_str.size()),
        false);
    if (url == nullptr) {
        return false;
    }
    CFRelease_Guard url_guard{url};

    CFBooleanRef is_alias_value = nullptr;
    Boolean ok = CFURLCopyResourcePropertyForKey(
        url, kCFURLIsAliasFileKey, &is_alias_value, nullptr);

    if (!ok || is_alias_value == nullptr) {
        return false;
    }

    bool result = CFBooleanGetValue(is_alias_value);
    CFRelease(is_alias_value);
    return result;
#else
    (void)path;
    return false;
#endif
}

auto Symlinks::resolve_alias(std::string_view alias_path) const
    -> common::Result<std::filesystem::path> {
#ifdef __APPLE__
    if (alias_path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "alias_path cannot be empty");
    }

    const std::string path_str(alias_path);
    CFURLRef alias_url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(path_str.c_str()),
        static_cast<CFIndex>(path_str.size()),
        false);
    if (alias_url == nullptr) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Failed to create URL", path_str);
    }
    CFRelease_Guard alias_guard{alias_url};

    // Read bookmark data from alias file
    CFErrorRef cf_error = nullptr;
    CFDataRef bookmark = CFURLCreateBookmarkDataFromFile(
        kCFAllocatorDefault, alias_url, &cf_error);
    if (bookmark == nullptr) {
        if (cf_error != nullptr) {
            CFRelease(cf_error);
        }
        return common::Error::make(common::ErrorCode::IOError,
                                   "Failed to read alias bookmark data", path_str);
    }
    CFRelease_Guard bookmark_guard{bookmark};

    // Resolve bookmark to URL
    Boolean is_stale = false;
    CFURLRef resolved_url = CFURLCreateByResolvingBookmarkData(
        kCFAllocatorDefault,
        bookmark,
        kCFURLBookmarkResolutionWithoutMountingMask,
        nullptr,  // relativeToURL
        nullptr,  // resourcePropertiesToInclude
        &is_stale,
        &cf_error);

    if (resolved_url == nullptr) {
        if (cf_error != nullptr) {
            CFRelease(cf_error);
        }
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Failed to resolve alias", path_str);
    }
    CFRelease_Guard resolved_guard{resolved_url};

    // Extract file system path from resolved URL
    char resolved_path[PATH_MAX];
    if (!CFURLGetFileSystemRepresentation(resolved_url, true,
                                          reinterpret_cast<UInt8*>(resolved_path),
                                          PATH_MAX)) {
        return common::Error::make(common::ErrorCode::IOError,
                                   "Failed to get path from resolved alias", path_str);
    }

    return std::filesystem::path(resolved_path);
#else
    (void)alias_path;
    return common::Error::make(common::ErrorCode::NotSupported,
                               "Alias resolution is only supported on macOS");
#endif
}

}  // namespace fcxl::fs
