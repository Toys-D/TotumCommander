#include "fcxl/viewer/text_viewer.h"

#include <algorithm>
#include <array>
#include <cctype>
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

struct TextViewerState {
    std::filesystem::path path;
    std::string encoding = "UTF-8";
    std::string language = "txt";
    std::uint64_t total_lines = 0;
    std::uint64_t bom_size = 0;
};

std::mutex g_state_mutex;
std::unordered_map<const TextViewer*, TextViewerState> g_states;

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

auto load_state_copy(const TextViewer* viewer) -> std::optional<TextViewerState> {
    std::lock_guard<std::mutex> lock(g_state_mutex);
    const auto it = g_states.find(viewer);
    if (it == g_states.end()) {
        return std::nullopt;
    }
    return it->second;
}

auto save_state(const TextViewer* viewer, TextViewerState state) -> void {
    std::lock_guard<std::mutex> lock(g_state_mutex);
    g_states[viewer] = std::move(state);
}

auto lowercase(std::string value) -> std::string {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

auto detect_language_from_extension(std::string extension) -> std::string {
    extension = lowercase(std::move(extension));
    if (!extension.empty() && extension.front() == '.') {
        extension.erase(extension.begin());
    }

    if (extension == "cpp" || extension == "cxx" || extension == "cc" ||
        extension == "hpp" || extension == "hh" || extension == "hxx") {
        return "cpp";
    }
    if (extension == "c" || extension == "h") {
        return "c";
    }
    if (extension == "py") {
        return "py";
    }
    if (extension == "swift") {
        return "swift";
    }
    if (extension == "js" || extension == "mjs" || extension == "cjs") {
        return "js";
    }
    if (extension == "ts") {
        return "ts";
    }
    if (extension == "html" || extension == "htm") {
        return "html";
    }
    if (extension == "md" || extension == "markdown") {
        return "md";
    }
    if (extension == "json") {
        return "json";
    }
    if (extension == "xml") {
        return "xml";
    }
    if (extension == "yaml" || extension == "yml") {
        return "yaml";
    }
    if (extension == "txt" || extension == "log" || extension.empty()) {
        return "txt";
    }
    return extension;
}

auto detect_encoding_and_bom_size(const std::filesystem::path& path)
    -> common::Result<std::pair<std::string, std::uint64_t>> {
    std::ifstream input(path, std::ios::binary);
    if (!input.is_open()) {
        return common::Error::make(common::ErrorCode::IOError,
                                   "Failed to open file for encoding detection",
                                   path.string());
    }

    std::array<unsigned char, 4> bytes = {0, 0, 0, 0};
    input.read(reinterpret_cast<char*>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
    const std::streamsize read_count = input.gcount();

    if (read_count >= 4 && bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0xFE &&
        bytes[3] == 0xFF) {
        return std::make_pair(std::string("UTF-32BE"), static_cast<std::uint64_t>(4));
    }
    if (read_count >= 4 && bytes[0] == 0xFF && bytes[1] == 0xFE && bytes[2] == 0x00 &&
        bytes[3] == 0x00) {
        return std::make_pair(std::string("UTF-32LE"), static_cast<std::uint64_t>(4));
    }
    if (read_count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
        return std::make_pair(std::string("UTF-8"), static_cast<std::uint64_t>(3));
    }
    if (read_count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return std::make_pair(std::string("UTF-16BE"), static_cast<std::uint64_t>(2));
    }
    if (read_count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
        return std::make_pair(std::string("UTF-16LE"), static_cast<std::uint64_t>(2));
    }

    return std::make_pair(std::string("UTF-8"), static_cast<std::uint64_t>(0));
}

auto count_lines_in_file(const std::filesystem::path& path) -> common::Result<std::uint64_t> {
    std::ifstream input(path, std::ios::binary);
    if (!input.is_open()) {
        return common::Error::make(common::ErrorCode::IOError,
                                   "Failed to open file for line counting",
                                   path.string());
    }

    std::uint64_t lines = 0;
    bool has_any_data = false;
    char last_char = '\0';
    std::array<char, 8192> buffer = {};
    while (input.good()) {
        input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        const auto read_size = input.gcount();
        if (read_size <= 0) {
            break;
        }
        has_any_data = true;
        for (std::streamsize i = 0; i < read_size; ++i) {
            if (buffer[static_cast<std::size_t>(i)] == '\n') {
                ++lines;
            }
        }
        last_char = buffer[static_cast<std::size_t>(read_size - 1)];
    }

    if (input.bad()) {
        return common::Error::make(common::ErrorCode::IOError,
                                   "Failed while reading file for line counting",
                                   path.string());
    }

    if (has_any_data && last_char != '\n') {
        ++lines;
    }
    return lines;
}

}  // namespace

auto TextViewer::open(std::string_view path) -> common::Result<void> {
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

    const auto encoding_result = detect_encoding_and_bom_size(file_path);
    if (!encoding_result.has_value()) {
        return encoding_result.error();
    }

    const auto lines_result = count_lines_in_file(file_path);
    if (!lines_result.has_value()) {
        return lines_result.error();
    }

    TextViewerState state;
    state.path = file_path;
    state.encoding = encoding_result.value().first;
    state.bom_size = encoding_result.value().second;
    state.language = detect_language_from_extension(file_path.extension().string());
    state.total_lines = lines_result.value();
    save_state(this, std::move(state));
    return {};
}

auto TextViewer::get_lines(std::uint64_t from, std::uint64_t count) const
    -> common::Result<std::vector<std::string>> {
    if (count == 0) {
        return std::vector<std::string>{};
    }

    const auto state_opt = load_state_copy(this);
    if (!state_opt.has_value()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "File is not open");
    }

    const TextViewerState state = state_opt.value();
    if (from >= state.total_lines) {
        return std::vector<std::string>{};
    }

    std::ifstream input(state.path, std::ios::binary);
    if (!input.is_open()) {
        return common::Error::make(common::ErrorCode::IOError,
                                   "Failed to open file for reading lines",
                                   state.path.string());
    }

    if (state.bom_size > 0) {
        input.seekg(static_cast<std::streamoff>(state.bom_size), std::ios::beg);
        if (input.fail()) {
            return common::Error::make(common::ErrorCode::IOError,
                                       "Failed to seek file after BOM",
                                       state.path.string());
        }
    }

    std::uint64_t current_line_index = 0;
    std::string line;
    while (current_line_index < from && std::getline(input, line)) {
        ++current_line_index;
    }

    std::vector<std::string> lines;
    lines.reserve(static_cast<std::size_t>(count));
    while (lines.size() < count && std::getline(input, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        lines.push_back(line);
    }

    if (input.bad()) {
        return common::Error::make(common::ErrorCode::IOError,
                                   "Failed while reading file lines",
                                   state.path.string());
    }
    return lines;
}

auto TextViewer::total_lines() const -> std::uint64_t {
    const auto state_opt = load_state_copy(this);
    if (!state_opt.has_value()) {
        return 0;
    }
    return state_opt.value().total_lines;
}

auto TextViewer::detected_encoding() const -> std::string {
    const auto state_opt = load_state_copy(this);
    if (!state_opt.has_value()) {
        return "UTF-8";
    }
    return state_opt.value().encoding;
}

auto TextViewer::detect_language() const -> std::string {
    const auto state_opt = load_state_copy(this);
    if (!state_opt.has_value()) {
        return "txt";
    }
    return state_opt.value().language;
}

void TextViewer::close() {
    std::lock_guard<std::mutex> lock(g_state_mutex);
    g_states.erase(this);
}

}  // namespace fcxl::viewer
