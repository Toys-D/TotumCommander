#include "fcxl/filesystem/navigator.h"

#include <array>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <system_error>
#include <unordered_map>
#include <vector>

#include <dirent.h>
#include <sys/stat.h>

#if defined(__APPLE__)
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <sys/attr.h>
#include <sys/vnode.h>
#include <unistd.h>
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
        case std::errc::operation_not_supported:
        case std::errc::function_not_supported:
            code = common::ErrorCode::NotSupported;
            break;
        case std::errc::filename_too_long:
            code = common::ErrorCode::NameTooLong;
            break;
        case std::errc::no_space_on_device:
            code = common::ErrorCode::DiskFull;
            break;
        default:
            code = common::ErrorCode::IOError;
            break;
    }

    return common::Error::make(code, std::move(message), path.string());
}

[[maybe_unused]]
auto to_system_clock_time(std::filesystem::file_time_type file_time)
    -> std::chrono::system_clock::time_point {
    const auto file_now = std::filesystem::file_time_type::clock::now();
    const auto system_now = std::chrono::system_clock::now();
    return std::chrono::time_point_cast<std::chrono::system_clock::duration>(
        file_time - file_now + system_now);
}

#if defined(__APPLE__)
auto to_system_clock_time(const timespec& ts) -> std::chrono::system_clock::time_point {
    const auto base = std::chrono::system_clock::from_time_t(ts.tv_sec);
    const auto fractional = std::chrono::duration_cast<std::chrono::system_clock::duration>(
        std::chrono::nanoseconds(ts.tv_nsec));
    return base + fractional;
}

auto default_lookup_buffer_size(long configured_size) -> std::size_t {
    constexpr std::size_t kFallbackBufferSize = 16U * 1024U;
    if (configured_size > 0) {
        return static_cast<std::size_t>(configured_size);
    }
    return kFallbackBufferSize;
}

auto resolve_user_name(uid_t uid,
                       std::unordered_map<uid_t, std::string>& cache,
                       std::vector<char>& lookup_buffer) -> std::string {
    const auto it = cache.find(uid);
    if (it != cache.end()) {
        return it->second;
    }

    if (lookup_buffer.empty()) {
        lookup_buffer.resize(default_lookup_buffer_size(sysconf(_SC_GETPW_R_SIZE_MAX)));
    }

    std::string owner_name;
    for (;;) {
        struct passwd pwd {};
        struct passwd* pwd_result = nullptr;
        const int rc = getpwuid_r(uid, &pwd, lookup_buffer.data(), lookup_buffer.size(), &pwd_result);
        if (rc == 0) {
            if (pwd_result != nullptr && pwd_result->pw_name != nullptr) {
                owner_name = pwd_result->pw_name;
            }
            break;
        }
        if (rc != ERANGE || lookup_buffer.size() >= 1024U * 1024U) {
            break;
        }
        lookup_buffer.resize(lookup_buffer.size() * 2U);
    }

    cache.emplace(uid, owner_name);
    return owner_name;
}

auto resolve_group_name(gid_t gid,
                        std::unordered_map<gid_t, std::string>& cache,
                        std::vector<char>& lookup_buffer) -> std::string {
    const auto it = cache.find(gid);
    if (it != cache.end()) {
        return it->second;
    }

    if (lookup_buffer.empty()) {
        lookup_buffer.resize(default_lookup_buffer_size(sysconf(_SC_GETGR_R_SIZE_MAX)));
    }

    std::string group_name;
    for (;;) {
        struct group grp {};
        struct group* grp_result = nullptr;
        const int rc = getgrgid_r(gid, &grp, lookup_buffer.data(), lookup_buffer.size(), &grp_result);
        if (rc == 0) {
            if (grp_result != nullptr && grp_result->gr_name != nullptr) {
                group_name = grp_result->gr_name;
            }
            break;
        }
        if (rc != ERANGE || lookup_buffer.size() >= 1024U * 1024U) {
            break;
        }
        lookup_buffer.resize(lookup_buffer.size() * 2U);
    }

    cache.emplace(gid, group_name);
    return group_name;
}
#endif

[[maybe_unused]]
auto entry_type_from_status(const std::filesystem::file_status& status) -> common::EntryType {
    if (std::filesystem::is_symlink(status)) {
        return common::EntryType::Symlink;
    }
    if (std::filesystem::is_directory(status)) {
        return common::EntryType::Directory;
    }
    if (std::filesystem::is_regular_file(status)) {
        return common::EntryType::File;
    }
    return common::EntryType::Other;
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

auto permissions_from_access_mask(uint32_t access_mask) -> std::string {
    constexpr uint32_t kPermissionMask = 0777U;
    const auto perms = static_cast<std::filesystem::perms>(access_mask & kPermissionMask);
    return permissions_to_string(perms);
}

auto is_hidden_name(std::string_view name) -> bool {
    return !name.empty() && name.front() == '.';
}

auto validate_directory_path(std::string_view path)
    -> common::Result<std::filesystem::path> {
    if (path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument, "Path cannot be empty");
    }

    const std::filesystem::path directory_path(path);
    std::error_code ec;

    const bool exists = std::filesystem::exists(directory_path, ec);
    if (ec) {
        return map_error_code(ec, "Failed to check path existence", directory_path);
    }
    if (!exists) {
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Directory does not exist",
                                   directory_path.string());
    }

    const bool is_dir = std::filesystem::is_directory(directory_path, ec);
    if (ec) {
        return map_error_code(ec, "Failed to check directory type", directory_path);
    }
    if (!is_dir) {
        return common::Error::make(common::ErrorCode::NotADirectory,
                                   "Path is not a directory",
                                   directory_path.string());
    }

    return directory_path;
}

/// Optimized directory listing: readdir() + single lstat() per entry.
/// The old std::filesystem version did 3-4 separate stat() syscalls per file,
/// causing 40-100s delays on slow USB drives. This version does exactly ONE.
auto list_directory_std(const std::filesystem::path& directory_path,
                        bool show_hidden) -> common::Result<std::vector<common::FileEntry>> {
    DIR* dir = opendir(directory_path.c_str());
    if (!dir) {
        return common::Error::make(
            common::ErrorCode::IOError,
            std::string("Failed to open directory: ") + strerror(errno),
            directory_path.string());
    }

    std::vector<common::FileEntry> entries;
#if defined(__APPLE__)
    std::unordered_map<uid_t, std::string> owner_cache;
    std::unordered_map<gid_t, std::string> group_cache;
    std::vector<char> user_lookup_buffer;
    std::vector<char> group_lookup_buffer;
#endif

    errno = 0;
    while (struct dirent* dp = readdir(dir)) {
        if (dp->d_name[0] == '.' &&
            (dp->d_name[1] == '\0' ||
             (dp->d_name[1] == '.' && dp->d_name[2] == '\0'))) {
            continue;
        }

        const std::string name(dp->d_name);
        const bool hidden = is_hidden_name(name);
        if (!show_hidden && hidden) {
            continue;
        }

        common::FileEntry entry;
        entry.name = name;
        entry.path = directory_path / name;
        entry.extension = entry.path.extension().string();
        entry.is_hidden = hidden;

        // d_type from readdir gives type without any syscall on most filesystems
        bool type_known = true;
        switch (dp->d_type) {
            case DT_DIR: entry.type = common::EntryType::Directory; break;
            case DT_LNK: entry.type = common::EntryType::Symlink; entry.is_symlink = true; break;
            case DT_REG: entry.type = common::EntryType::File; break;
            case DT_UNKNOWN: type_known = false; break;
            default: entry.type = common::EntryType::Other; break;
        }

        // Single lstat() for ALL metadata (size, dates, permissions, owner)
        struct stat st {};
        if (::lstat(entry.path.c_str(), &st) == 0) {
            if (!type_known) {
                if (S_ISDIR(st.st_mode)) {
                    entry.type = common::EntryType::Directory;
                } else if (S_ISLNK(st.st_mode)) {
                    entry.type = common::EntryType::Symlink;
                    entry.is_symlink = true;
                } else if (S_ISREG(st.st_mode)) {
                    entry.type = common::EntryType::File;
                } else {
                    entry.type = common::EntryType::Other;
                }
            }

            if (entry.is_symlink) {
                // Follow symlink for target file size
                struct stat target {};
                entry.size = (::stat(entry.path.c_str(), &target) == 0 && S_ISREG(target.st_mode))
                    ? static_cast<uint64_t>(target.st_size)
                    : 0;
            } else {
                entry.size = S_ISREG(st.st_mode) ? static_cast<uint64_t>(st.st_size) : 0;
            }

#if defined(__APPLE__)
            // Honour the macOS "hidden" file flag (UF_HIDDEN), not just dot-names — this is
            // the flag Finder sets and reads, so a file hidden via our properties window (or
            // Finder) disappears here too. Free: the lstat above already ran for metadata.
            if ((st.st_flags & UF_HIDDEN) != 0) {
                entry.is_hidden = true;
                if (!show_hidden) {
                    errno = 0;
                    continue;
                }
            }
            entry.date_modified = to_system_clock_time(st.st_mtimespec);
            entry.date_created = to_system_clock_time(st.st_birthtimespec);
            entry.permissions = permissions_from_access_mask(st.st_mode);
            entry.owner = resolve_user_name(st.st_uid, owner_cache, user_lookup_buffer);
            entry.group = resolve_group_name(st.st_gid, group_cache, group_lookup_buffer);
#else
            entry.date_modified = std::chrono::system_clock::from_time_t(st.st_mtime);
            entry.date_created = entry.date_modified;
            entry.permissions = permissions_from_access_mask(st.st_mode);
            entry.owner.clear();
            entry.group.clear();
#endif
        } else {
            entry.size = 0;
            entry.date_modified = std::chrono::system_clock::time_point{};
            entry.date_created = entry.date_modified;
        }

        entries.push_back(std::move(entry));
        errno = 0;
    }

    closedir(dir);
    return entries;
}

/// Ultra-fast directory listing: readdir() only, NO stat() calls at all.
/// Returns only names, paths, extensions, types (from d_type), and hidden flags.
/// Size = 0, dates = epoch, permissions/owner = empty.
/// Used for instant display on slow volumes; metadata loaded in background.
auto list_directory_readdir_only(const std::filesystem::path& directory_path,
                                 bool show_hidden) -> common::Result<std::vector<common::FileEntry>> {
    DIR* dir = opendir(directory_path.c_str());
    if (!dir) {
        return common::Error::make(
            common::ErrorCode::IOError,
            std::string("Failed to open directory: ") + strerror(errno),
            directory_path.string());
    }

    std::vector<common::FileEntry> entries;

    while (struct dirent* dp = readdir(dir)) {
        if (dp->d_name[0] == '.' &&
            (dp->d_name[1] == '\0' ||
             (dp->d_name[1] == '.' && dp->d_name[2] == '\0'))) {
            continue;
        }

        const std::string name(dp->d_name);
        const bool hidden = is_hidden_name(name);
        if (!show_hidden && hidden) {
            continue;
        }

        common::FileEntry entry;
        entry.name = name;
        entry.path = directory_path / name;
        entry.extension = entry.path.extension().string();
        entry.is_hidden = hidden;

        switch (dp->d_type) {
            case DT_DIR: entry.type = common::EntryType::Directory; break;
            case DT_LNK: entry.type = common::EntryType::Symlink; entry.is_symlink = true; break;
            case DT_REG: entry.type = common::EntryType::File; break;
            case DT_UNKNOWN: {
                // Rare: d_type unavailable, need lstat just for type
                struct stat st {};
                if (::lstat(entry.path.c_str(), &st) == 0) {
                    if (S_ISDIR(st.st_mode)) entry.type = common::EntryType::Directory;
                    else if (S_ISLNK(st.st_mode)) { entry.type = common::EntryType::Symlink; entry.is_symlink = true; }
                    else if (S_ISREG(st.st_mode)) entry.type = common::EntryType::File;
                    else entry.type = common::EntryType::Other;
                }
                break;
            }
            default: entry.type = common::EntryType::Other; break;
        }

        // No stat: size = 0, dates = epoch, permissions/owner = empty
        entry.size = 0;
        entry.date_modified = std::chrono::system_clock::time_point{};
        entry.date_created = std::chrono::system_clock::time_point{};

        entries.push_back(std::move(entry));
    }

    closedir(dir);
    return entries;
}

#if defined(__APPLE__)
template <typename T>
auto read_value(const char*& cursor, const char* record_end, T* out) -> bool {
    if (cursor + sizeof(T) > record_end || out == nullptr) {
        return false;
    }
    std::memcpy(out, cursor, sizeof(T));
    cursor += sizeof(T);
    return true;
}

auto entry_type_from_obj_type(fsobj_type_t obj_type) -> common::EntryType {
    switch (obj_type) {
        case VDIR:
            return common::EntryType::Directory;
        case VLNK:
            return common::EntryType::Symlink;
        case VREG:
            return common::EntryType::File;
        default:
            return common::EntryType::Other;
    }
}

auto list_directory_getattrlistbulk(const std::filesystem::path& directory_path,
                                    bool show_hidden)
    -> common::Result<std::vector<common::FileEntry>> {
    constexpr std::size_t kAttrBufferSize = 256U * 1024U;
    std::vector<char> attr_buffer(kAttrBufferSize);
    std::vector<common::FileEntry> entries;

    const int dir_fd = open(directory_path.c_str(), O_RDONLY | O_CLOEXEC);
    if (dir_fd < 0) {
        return map_error_code(
            std::error_code(errno, std::generic_category()),
            "Failed to open directory for fast listing",
            directory_path);
    }

    struct attrlist attr_list {};
    attr_list.bitmapcount = ATTR_BIT_MAP_COUNT;
    attr_list.commonattr = ATTR_CMN_RETURNED_ATTRS |
                           ATTR_CMN_NAME |
                           ATTR_CMN_ERROR |
                           ATTR_CMN_OBJTYPE |
                           ATTR_CMN_CRTIME |
                           ATTR_CMN_MODTIME |
                           ATTR_CMN_FNDRINFO |   // Finder flags — carries the alias bit
                           ATTR_CMN_OWNERID |
                           ATTR_CMN_GRPID |
                           ATTR_CMN_ACCESSMASK |
                           ATTR_CMN_FLAGS;   // BSD flags — carries UF_HIDDEN (Finder's hidden bit)
    attr_list.dirattr = ATTR_DIR_ENTRYCOUNT;  // free here: same call already reads every record
    attr_list.fileattr = ATTR_FILE_TOTALSIZE;

    std::unordered_map<uid_t, std::string> owner_cache;
    std::unordered_map<gid_t, std::string> group_cache;
    std::vector<char> user_lookup_buffer;
    std::vector<char> group_lookup_buffer;

    for (;;) {
        errno = 0;
        const int returned_count = getattrlistbulk(
            dir_fd,
            &attr_list,
            attr_buffer.data(),
            attr_buffer.size(),
            0);

        if (returned_count == 0) {
            break;
        }
        if (returned_count < 0) {
            if (errno == EINTR) {
                continue;
            }
            common::Error error {};
            if (errno == ENOTSUP || errno == ENOSYS || errno == EOPNOTSUPP || errno == EINVAL) {
                error = common::Error::make(
                    common::ErrorCode::NotSupported,
                    "Bulk directory attributes are not supported on this volume",
                    directory_path.string());
            } else {
                error = map_error_code(
                    std::error_code(errno, std::generic_category()),
                    "Failed to read directory attributes in bulk",
                    directory_path);
            }
            close(dir_fd);
            return error;
        }

        const char* record = attr_buffer.data();
        const char* const buffer_end = attr_buffer.data() + attr_buffer.size();

        for (int i = 0; i < returned_count; ++i) {
            uint32_t record_length = 0;
            if (!read_value(record, buffer_end, &record_length) ||
                record_length < sizeof(uint32_t) + sizeof(attribute_set_t)) {
                break;
            }

            const char* const record_start = record - sizeof(uint32_t);
            const char* const record_end = record_start + record_length;
            if (record_end > buffer_end) {
                record = buffer_end;
                break;
            }

            const char* cursor = record;

            attribute_set_t returned_attrs {};
            if (!read_value(cursor, record_end, &returned_attrs)) {
                record = record_end;
                continue;
            }

            uint32_t item_error = 0;
            if ((returned_attrs.commonattr & ATTR_CMN_ERROR) != 0 &&
                !read_value(cursor, record_end, &item_error)) {
                record = record_end;
                continue;
            }
            if (item_error != 0) {
                record = record_end;
                continue;
            }

            attrreference_t name_ref {};
            const char* name_ref_ptr = cursor;
            if ((returned_attrs.commonattr & ATTR_CMN_NAME) != 0 &&
                !read_value(cursor, record_end, &name_ref)) {
                record = record_end;
                continue;
            }

            fsobj_type_t object_type = VNON;
            if ((returned_attrs.commonattr & ATTR_CMN_OBJTYPE) != 0 &&
                !read_value(cursor, record_end, &object_type)) {
                record = record_end;
                continue;
            }

            timespec created_time {};
            if ((returned_attrs.commonattr & ATTR_CMN_CRTIME) != 0 &&
                !read_value(cursor, record_end, &created_time)) {
                record = record_end;
                continue;
            }

            timespec modified_time {};
            if ((returned_attrs.commonattr & ATTR_CMN_MODTIME) != 0 &&
                !read_value(cursor, record_end, &modified_time)) {
                record = record_end;
                continue;
            }

            // FNDRINFO sits between the times and OWNERID in the canonical common-attr
            // order, so it is read HERE. Its first 16 bytes are the FileInfo/FolderInfo
            // union; the Finder flags are the 16-bit big-endian field at offset 8, and
            // 0x8000 (kIsAlias) is the alias bit.
            std::array<unsigned char, 32> finder_info {};
            if ((returned_attrs.commonattr & ATTR_CMN_FNDRINFO) != 0 &&
                !read_value(cursor, record_end, &finder_info)) {
                record = record_end;
                continue;
            }
            const uint16_t finder_flags =
                static_cast<uint16_t>((finder_info[8] << 8) | finder_info[9]);
            const bool is_alias = (finder_flags & 0x8000U) != 0;

            uid_t owner_id = 0;
            if ((returned_attrs.commonattr & ATTR_CMN_OWNERID) != 0 &&
                !read_value(cursor, record_end, &owner_id)) {
                record = record_end;
                continue;
            }

            gid_t group_id = 0;
            if ((returned_attrs.commonattr & ATTR_CMN_GRPID) != 0 &&
                !read_value(cursor, record_end, &group_id)) {
                record = record_end;
                continue;
            }

            uint32_t access_mask = 0;
            if ((returned_attrs.commonattr & ATTR_CMN_ACCESSMASK) != 0 &&
                !read_value(cursor, record_end, &access_mask)) {
                record = record_end;
                continue;
            }

            // ATTR_CMN_FLAGS follows ACCESSMASK in the canonical common-attr order, so it must
            // be read here, before any file attributes.
            uint32_t bsd_flags = 0;
            if ((returned_attrs.commonattr & ATTR_CMN_FLAGS) != 0 &&
                !read_value(cursor, record_end, &bsd_flags)) {
                record = record_end;
                continue;
            }

            // Directory attributes sit between the common and the file ones in the record, so
            // the entry count must be read here — reading it after the size would decode both
            // fields from the wrong offsets.
            uint32_t entry_count = 0;
            const bool entry_count_known =
                (returned_attrs.dirattr & ATTR_DIR_ENTRYCOUNT) != 0;
            if (entry_count_known && !read_value(cursor, record_end, &entry_count)) {
                record = record_end;
                continue;
            }

            off_t total_size = 0;
            if ((returned_attrs.fileattr & ATTR_FILE_TOTALSIZE) != 0 &&
                !read_value(cursor, record_end, &total_size)) {
                record = record_end;
                continue;
            }

            std::string name;
            if ((returned_attrs.commonattr & ATTR_CMN_NAME) != 0) {
                const char* const name_ptr = name_ref_ptr + name_ref.attr_dataoffset;
                if (name_ptr >= record_start && name_ptr < record_end) {
                    const std::size_t max_possible_length =
                        static_cast<std::size_t>(record_end - name_ptr);
                    const std::size_t max_length =
                        std::min<std::size_t>(name_ref.attr_length, max_possible_length);
                    if (name_ref.attr_length > max_possible_length) {
                        record = record_end;
                        continue;
                    }
                    const std::size_t actual_length = strnlen(name_ptr, max_length);
                    if (actual_length < max_length) {
                        name.assign(name_ptr, actual_length);
                    }
                }
            }

            record = record_end;
            if (name.empty()) {
                continue;
            }

            // Hidden = a dot-name OR the macOS UF_HIDDEN flag (what Finder and our properties
            // window set), so a flag-hidden file with a normal name is filtered here too.
            const bool hidden = is_hidden_name(name) || ((bsd_flags & UF_HIDDEN) != 0);
            if (!show_hidden && hidden) {
                continue;
            }

            common::FileEntry entry;
            entry.path = directory_path / name;
            entry.name = std::move(name);
            entry.extension = entry.path.extension().string();
            entry.type = entry_type_from_obj_type(object_type);
            entry.is_hidden = hidden;
            entry.is_symlink = entry.type == common::EntryType::Symlink;
            // A symlink also carries the alias bit on some volumes; only a plain file is an
            // alias in the Finder sense.
            entry.is_alias = is_alias && entry.type == common::EntryType::File;
            entry.size = (entry.type == common::EntryType::File && total_size > 0)
                             ? static_cast<uint64_t>(total_size)
                             : 0;
            // Only a directory has a child count, and only when the volume reported one.
            entry.entry_count = (entry_count_known && entry.type == common::EntryType::Directory)
                                    ? static_cast<int64_t>(entry_count)
                                    : -1;
            if ((returned_attrs.commonattr & ATTR_CMN_MODTIME) != 0) {
                entry.date_modified = to_system_clock_time(modified_time);
            } else if ((returned_attrs.commonattr & ATTR_CMN_CRTIME) != 0) {
                entry.date_modified = to_system_clock_time(created_time);
            } else {
                entry.date_modified = std::chrono::system_clock::time_point{};
            }
            if ((returned_attrs.commonattr & ATTR_CMN_CRTIME) != 0) {
                entry.date_created = to_system_clock_time(created_time);
            } else {
                entry.date_created = entry.date_modified;
            }
            if ((returned_attrs.commonattr & ATTR_CMN_ACCESSMASK) != 0) {
                entry.permissions = permissions_from_access_mask(access_mask);
            } else {
                entry.permissions.clear();
            }
            if ((returned_attrs.commonattr & ATTR_CMN_OWNERID) != 0) {
                entry.owner = resolve_user_name(owner_id, owner_cache, user_lookup_buffer);
            } else {
                entry.owner.clear();
            }
            if ((returned_attrs.commonattr & ATTR_CMN_GRPID) != 0) {
                entry.group = resolve_group_name(group_id, group_cache, group_lookup_buffer);
            } else {
                entry.group.clear();
            }
            entries.push_back(std::move(entry));
        }
    }

    close(dir_fd);
    return entries;
}
#endif

auto wildcard_match(std::string_view pattern, std::string_view text) -> bool {
    std::size_t p = 0;
    std::size_t t = 0;
    std::size_t star = std::string_view::npos;
    std::size_t match = 0;

    while (t < text.size()) {
        if (p < pattern.size() && (pattern[p] == '?' || pattern[p] == text[t])) {
            ++p;
            ++t;
            continue;
        }

        if (p < pattern.size() && pattern[p] == '*') {
            star = p++;
            match = t;
            continue;
        }

        if (star != std::string_view::npos) {
            p = star + 1;
            t = ++match;
            continue;
        }

        return false;
    }

    while (p < pattern.size() && pattern[p] == '*') {
        ++p;
    }

    return p == pattern.size();
}

auto compare_by_field(const common::FileEntry& lhs,
                      const common::FileEntry& rhs,
                      common::SortField field) -> int {
    switch (field) {
        case common::SortField::Name:
            if (lhs.name < rhs.name) return -1;
            if (rhs.name < lhs.name) return 1;
            return 0;
        case common::SortField::Extension:
            if (lhs.extension < rhs.extension) return -1;
            if (rhs.extension < lhs.extension) return 1;
            return 0;
        case common::SortField::Size:
            if (lhs.size < rhs.size) return -1;
            if (rhs.size < lhs.size) return 1;
            return 0;
        case common::SortField::DateModified:
            if (lhs.date_modified < rhs.date_modified) return -1;
            if (rhs.date_modified < lhs.date_modified) return 1;
            return 0;
        case common::SortField::DateCreated:
            if (lhs.date_created < rhs.date_created) return -1;
            if (rhs.date_created < lhs.date_created) return 1;
            return 0;
        case common::SortField::Permissions:
            if (lhs.permissions < rhs.permissions) return -1;
            if (rhs.permissions < lhs.permissions) return 1;
            return 0;
        case common::SortField::Owner:
            if (lhs.owner < rhs.owner) return -1;
            if (rhs.owner < lhs.owner) return 1;
            return 0;
    }

    return 0;
}

}  // namespace

Navigator::Navigator() = default;
Navigator::~Navigator() = default;

auto Navigator::list_directory(std::string_view path, bool show_hidden) const
    -> common::Result<std::vector<common::FileEntry>> {
    const auto validated = validate_directory_path(path);
    if (!validated.has_value()) {
        return validated.error();
    }
    return list_directory_std(validated.value(), show_hidden);
}

auto Navigator::list_directory_fast(std::string_view path, bool show_hidden) const
    -> common::Result<std::vector<common::FileEntry>> {
    const auto validated = validate_directory_path(path);
    if (!validated.has_value()) {
        return validated.error();
    }
    const std::filesystem::path directory_path = validated.value();

#if !defined(__APPLE__)
    return list_directory_std(directory_path, show_hidden);
#else
    const auto fast_result = list_directory_getattrlistbulk(directory_path, show_hidden);
    if (fast_result.has_value()) {
        return fast_result;
    }
    return list_directory_std(directory_path, show_hidden);
#endif
}

auto Navigator::list_directory_names_only(std::string_view path, bool show_hidden) const
    -> common::Result<std::vector<common::FileEntry>> {
    const auto validated = validate_directory_path(path);
    if (!validated.has_value()) {
        return validated.error();
    }
    return list_directory_readdir_only(validated.value(), show_hidden);
}

void Navigator::sort_entries(std::vector<common::FileEntry>& entries,
                             common::SortField field,
                             common::SortDirection direction) const {
    std::sort(entries.begin(), entries.end(), [field, direction](const common::FileEntry& lhs,
                                                                  const common::FileEntry& rhs) {
        const bool lhs_is_dir = lhs.type == common::EntryType::Directory;
        const bool rhs_is_dir = rhs.type == common::EntryType::Directory;
        if (lhs_is_dir != rhs_is_dir) {
            return lhs_is_dir;
        }

        int cmp = compare_by_field(lhs, rhs, field);
        if (cmp == 0) {
            cmp = compare_by_field(lhs, rhs, common::SortField::Name);
        }

        if (direction == common::SortDirection::Ascending) {
            return cmp < 0;
        }
        return cmp > 0;
    });
}

auto Navigator::filter_entries(const std::vector<common::FileEntry>& entries,
                               std::string_view pattern) const -> std::vector<common::FileEntry> {
    if (pattern.empty() || pattern == "*") {
        return entries;
    }

    std::vector<common::FileEntry> filtered;
    filtered.reserve(entries.size());
    for (const common::FileEntry& entry : entries) {
        if (wildcard_match(pattern, entry.name)) {
            filtered.push_back(entry);
        }
    }
    return filtered;
}

auto Navigator::parent_path(std::string_view path) const -> common::Result<std::filesystem::path> {
    if (path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument, "Path cannot be empty");
    }

    return std::filesystem::path(path).parent_path();
}

auto Navigator::home_path() -> std::filesystem::path {
    const char* home = std::getenv("HOME");
    if (home == nullptr || *home == '\0') {
        return root_path();
    }
    return std::filesystem::path(home);
}

auto Navigator::root_path() -> std::filesystem::path {
    return std::filesystem::path("/");
}

auto Navigator::is_valid_directory(std::string_view path) const -> bool {
    if (path.empty()) {
        return false;
    }

    std::error_code ec;
    const bool is_dir = std::filesystem::is_directory(std::filesystem::path(path), ec);
    return !ec && is_dir;
}

auto Navigator::calculate_total_size(const std::vector<common::FileEntry>& entries) const
    -> uint64_t {
    uint64_t total_size = 0;
    for (const common::FileEntry& entry : entries) {
        total_size += entry.size;
    }
    return total_size;
}

}  // namespace fcxl::fs
