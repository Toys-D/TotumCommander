#include <gtest/gtest.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>

#include "fcxl/tools/checksum.h"

using namespace fcxl;
namespace stdfs = std::filesystem;

class ChecksumTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        test_dir_ = stdfs::temp_directory_path() / ("fcxl_test_checksum_" + unique);
        stdfs::create_directories(test_dir_);

        // Create a test file with known content "hello\n"
        test_file_ = test_dir_ / "hello.txt";
        std::ofstream ofs(test_file_);
        ofs << "hello\n";
    }

    void TearDown() override {
        std::error_code ec;
        stdfs::remove_all(test_dir_, ec);
    }

    stdfs::path test_dir_;
    stdfs::path test_file_;
    tools::Checksum checksum_;
};

TEST_F(ChecksumTest, should_compute_md5) {
    auto result = checksum_.md5(test_file_.string());
    ASSERT_TRUE(result.has_value());
    // "hello\n" MD5 = b1946ac92492d2347c6235b4d2611184
    EXPECT_EQ(result.value(), "b1946ac92492d2347c6235b4d2611184");
}

TEST_F(ChecksumTest, should_compute_sha1) {
    auto result = checksum_.sha1(test_file_.string());
    ASSERT_TRUE(result.has_value());
    // "hello\n" SHA1 = f572d396fae9206628714fb2ce00f72e94f2258f
    EXPECT_EQ(result.value(), "f572d396fae9206628714fb2ce00f72e94f2258f");
}

TEST_F(ChecksumTest, should_compute_sha256) {
    auto result = checksum_.sha256(test_file_.string());
    ASSERT_TRUE(result.has_value());
    // "hello\n" SHA256 = 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
    EXPECT_EQ(result.value(), "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03");
}

TEST_F(ChecksumTest, should_compute_all_in_single_pass) {
    auto result = checksum_.compute_all(test_file_.string());
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result.value().md5, "b1946ac92492d2347c6235b4d2611184");
    EXPECT_EQ(result.value().sha1, "f572d396fae9206628714fb2ce00f72e94f2258f");
    EXPECT_EQ(result.value().sha256, "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03");
}

TEST_F(ChecksumTest, should_verify_matching_hash) {
    auto result = checksum_.verify(test_file_.string(), "b1946ac92492d2347c6235b4d2611184");
    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(result.value());
}

TEST_F(ChecksumTest, should_reject_wrong_hash) {
    auto result = checksum_.verify(test_file_.string(), "00000000000000000000000000000000");
    ASSERT_TRUE(result.has_value());
    EXPECT_FALSE(result.value());
}

TEST_F(ChecksumTest, should_return_error_for_missing_file) {
    auto result = checksum_.md5("/tmp/fcxl_nonexistent_file_12345.txt");
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::NotFound);
}

TEST_F(ChecksumTest, should_reject_invalid_hash_length) {
    auto result = checksum_.verify(test_file_.string(), "abc");
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::InvalidArgument);
}
