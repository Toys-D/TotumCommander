#include <gtest/gtest.h>

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "fcxl/viewer/hex_viewer.h"

namespace stdfs = std::filesystem;

class HexViewerTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        test_dir_ = stdfs::temp_directory_path() / ("fcxl_test_hex_viewer_" + unique);
        stdfs::create_directories(test_dir_);
    }

    void TearDown() override {
        std::error_code ec;
        stdfs::remove_all(test_dir_, ec);
    }

    static auto write_binary_file(const stdfs::path& path,
                                  const std::vector<std::uint8_t>& bytes) -> void {
        std::ofstream ofs(path, std::ios::binary);
        ofs.write(reinterpret_cast<const char*>(bytes.data()),
                  static_cast<std::streamsize>(bytes.size()));
    }

    stdfs::path test_dir_;
    fcxl::viewer::HexViewer viewer_;
};

TEST_F(HexViewerTest, should_open_file_and_report_size) {
    const auto file = test_dir_ / "bytes.bin";
    write_binary_file(file, {0x00, 0x01, 0x41, 0x7E, 0x7F});

    const auto open_result = viewer_.open(file.string());
    ASSERT_TRUE(open_result.has_value());
    EXPECT_EQ(viewer_.file_size(), static_cast<std::uint64_t>(5));
}

TEST_F(HexViewerTest, should_read_hex_lines_with_offsets_and_ascii) {
    const auto file = test_dir_ / "sample.bin";
    write_binary_file(file, {'A', 'B', 'C', 0x00, 'D', 'E'});

    const auto open_result = viewer_.open(file.string());
    ASSERT_TRUE(open_result.has_value());

    const auto lines_result = viewer_.get_lines(0, 2, 4);
    ASSERT_TRUE(lines_result.has_value());
    ASSERT_EQ(lines_result.value().size(), static_cast<std::size_t>(2));

    EXPECT_EQ(lines_result.value()[0].offset, static_cast<std::uint64_t>(0));
    EXPECT_EQ(lines_result.value()[0].bytes,
              (std::vector<std::uint8_t>{'A', 'B', 'C', 0x00}));
    EXPECT_EQ(lines_result.value()[0].ascii, "ABC.");

    EXPECT_EQ(lines_result.value()[1].offset, static_cast<std::uint64_t>(4));
    EXPECT_EQ(lines_result.value()[1].bytes,
              (std::vector<std::uint8_t>{'D', 'E'}));
    EXPECT_EQ(lines_result.value()[1].ascii, "DE");
}

TEST_F(HexViewerTest, should_return_empty_lines_for_offset_beyond_end) {
    const auto file = test_dir_ / "tiny.bin";
    write_binary_file(file, {0x10, 0x11, 0x12});

    const auto open_result = viewer_.open(file.string());
    ASSERT_TRUE(open_result.has_value());

    const auto lines_result = viewer_.get_lines(100, 5, 16);
    ASSERT_TRUE(lines_result.has_value());
    EXPECT_TRUE(lines_result.value().empty());
}

TEST_F(HexViewerTest, should_reject_zero_bytes_per_line) {
    const auto file = test_dir_ / "tiny.bin";
    write_binary_file(file, {0x10, 0x11});

    const auto open_result = viewer_.open(file.string());
    ASSERT_TRUE(open_result.has_value());

    const auto lines_result = viewer_.get_lines(0, 2, 0);
    ASSERT_FALSE(lines_result.has_value());
    EXPECT_EQ(lines_result.error().code, fcxl::common::ErrorCode::InvalidArgument);
}

TEST_F(HexViewerTest, should_return_not_found_for_missing_file) {
    const auto missing = test_dir_ / "missing.bin";

    const auto open_result = viewer_.open(missing.string());
    ASSERT_FALSE(open_result.has_value());
    EXPECT_EQ(open_result.error().code, fcxl::common::ErrorCode::NotFound);
}
