#include <gtest/gtest.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>
#include <vector>

#include <unistd.h>

#include "fcxl/search/duplicate_finder.h"

using namespace fcxl;
namespace stdfs = std::filesystem;

class DuplicateFinderTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        test_dir_ = stdfs::temp_directory_path() / ("fcxl_test_duplicates_" + unique);
        stdfs::create_directories(test_dir_);
    }

    void TearDown() override {
        std::error_code ec;
        stdfs::remove_all(test_dir_, ec);
    }

    static void write_file(const stdfs::path& path, std::string_view content) {
        stdfs::create_directories(path.parent_path());
        std::ofstream ofs(path, std::ios::binary);
        ofs << content;
    }

    auto find(search::DuplicateOptions options = {}) -> std::vector<common::DuplicateGroup> {
        const auto result = finder_.find(test_dir_.string(), options);
        EXPECT_TRUE(result.has_value());
        return result.has_value() ? result.value() : std::vector<common::DuplicateGroup>{};
    }

    stdfs::path test_dir_;
    search::DuplicateFinder finder_;
};

TEST_F(DuplicateFinderTest, should_find_two_files_with_the_same_content) {
    write_file(test_dir_ / "a.bin", "same-content");
    write_file(test_dir_ / "sub" / "b.bin", "same-content");
    write_file(test_dir_ / "other.bin", "different!!!");

    const auto groups = find();

    ASSERT_EQ(groups.size(), static_cast<std::size_t>(1));
    EXPECT_EQ(groups[0].files,
              (std::vector<stdfs::path>{test_dir_ / "a.bin", test_dir_ / "sub" / "b.bin"}));
}

TEST_F(DuplicateFinderTest, should_not_call_a_symlink_a_copy_of_its_target) {
    write_file(test_dir_ / "a.bin", "same-content");
    stdfs::create_symlink(test_dir_ / "a.bin", test_dir_ / "link.bin");

    EXPECT_TRUE(find().empty());
}

TEST_F(DuplicateFinderTest, should_not_call_two_names_of_one_file_copies) {
    // A hard link is the same file under a second name: deleting one frees nothing.
    write_file(test_dir_ / "a.bin", "same-content");
    stdfs::create_hard_link(test_dir_ / "a.bin", test_dir_ / "second-name.bin");

    EXPECT_TRUE(find().empty());
}

TEST_F(DuplicateFinderTest, should_still_pair_a_hard_linked_file_with_a_real_copy) {
    write_file(test_dir_ / "a.bin", "same-content");
    stdfs::create_hard_link(test_dir_ / "a.bin", test_dir_ / "second-name.bin");
    write_file(test_dir_ / "real-copy.bin", "same-content");

    const auto groups = find();

    ASSERT_EQ(groups.size(), static_cast<std::size_t>(1));
    EXPECT_EQ(groups[0].files.size(), static_cast<std::size_t>(2));
}

TEST_F(DuplicateFinderTest, should_stay_out_of_hidden_places_by_default) {
    write_file(test_dir_ / "sub" / "a.bin", "same-content");
    write_file(test_dir_ / ".git" / "objects" / "b.bin", "same-content");
    write_file(test_dir_ / ".hidden.bin", "same-content");

    EXPECT_TRUE(find().empty());

    search::DuplicateOptions options;
    options.include_hidden = true;
    const auto groups = find(options);
    ASSERT_EQ(groups.size(), static_cast<std::size_t>(1));
    EXPECT_EQ(groups[0].files.size(), static_cast<std::size_t>(3));
}

TEST_F(DuplicateFinderTest, should_put_the_biggest_waste_first_and_order_the_copies) {
    write_file(test_dir_ / "small-1.bin", "tiny");
    write_file(test_dir_ / "small-2.bin", "tiny");
    write_file(test_dir_ / "z-big.bin", std::string(5000, 'b'));
    write_file(test_dir_ / "a-big.bin", std::string(5000, 'b'));
    write_file(test_dir_ / "m-big.bin", std::string(5000, 'b'));
    write_file(test_dir_ / "mid-1.bin", std::string(6000, 'm'));
    write_file(test_dir_ / "mid-2.bin", std::string(6000, 'm'));

    const auto groups = find();

    // 5000 × 2 spare copies is more waste than 6000 × 1, and both are more than 4 × 1.
    ASSERT_EQ(groups.size(), static_cast<std::size_t>(3));
    EXPECT_EQ(groups[0].size, static_cast<uint64_t>(5000));
    EXPECT_EQ(groups[1].size, static_cast<uint64_t>(6000));
    EXPECT_EQ(groups[2].size, static_cast<uint64_t>(4));
    EXPECT_EQ(groups[0].files,
              (std::vector<stdfs::path>{test_dir_ / "a-big.bin", test_dir_ / "m-big.bin",
                                        test_dir_ / "z-big.bin"}));
}

TEST_F(DuplicateFinderTest, should_order_same_named_files_the_same_way_every_time) {
    search::DuplicateOptions options;
    options.strategy = search::DuplicateStrategy::ByName;
    write_file(test_dir_ / "b" / "notes.txt", "one");
    write_file(test_dir_ / "a" / "notes.txt", "another");
    write_file(test_dir_ / "a" / "readme.md", "x");
    write_file(test_dir_ / "b" / "readme.md", "yy");
    write_file(test_dir_ / "c" / "readme.md", "zzz");

    const auto groups = find(options);

    ASSERT_EQ(groups.size(), static_cast<std::size_t>(2));
    EXPECT_EQ(groups[0].files.size(), static_cast<std::size_t>(3));   // more copies first
    EXPECT_EQ(groups[1].files,
              (std::vector<stdfs::path>{test_dir_ / "a" / "notes.txt",
                                        test_dir_ / "b" / "notes.txt"}));
}

TEST_F(DuplicateFinderTest, should_leave_out_files_outside_the_size_limits) {
    write_file(test_dir_ / "small-1.bin", "tiny");
    write_file(test_dir_ / "small-2.bin", "tiny");
    write_file(test_dir_ / "big-1.bin", std::string(5000, 'b'));
    write_file(test_dir_ / "big-2.bin", std::string(5000, 'b'));
    search::DuplicateOptions options;

    options.limits.min_size = 1000;
    const auto big = find(options);
    ASSERT_EQ(big.size(), static_cast<std::size_t>(1));
    EXPECT_EQ(big[0].size, static_cast<uint64_t>(5000));

    options.limits.min_size = 0;
    options.limits.max_size = 1000;
    const auto small = find(options);
    ASSERT_EQ(small.size(), static_cast<std::size_t>(1));
    EXPECT_EQ(small[0].size, static_cast<uint64_t>(4));
}

TEST_F(DuplicateFinderTest, should_leave_out_files_changed_outside_the_dates) {
    write_file(test_dir_ / "old-1.bin", "old-content");
    write_file(test_dir_ / "old-2.bin", "old-content");
    write_file(test_dir_ / "new-1.bin", "new-content");
    write_file(test_dir_ / "new-2.bin", "new-content");
    const auto month_ago = stdfs::file_time_type::clock::now() - std::chrono::hours(24 * 30);
    stdfs::last_write_time(test_dir_ / "old-1.bin", month_ago);
    stdfs::last_write_time(test_dir_ / "old-2.bin", month_ago);
    search::DuplicateOptions options;
    options.limits.date_from = std::chrono::system_clock::now() - std::chrono::hours(24 * 7);

    const auto groups = find(options);

    ASSERT_EQ(groups.size(), static_cast<std::size_t>(1));
    EXPECT_EQ(groups[0].files,
              (std::vector<stdfs::path>{test_dir_ / "new-1.bin", test_dir_ / "new-2.bin"}));
}
