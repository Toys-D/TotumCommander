#pragma once
/// @file sftp_client.h
/// SFTP client using libssh2.
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
#include "fcxl/common/types.h"

namespace fcxl::network {

struct SftpConnectionInfo {
    std::string host;
    uint16_t port = 22;
    std::string username;
    std::string password;
    std::string private_key_path;
    int timeout_seconds = 30;
};

using ProgressCallback = std::function<bool(int64_t, int64_t)>;

class SftpClient {
public:
    SftpClient();
    ~SftpClient();

    SftpClient(const SftpClient&) = delete;
    SftpClient& operator=(const SftpClient&) = delete;

    [[nodiscard]] auto connect(const SftpConnectionInfo& info) -> common::Result<void>;
    void disconnect();
    [[nodiscard]] auto is_connected() const -> bool;

    [[nodiscard]] auto list_directory(std::string_view path)
        -> common::Result<std::vector<common::FileEntry>>;

    /// @param resume_from bytes already at the destination; the transfer continues from
    ///        there. Zero starts over and truncates. `ErrorCode::NotSupported` comes back
    ///        when continuing makes no sense — the far side is shorter than the offset —
    ///        and the caller is expected to start from zero instead.
    /// Progress is always about the whole file, offset included.
    [[nodiscard]] auto download(std::string_view remote, std::string_view local,
                                int64_t resume_from = 0,
                                ProgressCallback progress = nullptr) -> common::Result<void>;
    [[nodiscard]] auto upload(std::string_view local, std::string_view remote,
                              int64_t resume_from = 0,
                              ProgressCallback progress = nullptr) -> common::Result<void>;

    /// Ceiling for every following transfer, in bytes per second; zero lifts it. libssh2
    /// has no throttle of its own, so this one is paced by hand between blocks.
    void set_speed_limits(int64_t download_bytes_per_second, int64_t upload_bytes_per_second);

    [[nodiscard]] auto remove(std::string_view remote) -> common::Result<void>;
    [[nodiscard]] auto remove_directory(std::string_view remote) -> common::Result<void>;
    [[nodiscard]] auto create_directory(std::string_view remote) -> common::Result<void>;
    [[nodiscard]] auto rename(std::string_view from, std::string_view to) -> common::Result<void>;

private:
    struct Impl;
    Impl* impl_ = nullptr;
};

} // namespace fcxl::network
