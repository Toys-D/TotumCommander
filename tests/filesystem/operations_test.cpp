#include <gtest/gtest.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>

#include "fcxl/filesystem/operations.h"

using namespace fcxl;
namespace stdfs = std::filesystem;

class OperationsTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        test_dir_ = stdfs::temp_directory_path() / ("fcxl_test_operations_" + unique);
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

    static auto read_file(const stdfs::path& path) -> std::string {
        std::ifstream ifs(path);
        return std::string(std::istreambuf_iterator<char>(ifs), std::istreambuf_iterator<char>());
    }

    stdfs::path test_dir_;
    fs::Operations operations_;
};

TEST_F(OperationsTest, should_copy_file) {
    const auto source = test_dir_ / "source.txt";
    const auto destination = test_dir_ / "destination.txt";
    create_file(source, "hello copy");

    const auto result = operations_.copy(source.string(), destination.string());

    ASSERT_TRUE(result.has_value());
    ASSERT_TRUE(stdfs::exists(destination));
    EXPECT_EQ(read_file(destination), "hello copy");
}

TEST_F(OperationsTest, should_copy_directory_recursively) {
    const auto source_dir = test_dir_ / "source_dir";
    const auto nested_dir = source_dir / "nested";
    stdfs::create_directories(nested_dir);
    create_file(source_dir / "root.txt", "root");
    create_file(nested_dir / "nested.txt", "nested");

    const auto destination_dir = test_dir_ / "destination_dir";
    const auto result = operations_.copy(source_dir.string(), destination_dir.string());

    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(stdfs::is_directory(destination_dir));
    EXPECT_TRUE(stdfs::exists(destination_dir / "root.txt"));
    EXPECT_TRUE(stdfs::exists(destination_dir / "nested" / "nested.txt"));
}

TEST_F(OperationsTest, should_move_file) {
    const auto source = test_dir_ / "move_source.txt";
    const auto destination = test_dir_ / "move_destination.txt";
    create_file(source, "move me");

    const auto result = operations_.move(source.string(), destination.string());

    ASSERT_TRUE(result.has_value());
    EXPECT_FALSE(stdfs::exists(source));
    EXPECT_TRUE(stdfs::exists(destination));
}

TEST_F(OperationsTest, should_rename_file) {
    const auto source = test_dir_ / "old_name.txt";
    create_file(source, "rename me");

    const auto result = operations_.rename(source.string(), "new_name.txt");

    ASSERT_TRUE(result.has_value());
    EXPECT_FALSE(stdfs::exists(source));
    EXPECT_TRUE(stdfs::exists(test_dir_ / "new_name.txt"));
}

TEST_F(OperationsTest, should_delete_file) {
    const auto file_path = test_dir_ / "delete_me.txt";
    create_file(file_path, "delete");

    const auto result = operations_.remove(file_path.string(), false);

    ASSERT_TRUE(result.has_value());
    EXPECT_FALSE(stdfs::exists(file_path));
}

TEST_F(OperationsTest, should_trash_file) {
    const auto file_path = test_dir_ / "trash_me.txt";
    create_file(file_path, "trash");

    const auto result = operations_.trash(file_path.string());

    ASSERT_TRUE(result.has_value());
    EXPECT_FALSE(stdfs::exists(file_path));
}

TEST_F(OperationsTest, should_create_directory) {
    const auto dir_path = test_dir_ / "new_dir";

    const auto result = operations_.create_directory(dir_path.string());

    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(stdfs::is_directory(dir_path));
}

TEST_F(OperationsTest, should_create_nested_directories) {
    const auto dir_path = test_dir_ / "a" / "b" / "c";

    const auto result = operations_.create_directories(dir_path.string());

    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(stdfs::is_directory(dir_path));
}

TEST_F(OperationsTest, should_return_error_for_nonexistent_source) {
    const auto source = test_dir_ / "missing.txt";
    const auto destination = test_dir_ / "out.txt";

    const auto result = operations_.copy(source.string(), destination.string());

    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::NotFound);
}

TEST_F(OperationsTest, should_return_error_copying_to_existing_file) {
    const auto source = test_dir_ / "source.txt";
    const auto destination = test_dir_ / "destination.txt";
    create_file(source, "source");
    create_file(destination, "destination");

    const auto result =
        operations_.copy(source.string(), destination.string(), common::ConflictResolution::Skip);

    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::AlreadyExists);
    EXPECT_EQ(read_file(destination), "destination");
}
