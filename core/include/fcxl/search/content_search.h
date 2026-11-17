#pragma once
/// @file content_search.h
#include <filesystem>
#include <functional>
#include <string>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
#include "fcxl/search/exclusions.h"
namespace fcxl::search {
struct ContentMatch {
    std::filesystem::path file;
    uint64_t line_number = 0;
    std::string line_content;
    uint64_t column = 0;
    /// How many lines of the file matched. More than one only when the search was asked to
    /// answer once per file — the match then stands for all of them and carries the first.
    uint64_t match_count = 1;
};
using ContentResultCallback = std::function<void(const ContentMatch&)>;
/// Called with each directory as the search enters it — drives a "scanning …" status line.
/// Invoked on the search thread; the callee is responsible for throttling / thread-hopping.
using ScanProgressCallback = std::function<void(std::string_view current_dir)>;
/// What a content search may be told besides the text itself.
struct ContentOptions {
    bool use_regex = false;
    bool recursive = true;
    /// Off by default: someone looking for "договор" wants "Договор" as well, and has to ask
    /// for the opposite rather than for this.
    bool case_sensitive = false;
    /// Dot-names and entries carrying the macOS hidden flag; a hidden directory is not entered.
    bool include_hidden = false;
    /// Which files to open at all — "*.txt;*.md"; empty or "*" means every file. Applied to
    /// the name BEFORE the file is read, so a narrow mask makes the search faster, not just
    /// its answer shorter.
    std::string name_mask;
    std::vector<std::string> exclude_patterns;
    /// Size and change-date limits; a file outside them is not opened.
    FileLimits limits;
    /// One match per file instead of one per line: the first matching line, and the number of
    /// lines that matched. What a list of FILES wants — a log with ten thousand hits is one
    /// find, not ten thousand rows. The callback is then called once per file, after the file
    /// has been read to the end.
    bool one_per_file = false;
};

/// Finding text inside files.
///
/// A file is read the way the editor and the viewer read it: a byte-order mark names UTF-16
/// or UTF-32, otherwise the text is UTF-8, and a line that is not valid UTF-8 is taken for
/// Windows-1251. A file with a zero byte near its start and no mark is binary and is skipped.
/// A match carries the line it was found in — cut down to the part around the match when the
/// line is very long, because a minified file is one line of megabytes.
class ContentSearch {
public:
    [[nodiscard]] auto search(std::string_view root_path, std::string_view pattern, const ContentOptions& options, ContentResultCallback on_found = nullptr, ScanProgressCallback on_scan_dir = nullptr) -> common::Result<std::vector<ContentMatch>>;
    /// The older, positional form: every option not named here keeps its default.
    [[nodiscard]] auto search(std::string_view root_path, std::string_view pattern, bool use_regex = false, bool recursive = true, const std::vector<std::string>& exclude_patterns = {}, ContentResultCallback on_found = nullptr, ScanProgressCallback on_scan_dir = nullptr) -> common::Result<std::vector<ContentMatch>>;
    void cancel();
private:
    bool cancelled_ = false;
};
} // namespace fcxl::search
