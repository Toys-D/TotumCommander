#include "fcxl/filesystem/operations.h"

#include <cstdlib>
#include <string>
#include <system_error>

#include <sys/clonefile.h>
#include <copyfile.h>
#include <removefile.h>
#include <errno.h>

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
        case std::errc::no_space_on_device:
            code = common::ErrorCode::DiskFull;
            break;
        default:
            code = common::ErrorCode::IOError;
            break;
    }

    return common::Error::make(code, std::move(message), path.string());
}

auto path_exists(const std::filesystem::path& path, std::error_code& ec) -> bool {
    ec.clear();
    return std::filesystem::exists(path, ec);
}

auto make_unique_path(const std::filesystem::path& path) -> common::Result<std::filesystem::path> {
    std::error_code ec;
    if (!path_exists(path, ec)) {
        if (ec) {
            return map_error_code(ec, "Failed to check path existence", path);
        }
        return path;
    }

    const std::filesystem::path parent = path.parent_path();
    const std::string stem = path.stem().string();
    const std::string extension = path.extension().string();
    const bool has_extension = !extension.empty() && path.has_extension();

    for (int index = 1; index <= 10000; ++index) {
        const std::string numbered =
            has_extension ? (stem + " (" + std::to_string(index) + ")" + extension)
                          : (path.filename().string() + " (" + std::to_string(index) + ")");
        const std::filesystem::path candidate = parent / numbered;
        if (!path_exists(candidate, ec)) {
            if (ec) {
                return map_error_code(ec, "Failed to check path existence", candidate);
            }
            return candidate;
        }
    }

    return common::Error::make(common::ErrorCode::AlreadyExists,
                               "Unable to generate unique destination path",
                               path.string());
}

auto resolve_conflict(const std::filesystem::path& destination,
                      common::ConflictResolution on_conflict) -> common::Result<std::filesystem::path> {
    std::error_code ec;
    if (!path_exists(destination, ec)) {
        if (ec) {
            return map_error_code(ec, "Failed to check destination existence", destination);
        }
        return destination;
    }

    switch (on_conflict) {
        case common::ConflictResolution::Skip:
        case common::ConflictResolution::Ask:
            return common::Error::make(common::ErrorCode::AlreadyExists,
                                       "Destination already exists",
                                       destination.string());
        case common::ConflictResolution::Overwrite: {
            std::filesystem::remove_all(destination, ec);
            if (ec) {
                return map_error_code(ec, "Failed to remove destination", destination);
            }
            return destination;
        }
        case common::ConflictResolution::Rename:
            return make_unique_path(destination);
    }

    return common::Error::make(common::ErrorCode::Unknown,
                               "Unsupported conflict resolution",
                               destination.string());
}

// Attempts an APFS Copy-on-Write clone via clonefile(2).
// Falls back to std::filesystem copy on non-APFS volumes or when clonefile is unavailable.
[[maybe_unused]]
auto copy_with_clonefile(const std::filesystem::path& source,
                         const std::filesystem::path& destination,
                         bool is_directory) -> common::Result<void> {
    // clonefile(2) requires destination to not exist.
    // resolve_conflict() already removed or avoided any conflict, so this is safe.
    const int ret = ::clonefile(source.c_str(), destination.c_str(), CLONE_NOOWNERCOPY);
    if (ret == 0) {
        return common::Result<void>();  // Instant CoW clone succeeded
    }

    // clonefile failed (ENOTSUP on HFS+/FAT/network, EEXIST if dst appeared, etc.)
    // Fall back to standard copy.
    std::error_code ec;
    if (is_directory) {
        std::filesystem::copy(source, destination, std::filesystem::copy_options::recursive, ec);
    } else {
        std::filesystem::copy_file(source, destination, std::filesystem::copy_options::none, ec);
    }
    if (ec) {
        return map_error_code(ec, "Copy operation failed", source);
    }
    return common::Result<void>();
}

auto move_to_trash_fallback(const std::filesystem::path& source) -> common::Result<void> {
    const char* home = std::getenv("HOME");
    if (home == nullptr || *home == '\0') {
        return common::Error::make(common::ErrorCode::IOError, "HOME environment variable is not set");
    }

    std::error_code ec;
    const std::filesystem::path trash_directory = std::filesystem::path(home) / ".Trash";
    std::filesystem::create_directories(trash_directory, ec);
    if (ec) {
        return map_error_code(ec, "Failed to create trash directory", trash_directory);
    }

    auto candidate_result = make_unique_path(trash_directory / source.filename());
    if (!candidate_result.has_value()) {
        return candidate_result.error();
    }

    std::filesystem::rename(source, candidate_result.value(), ec);
    if (ec) {
        return map_error_code(ec, "Failed to move file to trash", source);
    }
    return common::Result<void>();
}

// Callback context for copyfile progress reporting.
struct CopyCallbackContext {
    ProgressCallback* cb;
    std::string src;
    std::string dst;
};

// Static callback for copyfile — reports progress and supports cancellation.
int copyfile_status_callback(int /*what*/, int stage, copyfile_state_t s,
                             const char* /*src*/, const char* /*dst*/, void* raw_ctx) {
    auto* c = static_cast<CopyCallbackContext*>(raw_ctx);
    if (!c || !c->cb) return COPYFILE_CONTINUE;

    if (stage == COPYFILE_PROGRESS) {
        common::OperationProgress p;
        p.type = common::OperationType::Copy;
        p.source = c->src;
        p.destination = c->dst;
        off_t bytes_copied = 0;
        copyfile_state_get(s, COPYFILE_STATE_COPIED, &bytes_copied);
        p.bytes_done = static_cast<uint64_t>(bytes_copied);
        if (!(*c->cb)(p)) {
            return COPYFILE_QUIT;
        }
    }

    return COPYFILE_CONTINUE;
}

// Callback context for removefile progress/cancellation.
struct RemoveCallbackContext {
    ProgressCallback* cb;
    std::string base_path;
};

// Static callback for removefile — reports progress and supports cancellation.
int removefile_confirm_callback(removefile_state_t /*state*/, const char* rm_path, void* raw_ctx) {
    auto* c = static_cast<RemoveCallbackContext*>(raw_ctx);
    if (!c || !c->cb) return REMOVEFILE_PROCEED;

    common::OperationProgress p;
    p.type = common::OperationType::Delete;
    p.source = rm_path ? rm_path : "";
    return (*c->cb)(p) ? REMOVEFILE_PROCEED : REMOVEFILE_SKIP;
}

}  // namespace

Operations::Operations() = default;
Operations::~Operations() = default;

auto Operations::copy(std::string_view source,
                      std::string_view destination,
                      common::ConflictResolution on_conflict,
                      ProgressCallback progress_cb) -> common::Result<void> {
    if (source.empty() || destination.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Source and destination cannot be empty");
    }

    std::error_code ec;
    const std::filesystem::path source_path(source);
    const std::filesystem::path destination_path(destination);

    if (!path_exists(source_path, ec)) {
        if (ec) {
            return map_error_code(ec, "Failed to check source existence", source_path);
        }
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Source does not exist",
                                   source_path.string());
    }

    auto destination_result = resolve_conflict(destination_path, on_conflict);
    if (!destination_result.has_value()) {
        return destination_result.error();
    }
    const std::filesystem::path final_destination = destination_result.value();

    // Try instant APFS clone first.
    if (::clonefile(source_path.c_str(), final_destination.c_str(), CLONE_NOOWNERCOPY) == 0) {
        if (progress_cb) {
            common::OperationProgress p;
            p.type = common::OperationType::Copy;
            p.source = source_path.string();
            p.destination = final_destination.string();
            p.bytes_done = p.bytes_total;
            progress_cb(p);
        }
        return common::Result<void>();
    }

    // clonefile failed — use copyfile() with progress callback support.
    auto state = copyfile_state_alloc();
    if (!state) {
        return common::Error::make(common::ErrorCode::IOError, "Failed to allocate copyfile state");
    }

    // Heap-allocated context — safe even if API were async.
    auto ctx = std::make_unique<CopyCallbackContext>();
    ctx->cb = progress_cb ? &progress_cb : nullptr;
    ctx->src = source_path.string();
    ctx->dst = final_destination.string();

    if (progress_cb) {
        copyfile_state_set(state, COPYFILE_STATE_STATUS_CTX, ctx.get());
        copyfile_state_set(state, COPYFILE_STATE_STATUS_CB,
                           reinterpret_cast<void*>(&copyfile_status_callback));
    }

    copyfile_flags_t flags = COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW;
    const int ret = copyfile(source_path.c_str(), final_destination.c_str(), state, flags);
    const int saved_errno = errno;
    copyfile_state_free(state);

    if (ret != 0) {
        if (saved_errno == ECANCELED) {
            return common::Error::make(common::ErrorCode::IOError, "Copy cancelled by user", source_path.string());
        }
        return common::Error::make(common::ErrorCode::IOError,
                                   std::string("Copy failed: ") + strerror(saved_errno),
                                   source_path.string());
    }

    return common::Result<void>();
}

auto Operations::move(std::string_view source,
                      std::string_view destination,
                      common::ConflictResolution on_conflict,
                      ProgressCallback progress_cb) -> common::Result<void> {
    if (source.empty() || destination.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Source and destination cannot be empty");
    }

    std::error_code ec;
    const std::filesystem::path source_path(source);
    const std::filesystem::path destination_path(destination);

    if (!path_exists(source_path, ec)) {
        if (ec) {
            return map_error_code(ec, "Failed to check source existence", source_path);
        }
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Source does not exist",
                                   source_path.string());
    }

    auto destination_result = resolve_conflict(destination_path, on_conflict);
    if (!destination_result.has_value()) {
        return destination_result.error();
    }
    const std::filesystem::path final_destination = destination_result.value();

    // rename() is O(1) on same volume — instant for any size.
    std::filesystem::rename(source_path, final_destination, ec);
    if (!ec) {
        return common::Result<void>();
    }

    if (static_cast<std::errc>(ec.value()) != std::errc::cross_device_link) {
        return map_error_code(ec, "Move operation failed", source_path);
    }

    // Cross-volume: copy with progress, then remove source with removefile().
    auto copy_result = copy(source, final_destination.string(), common::ConflictResolution::Skip, progress_cb);
    if (!copy_result.has_value()) {
        return copy_result.error();
    }

    // Use removefile() for fast recursive removal instead of std::filesystem::remove_all.
    const int rm_result = removefile(source_path.c_str(), nullptr, REMOVEFILE_RECURSIVE);
    if (rm_result != 0) {
        return common::Error::make(common::ErrorCode::IOError,
                                   std::string("Failed to remove source after move: ") + strerror(errno),
                                   source_path.string());
    }

    return common::Result<void>();
}

auto Operations::trash(std::string_view path) -> common::Result<void> {
    if (path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument, "Path cannot be empty");
    }

    std::error_code ec;
    const std::filesystem::path source_path(path);
    if (!path_exists(source_path, ec)) {
        if (ec) {
            return map_error_code(ec, "Failed to check path existence", source_path);
        }
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Path does not exist",
                                   source_path.string());
    }

    // Direct rename to ~/.Trash — O(1) on same volume, no osascript overhead.
    return move_to_trash_fallback(source_path);
}

auto Operations::remove(std::string_view path,
                        bool recursive,
                        ProgressCallback progress_cb) -> common::Result<void> {
    if (path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument, "Path cannot be empty");
    }

    std::error_code ec;
    const std::filesystem::path target_path(path);
    if (!path_exists(target_path, ec)) {
        if (ec) {
            return map_error_code(ec, "Failed to check path existence", target_path);
        }
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Path does not exist",
                                   target_path.string());
    }

    const bool is_directory = std::filesystem::is_directory(target_path, ec);
    if (ec) {
        return map_error_code(ec, "Failed to inspect path type", target_path);
    }

    if (is_directory && recursive) {
        // Use removefile() — fast recursive deletion with cancellation support.
        auto rm_state = removefile_state_alloc();
        if (!rm_state) {
            return common::Error::make(common::ErrorCode::IOError,
                                       "Failed to allocate removefile state",
                                       target_path.string());
        }

        // Heap-allocated context — safe even if API were async.
        auto ctx = std::make_unique<RemoveCallbackContext>();
        ctx->cb = progress_cb ? &progress_cb : nullptr;
        ctx->base_path = target_path.string();

        if (progress_cb) {
            removefile_state_set(rm_state, REMOVEFILE_STATE_CONFIRM_CONTEXT, ctx.get());
            removefile_state_set(rm_state, REMOVEFILE_STATE_CONFIRM_CALLBACK,
                                 reinterpret_cast<void*>(&removefile_confirm_callback));
        }

        removefile_flags_t flags = REMOVEFILE_RECURSIVE;
        if (progress_cb) {
            flags |= REMOVEFILE_STATE_CONFIRM_CALLBACK;
        }

        const int result = removefile(target_path.c_str(), rm_state, flags);
        const int saved_errno = errno;
        removefile_state_free(rm_state);

        if (result != 0) {
            return common::Error::make(common::ErrorCode::IOError,
                                       std::string("Remove failed: ") + strerror(saved_errno),
                                       target_path.string());
        }
    } else {
        std::filesystem::remove(target_path, ec);
    }
    if (ec) {
        return map_error_code(ec, "Remove operation failed", target_path);
    }

    return common::Result<void>();
}

auto Operations::rename(std::string_view path, std::string_view new_name) -> common::Result<void> {
    if (path.empty() || new_name.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Path and new_name cannot be empty");
    }

    std::error_code ec;
    const std::filesystem::path source_path(path);
    if (!path_exists(source_path, ec)) {
        if (ec) {
            return map_error_code(ec, "Failed to check source existence", source_path);
        }
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Path does not exist",
                                   source_path.string());
    }

    const std::filesystem::path destination_path = source_path.parent_path() / std::string(new_name);
    if (path_exists(destination_path, ec)) {
        if (ec) {
            return map_error_code(ec, "Failed to check destination existence", destination_path);
        }
        return common::Error::make(common::ErrorCode::AlreadyExists,
                                   "Destination already exists",
                                   destination_path.string());
    }
    if (ec) {
        return map_error_code(ec, "Failed to check destination existence", destination_path);
    }

    std::filesystem::rename(source_path, destination_path, ec);
    if (ec) {
        return map_error_code(ec, "Rename operation failed", source_path);
    }

    return common::Result<void>();
}

auto Operations::create_directory(std::string_view path) -> common::Result<void> {
    if (path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument, "Path cannot be empty");
    }

    std::error_code ec;
    const std::filesystem::path directory_path(path);
    const bool created = std::filesystem::create_directory(directory_path, ec);
    if (ec) {
        return map_error_code(ec, "Failed to create directory", directory_path);
    }
    if (!created) {
        return common::Error::make(common::ErrorCode::AlreadyExists,
                                   "Directory already exists",
                                   directory_path.string());
    }

    return common::Result<void>();
}

auto Operations::create_directories(std::string_view path) -> common::Result<void> {
    if (path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument, "Path cannot be empty");
    }

    std::error_code ec;
    const std::filesystem::path directory_path(path);
    std::filesystem::create_directories(directory_path, ec);
    if (ec) {
        return map_error_code(ec, "Failed to create directories", directory_path);
    }

    return common::Result<void>();
}

}  // namespace fcxl::fs
