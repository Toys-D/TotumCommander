#include <gtest/gtest.h>
#include <filesystem>
#include <fstream>
#include <sys/stat.h>   // chflags / UF_HIDDEN
#include "fcxl/filesystem/navigator.h"

using namespace fcxl;
namespace stdfs = std::filesystem;

class NavigatorTest : public ::testing::Test {
protected:
    void SetUp() override {
        test_dir_ = stdfs::temp_directory_path() / "fcxl_test_navigator";
        stdfs::create_directories(test_dir_);
        create_file(test_dir_ / "file_a.txt", "hello");
        create_file(test_dir_ / "file_b.cpp", "world");
        create_file(test_dir_ / ".hidden_file", "secret");
        stdfs::create_directory(test_dir_ / "subdir");
        stdfs::create_directory(test_dir_ / ".hidden_dir");
    }
    void TearDown() override { stdfs::remove_all(test_dir_); }
    static void create_file(const stdfs::path& p, std::string_view c) {
        std::ofstream ofs(p); ofs << c;
    }
    stdfs::path test_dir_;
    fs::Navigator navigator_;
};

TEST_F(NavigatorTest, should_list_files_in_directory) {
    auto result = navigator_.list_directory(test_dir_.string(), false);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result.value().size(), 3u);
}

TEST_F(NavigatorTest, should_list_files_in_directory_using_fast_path) {
    auto result = navigator_.list_directory_fast(test_dir_.string(), false);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result.value().size(), 3u);
}

TEST_F(NavigatorTest, should_list_hidden_files_when_requested) {
    auto result = navigator_.list_directory(test_dir_.string(), true);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result.value().size(), 5u);
}

TEST_F(NavigatorTest, should_list_hidden_files_when_requested_using_fast_path) {
    auto result = navigator_.list_directory_fast(test_dir_.string(), true);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result.value().size(), 5u);
}

#if defined(__APPLE__)
// A file with a NORMAL name but the macOS UF_HIDDEN flag (what Finder and our properties
// window set) must count as hidden — filtered out unless hidden files are shown. Before the
// fix, hidden was decided purely by the leading dot, so this file stayed visible.
TEST_F(NavigatorTest, should_honour_UF_HIDDEN_flag_on_a_normal_named_file) {
    const auto flagged = test_dir_ / "flagged_visible_name.txt";
    create_file(flagged, "x");
    ASSERT_EQ(::chflags(flagged.c_str(), UF_HIDDEN), 0) << "could not set UF_HIDDEN";

    auto has_flagged = [](const auto& entries) {
        for (const auto& e : entries) {
            if (e.name == "flagged_visible_name.txt") return true;
        }
        return false;
    };

    // Hidden files OFF → filtered on BOTH listing paths.
    auto std_off = navigator_.list_directory(test_dir_.string(), false);
    ASSERT_TRUE(std_off.has_value());
    EXPECT_FALSE(has_flagged(std_off.value())) << "std path leaked a UF_HIDDEN file";

    auto fast_off = navigator_.list_directory_fast(test_dir_.string(), false);
    ASSERT_TRUE(fast_off.has_value());
    EXPECT_FALSE(has_flagged(fast_off.value())) << "fast path leaked a UF_HIDDEN file";

    // Hidden files ON → present, and marked is_hidden.
    auto shown = navigator_.list_directory(test_dir_.string(), true);
    ASSERT_TRUE(shown.has_value());
    bool found = false;
    for (const auto& e : shown.value()) {
        if (e.name == "flagged_visible_name.txt") {
            found = true;
            EXPECT_TRUE(e.is_hidden) << "a UF_HIDDEN file must report is_hidden";
        }
    }
    EXPECT_TRUE(found) << "the flag-hidden file must show when hidden files are enabled";
}
#endif

TEST_F(NavigatorTest, should_return_error_for_nonexistent_path) {
    auto result = navigator_.list_directory("/nonexistent/path/12345");
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::NotFound);
}

TEST_F(NavigatorTest, should_return_error_for_nonexistent_path_using_fast_path) {
    auto result = navigator_.list_directory_fast("/nonexistent/path/12345");
    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::NotFound);
}

TEST_F(NavigatorTest, should_get_parent_path) {
    auto result = navigator_.parent_path(test_dir_.string());
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result.value(), test_dir_.parent_path());
}

TEST_F(NavigatorTest, should_validate_existing_directory) {
    EXPECT_TRUE(navigator_.is_valid_directory(test_dir_.string()));
}

TEST_F(NavigatorTest, should_reject_nonexistent_as_directory) {
    EXPECT_FALSE(navigator_.is_valid_directory("/nonexistent/path"));
}
