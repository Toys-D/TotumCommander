#include "fcxl/filesystem/attributes.h"

#include <cerrno>
#include <cstring>
#include <grp.h>
#include <pwd.h>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <vector>

namespace fcxl::fs {
namespace {

auto map_errno_to_error(int err, std::string message, std::string path) -> common::Error {
    common::ErrorCode code = common::ErrorCode::IOError;
    switch (err) {
        case ENOENT:
        case ENOTDIR:
#ifdef ENOATTR
        case ENOATTR:
#endif
            code = common::ErrorCode::NotFound;
            break;
        case EACCES:
        case EPERM:
            code = common::ErrorCode::PermissionDenied;
            break;
        case EEXIST:
            code = common::ErrorCode::AlreadyExists;
            break;
        case EINVAL:
            code = common::ErrorCode::InvalidArgument;
            break;
        case ENAMETOOLONG:
            code = common::ErrorCode::NameTooLong;
            break;
        default:
            code = common::ErrorCode::IOError;
            break;
    }
    return common::Error::make(code, std::move(message), std::move(path));
}

auto mode_to_permissions_string(mode_t mode) -> std::string {
    std::string value;
    value.reserve(9);

    value.push_back((mode & S_IRUSR) != 0 ? 'r' : '-');
    value.push_back((mode & S_IWUSR) != 0 ? 'w' : '-');
    value.push_back((mode & S_IXUSR) != 0 ? 'x' : '-');

    value.push_back((mode & S_IRGRP) != 0 ? 'r' : '-');
    value.push_back((mode & S_IWGRP) != 0 ? 'w' : '-');
    value.push_back((mode & S_IXGRP) != 0 ? 'x' : '-');

    value.push_back((mode & S_IROTH) != 0 ? 'r' : '-');
    value.push_back((mode & S_IWOTH) != 0 ? 'w' : '-');
    value.push_back((mode & S_IXOTH) != 0 ? 'x' : '-');

    return value;
}

auto parse_symbolic_permissions(std::string_view mode, mode_t* out_mode) -> bool {
    if (mode.size() != 9 || out_mode == nullptr) {
        return false;
    }

    const auto expected = [](char c, char yes) { return c == yes || c == '-'; };
    if (!expected(mode[0], 'r') || !expected(mode[1], 'w') || !expected(mode[2], 'x') ||
        !expected(mode[3], 'r') || !expected(mode[4], 'w') || !expected(mode[5], 'x') ||
        !expected(mode[6], 'r') || !expected(mode[7], 'w') || !expected(mode[8], 'x')) {
        return false;
    }

    mode_t parsed = 0;
    if (mode[0] == 'r') parsed |= S_IRUSR;
    if (mode[1] == 'w') parsed |= S_IWUSR;
    if (mode[2] == 'x') parsed |= S_IXUSR;
    if (mode[3] == 'r') parsed |= S_IRGRP;
    if (mode[4] == 'w') parsed |= S_IWGRP;
    if (mode[5] == 'x') parsed |= S_IXGRP;
    if (mode[6] == 'r') parsed |= S_IROTH;
    if (mode[7] == 'w') parsed |= S_IWOTH;
    if (mode[8] == 'x') parsed |= S_IXOTH;

    *out_mode = parsed;
    return true;
}

auto parse_octal_permissions(std::string_view mode, mode_t* out_mode) -> bool {
    if (out_mode == nullptr) {
        return false;
    }

    if (mode.empty() || mode.size() > 4) {
        return false;
    }

    mode_t parsed = 0;
    for (char ch : mode) {
        if (ch < '0' || ch > '7') {
            return false;
        }
        parsed = static_cast<mode_t>((parsed << 3) + static_cast<mode_t>(ch - '0'));
    }

    *out_mode = static_cast<mode_t>(parsed & 0777);
    return true;
}

}  // namespace

auto Attributes::get_permissions(std::string_view path) const -> common::Result<std::string> {
    if (path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument, "Path cannot be empty");
    }

    struct stat st = {};
    if (::stat(std::string(path).c_str(), &st) != 0) {
        return map_errno_to_error(errno, "Failed to get file permissions", std::string(path));
    }

    return mode_to_permissions_string(st.st_mode);
}

auto Attributes::set_permissions(std::string_view path, std::string_view mode) -> common::Result<void> {
    if (path.empty() || mode.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Path and mode cannot be empty");
    }

    mode_t parsed_mode = 0;
    if (!parse_symbolic_permissions(mode, &parsed_mode) &&
        !parse_octal_permissions(mode, &parsed_mode)) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Invalid permission format",
                                   std::string(path));
    }

    if (::chmod(std::string(path).c_str(), parsed_mode) != 0) {
        return map_errno_to_error(errno, "Failed to set file permissions", std::string(path));
    }

    return common::Result<void>();
}

auto Attributes::get_owner(std::string_view path) const -> common::Result<std::string> {
    if (path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument, "Path cannot be empty");
    }

    struct stat st = {};
    if (::stat(std::string(path).c_str(), &st) != 0) {
        return map_errno_to_error(errno, "Failed to get file owner", std::string(path));
    }

    const passwd* pwd = ::getpwuid(st.st_uid);
    if (pwd == nullptr || pwd->pw_name == nullptr) {
        return std::to_string(static_cast<unsigned long long>(st.st_uid));
    }

    return std::string(pwd->pw_name);
}

auto Attributes::set_owner(std::string_view path, std::string_view owner, std::string_view group)
    -> common::Result<void> {
    if (path.empty() || owner.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Path and owner cannot be empty");
    }

    struct stat st = {};
    if (::stat(std::string(path).c_str(), &st) != 0) {
        return map_errno_to_error(errno, "Failed to get current owner/group", std::string(path));
    }

    const passwd* pwd = ::getpwnam(std::string(owner).c_str());
    if (pwd == nullptr) {
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Owner does not exist",
                                   std::string(owner));
    }

    gid_t gid = st.st_gid;
    if (!group.empty()) {
        const struct group* grp = ::getgrnam(std::string(group).c_str());
        if (grp == nullptr) {
            return common::Error::make(common::ErrorCode::NotFound,
                                       "Group does not exist",
                                       std::string(group));
        }
        gid = grp->gr_gid;
    }

    if (::chown(std::string(path).c_str(), pwd->pw_uid, gid) != 0) {
        return map_errno_to_error(errno, "Failed to set owner/group", std::string(path));
    }

    return common::Result<void>();
}

auto Attributes::get_xattr(std::string_view path, std::string_view name) const
    -> common::Result<std::string> {
    if (path.empty() || name.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Path and xattr name cannot be empty");
    }

    const std::string path_str(path);
    const std::string name_str(name);

    errno = 0;
    const ssize_t size = ::getxattr(path_str.c_str(), name_str.c_str(), nullptr, 0, 0, 0);
    if (size < 0) {
        return map_errno_to_error(errno, "Failed to get xattr size", path_str);
    }

    std::string value(static_cast<std::size_t>(size), '\0');
    errno = 0;
    const ssize_t read_size =
        ::getxattr(path_str.c_str(), name_str.c_str(), value.data(), value.size(), 0, 0);
    if (read_size < 0) {
        return map_errno_to_error(errno, "Failed to read xattr", path_str);
    }

    value.resize(static_cast<std::size_t>(read_size));
    return value;
}

auto Attributes::set_xattr(std::string_view path,
                           std::string_view name,
                           std::string_view value) -> common::Result<void> {
    if (path.empty() || name.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Path and xattr name cannot be empty");
    }

    const std::string path_str(path);
    const std::string name_str(name);
    const std::string value_str(value);

    if (::setxattr(path_str.c_str(), name_str.c_str(), value_str.data(), value_str.size(), 0, 0) !=
        0) {
        return map_errno_to_error(errno, "Failed to set xattr", path_str);
    }

    return common::Result<void>();
}

auto Attributes::remove_xattr(std::string_view path, std::string_view name) -> common::Result<void> {
    if (path.empty() || name.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Path and xattr name cannot be empty");
    }

    const std::string path_str(path);
    const std::string name_str(name);

    if (::removexattr(path_str.c_str(), name_str.c_str(), 0) != 0) {
        return map_errno_to_error(errno, "Failed to remove xattr", path_str);
    }

    return common::Result<void>();
}

auto Attributes::list_xattrs(std::string_view path) const -> common::Result<std::vector<std::string>> {
    if (path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument, "Path cannot be empty");
    }

    const std::string path_str(path);

    errno = 0;
    const ssize_t size = ::listxattr(path_str.c_str(), nullptr, 0, 0);
    if (size < 0) {
        return map_errno_to_error(errno, "Failed to list xattrs", path_str);
    }

    if (size == 0) {
        return std::vector<std::string>{};
    }

    std::vector<char> buffer(static_cast<std::size_t>(size));
    errno = 0;
    const ssize_t read_size = ::listxattr(path_str.c_str(), buffer.data(), buffer.size(), 0);
    if (read_size < 0) {
        return map_errno_to_error(errno, "Failed to read xattr list", path_str);
    }

    std::vector<std::string> result;
    std::size_t offset = 0;
    while (offset < static_cast<std::size_t>(read_size)) {
        const char* name_ptr = buffer.data() + offset;
        const std::size_t name_len = std::strlen(name_ptr);
        if (name_len == 0) {
            break;
        }

        result.emplace_back(name_ptr, name_len);
        offset += name_len + 1;
    }

    return result;
}

}  // namespace fcxl::fs
