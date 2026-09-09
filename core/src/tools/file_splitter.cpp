#include "fcxl/tools/file_splitter.h"

#include <array>
#include <cerrno>
#include <cstdio>
#include <filesystem>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

namespace fcxl::tools {
namespace {
constexpr std::size_t kBufferSize = 65536;
}

namespace {
/// Remove whatever a cancelled or failed run had produced, so no truncated parts are left behind.
void discard(const std::vector<std::string>& paths) {
    std::error_code ignored;
    for (const auto& p : paths) std::filesystem::remove(p, ignored);
}
}  // namespace

auto FileSplitter::split(std::string_view path,
                          uint64_t chunk_size,
                          std::string_view output_dir,
                          const ProgressFn& progress)
    -> common::Result<std::vector<std::string>> {
    if (chunk_size == 0) {
        return common::Error::make(common::ErrorCode::InvalidArgument, "Chunk size must be > 0");
    }

    const std::string source_path(path);
    const std::string out_dir(output_dir);

    FILE* src = std::fopen(source_path.c_str(), "rb");
    if (src == nullptr) {
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Cannot open source file", source_path);
    }

    // Get total file size
    std::fseek(src, 0, SEEK_END);
    const auto file_size = static_cast<uint64_t>(std::ftell(src));
    std::fseek(src, 0, SEEK_SET);

    // Create output directory if needed
    std::error_code ec;
    std::filesystem::create_directories(out_dir, ec);

    const std::string base_name = std::filesystem::path(source_path).filename().string();
    std::vector<std::string> parts;
    uint64_t bytes_remaining = file_size;
    int part_index = 1;

    std::array<char, kBufferSize> buffer{};

    while (bytes_remaining > 0) {
        std::ostringstream part_name;
        part_name << base_name << "." << std::setfill('0') << std::setw(3) << part_index;
        const std::string part_path =
            (std::filesystem::path(out_dir) / part_name.str()).string();

        FILE* dst = std::fopen(part_path.c_str(), "wb");
        if (dst == nullptr) {
            std::fclose(src);
            return common::Error::make(common::ErrorCode::IOError,
                                       "Cannot create part file", part_path);
        }

        uint64_t chunk_remaining = std::min(chunk_size, bytes_remaining);
        while (chunk_remaining > 0) {
            const auto to_read = std::min(static_cast<uint64_t>(kBufferSize), chunk_remaining);
            const auto read = std::fread(buffer.data(), 1, static_cast<std::size_t>(to_read), src);
            if (read == 0) break;
            // Checked: an unchecked fwrite turns a full disk into silently truncated parts, and
            // the join would then rebuild a corrupt file that only the checksum could catch.
            if (std::fwrite(buffer.data(), 1, read, dst) != read) {
                std::fclose(dst);
                std::fclose(src);
                parts.push_back(part_path);
                discard(parts);
                return common::Error::make(common::ErrorCode::DiskFull,
                                           "Cannot write part file", part_path);
            }
            chunk_remaining -= read;
            bytes_remaining -= read;

            if (progress && progress(file_size - bytes_remaining, file_size)) {
                std::fclose(dst);
                std::fclose(src);
                parts.push_back(part_path);
                discard(parts);
                return common::Error::make(common::ErrorCode::Cancelled, "Split cancelled");
            }
        }

        std::fclose(dst);
        parts.push_back(part_path);
        ++part_index;
    }

    std::fclose(src);
    if (progress) progress(file_size, file_size);
    return parts;
}

auto FileSplitter::join(const std::vector<std::string>& parts,
                         std::string_view output_path,
                         const ProgressFn& progress) -> common::Result<void> {
    if (parts.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument, "No parts to join");
    }

    // Total up front, so the caller can show a real percentage rather than a spinner.
    uint64_t total = 0;
    {
        std::error_code ec;
        for (const auto& part_path : parts) {
            const auto size = std::filesystem::file_size(part_path, ec);
            if (!ec) total += size;
        }
    }
    uint64_t done = 0;

    const std::string out_path(output_path);
    FILE* dst = std::fopen(out_path.c_str(), "wb");
    if (dst == nullptr) {
        return common::Error::make(common::ErrorCode::IOError,
                                   "Cannot create output file", out_path);
    }

    std::array<char, kBufferSize> buffer{};

    for (const auto& part_path : parts) {
        FILE* src = std::fopen(part_path.c_str(), "rb");
        if (src == nullptr) {
            std::fclose(dst);
            return common::Error::make(common::ErrorCode::NotFound,
                                       "Cannot open part file", part_path);
        }

        std::size_t read = 0;
        while ((read = std::fread(buffer.data(), 1, kBufferSize, src)) > 0) {
            if (std::fwrite(buffer.data(), 1, read, dst) != read) {
                std::fclose(src);
                std::fclose(dst);
                discard({out_path});
                return common::Error::make(common::ErrorCode::DiskFull,
                                           "Cannot write output file", out_path);
            }
            done += read;
            if (progress && progress(done, total)) {
                std::fclose(src);
                std::fclose(dst);
                // A half-joined file is worse than none: it looks complete to the eye.
                discard({out_path});
                return common::Error::make(common::ErrorCode::Cancelled, "Join cancelled");
            }
        }

        std::fclose(src);
    }

    std::fclose(dst);
    if (progress) progress(total, total);
    return common::Result<void>();
}

}  // namespace fcxl::tools
