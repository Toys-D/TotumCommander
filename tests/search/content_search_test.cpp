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

// ---------------------------------------------------------------------------
// Case
// ---------------------------------------------------------------------------

TEST_F(ContentSearchTest, should_ignore_case_by_default) {
    write_text_file(test_dir_ / "a.txt", "The Needle is here\n");

    const auto result = content_search_.search(test_dir_.string(), "needle");

    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(result.value()[0].line_content, "The Needle is here");
}

TEST_F(ContentSearchTest, should_ignore_case_in_cyrillic) {
    write_text_file(test_dir_ / "a.txt", "первая\nДоговор аренды\n");

    const auto lower = content_search_.search(test_dir_.string(), "договор");
    ASSERT_TRUE(lower.has_value());
    ASSERT_EQ(lower.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(lower.value()[0].line_number, static_cast<uint64_t>(2));
    EXPECT_EQ(lower.value()[0].line_content, "Договор аренды");

    const auto upper = content_search_.search(test_dir_.string(), "ДОГОВОР АРЕНДЫ");
    ASSERT_TRUE(upper.has_value());
    EXPECT_EQ(upper.value().size(), static_cast<std::size_t>(1));
}

TEST_F(ContentSearchTest, should_respect_case_when_asked) {
    write_text_file(test_dir_ / "a.txt", "Договор аренды\nNeedle\n");
    search::ContentOptions options;
    options.case_sensitive = true;

    const auto cyrillic = content_search_.search(test_dir_.string(), "договор", options);
    ASSERT_TRUE(cyrillic.has_value());
    EXPECT_TRUE(cyrillic.value().empty());

    const auto ascii = content_search_.search(test_dir_.string(), "needle", options);
    ASSERT_TRUE(ascii.has_value());
    EXPECT_TRUE(ascii.value().empty());

    const auto exact = content_search_.search(test_dir_.string(), "Договор", options);
    ASSERT_TRUE(exact.has_value());
    EXPECT_EQ(exact.value().size(), static_cast<std::size_t>(1));
}

TEST_F(ContentSearchTest, should_ignore_case_in_a_regex_and_leave_its_escapes_alone) {
    write_text_file(test_dir_ / "a.txt", "договор 15 от мая\nДОГОВОР без номера\n");

    // \S and \D mean the opposite of \s and \d: folding the pattern must not touch them.
    const auto result = content_search_.search(test_dir_.string(), R"(ДОГОВОР\s\d+\s\S+)", true);

    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(result.value()[0].line_number, static_cast<uint64_t>(1));
}

// ---------------------------------------------------------------------------
// Hidden
// ---------------------------------------------------------------------------

TEST_F(ContentSearchTest, should_not_look_into_hidden_places_by_default) {
    stdfs::create_directories(test_dir_ / ".git");
    write_text_file(test_dir_ / ".git" / "HEAD", "needle\n");
    write_text_file(test_dir_ / ".secret.txt", "needle\n");
    write_text_file(test_dir_ / "visible.txt", "needle\n");

    const auto result = content_search_.search(test_dir_.string(), "needle");

    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(result.value()[0].file, test_dir_ / "visible.txt");
}

TEST_F(ContentSearchTest, should_look_into_hidden_places_when_asked) {
    stdfs::create_directories(test_dir_ / ".git");
    write_text_file(test_dir_ / ".git" / "HEAD", "needle\n");
    write_text_file(test_dir_ / "visible.txt", "needle\n");
    search::ContentOptions options;
    options.include_hidden = true;

    const auto result = content_search_.search(test_dir_.string(), "needle", options);

    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result.value().size(), static_cast<std::size_t>(2));
}

// ---------------------------------------------------------------------------
// Encodings — the ones the editor and the viewer read
// ---------------------------------------------------------------------------

TEST_F(ContentSearchTest, should_read_windows_1251) {
    // "Договор в 1251" in Windows-1251.
    write_binary_file(test_dir_ / "win.txt",
                      {0xC4, 0xEE, 0xE3, 0xEE, 0xE2, 0xEE, 0xF0, 0x20, 0xE2, 0x20,
                       0x31, 0x32, 0x35, 0x31, 0x0D, 0x0A});

    const auto result = content_search_.search(test_dir_.string(), "договор");

    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(result.value()[0].line_content, "Договор в 1251");
}

TEST_F(ContentSearchTest, should_read_utf16_with_a_byte_order_mark) {
    // FF FE, then "Да needle\nвторая" in UTF-16LE. Every second byte of the Latin part is a
    // zero, which is what used to get such a file called binary.
    std::vector<unsigned char> bytes = {0xFF, 0xFE};
    const char16_t text[] = u"Да needle\nвторая";
    for (const char16_t unit : text) {
        if (unit == 0) break;
        bytes.push_back(static_cast<unsigned char>(unit & 0xFF));
        bytes.push_back(static_cast<unsigned char>(unit >> 8));
    }
    write_binary_file(test_dir_ / "wide.txt", bytes);

    const auto result = content_search_.search(test_dir_.string(), "NEEDLE");

    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(result.value()[0].line_number, static_cast<uint64_t>(1));
    EXPECT_EQ(result.value()[0].line_content, "Да needle");
}

TEST_F(ContentSearchTest, should_drop_the_carriage_return_of_a_windows_line) {
    write_text_file(test_dir_ / "crlf.txt", "one\r\nneedle here\r\n");

    const auto result = content_search_.search(test_dir_.string(), "needle");

    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(result.value()[0].line_content, "needle here");
}

// ---------------------------------------------------------------------------
// The name mask chooses which files are opened at all
// ---------------------------------------------------------------------------

TEST_F(ContentSearchTest, should_only_open_files_the_name_mask_lets_through) {
    write_text_file(test_dir_ / "a.txt", "needle\n");
    write_text_file(test_dir_ / "b.log", "needle\n");
    write_text_file(test_dir_ / "c.md", "needle\n");
    search::ContentOptions options;

    options.name_mask = "*.TXT";
    const auto one = content_search_.search(test_dir_.string(), "needle", options);
    ASSERT_TRUE(one.has_value());
    ASSERT_EQ(one.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(one.value()[0].file, test_dir_ / "a.txt");

    options.name_mask = "*.txt;*.md";
    const auto two = content_search_.search(test_dir_.string(), "needle", options);
    ASSERT_TRUE(two.has_value());
    EXPECT_EQ(two.value().size(), static_cast<std::size_t>(2));

    options.name_mask = "*";
    const auto all = content_search_.search(test_dir_.string(), "needle", options);
    ASSERT_TRUE(all.has_value());
    EXPECT_EQ(all.value().size(), static_cast<std::size_t>(3));
}

// ---------------------------------------------------------------------------
// A found line is a line to show, not a megabyte to keep
// ---------------------------------------------------------------------------

TEST_F(ContentSearchTest, should_cut_a_very_long_line_down_to_the_part_around_the_match) {
    std::string line(200000, 'x');
    line.replace(100000, 6, "needle");
    write_text_file(test_dir_ / "min.js", line + "\n");

    const auto result = content_search_.search(test_dir_.string(), "needle");

    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result.value().size(), static_cast<std::size_t>(1));
    const auto& shown = result.value()[0].line_content;
    EXPECT_LE(shown.size(), static_cast<std::size_t>(600));
    EXPECT_NE(shown.find("needle"), std::string::npos);
    EXPECT_EQ(result.value()[0].column, static_cast<uint64_t>(100001));
}

// ---------------------------------------------------------------------------
// Size and date limits — the same ones the name search has
// ---------------------------------------------------------------------------

TEST_F(ContentSearchTest, should_only_open_files_within_the_size_limits) {
    write_text_file(test_dir_ / "small.txt", "needle\n");
    write_text_file(test_dir_ / "big.txt", "needle\n" + std::string(5000, 'x') + "\n");
    search::ContentOptions options;

    options.limits.min_size = 1000;
    const auto big = content_search_.search(test_dir_.string(), "needle", options);
    ASSERT_TRUE(big.has_value());
    ASSERT_EQ(big.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(big.value()[0].file, test_dir_ / "big.txt");

    options.limits.min_size = 0;
    options.limits.max_size = 1000;
    const auto small = content_search_.search(test_dir_.string(), "needle", options);
    ASSERT_TRUE(small.has_value());
    ASSERT_EQ(small.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(small.value()[0].file, test_dir_ / "small.txt");
}

TEST_F(ContentSearchTest, should_only_open_files_changed_within_the_dates) {
    write_text_file(test_dir_ / "old.txt", "needle\n");
    write_text_file(test_dir_ / "fresh.txt", "needle\n");
    const auto now = std::chrono::system_clock::now();
    stdfs::last_write_time(test_dir_ / "old.txt",
                           stdfs::file_time_type::clock::now() - std::chrono::hours(24 * 30));
    search::ContentOptions options;

    options.limits.date_from = now - std::chrono::hours(24 * 7);
    const auto recent = content_search_.search(test_dir_.string(), "needle", options);
    ASSERT_TRUE(recent.has_value());
    ASSERT_EQ(recent.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(recent.value()[0].file, test_dir_ / "fresh.txt");

    options.limits.date_from = {};
    options.limits.date_to = now - std::chrono::hours(24 * 7);
    const auto older = content_search_.search(test_dir_.string(), "needle", options);
    ASSERT_TRUE(older.has_value());
    ASSERT_EQ(older.value().size(), static_cast<std::size_t>(1));
    EXPECT_EQ(older.value()[0].file, test_dir_ / "old.txt");
}

// ---------------------------------------------------------------------------
// One answer per file
// ---------------------------------------------------------------------------

TEST_F(ContentSearchTest, should_answer_once_per_file_and_count_the_rest) {
    write_text_file(test_dir_ / "many.txt", "first needle\nnothing\nsecond needle\nthird needle\n");
    write_text_file(test_dir_ / "one.txt", "skip\nthe only needle\n");
    search::ContentOptions options;
    options.one_per_file = true;
    int told = 0;

    const auto result = content_search_.search(
        test_dir_.string(), "needle", options,
        [&told](const search::ContentMatch& match) {
            ++told;
            // Told about a file only once it has been read to the end: the count is final.
            if (match.file.filename() == "many.txt") {
                EXPECT_EQ(match.match_count, static_cast<uint64_t>(3));
            }
        });

    ASSERT_TRUE(result.has_value());
    ASSERT_EQ(result.value().size(), static_cast<std::size_t>(2));
    EXPECT_EQ(told, 2);
    for (const auto& match : result.value()) {
        if (match.file.filename() == "many.txt") {
            EXPECT_EQ(match.line_number, static_cast<uint64_t>(1));
            EXPECT_EQ(match.line_content, "first needle");
            EXPECT_EQ(match.match_count, static_cast<uint64_t>(3));
        } else {
            EXPECT_EQ(match.line_number, static_cast<uint64_t>(2));
            EXPECT_EQ(match.match_count, static_cast<uint64_t>(1));
        }
    }
}

TEST_F(ContentSearchTest, should_keep_answering_per_line_unless_asked_otherwise) {
    write_text_file(test_dir_ / "many.txt", "first needle\nsecond needle\n");

    const auto result = content_search_.search(test_dir_.string(), "needle");

    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result.value().size(), static_cast<std::size_t>(2));
}
