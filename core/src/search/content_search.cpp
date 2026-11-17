#include "fcxl/search/content_search.h"

#include "fcxl/search/exclusions.h"
#include "fcxl/search/name_match.h"

#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <fstream>
#include <optional>
#include <regex>
#include <string>
#include <system_error>

namespace fcxl::search {
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

/// A found line longer than this is cut down to the part around the match.
constexpr std::size_t kSnippetBytes = 400;
/// How much of the line before the match is kept in a cut line.
constexpr std::size_t kSnippetLead = 80;
/// A UTF-16 file has to be converted whole before it has lines at all; past this size it is
/// left alone rather than read into memory.
constexpr std::uintmax_t kWideFileLimit = 64ULL * 1024 * 1024;

auto is_ascii(std::string_view text) -> bool {
    return std::all_of(text.begin(), text.end(),
                       [](const char byte) { return static_cast<unsigned char>(byte) < 0x80; });
}

void fold_ascii(std::string& text) {
    for (char& byte : text) {
        if (byte >= 'A' && byte <= 'Z') {
            byte = static_cast<char>(byte + ('a' - 'A'));
        }
    }
}

auto is_continuation(char byte) -> bool {
    return (static_cast<unsigned char>(byte) & 0xC0) == 0x80;
}

/// Well-formed UTF-8, by the rules: no overlong forms, no surrogates, nothing past U+10FFFF.
auto is_valid_utf8(std::string_view text) -> bool {
    std::size_t index = 0;
    while (index < text.size()) {
        const auto lead = static_cast<unsigned char>(text[index]);
        std::size_t length = 0;
        if (lead < 0x80) {
            ++index;
            continue;
        } else if (lead >= 0xC2 && lead <= 0xDF) {
            length = 2;
        } else if (lead >= 0xE0 && lead <= 0xEF) {
            length = 3;
        } else if (lead >= 0xF0 && lead <= 0xF4) {
            length = 4;
        } else {
            return false;
        }
        if (index + length > text.size()) {
            return false;
        }
        for (std::size_t offset = 1; offset < length; ++offset) {
            if (!is_continuation(text[index + offset])) {
                return false;
            }
        }
        const auto second = static_cast<unsigned char>(text[index + 1]);
        if ((lead == 0xE0 && second < 0xA0) || (lead == 0xED && second > 0x9F) ||
            (lead == 0xF0 && second < 0x90) || (lead == 0xF4 && second > 0x8F)) {
            return false;
        }
        index += length;
    }
    return true;
}

/// Bytes in a named encoding, as UTF-8. Nothing when the bytes do not read as that encoding.
auto decode_bytes(std::string_view bytes, CFStringEncoding encoding, bool with_mark)
    -> std::optional<std::string> {
    CFStringRef text = CFStringCreateWithBytes(kCFAllocatorDefault,
                                               reinterpret_cast<const UInt8*>(bytes.data()),
                                               static_cast<CFIndex>(bytes.size()),
                                               encoding,
                                               with_mark);
    if (text == nullptr) {
        return std::nullopt;
    }
    const CFIndex length = CFStringGetLength(text);
    const CFRange range = CFRangeMake(0, length);
    CFIndex byte_count = 0;
    CFStringGetBytes(text, range, kCFStringEncodingUTF8, '?', false, nullptr, 0, &byte_count);
    std::string utf8(static_cast<std::size_t>(byte_count), '\0');
    if (byte_count > 0) {
        CFStringGetBytes(text, range, kCFStringEncodingUTF8, '?', false,
                         reinterpret_cast<UInt8*>(utf8.data()), byte_count, &byte_count);
    }
    CFRelease(text);
    return utf8;
}

/// How a file's bytes are to be read.
enum class FileKind {
    Lines,       ///< UTF-8 or a single-byte encoding: read line by line as it stands.
    LinesAfterMark,  ///< The same, behind a three-byte UTF-8 mark.
    Wide16,      ///< UTF-16 with a byte-order mark.
    Wide32,      ///< UTF-32 with a byte-order mark.
    Binary       ///< Not text, or not readable.
};

/// The same rule the editor and the viewer follow: a mark at the start names the encoding and
/// makes the file text whatever comes next; without one, a zero byte near the start means
/// binary. In Latin text every second byte of UTF-16 is a zero, so the mark has to be looked
/// for first.
auto sniff_file(const std::filesystem::path& path) -> FileKind {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs.is_open()) {
        return FileKind::Binary;
    }
    std::array<char, 512> buffer{};
    ifs.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    const auto count = static_cast<std::size_t>(ifs.gcount());
    const auto byte = [&buffer](std::size_t index) {
        return static_cast<unsigned char>(buffer[index]);
    };
    // The four-byte marks first: FF FE 00 00 starts like the UTF-16 one.
    if (count >= 4 && ((byte(0) == 0xFF && byte(1) == 0xFE && byte(2) == 0x00 && byte(3) == 0x00) ||
                       (byte(0) == 0x00 && byte(1) == 0x00 && byte(2) == 0xFE && byte(3) == 0xFF))) {
        return FileKind::Wide32;
    }
    if (count >= 2 && ((byte(0) == 0xFF && byte(1) == 0xFE) || (byte(0) == 0xFE && byte(1) == 0xFF))) {
        return FileKind::Wide16;
    }
    if (count >= 3 && byte(0) == 0xEF && byte(1) == 0xBB && byte(2) == 0xBF) {
        return FileKind::LinesAfterMark;
    }
    for (std::size_t index = 0; index < count; ++index) {
        if (buffer[index] == '\0') {
            return FileKind::Binary;
        }
    }
    return FileKind::Lines;
}

/// A regular expression brought to one case, with its escapes left as they were: "\S" and
/// "\D" mean the opposite of "\s" and "\d", so only what stands outside an escape is folded.
auto fold_regex_pattern(std::string_view pattern) -> std::string {
    std::string folded;
    std::string run;
    const auto flush = [&folded, &run] {
        folded += to_folded_text(run);
        run.clear();
    };
    for (std::size_t index = 0; index < pattern.size(); ++index) {
        if (pattern[index] != '\\' || index + 1 >= pattern.size()) {
            run.push_back(pattern[index]);
            continue;
        }
        flush();
        folded.push_back(pattern[index]);
        folded.push_back(pattern[++index]);
        while (index + 1 < pattern.size() && is_continuation(pattern[index + 1])) {
            folded.push_back(pattern[++index]);
        }
    }
    flush();
    return folded;
}

/// The question asked of every line.
class LineMatcher {
public:
    /// Nothing when the regular expression does not compile.
    static auto make(std::string_view pattern, bool use_regex, bool case_sensitive)
        -> std::optional<LineMatcher> {
        LineMatcher matcher;
        matcher.case_sensitive_ = case_sensitive;
        if (use_regex) {
            const std::string source = case_sensitive ? std::string(pattern)
                                                      : fold_regex_pattern(pattern);
            try {
                matcher.regex_.emplace(source, std::regex::ECMAScript);
            } catch (const std::regex_error&) {
                return std::nullopt;
            }
            matcher.needle_is_ascii_ = is_ascii(source);
        } else {
            matcher.needle_ = case_sensitive ? std::string(pattern) : to_folded_text(pattern);
            matcher.needle_is_ascii_ = is_ascii(matcher.needle_);
        }
        return matcher;
    }

    /// Where in @p line the match starts, or npos.
    [[nodiscard]] auto find(const std::string& line) -> std::size_t {
        const std::string* subject = &line;
        if (!case_sensitive_) {
            const bool line_is_ascii = is_ascii(line);
            if (!needle_is_ascii_ && line_is_ascii && !regex_) {
                return std::string::npos;   // letters outside ASCII cannot be in an ASCII line
            }
            if (needle_is_ascii_ || line_is_ascii) {
                // What is being looked for is ASCII, so only ASCII can match it: the rest of
                // the line needs no folding, and no trip through the Unicode tables.
                scratch_ = line;
                fold_ascii(scratch_);
            } else {
                scratch_ = to_folded_text(line);
            }
            subject = &scratch_;
        }
        if (regex_) {
            std::smatch match;
            if (!std::regex_search(*subject, match, *regex_)) {
                return std::string::npos;
            }
            return static_cast<std::size_t>(match.position());
        }
        return subject->find(needle_);
    }

private:
    bool case_sensitive_ = false;
    bool needle_is_ascii_ = true;
    std::string needle_;
    std::optional<std::regex> regex_;
    std::string scratch_;
};

/// The line as it goes into a result: whole when short, otherwise the stretch around the
/// match, cut on character boundaries and marked where it was cut.
auto snippet(const std::string& line, std::size_t position) -> std::string {
    if (line.size() <= kSnippetBytes) {
        return line;
    }
    std::size_t start = position > kSnippetLead ? position - kSnippetLead : 0;
    start = std::min(start, line.size());
    while (start < line.size() && is_continuation(line[start])) {
        ++start;
    }
    std::size_t end = std::min(line.size(), start + kSnippetBytes);
    while (end > start && end < line.size() && is_continuation(line[end])) {
        --end;
    }
    std::string shown;
    if (start > 0) {
        shown += "\xE2\x80\xA6";   // …
    }
    shown.append(line, start, end - start);
    if (end < line.size()) {
        shown += "\xE2\x80\xA6";
    }
    return shown;
}

}  // namespace

auto ContentSearch::search(std::string_view root_path,
                           std::string_view pattern,
                           bool use_regex,
                           bool recursive,
                           const std::vector<std::string>& exclude_patterns,
                           ContentResultCallback on_found,
                           ScanProgressCallback on_scan_dir)
    -> common::Result<std::vector<ContentMatch>> {
    ContentOptions options;
    options.use_regex = use_regex;
    options.recursive = recursive;
    options.exclude_patterns = exclude_patterns;
    return search(root_path, pattern, options, std::move(on_found), std::move(on_scan_dir));
}

auto ContentSearch::search(std::string_view root_path,
                           std::string_view pattern,
                           const ContentOptions& options,
                           ContentResultCallback on_found,
                           ScanProgressCallback on_scan_dir)
    -> common::Result<std::vector<ContentMatch>> {
    if (root_path.empty() || pattern.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Root path and pattern cannot be empty");
    }

    const std::filesystem::path root(root_path);
    std::error_code ec;
    const bool exists = std::filesystem::exists(root, ec);
    if (ec) {
        return map_error_code(ec, "Failed to check root path existence", root);
    }
    if (!exists) {
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Root path does not exist",
                                   root.string());
    }

    const bool is_directory = std::filesystem::is_directory(root, ec);
    if (ec) {
        return map_error_code(ec, "Failed to inspect root path type", root);
    }
    if (!is_directory) {
        return common::Error::make(common::ErrorCode::NotADirectory,
                                   "Root path is not a directory",
                                   root.string());
    }

    auto matcher = LineMatcher::make(pattern, options.use_regex, options.case_sensitive);
    if (!matcher) {
        return common::Error::make(common::ErrorCode::InvalidArgument,
                                   "Invalid regex pattern",
                                   root.string());
    }
    const NameMaskSet name_masks(options.name_mask);

    cancelled_ = false;
    std::vector<ContentMatch> results;
    // Where the matches of the file being read begin — for answering once per file.
    std::size_t file_start = 0;

    // One line of one file. The line arrives as the file holds it and leaves as UTF-8.
    const auto take_line = [&](const std::filesystem::path& file, std::string& line,
                               uint64_t line_number) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();   // a Windows line ending is not part of the line
        }
        if (!is_ascii(line) && !is_valid_utf8(line)) {
            if (auto decoded = decode_bytes(line, kCFStringEncodingWindowsCyrillic, false)) {
                line = std::move(*decoded);
            }
        }
        const std::size_t position = matcher->find(line);
        if (position == std::string::npos) {
            return;
        }
        if (options.one_per_file && results.size() > file_start) {
            ++results.back().match_count;   // the file is already in the answer
            return;
        }
        ContentMatch content_match;
        content_match.file = file;
        content_match.line_number = line_number;
        content_match.line_content = snippet(line, position);
        content_match.column = static_cast<uint64_t>(position) + 1;
        if (on_found && !options.one_per_file) {
            on_found(content_match);
        }
        results.push_back(std::move(content_match));
    };

    const auto read_file = [&](const std::filesystem::path& file) {
        const FileKind kind = sniff_file(file);
        if (kind == FileKind::Binary) {
            return;
        }
        if (kind == FileKind::Wide16 || kind == FileKind::Wide32) {
            std::error_code size_ec;
            const auto size = std::filesystem::file_size(file, size_ec);
            if (size_ec || size > kWideFileLimit) {
                return;
            }
            std::ifstream wide(file, std::ios::binary);
            if (!wide.is_open()) {
                return;
            }
            std::string bytes(static_cast<std::size_t>(size), '\0');
            wide.read(bytes.data(), static_cast<std::streamsize>(bytes.size()));
            bytes.resize(static_cast<std::size_t>(wide.gcount()));
            const auto text = decode_bytes(
                bytes, kind == FileKind::Wide16 ? kCFStringEncodingUTF16 : kCFStringEncodingUTF32,
                true);
            if (!text) {
                return;
            }
            uint64_t line_number = 0;
            std::size_t start = 0;
            std::string line;
            while (!cancelled_ && start <= text->size()) {
                const std::size_t hit = text->find('\n', start);
                const std::size_t end = hit == std::string::npos ? text->size() : hit;
                if (hit == std::string::npos && end == start) {
                    break;   // nothing after the last line break
                }
                line.assign(*text, start, end - start);
                take_line(file, line, ++line_number);
                if (hit == std::string::npos) {
                    break;
                }
                start = hit + 1;
            }
            return;
        }

        std::ifstream ifs(file, std::ios::binary);
        if (!ifs.is_open()) {
            return;
        }
        if (kind == FileKind::LinesAfterMark) {
            ifs.seekg(3);
        }
        std::string line;
        uint64_t line_number = 0;
        while (!cancelled_ && std::getline(ifs, line)) {
            take_line(file, line, ++line_number);
        }
    };

    const auto search_file = [&](const std::filesystem::path& file) {
        file_start = results.size();
        read_file(file);
        // Once per file: told only now, when the count of matching lines is final.
        if (options.one_per_file && on_found && results.size() > file_start) {
            on_found(results.back());
        }
    };

    std::filesystem::recursive_directory_iterator iterator(
        root, std::filesystem::directory_options::skip_permission_denied, ec);
    if (ec) {
        return map_error_code(ec, "Failed to iterate root path", root);
    }

    // One entry that cannot be looked at must not cost the whole answer: it is stepped over,
    // the way the name search steps over it.
    const auto advance = [&iterator] {
        std::error_code step_ec;
        iterator.increment(step_ec);
    };

    const std::filesystem::recursive_directory_iterator end;
    while (iterator != end) {
        if (cancelled_) {
            break;
        }

        const std::filesystem::directory_entry& dir_entry = *iterator;
        const std::filesystem::path entry_path = dir_entry.path();
        const std::string name = entry_path.filename().string();

        std::error_code entry_ec;
        const bool is_dir = dir_entry.is_directory(entry_ec);
        if (entry_ec) {
            advance();
            continue;
        }
        if (is_dir && !options.recursive) {
            iterator.disable_recursion_pending();
        }

        // Excluded names are never opened, and excluded directories are never entered — the
        // same rule the name search follows, so both modes answer about the same tree.
        if (is_excluded(name, options.exclude_patterns)) {
            if (is_dir) {
                iterator.disable_recursion_pending();
            }
            advance();
            continue;
        }

        // Hidden the same way too: a hidden directory is left out with everything under it.
        if (!options.include_hidden &&
            (is_hidden_name(name) || (is_dir && has_hidden_flag(entry_path)))) {
            if (is_dir) {
                iterator.disable_recursion_pending();
            }
            advance();
            continue;
        }

        if (is_dir) {
            // Report the directory being entered for the "scanning …" status line.
            if (on_scan_dir) {
                on_scan_dir(entry_path.string());
            }
            advance();
            continue;
        }

        const bool regular_file = dir_entry.is_regular_file(entry_ec);
        if (entry_ec || !regular_file || !name_masks.matches(name) ||
            (!options.include_hidden && has_hidden_flag(entry_path)) ||
            !options.limits.allows(entry_path)) {
            advance();
            continue;
        }

        search_file(entry_path);
        advance();
    }

    return results;
}

void ContentSearch::cancel() { cancelled_ = true; }

}  // namespace fcxl::search
