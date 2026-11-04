#include <gtest/gtest.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

#include "fcxl/compare/dir_diff.h"

using namespace fcxl;
namespace stdfs = std::filesystem;

class DirDiffTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        root_ = stdfs::temp_directory_path() / ("fcxl_test_dir_diff_" + unique);
        stdfs::create_directories(left_ = root_ / "left");
        stdfs::create_directories(right_ = root_ / "right");
    }

    void TearDown() override {
        std::error_code ec;
        stdfs::remove_all(root_, ec);
    }

    static void write(const stdfs::path& path, std::string_view content) {
        std::ofstream ofs(path, std::ios::binary);
        ofs << content;
    }

    auto compare(bool by_content = false) -> std::vector<compare::DirDiffEntry> {
        auto result = compare::DirDiff{}.compare(left_.string(), right_.string(), by_content);
        EXPECT_TRUE(result.has_value());
        return result.has_value() ? result.value() : std::vector<compare::DirDiffEntry>{};
    }

    stdfs::path root_;
    stdfs::path left_;
    stdfs::path right_;
};

TEST_F(DirDiffTest, should_sort_entries_into_same_different_and_one_sided) {
    write(left_ / "same.txt", "abc");
    write(right_ / "same.txt", "abc");
    write(left_ / "other.txt", "abc");
    write(right_ / "other.txt", "abcdef");
    write(left_ / "left.txt", "x");
    write(right_ / "right.txt", "x");

    const auto entries = compare();
    auto status_of = [&entries](std::string_view name) {
        const auto found = std::find_if(entries.begin(), entries.end(), [name](const auto& entry) {
            return entry.relative_path == stdfs::path(name);
        });
        EXPECT_NE(found, entries.end()) << name;
        return found != entries.end() ? found->status : compare::DirEntryStatus::Same;
    };
    EXPECT_EQ(entries.size(), 4U);
    EXPECT_EQ(status_of("same.txt"), compare::DirEntryStatus::Same);
    EXPECT_EQ(status_of("other.txt"), compare::DirEntryStatus::Different);
    EXPECT_EQ(status_of("left.txt"), compare::DirEntryStatus::LeftOnly);
    EXPECT_EQ(status_of("right.txt"), compare::DirEntryStatus::RightOnly);
}

// macOS keeps a name in the form it was written: Finder and everything through Cocoa write it
// decomposed ("ё" = "е" + U+0308), a terminal or another system — composed. One name on screen,
// two byte strings — and the same file used to show up as "only left" plus "only right".
constexpr std::string_view kComposed = "отчёт";        // "ё" одним знаком
constexpr std::string_view kDecomposed = "отчёт";     // "е" + U+0308

TEST_F(DirDiffTest, should_pair_one_name_written_in_two_unicode_forms) {
    stdfs::create_directories(left_ / kDecomposed);
    stdfs::create_directories(right_ / kComposed);
    write(left_ / kDecomposed / "файл.txt", "один");
    write(right_ / kComposed / "файл.txt", "один");
    write(left_ / (std::string(kDecomposed) + ".pdf"), "отчёт");
    write(right_ / (std::string(kComposed) + ".pdf"), "отчёт, но другой");

    const auto entries = compare(true);
    ASSERT_EQ(entries.size(), 3U) << "пара, а не «только слева» + «только справа»";
    for (const auto& entry : entries) {
        EXPECT_NE(entry.status, compare::DirEntryStatus::LeftOnly) << entry.relative_path;
        EXPECT_NE(entry.status, compare::DirEntryStatus::RightOnly) << entry.relative_path;
    }
    EXPECT_TRUE(entries[0].is_directory);
    EXPECT_EQ(entries[0].relative_path, stdfs::path(kDecomposed)) << "написание левой стороны";
    const auto pdf = std::find_if(entries.begin(), entries.end(), [](const auto& entry) {
        return entry.relative_path.extension() == ".pdf";
    });
    ASSERT_NE(pdf, entries.end());
    EXPECT_EQ(pdf->status, compare::DirEntryStatus::Different) << "содержимое сверено с правым файлом";
}
