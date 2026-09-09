#include <gtest/gtest.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>
#include <vector>

#include "fcxl/search/content_search.h"

using namespace fcxl;
namespace stdfs = std::filesystem;

class ContentSearchTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        test_dir_ = stdfs::temp_directory_path() / ("fcxl_test_content_search_" + unique);
        stdfs::create_directories(test_dir_);
    }

    void TearDown() override {
        std::error_code ec;
        stdfs::remove_all(test_dir_, ec);
    }

    static void write_text_file(const stdfs::path& path, std::string_view content) {
        std::ofstream ofs(path, std::ios::binary);
        ofs << content;
    }

    static void write_binary_file(const stdfs::path& path, const std::vector<unsigned char>& bytes) {
        std::ofstream ofs(path, std::ios::binary);
        ofs.write(reinterpret_cast<const char*>(bytes.data()),
                  static_cast<std::streamsize>(bytes.size()));
    }

    stdfs::path test_dir_;
    search::ContentSearch content_search_;
};

TEST_F(ContentSearchTest, should_find_text_in_file) {
    const auto file = test_dir_ / "notes.txt";
    write_text_file(file, "hello\nfind me here\nbye\n");

    const auto result = content_search_.search(test_dir_.string(), "find me");

    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(result.value()[0].file, file);
    EXPECT_EQ(result.value()[0].line_content, "find me here");
}

TEST_F(ContentSearchTest, should_return_correct_line_number) {
    const auto file = test_dir_ / "lines.txt";
    write_text_file(file, "line1\nline2\ntarget value\nline4\n");

    const auto result = content_search_.search(test_dir_.string(), "target");

    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(result.value()[0].line_number, static_cast<uint64_t>(3));
    EXPECT_EQ(result.value()[0].column, static_cast<uint64_t>(1));
}

TEST_F(ContentSearchTest, should_find_by_regex) {
    const auto file = test_dir_ / "regex.txt";
    write_text_file(file, "abc-111\nabc-xyz\nabc-222\n");

    const auto result = content_search_.search(test_dir_.string(), R"(abc-\d+)", true);

    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result.value().size(), static_cast<std::size_t>(2));
    EXPECT_EQ(result.value()[0].line_content, "abc-111");
    EXPECT_EQ(result.value()[1].line_content, "abc-222");
}

TEST_F(ContentSearchTest, should_search_recursively) {
    const auto nested = test_dir_ / "sub" / "nested";
    stdfs::create_directories(nested);
    const auto file = nested / "deep.txt";
    write_text_file(file, "root\nneedle\n");

    const auto result = content_search_.search(test_dir_.string(), "needle", false, true);

    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(result.value()[0].file, file);
}

TEST_F(ContentSearchTest, should_skip_binary_files) {
    const auto text_file = test_dir_ / "text.txt";
    const auto binary_file = test_dir_ / "binary.bin";

    write_text_file(text_file, "needle text\n");
    write_binary_file(binary_file, {0x41, 0x42, 0x00, 0x43, 0x44, 0x45});

    const auto result = content_search_.search(test_dir_.string(), "needle");

    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(result.value()[0].file, text_file);
}

TEST_F(ContentSearchTest, should_return_empty_for_no_match) {
    write_text_file(test_dir_ / "a.txt", "hello");
    write_text_file(test_dir_ / "b.txt", "world");

    const auto result = content_search_.search(test_dir_.string(), "missing-value");

    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(result.value().empty());
}

TEST_F(ContentSearchTest, should_cancel_search) {
    const auto file = test_dir_ / "many.txt";
    std::string large_content;
    for (int i = 0; i < 500; ++i) {
        large_content += "target line " + std::to_string(i) + "\n";
    }
    write_text_file(file, large_content);

    const auto result = content_search_.search(
        test_dir_.string(),
        "target",
        false,
        true,
        {},
        [&](const search::ContentMatch&) { content_search_.cancel(); });

    ASSERT_TRUE(result.has_value());
    EXPECT_LT(result.value().size(), static_cast<std::size_t>(500));
    EXPECT_FALSE(result.value().empty());
}
