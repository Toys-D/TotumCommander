#include "fcxl/compare/file_diff.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace fcxl::compare {
namespace {

auto read_lines(std::string_view path) -> common::Result<std::vector<std::string>> {
    const std::string path_str(path);
    std::ifstream file(path_str);
    if (!file.is_open()) {
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Failed to open file", path_str);
    }

    std::vector<std::string> lines;
    std::string line;
    while (std::getline(file, line)) {
        lines.push_back(std::move(line));
    }
    return lines;
}

/// Myers diff algorithm — simple O(ND) implementation for line-level diff
auto compute_lcs_diff(const std::vector<std::string>& a,
                      const std::vector<std::string>& b) -> std::vector<DiffLine> {
    const auto n = static_cast<int>(a.size());
    const auto m = static_cast<int>(b.size());

    // For very large files, fall back to simple comparison. Gate on the PRODUCT n*m, not the
    // sum: the LCS table below is O(n*m). A sum check let two ~90k-line files through and then
    // tried to allocate ~32 GB (bad_alloc → crash through the bridge).
    if (static_cast<int64_t>(n) * static_cast<int64_t>(m) > 10'000'000) {
        std::vector<DiffLine> result;
        const auto max_lines = std::max(n, m);
        for (int i = 0; i < max_lines; ++i) {
            DiffLine dl;
            if (i < n && i < m) {
                const auto& left = a[static_cast<std::size_t>(i)];
                const auto& right = b[static_cast<std::size_t>(i)];
                if (left == right) {
                    dl.line_left = static_cast<uint64_t>(i + 1);
                    dl.line_right = static_cast<uint64_t>(i + 1);
                    dl.type = DiffType::Equal;
                    dl.content = left;
                } else {
                    // Removed + Added, never Modified: a DiffLine carries ONE content string,
                    // so a "modified" line could only show the left file's text — the right
                    // column would then display words that are not in the right file at all.
                    dl.line_left = static_cast<uint64_t>(i + 1);
                    dl.type = DiffType::Removed;
                    dl.content = left;
                    result.push_back(dl);
                    dl = DiffLine{};
                    dl.line_right = static_cast<uint64_t>(i + 1);
                    dl.type = DiffType::Added;
                    dl.content = right;
                }
            } else if (i < n) {
                dl.line_left = static_cast<uint64_t>(i + 1);
                dl.type = DiffType::Removed;
                dl.content = a[static_cast<std::size_t>(i)];
            } else {
                dl.line_right = static_cast<uint64_t>(i + 1);
                dl.type = DiffType::Added;
                dl.content = b[static_cast<std::size_t>(i)];
            }
            result.push_back(std::move(dl));
        }
        return result;
    }

    // Build LCS table for moderate-sized files
    std::vector<std::vector<int>> dp(static_cast<std::size_t>(n + 1),
                                      std::vector<int>(static_cast<std::size_t>(m + 1), 0));
    for (int i = 1; i <= n; ++i) {
        for (int j = 1; j <= m; ++j) {
            if (a[static_cast<std::size_t>(i - 1)] == b[static_cast<std::size_t>(j - 1)]) {
                dp[static_cast<std::size_t>(i)][static_cast<std::size_t>(j)] =
                    dp[static_cast<std::size_t>(i - 1)][static_cast<std::size_t>(j - 1)] + 1;
            } else {
                dp[static_cast<std::size_t>(i)][static_cast<std::size_t>(j)] = std::max(
                    dp[static_cast<std::size_t>(i - 1)][static_cast<std::size_t>(j)],
                    dp[static_cast<std::size_t>(i)][static_cast<std::size_t>(j - 1)]);
            }
        }
    }

    // Backtrack to build diff
    std::vector<DiffLine> result;
    int i = n, j = m;
    std::vector<DiffLine> reversed;

    while (i > 0 || j > 0) {
        DiffLine dl;
        if (i > 0 && j > 0 &&
            a[static_cast<std::size_t>(i - 1)] == b[static_cast<std::size_t>(j - 1)]) {
            dl.line_left = static_cast<uint64_t>(i);
            dl.line_right = static_cast<uint64_t>(j);
            dl.type = DiffType::Equal;
            dl.content = a[static_cast<std::size_t>(i - 1)];
            --i;
            --j;
        } else if (j > 0 &&
                   (i == 0 ||
                    dp[static_cast<std::size_t>(i)][static_cast<std::size_t>(j - 1)] >=
                        dp[static_cast<std::size_t>(i - 1)][static_cast<std::size_t>(j)])) {
            dl.line_right = static_cast<uint64_t>(j);
            dl.type = DiffType::Added;
            dl.content = b[static_cast<std::size_t>(j - 1)];
            --j;
        } else {
            dl.line_left = static_cast<uint64_t>(i);
            dl.type = DiffType::Removed;
            dl.content = a[static_cast<std::size_t>(i - 1)];
            --i;
        }
        reversed.push_back(std::move(dl));
    }

    result.reserve(reversed.size());
    for (auto it = reversed.rbegin(); it != reversed.rend(); ++it) {
        result.push_back(std::move(*it));
    }

    return result;
}

}  // namespace

auto FileDiff::compare(std::string_view file_a, std::string_view file_b)
    -> common::Result<std::vector<DiffLine>> {
    auto lines_a_result = read_lines(file_a);
    if (!lines_a_result.has_value()) {
        return lines_a_result.error();
    }

    auto lines_b_result = read_lines(file_b);
    if (!lines_b_result.has_value()) {
        return lines_b_result.error();
    }

    return compute_lcs_diff(lines_a_result.value(), lines_b_result.value());
}

auto FileDiff::are_identical(std::string_view file_a, std::string_view file_b)
    -> common::Result<bool> {
    const std::string path_a(file_a);
    const std::string path_b(file_b);

    FILE* fa = std::fopen(path_a.c_str(), "rb");
    if (fa == nullptr) {
        return common::Error::make(common::ErrorCode::NotFound, "Cannot open file", path_a);
    }

    FILE* fb = std::fopen(path_b.c_str(), "rb");
    if (fb == nullptr) {
        std::fclose(fa);
        return common::Error::make(common::ErrorCode::NotFound, "Cannot open file", path_b);
    }

    constexpr std::size_t kBufSize = 65536;
    std::vector<unsigned char> buf_a(kBufSize);
    std::vector<unsigned char> buf_b(kBufSize);

    bool identical = true;
    while (true) {
        const auto read_a = std::fread(buf_a.data(), 1, kBufSize, fa);
        const auto read_b = std::fread(buf_b.data(), 1, kBufSize, fb);

        if (read_a != read_b) {
            identical = false;
            break;
        }
        if (read_a == 0) {
            break;
        }
        if (std::memcmp(buf_a.data(), buf_b.data(), read_a) != 0) {
            identical = false;
            break;
        }
    }

    std::fclose(fa);
    std::fclose(fb);

    return identical;
}

}  // namespace fcxl::compare
