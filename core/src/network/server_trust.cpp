#include "fcxl/network/server_trust.h"

#include <curl/curl.h>

namespace fcxl::network {

namespace {

constexpr std::string_view kBase64Alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Длина SHA-256 в байтах и в знаках base64 (43 значащих и один «=»).
constexpr size_t kSha256Bytes = 32;
constexpr size_t kSha256Base64Chars = 44;

auto base64(std::string_view raw) -> std::string {
    std::string out;
    out.reserve((raw.size() + 2) / 3 * 4);
    const auto byte = [&](size_t i) { return static_cast<unsigned char>(raw[i]); };
    size_t i = 0;
    for (; i + 2 < raw.size(); i += 3) {
        const unsigned v = (static_cast<unsigned>(byte(i)) << 16)
                         | (static_cast<unsigned>(byte(i + 1)) << 8)
                         | static_cast<unsigned>(byte(i + 2));
        out.push_back(kBase64Alphabet[(v >> 18) & 0x3F]);
        out.push_back(kBase64Alphabet[(v >> 12) & 0x3F]);
        out.push_back(kBase64Alphabet[(v >> 6) & 0x3F]);
        out.push_back(kBase64Alphabet[v & 0x3F]);
    }
    if (i + 1 == raw.size()) {
        const unsigned v = static_cast<unsigned>(byte(i)) << 16;
        out.push_back(kBase64Alphabet[(v >> 18) & 0x3F]);
        out.push_back(kBase64Alphabet[(v >> 12) & 0x3F]);
        out += "==";
    } else if (i + 2 == raw.size()) {
        const unsigned v = (static_cast<unsigned>(byte(i)) << 16)
                         | (static_cast<unsigned>(byte(i + 1)) << 8);
        out.push_back(kBase64Alphabet[(v >> 18) & 0x3F]);
        out.push_back(kBase64Alphabet[(v >> 12) & 0x3F]);
        out.push_back(kBase64Alphabet[(v >> 6) & 0x3F]);
        out.push_back('=');
    }
    return out;
}

} // namespace

auto judge_server_key(std::string_view presented, std::string_view trusted) -> ServerKeyVerdict {
    if (trusted.empty()) return ServerKeyVerdict::Unknown;
    if (!presented.empty() && presented == trusted) return ServerKeyVerdict::Trusted;
    return ServerKeyVerdict::Changed;
}

auto format_host_key_fingerprint(std::string_view sha256_raw) -> std::string {
    if (sha256_raw.size() != kSha256Bytes) return {};
    auto encoded = base64(sha256_raw);
    while (!encoded.empty() && encoded.back() == '=') encoded.pop_back();
    return "SHA256:" + encoded;
}

auto parse_public_key_pin(std::string_view verbose_line) -> std::string {
    constexpr std::string_view marker = "public key hash: sha256//";
    const auto at = verbose_line.find(marker);
    if (at == std::string_view::npos) return {};
    auto hash = verbose_line.substr(at + marker.size());
    // До конца строки: libcurl завершает её переводом строки.
    const auto end = hash.find_first_of(" \t\r\n");
    if (end != std::string_view::npos) hash = hash.substr(0, end);
    if (hash.size() != kSha256Base64Chars || hash.back() != '=') return {};
    if (hash.substr(0, kSha256Base64Chars - 1).find_first_not_of(kBase64Alphabet)
        != std::string_view::npos) {
        return {};
    }
    return "sha256//" + std::string(hash);
}

auto judge_tls_failure(int curl_code, bool pinned) -> std::optional<ServerKeyVerdict> {
    if (!pinned && curl_code == CURLE_PEER_FAILED_VERIFICATION) return ServerKeyVerdict::Unknown;
    if (pinned && curl_code == CURLE_SSL_PINNEDPUBKEYNOTMATCH) return ServerKeyVerdict::Changed;
    return std::nullopt;
}

} // namespace fcxl::network
