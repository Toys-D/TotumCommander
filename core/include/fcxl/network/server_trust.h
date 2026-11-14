#pragma once
/// @file server_trust.h
/// Тот ли это сервер. Ключ узла SSH и открытый ключ сертификата TLS сверяются с тем, чему
/// человек уже доверился; пока ответа нет, серверу не говорят ни имени, ни пароля.
/// Общее для SFTP и FTPS.
#include <optional>
#include <string>
#include <string_view>

namespace fcxl::network {

/// Как предъявленный сервером ключ соотносится с известным.
enum class ServerKeyVerdict {
    Trusted,   ///< тот же, что человек уже подтвердил
    Unknown,   ///< об этом сервере ещё ничего не известно
    Changed,   ///< другой: сервер переустановили — или отвечает не он
};

/// Что сервер предъявил, когда подключение было остановлено из-за ключа.
struct ServerKeyReport {
    ServerKeyVerdict verdict = ServerKeyVerdict::Unknown;
    /// SFTP: «SHA256:…», как печатает `ssh-keygen -l`. FTPS: «sha256//…», как ждёт libcurl.
    /// В этом же виде отпечаток запоминается и возвращается сюда при следующем подключении.
    std::string fingerprint;
    /// SFTP: «ED25519», «RSA», «ECDSA», «DSA». У FTPS пусто.
    std::string key_type;
    /// FTPS: почему сертификат не прошёл обычную проверку. У SFTP пусто.
    std::string reason;
};

/// Сверить предъявленный ключ с доверенным. Пустой доверенный — сервер ещё не знаком;
/// пустой предъявленный доверенным не бывает никогда.
[[nodiscard]] auto judge_server_key(std::string_view presented, std::string_view trusted)
    -> ServerKeyVerdict;

/// Отпечаток ключа узла SSH из сырого хеша SHA-256 (32 байта): «SHA256:» и base64 без
/// хвостовых «=». Хеш другой длины отпечатка не даёт.
[[nodiscard]] auto format_host_key_fingerprint(std::string_view sha256_raw) -> std::string;

/// Достать привязку «sha256//…» из строки подробного вывода libcurl
/// (« public key hash: sha256//…»). Пусто — в строке её нет.
[[nodiscard]] auto parse_public_key_pin(std::string_view verbose_line) -> std::string;

/// Говорит ли отказ libcurl о ключе сервера. Проверка сертификата не прошла, а привязки ещё
/// нет — сервер не знаком; привязка есть и не совпала — ключ изменился. Остальное к ключу
/// отношения не имеет.
[[nodiscard]] auto judge_tls_failure(int curl_code, bool pinned)
    -> std::optional<ServerKeyVerdict>;

} // namespace fcxl::network
