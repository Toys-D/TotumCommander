#include "fcxl/viewer/hex_viewer.h"

#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>
#include <unordered_map>
#include <utility>
#include <vector>

namespace fcxl::viewer {
namespace {

struct HexViewerState {
    std::filesystem::path path;
    std::uint64_t file_size = 0;
};

std::mutex g_state_mutex;
std::unordered_map<const HexViewer*, HexViewerState> g_states;

auto map_error_code(const std::error_code& ec,
                    std::string message,
                    const std::filesystem::path& path = std::filesystem::path())
    -> common::Error {
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
        case std::errc::is_a_directory:
            code = common::ErrorCode::NotAFile;
            break;
        case std::errc::invalid_argument:
            code = common::ErrorCode::InvalidArgument;
            break;
        default:
            code = common::ErrorCode::IOError;
            break;
    }

    return common::Error::make(code, std::move(message), path.string());
}

auto load_state_copy(const HexViewer* viewer) -> std::optional<HexViewerState> {
    std::lock_guard<std::mutex> lock(g_state_mutex);
    const auto it = g_states.find(viewer);
    if (it == g_states.end()) {
        return std::nullopt;
    }
    return it->second;
}

auto save_state(const HexViewer* viewer, HexViewerState state) -> void {
    std::lock_guard<std::mutex> lock(g_state_mutex);
    g_states[viewer] = std::move(state);
}

auto is_printable_ascii(std::uint8_t byte) -> bool {
    return byte >= 32 && byte <= 126;
}

}  // namespace

auto HexViewer::open(std::string_view path) -> common::Result<void> {
    if (path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "File path cannot be empty");
    }

    const std::filesystem::path file_path(path);
    std::error_code ec;
    const bool exists = std::filesystem::exists(file_path, ec);
    if (ec) {
        return map_error_code(ec, "Failed to check file existence", file_path);
    }
    if (!exists) {
        return common::Error::make(common::ErrorCode::NotFound,
                                   "File does not exist",
                                   file_path.string());
    }

    const bool regular_file = std::filesystem::is_regular_file(file_path, ec);
    if (ec) {
        return map_error_code(ec, "Failed to inspect file type", file_path);
    }
    if (!regular_file) {
        return common::Error::make(common::ErrorCode::NotAFile,
                                   "Path is not a regular file",
                                   file_path.string());
    }

    const std::uint64_t size =
        static_cast<std::uint64_t>(std::filesystem::file_size(file_path, ec));
    if (ec) {
        return map_error_code(ec, "Failed to determine file size", file_path);
    }

    HexViewerState state;
    state.path = file_path;
    state.file_size = size;
    save_state(this, std::move(state));
    return {};
}

auto HexViewer::get_lines(std::uint64_t offset, std::uint64_t count, std::uint16_t bytes_per_line) const
    -> common::Result<std::vector<HexLine>> {
    if (bytes_per_line == 0) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "bytes_per_line cannot be zero");
    }
    if (count == 0) {
        return std::vector<HexLine>{};
    }

    const auto state_opt = load_state_copy(this);
    if (!state_opt.has_value()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "File is not open");
    }

    const HexViewerState state = state_opt.value();
    if (offset >= state.file_size) {
        return std::vector<HexLine>{};
    }

    std::ifstream input(state.path, std::ios::binary);
    if (!input.is_open()) {
        return common::Error::make(common::ErrorCode::IOError,
                                   "Failed to open file for hex reading",
                                   state.path.string());
    }

    input.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    if (input.fail()) {
        return common::Error::make(common::ErrorCode::IOError,
                                   "Failed to seek to requested offset",
                                   state.path.string());
    }

    std::vector<HexLine> lines;
    lines.reserve(static_cast<std::size_t>(count));
    std::uint64_t current_offset = offset;

    for (std::uint64_t i = 0; i < count && current_offset < state.file_size; ++i) {
        const std::uint64_t remaining = state.file_size - current_offset;
        const std::uint64_t requested =
            std::min<std::uint64_t>(remaining, static_cast<std::uint64_t>(bytes_per_line));

        std::vector<std::uint8_t> bytes(static_cast<std::size_t>(requested));
        input.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(requested));
        const std::streamsize read_size = input.gcount();
        if (read_size <= 0) {
            break;
        }
        bytes.resize(static_cast<std::size_t>(read_size));

        std::string ascii;
        ascii.reserve(bytes.size());
        for (const std::uint8_t byte : bytes) {
            ascii.push_back(is_printable_ascii(byte) ? static_cast<char>(byte) : '.');
        }

        HexLine line;
        line.offset = current_offset;
        line.bytes = std::move(bytes);
        line.ascii = std::move(ascii);
        lines.push_back(std::move(line));

        current_offset += static_cast<std::uint64_t>(read_size);
    }

    if (input.bad()) {
        return common::Error::make(common::ErrorCode::IOError,
                                   "Failed while reading file bytes",
                                   state.path.string());
    }
    return lines;
}

auto HexViewer::file_size() const -> std::uint64_t {
    const auto state_opt = load_state_copy(this);
    if (!state_opt.has_value()) {
        return 0;
    }
    return state_opt.value().file_size;
}

void HexViewer::close() {
    std::lock_guard<std::mutex> lock(g_state_mutex);
    g_states.erase(this);
}

}  // namespace fcxl::viewer
