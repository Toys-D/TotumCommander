#include <gtest/gtest.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "fcxl/tools/multi_rename.h"

using namespace fcxl;
namespace stdfs = std::filesystem;

class MultiRenameTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        test_dir_ = stdfs::temp_directory_path() / ("fcxl_test_rename_" + unique);
        stdfs::create_directories(test_dir_);
    }

    void TearDown() override {
        std::error_code ec;
        stdfs::remove_all(test_dir_, ec);
    }

    void create_file(const std::string& name) {
        std::ofstream ofs(test_dir_ / name);
        ofs << "data";
    }

    stdfs::path test_dir_;
    tools::MultiRename renamer_;
};

TEST_F(MultiRenameTest, should_preview_text_replacement) {
    std::vector<std::string> files = {
        (test_dir_ / "photo_old.jpg").string(),
        (test_dir_ / "photo_old_2.jpg").string()
    };

    tools::RenameRule rule;
    rule.search_pattern = "old";
    rule.replace_pattern = "new";

    auto previews = renamer_.preview(files, rule);

    ASSERT_EQ(previews.size(), 2u);
    EXPECT_EQ(previews[0].original, "photo_old.jpg");
    EXPECT_EQ(previews[0].renamed, "photo_new.jpg");
    EXPECT_EQ(previews[1].original, "photo_old_2.jpg");
    EXPECT_EQ(previews[1].renamed, "photo_new_2.jpg");
}

TEST_F(MultiRenameTest, should_preview_regex_replacement) {
    std::vector<std::string> files = {
        (test_dir_ / "IMG_20240101.jpg").string()
    };

    tools::RenameRule rule;
    rule.search_pattern = R"(IMG_(\d{4})(\d{2})(\d{2}))";
    rule.replace_pattern = "Photo_$1-$2-$3";
    rule.use_regex = true;

    auto previews = renamer_.preview(files, rule);

    ASSERT_EQ(previews.size(), 1u);
    EXPECT_EQ(previews[0].renamed, "Photo_2024-01-01.jpg");
}

TEST_F(MultiRenameTest, should_preview_counter) {
    std::vector<std::string> files = {
        (test_dir_ / "a.txt").string(),
        (test_dir_ / "b.txt").string(),
        (test_dir_ / "c.txt").string()
    };

    tools::RenameRule rule;
    rule.search_pattern = "";
    rule.replace_pattern = "";
    rule.counter_format = "_{N:03}";

    auto previews = renamer_.preview(files, rule);

    ASSERT_EQ(previews.size(), 3u);
    EXPECT_EQ(previews[0].renamed, "a_001.txt");
    EXPECT_EQ(previews[1].renamed, "b_002.txt");
    EXPECT_EQ(previews[2].renamed, "c_003.txt");
}

TEST_F(MultiRenameTest, should_execute_rename) {
    create_file("alpha.txt");
    create_file("beta.txt");

    std::vector<std::string> files = {
        (test_dir_ / "alpha.txt").string(),
        (test_dir_ / "beta.txt").string()
    };

    tools::RenameRule rule;
    rule.search_pattern = "";
    rule.replace_pattern = "";
    rule.counter_format = "_{N:02}";

    auto result = renamer_.execute(files, rule);

    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(stdfs::exists(test_dir_ / "alpha_01.txt"));
    EXPECT_TRUE(stdfs::exists(test_dir_ / "beta_02.txt"));
    EXPECT_FALSE(stdfs::exists(test_dir_ / "alpha.txt"));
    EXPECT_FALSE(stdfs::exists(test_dir_ / "beta.txt"));
}

TEST_F(MultiRenameTest, should_fail_on_conflict) {
    create_file("a.txt");
    create_file("b.txt");

    std::vector<std::string> files = {
        (test_dir_ / "a.txt").string()
    };

    tools::RenameRule rule;
    rule.search_pattern = "a";
    rule.replace_pattern = "b";

    auto result = renamer_.execute(files, rule);

    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::AlreadyExists);
}
