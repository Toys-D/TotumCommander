#include "fcxl/filesystem/volume_info.h"

#include <cerrno>
#include <string>
#include <sys/mount.h>

namespace fcxl::fs {
namespace {

auto map_errno_to_error(int err, std::string message, std::string path = "") -> common::Error {
    common::ErrorCode code = common::ErrorCode::IOError;
    switch (err) {
        case ENOENT:
        case ENOTDIR:
            code = common::ErrorCode::NotFound;
            break;
        case EACCES:
        case EPERM:
            code = common::ErrorCode::PermissionDenied;
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

auto volume_name_from_mount_point(const std::filesystem::path& mount_point) -> std::string {
    std::string name = mount_point.filename().string();
    if (!name.empty()) {
        return name;
    }
    if (mount_point == std::filesystem::path("/")) {
        return "/";
    }
    return mount_point.string();
}

auto to_volume_info(const struct statfs& fs_info) -> common::VolumeInfo {
    common::VolumeInfo volume;
    volume.mount_point = std::filesystem::path(fs_info.f_mntonname);
    volume.name = volume_name_from_mount_point(volume.mount_point);
    if (volume.name.empty()) {
        volume.name = std::string(fs_info.f_mntfromname);
    }

    const uint64_t block_size = static_cast<uint64_t>(fs_info.f_bsize);
    volume.total_bytes = static_cast<uint64_t>(fs_info.f_blocks) * block_size;
    volume.free_bytes = static_cast<uint64_t>(fs_info.f_bfree) * block_size;
    volume.available_bytes = static_cast<uint64_t>(fs_info.f_bavail) * block_size;
    volume.filesystem_type = std::string(fs_info.f_fstypename);

    volume.is_readonly = (fs_info.f_flags & MNT_RDONLY) != 0;
#ifdef MNT_REMOVABLE
    volume.is_removable = (fs_info.f_flags & MNT_REMOVABLE) != 0;
#else
    volume.is_removable = false;
#endif

    return volume;
}

}  // namespace

auto VolumeInfoProvider::get_volumes() const -> common::Result<std::vector<common::VolumeInfo>> {
    try {
        struct statfs* mounts = nullptr;
        const int count = ::getmntinfo(&mounts, MNT_NOWAIT);
        if (count <= 0 || mounts == nullptr) {
            return map_errno_to_error(errno, "Failed to enumerate mounted volumes");
        }

        std::vector<common::VolumeInfo> result;
        result.reserve(static_cast<std::size_t>(count));
        for (int index = 0; index < count; ++index) {
            result.push_back(to_volume_info(mounts[index]));
        }

        return result;
    } catch (const std::exception& ex) {
        return common::Error::make(common::ErrorCode::Unknown, ex.what());
    } catch (...) {
        return common::Error::make(common::ErrorCode::Unknown, "Unknown error while listing volumes");
    }
}

auto VolumeInfoProvider::get_volume_for_path(std::string_view path) const
    -> common::Result<common::VolumeInfo> {
    try {
        if (path.empty()) {
            return common::Error::make(common::ErrorCode::InvalidArgument, "Path cannot be empty");
        }

        struct statfs fs_info = {};
        const std::string path_string(path);
        if (::statfs(path_string.c_str(), &fs_info) != 0) {
            return map_errno_to_error(errno, "Failed to get volume for path", path_string);
        }

        return to_volume_info(fs_info);
    } catch (const std::exception& ex) {
        return common::Error::make(common::ErrorCode::Unknown, ex.what(), std::string(path));
    } catch (...) {
        return common::Error::make(common::ErrorCode::Unknown,
                                   "Unknown error while getting volume for path",
                                   std::string(path));
    }
}

}  // namespace fcxl::fs
