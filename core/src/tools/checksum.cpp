#include "fcxl/tools/checksum.h"

// MD5 is deprecated on macOS 10.15+ but we need it for checksum verification (non-security use)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#include <CommonCrypto/CommonDigest.h>

#include <array>
#include <cerrno>
#include <cstdio>
#include <iomanip>
#include <sstream>
#include <string>

namespace fcxl::tools {
namespace {

constexpr std::size_t kBufferSize = 65536;  // 64 KB read buffer

auto errno_to_error(const std::string& path) -> common::Error {
    switch (errno) {
        case ENOENT:
            return common::Error::make(common::ErrorCode::NotFound, "File not found", path);
        case EACCES:
        case EPERM:
            return common::Error::make(common::ErrorCode::PermissionDenied, "Permission denied", path);
        default:
            return common::Error::make(common::ErrorCode::IOError, "Failed to read file", path);
    }
}

auto bytes_to_hex(const unsigned char* data, std::size_t length) -> std::string {
    std::ostringstream oss;
    oss << std::hex << std::setfill('0');
    for (std::size_t i = 0; i < length; ++i) {
        oss << std::setw(2) << static_cast<unsigned int>(data[i]);
    }
    return oss.str();
}

}  // namespace

auto Checksum::md5(std::string_view path) const -> common::Result<std::string> {
    const std::string path_str(path);
    FILE* file = std::fopen(path_str.c_str(), "rb");
    if (file == nullptr) {
        return errno_to_error(path_str);
    }

    CC_MD5_CTX ctx;
    CC_MD5_Init(&ctx);

    std::array<unsigned char, kBufferSize> buffer{};
    std::size_t bytes_read = 0;
    while ((bytes_read = std::fread(buffer.data(), 1, buffer.size(), file)) > 0) {
        CC_MD5_Update(&ctx, buffer.data(), static_cast<CC_LONG>(bytes_read));
    }

    const bool read_error = std::ferror(file) != 0;
    std::fclose(file);

    if (read_error) {
        return common::Error::make(common::ErrorCode::IOError, "Read error during MD5", path_str);
    }

    std::array<unsigned char, CC_MD5_DIGEST_LENGTH> digest{};
    CC_MD5_Final(digest.data(), &ctx);

    return bytes_to_hex(digest.data(), digest.size());
}

auto Checksum::sha1(std::string_view path) const -> common::Result<std::string> {
    const std::string path_str(path);
    FILE* file = std::fopen(path_str.c_str(), "rb");
    if (file == nullptr) {
        return errno_to_error(path_str);
    }

    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);

    std::array<unsigned char, kBufferSize> buffer{};
    std::size_t bytes_read = 0;
    while ((bytes_read = std::fread(buffer.data(), 1, buffer.size(), file)) > 0) {
        CC_SHA1_Update(&ctx, buffer.data(), static_cast<CC_LONG>(bytes_read));
    }

    const bool read_error = std::ferror(file) != 0;
    std::fclose(file);

    if (read_error) {
        return common::Error::make(common::ErrorCode::IOError, "Read error during SHA1", path_str);
    }

    std::array<unsigned char, CC_SHA1_DIGEST_LENGTH> digest{};
    CC_SHA1_Final(digest.data(), &ctx);

    return bytes_to_hex(digest.data(), digest.size());
}

auto Checksum::sha256(std::string_view path) const -> common::Result<std::string> {
    const std::string path_str(path);
    FILE* file = std::fopen(path_str.c_str(), "rb");
    if (file == nullptr) {
        return errno_to_error(path_str);
    }

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);

    std::array<unsigned char, kBufferSize> buffer{};
    std::size_t bytes_read = 0;
    while ((bytes_read = std::fread(buffer.data(), 1, buffer.size(), file)) > 0) {
        CC_SHA256_Update(&ctx, buffer.data(), static_cast<CC_LONG>(bytes_read));
    }

    const bool read_error = std::ferror(file) != 0;
    std::fclose(file);

    if (read_error) {
        return common::Error::make(common::ErrorCode::IOError, "Read error during SHA256", path_str);
    }

    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest{};
    CC_SHA256_Final(digest.data(), &ctx);

    return bytes_to_hex(digest.data(), digest.size());
}

auto Checksum::compute_all(std::string_view path) const -> common::Result<common::ChecksumResult> {
    const std::string path_str(path);
    FILE* file = std::fopen(path_str.c_str(), "rb");
    if (file == nullptr) {
        return errno_to_error(path_str);
    }

    CC_MD5_CTX md5_ctx;
    CC_SHA1_CTX sha1_ctx;
    CC_SHA256_CTX sha256_ctx;
    CC_MD5_Init(&md5_ctx);
    CC_SHA1_Init(&sha1_ctx);
    CC_SHA256_Init(&sha256_ctx);

    std::array<unsigned char, kBufferSize> buffer{};
    std::size_t bytes_read = 0;
    while ((bytes_read = std::fread(buffer.data(), 1, buffer.size(), file)) > 0) {
        const auto len = static_cast<CC_LONG>(bytes_read);
        CC_MD5_Update(&md5_ctx, buffer.data(), len);
        CC_SHA1_Update(&sha1_ctx, buffer.data(), len);
        CC_SHA256_Update(&sha256_ctx, buffer.data(), len);
    }

    const bool read_error = std::ferror(file) != 0;
    std::fclose(file);

    if (read_error) {
        return common::Error::make(common::ErrorCode::IOError, "Read error during checksum", path_str);
    }

    std::array<unsigned char, CC_MD5_DIGEST_LENGTH> md5_digest{};
    std::array<unsigned char, CC_SHA1_DIGEST_LENGTH> sha1_digest{};
    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> sha256_digest{};
    CC_MD5_Final(md5_digest.data(), &md5_ctx);
    CC_SHA1_Final(sha1_digest.data(), &sha1_ctx);
    CC_SHA256_Final(sha256_digest.data(), &sha256_ctx);

    common::ChecksumResult result;
    result.md5 = bytes_to_hex(md5_digest.data(), md5_digest.size());
    result.sha1 = bytes_to_hex(sha1_digest.data(), sha1_digest.size());
    result.sha256 = bytes_to_hex(sha256_digest.data(), sha256_digest.size());

    return result;
}

auto Checksum::verify(std::string_view path, std::string_view expected_hash) const
    -> common::Result<bool> {
    const auto len = expected_hash.size();
    common::Result<std::string> computed = common::Error::make(common::ErrorCode::InvalidArgument,
                                                                "Unrecognized hash length");

    if (len == CC_MD5_DIGEST_LENGTH * 2) {
        computed = md5(path);
    } else if (len == CC_SHA1_DIGEST_LENGTH * 2) {
        computed = sha1(path);
    } else if (len == CC_SHA256_DIGEST_LENGTH * 2) {
        computed = sha256(path);
    } else {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Hash length does not match MD5 (32), SHA-1 (40), or SHA-256 (64)");
    }

    if (!computed.has_value()) {
        return computed.error();
    }

    return computed.value() == std::string(expected_hash);
}

}  // namespace fcxl::tools

#pragma clang diagnostic pop
