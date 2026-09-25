#include <gtest/gtest.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>

#include "fcxl/filesystem/symlinks.h"

using namespace fcxl;
namespace stdfs = std::filesystem;

class SymlinksTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        test_dir_ = stdfs::temp_directory_path() / ("fcxl_test_symlinks_" + unique);
        stdfs::create_directories(test_dir_);
    }

    void TearDown() override {
        std::error_code ec;
        stdfs::remove_all(test_dir_, ec);
    }

    static void create_file(const stdfs::path& path, std::string_view content) {
        std::ofstream ofs(path);
        ofs << content;
    }

    stdfs::path test_dir_;
    fs::Symlinks symlinks_;
};

TEST_F(SymlinksTest, should_create_symlink) {
    const auto target = test_dir_ / "target.txt";
    const auto link = test_dir_ / "link.txt";
    create_file(target, "data");

    const auto result = symlinks_.create_symlink(target.string(), link.string());

    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(stdfs::exists(link));
    EXPECT_TRUE(stdfs::is_symlink(link));
}

TEST_F(SymlinksTest, should_read_symlink) {
    const auto target = test_dir_ / "target_read.txt";
    const auto link = test_dir_ / "link_read.txt";
    create_file(target, "data");
    ASSERT_TRUE(symlinks_.create_symlink(target.string(), link.string()).has_value());

    const auto result = symlinks_.read_symlink(link.string());

    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result.value(), target);
}

TEST_F(SymlinksTest, should_detect_symlink) {
    const auto target = test_dir_ / "target_detect.txt";
    const auto link = test_dir_ / "link_detect.txt";
    create_file(target, "data");
    ASSERT_TRUE(symlinks_.create_symlink(target.string(), link.string()).has_value());

    EXPECT_TRUE(symlinks_.is_symlink(link.string()));
    EXPECT_FALSE(symlinks_.is_symlink(target.string()));
}

TEST_F(SymlinksTest, should_create_hardlink) {
    const auto target = test_dir_ / "target_hard.txt";
    const auto link = test_dir_ / "link_hard.txt";
    create_file(target, "data");

    const auto result = symlinks_.create_hardlink(target.string(), link.string());

    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(stdfs::exists(link));
    EXPECT_GE(stdfs::hard_link_count(target), static_cast<std::uintmax_t>(2));
}

TEST_F(SymlinksTest, should_return_error_for_nonexistent_target) {
    const auto target = test_dir_ / "missing.txt";
    const auto link = test_dir_ / "link_missing.txt";

    const auto result = symlinks_.create_symlink(target.string(), link.string());

    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::NotFound);
}

TEST_F(SymlinksTest, should_create_and_resolve_alias) {
    const auto target = test_dir_ / "alias_target.txt";
    const auto alias = test_dir_ / "alias_link";
    create_file(target, "alias data");

    const auto create_result = symlinks_.create_alias(target.string(), alias.string());
    ASSERT_TRUE(create_result.has_value()) << create_result.error().message;

    EXPECT_TRUE(symlinks_.is_alias(alias.string()));

    const auto resolve_result = symlinks_.resolve_alias(alias.string());
    ASSERT_TRUE(resolve_result.has_value()) << resolve_result.error().message;
    EXPECT_EQ(resolve_result.value(), stdfs::canonical(target));
}

TEST_F(SymlinksTest, should_not_detect_regular_file_as_alias) {
    const auto file = test_dir_ / "regular.txt";
    create_file(file, "not an alias");

    EXPECT_FALSE(symlinks_.is_alias(file.string()));
}
