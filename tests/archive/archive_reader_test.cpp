#include <gtest/gtest.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>
#include <tuple>
#include <utility>
#include <vector>

#include "fcxl/archive/archive_reader.h"
#include "fcxl/archive/archive_writer.h"

using namespace fcxl;
namespace stdfs = std::filesystem;

class ArchiveReaderTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        test_dir_ = stdfs::temp_directory_path() / ("fcxl_test_archive_reader_" + unique);
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

    static auto read_file(const stdfs::path& path) -> std::string {
        std::ifstream ifs(path, std::ios::binary);
        return std::string(std::istreambuf_iterator<char>(ifs), std::istreambuf_iterator<char>());
    }

    static auto shell_quote(const std::string& value) -> std::string {
        std::string quoted = "'";
        for (char c : value) {
            if (c == '\'') {
                quoted += "'\\''";
            } else {
                quoted.push_back(c);
            }
        }
        quoted.push_back('\'');
        return quoted;
    }

    auto create_archive(
        archive::ArchiveFormat format,
        std::string_view archive_name,
        const std::vector<std::pair<std::string, std::string>>& files) -> stdfs::path {
        const auto source_dir = test_dir_ / "source";
        stdfs::create_directories(source_dir);

        archive::ArchiveWriter writer;
        const auto archive_path = test_dir_ / archive_name;
        EXPECT_TRUE(writer.create(archive_path.string(), format).has_value());

        for (const auto& [relative_path, content] : files) {
            const auto file_path = source_dir / relative_path;
            write_file(file_path, content);
            EXPECT_TRUE(writer.add_file(file_path.string(), relative_path).has_value());
        }

        EXPECT_TRUE(writer.finalize().has_value());
        return archive_path;
    }

    auto create_tar_xz_archive(
        std::string_view archive_name,
        const std::vector<std::pair<std::string, std::string>>& files) -> stdfs::path {
        const auto source_dir = test_dir_ / "source_tar_xz";
        stdfs::create_directories(source_dir);
        for (const auto& [relative_path, content] : files) {
            write_file(source_dir / relative_path, content);
        }

        const auto archive_path = test_dir_ / archive_name;
        std::string command =
            "/usr/bin/tar -cJf " + shell_quote(archive_path.string()) +
            " -C " + shell_quote(source_dir.string());
        for (const auto& [relative_path, _] : files) {
            command += " " + shell_quote(relative_path);
        }
        const int result = std::system(command.c_str());
        EXPECT_EQ(result, 0);

        return archive_path;
    }

    auto list_paths(archive::ArchiveReader* reader) -> std::vector<std::string> {
        const auto list_result = reader->list_entries();
        EXPECT_TRUE(list_result.has_value()) << list_result.error().message;
        if (!list_result.has_value()) {
            return {};
        }

        std::vector<std::string> paths;
        paths.reserve(list_result.value().size());
        for (const auto& entry : list_result.value()) {
            paths.push_back(entry.path);
        }
        return paths;
    }

    stdfs::path test_dir_;
};

TEST_F(ArchiveReaderTest, should_list_entries_in_zip) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::ZIP,
        "sample.zip",
        {{"docs/readme.txt", "readme"}, {"notes.txt", "notes"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto paths = list_paths(&reader);
    EXPECT_NE(std::find(paths.begin(), paths.end(), "docs/readme.txt"), paths.end());
    EXPECT_NE(std::find(paths.begin(), paths.end(), "notes.txt"), paths.end());

    reader.close();
}

TEST_F(ArchiveReaderTest, should_list_entries_in_tar_gz) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::TAR_GZ,
        "sample.tar.gz",
        {{"dir/a.txt", "A"}, {"dir/b.txt", "B"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto paths = list_paths(&reader);
    EXPECT_NE(std::find(paths.begin(), paths.end(), "dir/a.txt"), paths.end());
    EXPECT_NE(std::find(paths.begin(), paths.end(), "dir/b.txt"), paths.end());

    reader.close();
}

TEST_F(ArchiveReaderTest, should_list_entries_in_tar_xz) {
    const auto archive_path = create_tar_xz_archive(
        "sample.tar.xz",
        {{"alpha.txt", "alpha"}, {"beta.txt", "beta"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto paths = list_paths(&reader);
    const bool has_alpha = std::find(paths.begin(), paths.end(), "alpha.txt") != paths.end() ||
        std::find(paths.begin(), paths.end(), "./alpha.txt") != paths.end();
    const bool has_beta = std::find(paths.begin(), paths.end(), "beta.txt") != paths.end() ||
        std::find(paths.begin(), paths.end(), "./beta.txt") != paths.end();
    EXPECT_TRUE(has_alpha);
    EXPECT_TRUE(has_beta);

    reader.close();
}

TEST_F(ArchiveReaderTest, should_list_entries_in_7z) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::SevenZip,
        "sample.7z",
        {{"folder/one.txt", "one"}, {"two.txt", "two"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto paths = list_paths(&reader);
    EXPECT_NE(std::find(paths.begin(), paths.end(), "folder/one.txt"), paths.end());
    EXPECT_NE(std::find(paths.begin(), paths.end(), "two.txt"), paths.end());

    reader.close();
}

TEST_F(ArchiveReaderTest, should_extract_all_from_zip) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::ZIP,
        "extract_all.zip",
        {{"nested/one.txt", "one"}, {"nested/two.txt", "two"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto extract_dir = test_dir_ / "extract_all";
    const auto result = reader.extract_all(extract_dir.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_EQ(read_file(extract_dir / "nested" / "one.txt"), "one");
    EXPECT_EQ(read_file(extract_dir / "nested" / "two.txt"), "two");

    reader.close();
}

TEST_F(ArchiveReaderTest, should_extract_single_entry) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::ZIP,
        "extract_single.zip",
        {{"a.txt", "A"}, {"b.txt", "B"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto extract_dir = test_dir_ / "extract_single";
    const auto result = reader.extract_entry("b.txt", extract_dir.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_FALSE(stdfs::exists(extract_dir / "a.txt"));
    EXPECT_EQ(read_file(extract_dir / "b.txt"), "B");

    reader.close();
}

TEST_F(ArchiveReaderTest, should_extract_single_zip_entry_without_libarchive_skip_scan) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::ZIP,
        "extract_single_fast.zip",
        {{"a.txt", "A"}, {"nested/b.txt", "B"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto extract_dir = test_dir_ / "extract_single_fast";
    archive::ArchiveReader::debug_reset_data_skip_call_count();
    const auto result = reader.extract_entry("nested/b.txt", extract_dir.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_EQ(read_file(extract_dir / "nested" / "b.txt"), "B");
    EXPECT_EQ(archive::ArchiveReader::debug_data_skip_call_count(), 0U);

    reader.close();
}

TEST_F(ArchiveReaderTest, should_handle_nested_directories_in_archive) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::ZIP,
        "nested.zip",
        {
            {"folder1/subfolder/deep.txt", "deep"},
            {"folder1/root.txt", "root"}
        }
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto extract_dir = test_dir_ / "nested_extract";
    const auto result = reader.extract_all(extract_dir.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_EQ(read_file(extract_dir / "folder1" / "subfolder" / "deep.txt"), "deep");
    EXPECT_EQ(read_file(extract_dir / "folder1" / "root.txt"), "root");

    reader.close();
}

TEST_F(ArchiveReaderTest, should_return_error_for_corrupted_archive) {
    const auto invalid_archive = test_dir_ / "broken.zip";
    write_file(invalid_archive, "not-an-archive-content");

    archive::ArchiveReader reader;
    const auto result = reader.open(invalid_archive.string());

    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::ArchiveError);
}

TEST_F(ArchiveReaderTest, should_return_error_for_nonexistent_file) {
    archive::ArchiveReader reader;

    const auto result = reader.open((test_dir_ / "missing.zip").string());

    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::NotFound);
}

TEST_F(ArchiveReaderTest, should_cancel_listing) {
    std::string large_payload(2 * 1024 * 1024, 'A');
    const auto archive_path = create_archive(
        archive::ArchiveFormat::TAR_GZ,
        "cancel.tar.gz",
        {{"large.bin", large_payload}, {"small.txt", "ok"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    std::atomic<bool> cancelled{true};
    const auto list_result = reader.list_entries(&cancelled);

    ASSERT_FALSE(list_result.has_value());
    EXPECT_EQ(list_result.error().code, common::ErrorCode::Cancelled);

    reader.close();
}

TEST_F(ArchiveReaderTest, should_skip_data_in_list_entries) {
    std::string large_payload(3 * 1024 * 1024, 'B');
    const auto archive_path = create_archive(
        archive::ArchiveFormat::TAR_GZ,
        "skip_data.tar.gz",
        {{"big.bin", large_payload}, {"small.txt", "small"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    archive::ArchiveReader::debug_reset_data_skip_call_count();
    const auto list_result = reader.list_entries();

    ASSERT_TRUE(list_result.has_value()) << list_result.error().message;
    EXPECT_GE(archive::ArchiveReader::debug_data_skip_call_count(),
              list_result.value().size());

    reader.close();
}

TEST_F(ArchiveReaderTest, should_use_cached_entries_when_archive_unchanged) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::TAR_GZ,
        "cached_entries.tar.gz",
        {{"docs/readme.txt", "readme"}, {"notes.txt", "notes"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    archive::ArchiveReader::debug_reset_data_skip_call_count();

    const auto first_result = reader.list_entries();
    ASSERT_TRUE(first_result.has_value()) << first_result.error().message;
    const size_t first_skip_count = archive::ArchiveReader::debug_data_skip_call_count();
    EXPECT_GT(first_skip_count, 0U);

    const auto second_result = reader.list_entries();
    ASSERT_TRUE(second_result.has_value()) << second_result.error().message;
    EXPECT_EQ(second_result.value().size(), first_result.value().size());
    EXPECT_EQ(archive::ArchiveReader::debug_data_skip_call_count(), first_skip_count);

    reader.close();
}

TEST_F(ArchiveReaderTest, should_invalidate_entries_cache_when_archive_mtime_changes) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::TAR_GZ,
        "mtime_invalidation.tar.gz",
        {{"folder/a.txt", "A"}, {"folder/b.txt", "B"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    archive::ArchiveReader::debug_reset_data_skip_call_count();
    const auto first_result = reader.list_entries();
    ASSERT_TRUE(first_result.has_value()) << first_result.error().message;
    const size_t first_skip_count = archive::ArchiveReader::debug_data_skip_call_count();
    EXPECT_GT(first_skip_count, 0U);

    std::error_code ec;
    const auto bumped_mtime = stdfs::file_time_type::clock::now() + std::chrono::seconds(5);
    stdfs::last_write_time(archive_path, bumped_mtime, ec);
    ASSERT_FALSE(ec) << ec.message();

    const auto second_result = reader.list_entries();
    ASSERT_TRUE(second_result.has_value()) << second_result.error().message;
    EXPECT_EQ(second_result.value().size(), first_result.value().size());
    EXPECT_GT(archive::ArchiveReader::debug_data_skip_call_count(), first_skip_count);

    reader.close();
}

TEST_F(ArchiveReaderTest, should_report_progress_when_extracting_all) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::ZIP,
        "extract_with_progress.zip",
        {{"docs/readme.txt", "readme"}, {"notes.txt", "notes"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto extract_dir = test_dir_ / "extract_progress";
    std::vector<std::tuple<std::string, uint64_t, uint64_t, int, int>> progress_events;
    const auto result = reader.extract_all(
        extract_dir.string(),
        nullptr,
        [&progress_events](const std::string& current_file,
                           uint64_t bytes_done,
                           uint64_t bytes_total,
                           int files_done,
                           int files_total) {
            progress_events.emplace_back(
                current_file,
                bytes_done,
                bytes_total,
                files_done,
                files_total
            );
        }
    );

    ASSERT_TRUE(result.has_value()) << result.error().message;
    ASSERT_FALSE(progress_events.empty());

    const auto& last_event = progress_events.back();
    EXPECT_EQ(std::get<1>(last_event), std::get<2>(last_event));
    EXPECT_EQ(std::get<3>(last_event), std::get<4>(last_event));
    EXPECT_GE(std::get<4>(last_event), 2);

    EXPECT_EQ(read_file(extract_dir / "docs" / "readme.txt"), "readme");
    EXPECT_EQ(read_file(extract_dir / "notes.txt"), "notes");

    reader.close();
}

TEST_F(ArchiveReaderTest, should_report_intermediate_progress_for_libarchive_extract_all) {
    std::string large_payload(6 * 1024 * 1024, 'R');
    const auto archive_path = create_archive(
        archive::ArchiveFormat::TAR_GZ,
        "extract_libarchive_progress.tar.gz",
        {{"large.bin", large_payload}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto extract_dir = test_dir_ / "extract_libarchive_progress";
    std::vector<uint64_t> bytes_done_events;
    const auto result = reader.extract_all(
        extract_dir.string(),
        nullptr,
        [&bytes_done_events](const std::string& current_file,
                             uint64_t bytes_done,
                             uint64_t bytes_total,
                             int files_done,
                             int files_total) {
            (void)current_file;
            (void)bytes_total;
            (void)files_done;
            (void)files_total;
            bytes_done_events.push_back(bytes_done);
        }
    );

    ASSERT_TRUE(result.has_value()) << result.error().message;
    ASSERT_GT(bytes_done_events.size(), 2U);
    const uint64_t final_bytes = bytes_done_events.back();
    const bool has_intermediate_progress = std::any_of(
        bytes_done_events.begin(),
        bytes_done_events.end(),
        [final_bytes](uint64_t value) {
            return value > 0 && value < final_bytes;
        }
    );
    EXPECT_TRUE(has_intermediate_progress);

    reader.close();
}

TEST_F(ArchiveReaderTest, should_cancel_extract_all_with_progress_callback) {
    std::string large_payload(4 * 1024 * 1024, 'C');
    const auto archive_path = create_archive(
        archive::ArchiveFormat::TAR_GZ,
        "extract_cancel_with_callback.tar.gz",
        {{"large.bin", large_payload}, {"small.txt", "ok"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto extract_dir = test_dir_ / "extract_cancel_progress";
    std::atomic<bool> cancelled{false};
    int callback_count = 0;
    const auto result = reader.extract_all(
        extract_dir.string(),
        &cancelled,
        [&cancelled, &callback_count](const std::string& current_file,
                                      uint64_t bytes_done,
                                      uint64_t bytes_total,
                                      int files_done,
                                      int files_total) {
            (void)current_file;
            (void)bytes_done;
            (void)bytes_total;
            (void)files_done;
            (void)files_total;
            ++callback_count;
            cancelled.store(true);
        }
    );

    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::Cancelled);
    EXPECT_GE(callback_count, 1);

    reader.close();
}

TEST_F(ArchiveReaderTest, should_extract_all_when_directory_entries_already_exist) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::ZIP,
        "existing_dirs.zip",
        {{"Transcribator/notes.txt", "notes"}, {"Transcribator/docs/readme.txt", "readme"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto extract_dir = test_dir_ / "existing_dirs_extract";
    std::error_code ec;
    stdfs::create_directories(extract_dir / "Transcribator" / "docs", ec);
    ASSERT_FALSE(ec) << ec.message();

    const auto result = reader.extract_all(extract_dir.string());
    ASSERT_TRUE(result.has_value()) << result.error().message;

    EXPECT_EQ(read_file(extract_dir / "Transcribator" / "notes.txt"), "notes");
    EXPECT_EQ(read_file(extract_dir / "Transcribator" / "docs" / "readme.txt"), "readme");

    reader.close();
}

TEST_F(ArchiveReaderTest, should_not_overwrite_existing_files_when_overwrite_disabled) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::ZIP,
        "no_overwrite.zip",
        {{"existing.txt", "from_archive"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto extract_dir = test_dir_ / "no_overwrite_extract";
    std::error_code ec;
    stdfs::create_directories(extract_dir, ec);
    ASSERT_FALSE(ec) << ec.message();

    const auto existing_file = extract_dir / "existing.txt";
    write_file(existing_file, "already_here");

    const auto result = reader.extract_all(
        extract_dir.string(),
        nullptr,
        false,
        [](const std::string&, uint64_t, uint64_t, int, int) {}
    );
    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_EQ(read_file(existing_file), "already_here");

    reader.close();
}

// Папка из архива должна выходить со всем содержимым. Панель просит извлечь «docs» —
// то, что человек выделил, — и раньше ридер искал ровно такую запись: в архиве без
// записей-каталогов её нет («Archive entry not found»), а в архиве с ними выходила
// одна пустая папка.
TEST_F(ArchiveReaderTest, should_extract_folder_with_its_files_from_zip) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::ZIP,
        "folder_subtree.zip",
        {{"docs/a.txt", "A"}, {"docs/sub/b.txt", "B"}, {"other.txt", "O"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto extract_dir = test_dir_ / "folder_subtree";
    const auto result = reader.extract_entry("docs", extract_dir.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_EQ(read_file(extract_dir / "docs" / "a.txt"), "A");
    EXPECT_EQ(read_file(extract_dir / "docs" / "sub" / "b.txt"), "B");
    EXPECT_FALSE(stdfs::exists(extract_dir / "other.txt"));

    reader.close();
}

TEST_F(ArchiveReaderTest, should_extract_folder_when_zip_stores_directory_entries) {
    // /usr/bin/zip -r кладёт в архив и записи «docs/», «docs/sub/» — как Finder и
    // большинство утилит. Ридер находил запись каталога, создавал пустую папку и выходил.
    const auto source_dir = test_dir_ / "source_zip_cli";
    write_file(source_dir / "docs" / "a.txt", "A");
    write_file(source_dir / "docs" / "sub" / "b.txt", "B");
    write_file(source_dir / "other.txt", "O");
    const auto archive_path = test_dir_ / "folder_dir_entries.zip";
    const std::string command = "cd " + shell_quote(source_dir.string()) +
        " && /usr/bin/zip -qr " + shell_quote(archive_path.string()) + " docs other.txt";
    ASSERT_EQ(std::system(command.c_str()), 0);

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());
    const auto listed = list_paths(&reader);
    ASSERT_TRUE(std::find(listed.begin(), listed.end(), "docs/") != listed.end() ||
                std::find(listed.begin(), listed.end(), "docs") != listed.end())
        << "test expects the archive to carry a directory entry";

    const auto extract_dir = test_dir_ / "folder_dir_entries";
    const auto result = reader.extract_entry("docs", extract_dir.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_EQ(read_file(extract_dir / "docs" / "a.txt"), "A");
    EXPECT_EQ(read_file(extract_dir / "docs" / "sub" / "b.txt"), "B");
    EXPECT_FALSE(stdfs::exists(extract_dir / "other.txt"));

    reader.close();
}

TEST_F(ArchiveReaderTest, should_extract_folder_with_its_files_from_tar_gz) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::TAR_GZ,
        "folder_subtree.tar.gz",
        {{"docs/a.txt", "A"}, {"docs/sub/b.txt", "B"}, {"other.txt", "O"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto extract_dir = test_dir_ / "folder_subtree_tgz";
    const auto result = reader.extract_entry("docs/", extract_dir.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_EQ(read_file(extract_dir / "docs" / "a.txt"), "A");
    EXPECT_EQ(read_file(extract_dir / "docs" / "sub" / "b.txt"), "B");
    EXPECT_FALSE(stdfs::exists(extract_dir / "other.txt"));

    reader.close();
}

TEST_F(ArchiveReaderTest, should_extract_folder_with_its_files_from_7z) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::SevenZip,
        "folder_subtree.7z",
        {{"docs/a.txt", "A"}, {"docs/sub/b.txt", "B"}, {"other.txt", "O"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto extract_dir = test_dir_ / "folder_subtree_7z";
    const auto result = reader.extract_entry("docs", extract_dir.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_EQ(read_file(extract_dir / "docs" / "a.txt"), "A");
    EXPECT_EQ(read_file(extract_dir / "docs" / "sub" / "b.txt"), "B");
    EXPECT_FALSE(stdfs::exists(extract_dir / "other.txt"));

    reader.close();
}

TEST_F(ArchiveReaderTest, should_not_extract_sibling_folder_with_same_prefix) {
    // «docs» — это не «docs2»: совпадать должен путь целиком или его каталог, а не буквы.
    const auto archive_path = create_archive(
        archive::ArchiveFormat::ZIP,
        "folder_prefix.zip",
        {{"docs/a.txt", "A"}, {"docs2/c.txt", "C"}, {"docs.txt", "D"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto extract_dir = test_dir_ / "folder_prefix";
    const auto result = reader.extract_entry("docs", extract_dir.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_EQ(read_file(extract_dir / "docs" / "a.txt"), "A");
    EXPECT_FALSE(stdfs::exists(extract_dir / "docs2"));
    EXPECT_FALSE(stdfs::exists(extract_dir / "docs.txt"));

    reader.close();
}

TEST_F(ArchiveReaderTest, should_still_report_missing_entry_after_folder_support) {
    const auto archive_path = create_archive(
        archive::ArchiveFormat::ZIP,
        "folder_missing.zip",
        {{"docs/a.txt", "A"}}
    );

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());

    const auto extract_dir = test_dir_ / "folder_missing";
    const auto result = reader.extract_entry("nothing", extract_dir.string());

    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::NotFound);

    reader.close();
}

TEST_F(ArchiveReaderTest, should_extract_folder_with_its_files_from_iso) {
    // ISO читается через libarchive, как tar и 7z, но именами и каталогами ведает
    // iso9660/Joliet — отдельная проверка, что папка выходит целиком и оттуда.
    const auto source_dir = test_dir_ / "source_iso";
    write_file(source_dir / "docs" / "a.txt", "A");
    write_file(source_dir / "docs" / "sub" / "b.txt", "B");
    write_file(source_dir / "other.txt", "O");
    const auto iso_path = test_dir_ / "folder_subtree.iso";
    const std::string command = "/usr/bin/hdiutil makehybrid -quiet -iso -joliet -o " +
        shell_quote(iso_path.string()) + " " + shell_quote(source_dir.string());
    ASSERT_EQ(std::system(command.c_str()), 0);

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(iso_path.string()).has_value());

    const auto extract_dir = test_dir_ / "folder_subtree_iso";
    const auto result = reader.extract_entry("docs", extract_dir.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_EQ(read_file(extract_dir / "docs" / "a.txt"), "A");
    EXPECT_EQ(read_file(extract_dir / "docs" / "sub" / "b.txt"), "B");
    EXPECT_FALSE(stdfs::exists(extract_dir / "other.txt"));

    reader.close();
}
