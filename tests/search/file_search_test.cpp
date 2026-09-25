#include <gtest/gtest.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

#include "fcxl/search/exclusions.h"
#include "fcxl/search/file_search.h"
#include "fcxl/search/name_match.h"

using namespace fcxl;
namespace stdfs = std::filesystem;

class FileSearchTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        test_dir_ = stdfs::temp_directory_path() / ("fcxl_test_file_search_" + unique);
        stdfs::create_directories(test_dir_);
    }

    void TearDown() override {
        std::error_code ec;
        stdfs::remove_all(test_dir_, ec);
    }

    static void create_file_with_content(const stdfs::path& path, std::string_view content) {
        std::ofstream ofs(path, std::ios::binary);
        ofs << content;
    }

    static void create_file_with_size(const stdfs::path& path, std::size_t size) {
        std::ofstream ofs(path, std::ios::binary);
        const std::string payload(size, 'x');
        ofs.write(payload.data(), static_cast<std::streamsize>(payload.size()));
    }

    static auto names_from_results(const std::vector<common::FileEntry>& results)
        -> std::vector<std::string> {
        std::vector<std::string> names;
        names.reserve(results.size());
        for (const auto& entry : results) {
            names.push_back(entry.name);
        }
        std::sort(names.begin(), names.end());
        return names;
    }

    common::SearchFilter make_filter(std::string pattern, bool recursive = true) {
        common::SearchFilter filter;
        filter.name_pattern = std::move(pattern);
        filter.recursive = recursive;
        return filter;
    }

    stdfs::path test_dir_;
    search::FileSearch file_search_;
};

TEST_F(FileSearchTest, should_find_files_by_wildcard) {
    create_file_with_content(test_dir_ / "a.txt", "a");
    create_file_with_content(test_dir_ / "b.log", "b");
    create_file_with_content(test_dir_ / "c.txt", "c");

    auto filter = make_filter("*.txt");
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    const auto names = names_from_results(result.value());
    EXPECT_EQ(names, (std::vector<std::string>{"a.txt", "c.txt"}));
}

TEST_F(FileSearchTest, should_find_files_by_regex) {
    create_file_with_content(test_dir_ / "file_1.dat", "1");
    create_file_with_content(test_dir_ / "file_22.dat", "22");
    create_file_with_content(test_dir_ / "file_a.dat", "a");

    auto filter = make_filter("^file_[0-9]+\\.dat$");
    filter.use_regex = true;
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    const auto names = names_from_results(result.value());
    EXPECT_EQ(names, (std::vector<std::string>{"file_1.dat", "file_22.dat"}));
}

TEST_F(FileSearchTest, should_respect_min_max_size_filter) {
    create_file_with_size(test_dir_ / "small.bin", 5);
    create_file_with_size(test_dir_ / "medium.bin", 20);
    create_file_with_size(test_dir_ / "large.bin", 100);

    auto filter = make_filter("*.bin");
    filter.min_size = 10;
    filter.max_size = 50;
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    const auto names = names_from_results(result.value());
    EXPECT_EQ(names, (std::vector<std::string>{"medium.bin"}));
}

TEST_F(FileSearchTest, should_find_recursively) {
    const auto nested = test_dir_ / "sub" / "nested";
    stdfs::create_directories(nested);
    create_file_with_content(nested / "deep.txt", "deep");

    auto filter = make_filter("*.txt", true);
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    const auto names = names_from_results(result.value());
    EXPECT_EQ(names, (std::vector<std::string>{"deep.txt"}));
}

TEST_F(FileSearchTest, should_not_find_in_nonrecursive_mode) {
    const auto nested = test_dir_ / "sub";
    stdfs::create_directories(nested);
    create_file_with_content(nested / "deep.txt", "deep");

    auto filter = make_filter("*.txt", false);
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(result.value().empty());
}

TEST_F(FileSearchTest, should_skip_hidden_files_by_default) {
    create_file_with_content(test_dir_ / ".secret.txt", "hidden");
    create_file_with_content(test_dir_ / "visible.txt", "visible");

    auto filter = make_filter("*.txt");
    filter.include_hidden = false;
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    const auto names = names_from_results(result.value());
    EXPECT_EQ(names, (std::vector<std::string>{"visible.txt"}));
}

TEST_F(FileSearchTest, should_include_hidden_files_when_requested) {
    create_file_with_content(test_dir_ / ".secret.txt", "hidden");
    create_file_with_content(test_dir_ / "visible.txt", "visible");

    auto filter = make_filter("*.txt");
    filter.include_hidden = true;
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    const auto names = names_from_results(result.value());
    EXPECT_EQ(names, (std::vector<std::string>{".secret.txt", "visible.txt"}));
}

TEST_F(FileSearchTest, should_return_empty_for_no_match) {
    create_file_with_content(test_dir_ / "a.txt", "a");
    create_file_with_content(test_dir_ / "b.log", "b");

    auto filter = make_filter("*.json");
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(result.value().empty());
}

TEST_F(FileSearchTest, should_return_error_for_nonexistent_root) {
    auto filter = make_filter("*.txt");
    const auto missing = test_dir_ / "missing_root";

    const auto result = file_search_.search(missing.string(), filter);

    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::NotFound);
}

TEST_F(FileSearchTest, should_call_callback_for_each_result) {
    create_file_with_content(test_dir_ / "one.txt", "1");
    create_file_with_content(test_dir_ / "two.txt", "2");
    create_file_with_content(test_dir_ / "three.txt", "3");

    auto filter = make_filter("*.txt");
    std::vector<std::string> callback_names;

    const auto result = file_search_.search(
        test_dir_.string(), filter, [&](const common::FileEntry& entry) {
            callback_names.push_back(entry.name);
        });

    ASSERT_TRUE(result.has_value());
    std::sort(callback_names.begin(), callback_names.end());
    const auto result_names = names_from_results(result.value());

    EXPECT_EQ(callback_names.size(), result.value().size());
    EXPECT_EQ(callback_names, result_names);
}

TEST_F(FileSearchTest, should_continue_search_when_entry_type_cannot_be_inspected) {
    const auto nested = test_dir_ / "nested";
    stdfs::create_directories(nested);
    create_file_with_content(nested / "target.jpg", "img");

    std::error_code ec;
    const auto broken_link = test_dir_ / "broken_link";
    stdfs::create_symlink(test_dir_ / "missing_target", broken_link, ec);
    if (ec) {
        GTEST_SKIP() << "Cannot create symlink in test environment: " << ec.message();
    }

    auto filter = make_filter("*.jpg", true);
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    const auto names = names_from_results(result.value());
    EXPECT_EQ(names, (std::vector<std::string>{"target.jpg"}));
}

// --- Exclusions: names the walk must not enter or report ---

TEST_F(FileSearchTest, should_parse_exclusion_spec_with_both_separators) {
    const auto patterns = search::parse_exclusions(" node_modules ; .cache, *.tmp ;; ");
    ASSERT_EQ(patterns.size(), 3U);
    EXPECT_EQ(patterns[0], "node_modules");
    EXPECT_EQ(patterns[1], ".cache");
    EXPECT_EQ(patterns[2], "*.tmp");
    EXPECT_TRUE(search::parse_exclusions("").empty());
    EXPECT_TRUE(search::parse_exclusions("  ;  , ").empty());
}

TEST_F(FileSearchTest, should_match_exclusion_on_whole_name_ignoring_case) {
    const auto patterns = search::parse_exclusions("build;*.tmp");
    EXPECT_TRUE(search::is_excluded("build", patterns));
    EXPECT_TRUE(search::is_excluded("BUILD", patterns));
    EXPECT_TRUE(search::is_excluded("scratch.tmp", patterns));
    // A pattern without a wildcard matches the whole name — "build" must not eat "rebuild.log".
    EXPECT_FALSE(search::is_excluded("rebuild.log", patterns));
    EXPECT_FALSE(search::is_excluded("builder", patterns));
    EXPECT_FALSE(search::is_excluded("anything", {}));
}

TEST_F(FileSearchTest, should_never_enter_an_excluded_directory) {
    stdfs::create_directories(test_dir_ / "node_modules" / "deep");
    stdfs::create_directories(test_dir_ / "src");
    create_file_with_content(test_dir_ / "src" / "wanted.txt", "x");
    create_file_with_content(test_dir_ / "node_modules" / "away.txt", "x");
    create_file_with_content(test_dir_ / "node_modules" / "deep" / "buried.txt", "x");

    auto filter = make_filter("*.txt");
    filter.exclude_patterns = search::parse_exclusions("node_modules");

    const auto result = file_search_.search(test_dir_.string(), filter);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(names_from_results(result.value()), std::vector<std::string>{"wanted.txt"});
}

TEST_F(FileSearchTest, should_skip_excluded_files_but_keep_their_neighbours) {
    create_file_with_content(test_dir_ / "keep.txt", "x");
    create_file_with_content(test_dir_ / "scratch.tmp", "x");

    auto filter = make_filter("*");
    filter.exclude_patterns = search::parse_exclusions("*.tmp");

    const auto result = file_search_.search(test_dir_.string(), filter);
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(names_from_results(result.value()), std::vector<std::string>{"keep.txt"});
}

// macOS stores a file name in whatever Unicode form it was written with, and hands it back
// byte for byte. Everything that goes through Cocoa — Finder, this app, an unpacked archive —
// writes the DECOMPOSED form: "ё" is stored as "е" followed by the combining diaeresis U+0308.
// A mask typed on the keyboard arrives COMPOSED. The two are the same name to a reader and two
// different byte strings to a comparison, so the search has to fold them together itself.
namespace {
constexpr std::string_view kComposedName = "отчёт за 2026.pdf";           // "ё" = U+0451
constexpr std::string_view kDecomposedName = "отче\u0308т за 2026.pdf";   // "е" + U+0308
}  // namespace

TEST_F(FileSearchTest, should_find_a_decomposed_name_by_a_composed_mask) {
    create_file_with_content(test_dir_ / kDecomposedName, "report");

    auto filter = make_filter("отчёт*");
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(names_from_results(result.value()),
              (std::vector<std::string>{std::string(kDecomposedName)}));
}

TEST_F(FileSearchTest, should_find_a_composed_name_by_a_decomposed_mask) {
    create_file_with_content(test_dir_ / kComposedName, "report");

    auto filter = make_filter("отче\u0308т*");
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(names_from_results(result.value()),
              (std::vector<std::string>{std::string(kComposedName)}));
}

// A mask with no wildcard is a piece of a name, so it is wrapped in "*" on both sides — the
// substring path has to fold the two forms together as well.
TEST_F(FileSearchTest, should_find_a_decomposed_name_by_a_composed_substring) {
    create_file_with_content(test_dir_ / kDecomposedName, "report");

    auto filter = make_filter("отчёт");
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result.value().size(), 1U);
}

// FNM_CASEFOLD only ever folded ASCII: "*.TXT" found "file.txt" while "ОТЧЁТ*" found nothing.
TEST_F(FileSearchTest, should_ignore_case_in_cyrillic_names) {
    create_file_with_content(test_dir_ / kComposedName, "report");
    create_file_with_content(test_dir_ / "ДОГОВОР.pdf", "contract");

    auto filter = make_filter("ОТЧЁТ*");
    const auto upper = file_search_.search(test_dir_.string(), filter);
    ASSERT_TRUE(upper.has_value());
    EXPECT_EQ(names_from_results(upper.value()),
              (std::vector<std::string>{std::string(kComposedName)}));

    auto lower_filter = make_filter("договор*");
    const auto lower = file_search_.search(test_dir_.string(), lower_filter);
    ASSERT_TRUE(lower.has_value());
    EXPECT_EQ(names_from_results(lower.value()), (std::vector<std::string>{"ДОГОВОР.pdf"}));
}

// Case folding has to survive the decomposed form too — an upper-case mask against a name the
// system stored decomposed is the everyday case on this platform.
TEST_F(FileSearchTest, should_ignore_case_in_a_decomposed_cyrillic_name) {
    create_file_with_content(test_dir_ / kDecomposedName, "report");

    auto filter = make_filter("ОТЧЁТ*");
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result.value().size(), 1U);
}

// "?" stands for one CHARACTER. Against raw bytes it stood for one byte, so it never matched
// anything outside ASCII — "отч?т" could not find "отчёт".
TEST_F(FileSearchTest, should_match_one_multibyte_character_with_a_question_mark) {
    create_file_with_content(test_dir_ / "отче\u0308т.pdf", "report");

    auto filter = make_filter("отч?т.pdf");
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result.value().size(), 1U);
}

TEST_F(FileSearchTest, should_find_a_decomposed_name_by_a_composed_regex) {
    create_file_with_content(test_dir_ / kDecomposedName, "report");

    auto filter = make_filter("^отчёт");
    filter.use_regex = true;
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result.value().size(), 1U);
}

// The forms have to stay folded together for a name that is not Cyrillic at all.
TEST_F(FileSearchTest, should_fold_the_two_forms_of_a_latin_accented_name) {
    create_file_with_content(test_dir_ / "cafe\u0301.txt", "latin");  // "e" + U+0301

    auto filter = make_filter("café*");
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(result.value().size(), 1U);
}

// A name that is not valid UTF-8 — a FAT or NTFS volume, a share on the network, an archive
// packed in a legacy encoding — has to stay reachable by an ASCII mask instead of falling out
// of the search. Matched directly: APFS refuses to create such a name, so no file can stand in.
TEST(NameMaskTest, should_still_match_a_name_that_is_not_valid_utf8) {
    const std::string broken = "report_\xff\xfe.txt";

    EXPECT_TRUE(search::NameMask("report_*").matches(broken));
    EXPECT_TRUE(search::NameMask("REPORT_*").matches(broken));
    EXPECT_FALSE(search::NameMask("notes_*").matches(broken));
}

TEST(NameMaskTest, should_treat_an_unterminated_bracket_as_an_ordinary_character) {
    EXPECT_TRUE(search::NameMask("[ab.txt").matches("[ab.txt"));
    EXPECT_TRUE(search::NameMask("*[*").matches("draft[1].txt"));
}

// Guards the mask syntax that already worked, so folding does not quietly change it.
TEST_F(FileSearchTest, should_keep_matching_ascii_masks_case_insensitively) {
    create_file_with_content(test_dir_ / "Report.TXT", "a");
    create_file_with_content(test_dir_ / "notes.txt", "b");

    auto filter = make_filter("*.txt");
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(names_from_results(result.value()),
              (std::vector<std::string>{"Report.TXT", "notes.txt"}));
}

TEST_F(FileSearchTest, should_keep_matching_bracket_expressions) {
    create_file_with_content(test_dir_ / "a.txt", "a");
    create_file_with_content(test_dir_ / "b.txt", "b");
    create_file_with_content(test_dir_ / "c.txt", "c");

    auto filter = make_filter("[ab].txt");
    const auto result = file_search_.search(test_dir_.string(), filter);

    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(names_from_results(result.value()), (std::vector<std::string>{"a.txt", "b.txt"}));
}
