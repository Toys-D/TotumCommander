#include <gtest/gtest.h>

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>
#include <vector>

#include "fcxl/viewer/text_viewer.h"

namespace stdfs = std::filesystem;

class TextViewerTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        test_dir_ = stdfs::temp_directory_path() / ("fcxl_test_text_viewer_" + unique);
        stdfs::create_directories(test_dir_);
    }

    void TearDown() override {
        std::error_code ec;
        stdfs::remove_all(test_dir_, ec);
    }

    static auto write_text_file(const stdfs::path& path, std::string_view content) -> void {
        std::ofstream ofs(path, std::ios::binary);
        ofs << content;
    }

    static auto write_binary_file(const stdfs::path& path,
                                  const std::vector<std::uint8_t>& bytes) -> void {
        std::ofstream ofs(path, std::ios::binary);
        ofs.write(reinterpret_cast<const char*>(bytes.data()),
                  static_cast<std::streamsize>(bytes.size()));
    }

    stdfs::path test_dir_;
    fcxl::viewer::TextViewer viewer_;
};

TEST_F(TextViewerTest, should_open_file_count_lines_and_get_requested_slice) {
    const auto file = test_dir_ / "sample.txt";
    write_text_file(file, "line1\nline2\nline3\nline4");

    const auto open_result = viewer_.open(file.string());
    ASSERT_TRUE(open_result.has_value());
    EXPECT_EQ(viewer_.total_lines(), static_cast<std::uint64_t>(4));

    const auto lines_result = viewer_.get_lines(1, 2);
    ASSERT_TRUE(lines_result.has_value());
    ASSERT_EQ(lines_result.value().size(), static_cast<std::size_t>(2));
    EXPECT_EQ(lines_result.value()[0], "line2");
    EXPECT_EQ(lines_result.value()[1], "line3");
}

TEST_F(TextViewerTest, should_detect_utf8_bom_encoding) {
    const auto file = test_dir_ / "bom.txt";
    write_binary_file(file, {0xEF, 0xBB, 0xBF, 'o', 'k', '\n'});

    const auto open_result = viewer_.open(file.string());
    ASSERT_TRUE(open_result.has_value());
    EXPECT_EQ(viewer_.detected_encoding(), "UTF-8");

    const auto lines_result = viewer_.get_lines(0, 1);
    ASSERT_TRUE(lines_result.has_value());
    ASSERT_EQ(lines_result.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(lines_result.value()[0], "ok");
}

TEST_F(TextViewerTest, should_detect_language_from_extension) {
    const auto file = test_dir_ / "main.swift";
    write_text_file(file, "print(\"hello\")\n");

    const auto open_result = viewer_.open(file.string());
    ASSERT_TRUE(open_result.has_value());
    EXPECT_EQ(viewer_.detect_language(), "swift");
}

TEST_F(TextViewerTest, should_return_empty_lines_when_offset_is_out_of_range) {
    const auto file = test_dir_ / "short.txt";
    write_text_file(file, "line1\nline2\n");

    const auto open_result = viewer_.open(file.string());
    ASSERT_TRUE(open_result.has_value());

    const auto lines_result = viewer_.get_lines(20, 5);
    ASSERT_TRUE(lines_result.has_value());
    EXPECT_TRUE(lines_result.value().empty());
}

TEST_F(TextViewerTest, should_return_not_found_for_missing_file) {
    const auto missing = test_dir_ / "missing.txt";

    const auto open_result = viewer_.open(missing.string());
    ASSERT_FALSE(open_result.has_value());
    EXPECT_EQ(open_result.error().code, fcxl::common::ErrorCode::NotFound);
}
