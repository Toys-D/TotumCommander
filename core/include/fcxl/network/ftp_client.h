#pragma once
/// @file ftp_client.h
/// FTP/FTPS client using libcurl.
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
#include "fcxl/common/types.h"

namespace fcxl::network {

struct ConnectionInfo {
    std::string host;
    uint16_t port = 21;
    std::string username;
    std::string password;
    bool use_tls = false;
    bool passive_mode = true;
    int timeout_seconds = 30;
};

/// Progress callback: (bytes_done, bytes_total) → return true to cancel.
using ProgressCallback = std::function<bool(int64_t, int64_t)>;

/// Чем кончился неудачный вход на сервер: код для программы и слова самого сервера.
struct ConnectFailure {
    common::ErrorCode code;
    /// Последний ответ сервера («530 User cannot log in.») — или, если сервер не успел
    /// ничего сказать, объяснение libcurl. Первые три цифры несут смысл и разбираются
    /// выше по течению: 530 — сервер отверг вход, 331 — до пароля дошло, а дальше связь
    /// оборвалась.
    std::string message;
};

/// Разобрать неудачу входа. Вынесено из `connect()` и объявлено здесь, чтобы это можно
/// было проверить тестами, не поднимая сервера.
///
/// @param curl_code   код libcurl (CURLE_LOGIN_DENIED и прочие)
/// @param last_reply  последняя строка управляющего канала, если она была
/// @param fallback    как эту неудачу называет сам libcurl
[[nodiscard]] auto describe_connect_failure(int curl_code, std::string_view last_reply,
                                            std::string_view fallback) -> ConnectFailure;

class FtpClient {
public:
    FtpClient();
    ~FtpClient();

    FtpClient(const FtpClient&) = delete;
    FtpClient& operator=(const FtpClient&) = delete;

    [[nodiscard]] auto connect(const ConnectionInfo& info) -> common::Result<void>;
    void disconnect();
    [[nodiscard]] auto is_connected() const -> bool;

    [[nodiscard]] auto list_directory(std::string_view path)
        -> common::Result<std::vector<common::FileEntry>>;

    /// @param resume_from bytes already transferred — the transfer continues from there
    ///        instead of starting over. Zero starts from the beginning and truncates
    ///        whatever was at the destination.
    ///
    /// A server that refuses to continue answers `ErrorCode::NotSupported`; the caller is
    /// expected to throw the leftovers away and ask again from zero rather than to give up.
    /// Progress is always reported for the WHOLE file, offset included.
    [[nodiscard]] auto download(std::string_view remote, std::string_view local,
                                int64_t resume_from = 0,
                                ProgressCallback progress = nullptr) -> common::Result<void>;
    [[nodiscard]] auto upload(std::string_view local, std::string_view remote,
                              int64_t resume_from = 0,
                              ProgressCallback progress = nullptr) -> common::Result<void>;

    /// Ceiling for every following transfer, in bytes per second; zero lifts it. Set once
    /// per session — a rate that changes mid-file would make the remaining-time estimate
    /// lie, and the user sets this in Settings, not per transfer.
    void set_speed_limits(int64_t download_bytes_per_second, int64_t upload_bytes_per_second);

    [[nodiscard]] auto remove(std::string_view remote) -> common::Result<void>;
    [[nodiscard]] auto remove_directory(std::string_view remote) -> common::Result<void>;
    [[nodiscard]] auto create_directory(std::string_view remote) -> common::Result<void>;
    [[nodiscard]] auto rename(std::string_view from, std::string_view to) -> common::Result<void>;

private:
    struct Impl;
    Impl* impl_ = nullptr;

    auto base_url() const -> std::string;
    auto make_url(std::string_view path) const -> std::string;
};

} // namespace fcxl::network
