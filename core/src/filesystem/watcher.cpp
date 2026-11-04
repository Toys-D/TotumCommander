#include "fcxl/filesystem/watcher.h"

#include <CoreServices/CoreServices.h>

#include <atomic>
#include <filesystem>
#include <future>
#include <mutex>
#include <string>
#include <system_error>
#include <thread>

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

auto map_flags_to_event(FSEventStreamEventFlags flags) -> WatchEvent {
    if ((flags & kFSEventStreamEventFlagItemRemoved) != 0) {
        return WatchEvent::Deleted;
    }
    if ((flags & kFSEventStreamEventFlagItemRenamed) != 0) {
        return WatchEvent::Renamed;
    }
    if ((flags & kFSEventStreamEventFlagItemCreated) != 0) {
        return WatchEvent::Created;
    }
    return WatchEvent::Modified;
}

}  // namespace

struct Watcher::Impl {
    std::atomic<bool> watching{false};
    std::mutex mutex;
    std::thread worker;
    FSEventStreamRef stream = nullptr;
    CFRunLoopRef run_loop = nullptr;
    WatchCallback callback;
    std::filesystem::path watched_path;

    ~Impl() { stop(); }

    [[nodiscard]] auto watch(std::string_view path, WatchCallback cb) -> common::Result<void> {
        if (path.empty()) {
            return common::Error::make(common::ErrorCode::InvalidArgument, "Path cannot be empty");
        }
        if (!cb) {
            return common::Error::make(common::ErrorCode::InvalidArgument,
                                       "Callback cannot be empty");
        }
        if (watching.load()) {
            return common::Error::make(common::ErrorCode::AlreadyExists,
                                       "Watcher is already running");
        }

        std::error_code ec;
        const std::filesystem::path fs_path(path);
        const bool exists = std::filesystem::exists(fs_path, ec);
        if (ec) {
            return map_error_code(ec, "Failed to check watched path existence", fs_path);
        }
        if (!exists) {
            return common::Error::make(common::ErrorCode::NotFound,
                                       "Watched path does not exist",
                                       fs_path.string());
        }
        if (!std::filesystem::is_directory(fs_path, ec)) {
            if (ec) {
                return map_error_code(ec, "Failed to inspect watched path type", fs_path);
            }
            return common::Error::make(common::ErrorCode::NotADirectory,
                                       "Watched path is not a directory",
                                       fs_path.string());
        }

        {
            std::lock_guard<std::mutex> lock(mutex);
            watched_path = fs_path;
            callback = std::move(cb);
        }

        std::promise<common::Result<void>> start_promise;
        std::future<common::Result<void>> start_future = start_promise.get_future();
        try {
            worker = std::thread(&Impl::run_worker, this, std::move(start_promise));
        } catch (const std::system_error& ex) {
            {
                std::lock_guard<std::mutex> lock(mutex);
                callback = nullptr;
                watched_path.clear();
            }
            return common::Error::make(common::ErrorCode::IOError, ex.what(), fs_path.string());
        }

        common::Result<void> start_result = start_future.get();
        if (!start_result.has_value()) {
            if (worker.joinable()) {
                worker.join();
            }
            std::lock_guard<std::mutex> lock(mutex);
            callback = nullptr;
            watched_path.clear();
        }
        return start_result;
    }

    void stop() {
        CFRunLoopRef run_loop_to_stop = nullptr;
        {
            std::lock_guard<std::mutex> lock(mutex);
            run_loop_to_stop = run_loop;
            if (run_loop_to_stop != nullptr) {
                CFRetain(run_loop_to_stop);
            }
        }

        if (run_loop_to_stop != nullptr) {
            CFRunLoopStop(run_loop_to_stop);
            CFRelease(run_loop_to_stop);
        }

        if (worker.joinable() && worker.get_id() != std::this_thread::get_id()) {
            worker.join();
        }

        watching.store(false);
        std::lock_guard<std::mutex> lock(mutex);
        callback = nullptr;
        watched_path.clear();
    }

    [[nodiscard]] auto is_watching() const -> bool { return watching.load(); }

    static void stream_callback(ConstFSEventStreamRef stream_ref,
                                void* client_callback_info,
                                size_t num_events,
                                void* event_paths,
                                const FSEventStreamEventFlags event_flags[],
                                const FSEventStreamEventId event_ids[]) {
        (void)stream_ref;
        (void)event_ids;

        auto* impl = static_cast<Impl*>(client_callback_info);
        if (impl == nullptr) {
            return;
        }

        impl->handle_events(num_events, event_paths, event_flags);
    }

    void run_worker(std::promise<common::Result<void>> start_promise) {
        const std::string watched_path_string = watched_path.string();
        CFStringRef path_ref =
            CFStringCreateWithCString(kCFAllocatorDefault,
                                      watched_path_string.c_str(),
                                      kCFStringEncodingUTF8);
        if (path_ref == nullptr) {
            start_promise.set_value(common::Error::make(common::ErrorCode::InvalidArgument,
                                                        "Failed to convert watched path to CFString",
                                                        watched_path_string));
            return;
        }

        const void* paths[] = {path_ref};
        CFArrayRef watched_paths =
            CFArrayCreate(kCFAllocatorDefault, paths, 1, &kCFTypeArrayCallBacks);
        CFRelease(path_ref);
        if (watched_paths == nullptr) {
            start_promise.set_value(common::Error::make(common::ErrorCode::IOError,
                                                        "Failed to create watched path array",
                                                        watched_path_string));
            return;
        }

        FSEventStreamContext context;
        context.version = 0;
        context.info = this;
        context.retain = nullptr;
        context.release = nullptr;
        context.copyDescription = nullptr;

        const FSEventStreamCreateFlags flags =
            kFSEventStreamCreateFlagFileEvents;

        FSEventStreamRef created_stream = FSEventStreamCreate(kCFAllocatorDefault,
                                                              &Impl::stream_callback,
                                                              &context,
                                                              watched_paths,
                                                              kFSEventStreamEventIdSinceNow,
                                                              0.3,
                                                              flags);
        CFRelease(watched_paths);

        if (created_stream == nullptr) {
            start_promise.set_value(common::Error::make(common::ErrorCode::IOError,
                                                        "Failed to create FSEvent stream",
                                                        watched_path_string));
            return;
        }

        CFRunLoopRef current_run_loop = CFRunLoopGetCurrent();
        if (current_run_loop == nullptr) {
            FSEventStreamRelease(created_stream);
            start_promise.set_value(common::Error::make(common::ErrorCode::IOError,
                                                        "Failed to get current run loop",
                                                        watched_path_string));
            return;
        }

        CFRetain(current_run_loop);
        {
            std::lock_guard<std::mutex> lock(mutex);
            stream = created_stream;
            run_loop = current_run_loop;
        }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        FSEventStreamScheduleWithRunLoop(created_stream, current_run_loop, kCFRunLoopDefaultMode);
#pragma clang diagnostic pop
        if (!FSEventStreamStart(created_stream)) {
            FSEventStreamInvalidate(created_stream);
            FSEventStreamRelease(created_stream);
            {
                std::lock_guard<std::mutex> lock(mutex);
                stream = nullptr;
                run_loop = nullptr;
            }
            CFRelease(current_run_loop);
            start_promise.set_value(common::Error::make(common::ErrorCode::IOError,
                                                        "Failed to start FSEvent stream",
                                                        watched_path_string));
            return;
        }

        watching.store(true);
        start_promise.set_value(common::Result<void>());

        CFRunLoopRun();

        FSEventStreamStop(created_stream);
        FSEventStreamInvalidate(created_stream);
        FSEventStreamRelease(created_stream);

        {
            std::lock_guard<std::mutex> lock(mutex);
            stream = nullptr;
            if (run_loop != nullptr) {
                CFRelease(run_loop);
                run_loop = nullptr;
            }
        }
        watching.store(false);
    }

    void handle_events(size_t num_events, void* event_paths, const FSEventStreamEventFlags* event_flags) {
        WatchCallback callback_copy;
        {
            std::lock_guard<std::mutex> lock(mutex);
            callback_copy = callback;
        }

        if (!callback_copy || event_paths == nullptr || event_flags == nullptr) {
            return;
        }

        auto** paths = static_cast<char**>(event_paths);
        for (size_t index = 0; index < num_events; ++index) {
            const char* raw_path = paths[index];
            if (raw_path == nullptr) {
                continue;
            }
            callback_copy(std::filesystem::path(raw_path), map_flags_to_event(event_flags[index]));
        }
    }
};

Watcher::Watcher() : impl_(std::make_unique<Impl>()) {}
Watcher::~Watcher() = default;

auto Watcher::watch(std::string_view path, WatchCallback callback) -> common::Result<void> {
    try {
        return impl_->watch(path, std::move(callback));
    } catch (const std::exception& ex) {
        return common::Error::make(common::ErrorCode::Unknown, ex.what(), std::string(path));
    } catch (...) {
        return common::Error::make(common::ErrorCode::Unknown,
                                   "Unknown watcher error",
                                   std::string(path));
    }
}

void Watcher::stop() { impl_->stop(); }

auto Watcher::is_watching() const -> bool { return impl_->is_watching(); }

}  // namespace fcxl::fs
