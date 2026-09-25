#include <gtest/gtest.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <pwd.h>
#include <string>
#include <string_view>
#include <unistd.h>

#include "fcxl/filesystem/attributes.h"

using namespace fcxl;
namespace stdfs = std::filesystem;

class AttributesTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        test_dir_ = stdfs::temp_directory_path() / ("fcxl_test_attributes_" + unique);
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
    fs::Attributes attributes_;
};

TEST_F(AttributesTest, should_get_permissions) {
    const auto file_path = test_dir_ / "permissions.txt";
    create_file(file_path, "data");
    ASSERT_EQ(::chmod(file_path.c_str(), 0755), 0);

    const auto result = attributes_.get_permissions(file_path.string());

    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result.value(), "rwxr-xr-x");
}

TEST_F(AttributesTest, should_set_permissions) {
    const auto file_path = test_dir_ / "set_permissions.txt";
    create_file(file_path, "data");

    const auto set_result = attributes_.set_permissions(file_path.string(), "rw-r-----");
    ASSERT_TRUE(set_result.has_value());

    const auto get_result = attributes_.get_permissions(file_path.string());
    ASSERT_TRUE(get_result.has_value());
    EXPECT_EQ(get_result.value(), "rw-r-----");
}

TEST_F(AttributesTest, should_get_owner) {
    const auto file_path = test_dir_ / "owner.txt";
    create_file(file_path, "data");

    const auto result = attributes_.get_owner(file_path.string());

    ASSERT_TRUE(result.has_value());
    ASSERT_FALSE(result.value().empty());

    const passwd* pwd = ::getpwuid(::getuid());
    ASSERT_NE(pwd, nullptr);
    EXPECT_EQ(result.value(), std::string(pwd->pw_name));
}

TEST_F(AttributesTest, should_return_error_for_nonexistent_path) {
    const auto missing_path = test_dir_ / "missing.txt";

    const auto result = attributes_.get_permissions(missing_path.string());

    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::NotFound);
}

TEST_F(AttributesTest, should_list_xattrs) {
    const auto file_path = test_dir_ / "list_xattrs.txt";
    create_file(file_path, "data");

    ASSERT_TRUE(attributes_.set_xattr(file_path.string(), "user.fcxl.a", "one").has_value());
    ASSERT_TRUE(attributes_.set_xattr(file_path.string(), "user.fcxl.b", "two").has_value());

    const auto result = attributes_.list_xattrs(file_path.string());

    ASSERT_TRUE(result.has_value());
    const auto& names = result.value();
    EXPECT_NE(std::find(names.begin(), names.end(), "user.fcxl.a"), names.end());
    EXPECT_NE(std::find(names.begin(), names.end(), "user.fcxl.b"), names.end());
}

TEST_F(AttributesTest, should_set_and_get_xattr) {
    const auto file_path = test_dir_ / "xattr.txt";
    create_file(file_path, "data");

    const auto set_result = attributes_.set_xattr(file_path.string(), "user.fcxl.note", "hello-xattr");
    ASSERT_TRUE(set_result.has_value());

    const auto get_result = attributes_.get_xattr(file_path.string(), "user.fcxl.note");

    ASSERT_TRUE(get_result.has_value());
    EXPECT_EQ(get_result.value(), "hello-xattr");
}

TEST_F(AttributesTest, should_remove_xattr) {
    const auto file_path = test_dir_ / "remove_xattr.txt";
    create_file(file_path, "data");

    ASSERT_TRUE(attributes_.set_xattr(file_path.string(), "user.fcxl.temp", "tmp").has_value());

    const auto remove_result = attributes_.remove_xattr(file_path.string(), "user.fcxl.temp");
    ASSERT_TRUE(remove_result.has_value());

    const auto get_result = attributes_.get_xattr(file_path.string(), "user.fcxl.temp");
    ASSERT_FALSE(get_result.has_value());
    EXPECT_EQ(get_result.error().code, common::ErrorCode::NotFound);
}
