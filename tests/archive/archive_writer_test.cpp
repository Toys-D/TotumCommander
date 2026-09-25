#include <gtest/gtest.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
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

class ArchiveWriterTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        test_dir_ = stdfs::temp_directory_path() / ("fcxl_test_archive_writer_" + unique);
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

    auto create_source_files(const std::vector<std::pair<std::string, std::string>>& files) -> stdfs::path {
        const auto source_dir = test_dir_ / "source";
        stdfs::create_directories(source_dir);

        for (const auto& [relative_path, content] : files) {
            write_file(source_dir / relative_path, content);
        }
        return source_dir;
    }

    auto create_archive_with_files(archive::ArchiveFormat format,
                                   std::string_view archive_name,
                                   const std::vector<std::pair<std::string, std::string>>& files,
                                   int compression_level = -1) -> stdfs::path {
        const auto source_dir = create_source_files(files);
        const auto archive_path = test_dir_ / archive_name;

        archive::ArchiveWriter writer;
        EXPECT_TRUE(writer.create(archive_path.string(), format, "", compression_level).has_value());
        for (const auto& [relative_path, _] : files) {
            const auto file_path = source_dir / relative_path;
            EXPECT_TRUE(writer.add_file(file_path.string(), relative_path).has_value());
        }
        EXPECT_TRUE(writer.finalize().has_value());

        return archive_path;
    }

    auto archive_contains_entries(const stdfs::path& archive_path,
                                  const std::vector<std::string>& expected_paths) -> bool {
        archive::ArchiveReader reader;
        if (!reader.open(archive_path.string()).has_value()) {
            return false;
        }

        const auto list_result = reader.list_entries();
        reader.close();
        if (!list_result.has_value()) {
            return false;
        }

        std::vector<std::string> actual;
        for (const auto& entry : list_result.value()) {
            actual.push_back(entry.path);
        }

        return std::all_of(expected_paths.begin(), expected_paths.end(), [&](const std::string& path) {
            return std::find(actual.begin(), actual.end(), path) != actual.end();
        });
    }

    stdfs::path test_dir_;
};

TEST_F(ArchiveWriterTest, should_create_zip_with_files) {
    const auto archive_path = create_archive_with_files(
        archive::ArchiveFormat::ZIP,
        "files.zip",
        {{"a.txt", "A"}, {"nested/b.txt", "B"}}
    );

    EXPECT_TRUE(stdfs::exists(archive_path));
    EXPECT_TRUE(archive_contains_entries(archive_path, {"a.txt", "nested/b.txt"}));
}

TEST_F(ArchiveWriterTest, should_create_tar_gz_with_files) {
    const auto archive_path = create_archive_with_files(
        archive::ArchiveFormat::TAR_GZ,
        "files.tar.gz",
        {{"a.txt", "A"}, {"nested/b.txt", "B"}}
    );

    EXPECT_TRUE(stdfs::exists(archive_path));
    EXPECT_TRUE(archive_contains_entries(archive_path, {"a.txt", "nested/b.txt"}));
}

TEST_F(ArchiveWriterTest, should_create_tar_with_files) {
    const auto archive_path = create_archive_with_files(
        archive::ArchiveFormat::TAR,
        "files.tar",
        {{"alpha.txt", "alpha"}, {"beta.txt", "beta"}}
    );

    EXPECT_TRUE(stdfs::exists(archive_path));
    EXPECT_TRUE(archive_contains_entries(archive_path, {"alpha.txt", "beta.txt"}));
}

// tar.xz has been writable since the Keka-style formats (2026-08-04); the test that expected
// a refusal outlived that by a month. What the writer still refuses is what nothing in
// libarchive writes: RAR and DMG.
TEST_F(ArchiveWriterTest, should_reject_formats_nothing_can_write) {
    for (const auto& [name, format] : {std::pair{"unsupported.rar", archive::ArchiveFormat::RAR},
                                       std::pair{"unsupported.dmg", archive::ArchiveFormat::DMG}}) {
        archive::ArchiveWriter writer;
        const auto result = writer.create((test_dir_ / name).string(), format);
        ASSERT_FALSE(result.has_value()) << name;
        EXPECT_EQ(result.error().code, common::ErrorCode::NotSupported) << name;
    }
}

TEST_F(ArchiveWriterTest, should_create_tar_xz_with_files) {
    const auto archive_path = create_archive_with_files(
        archive::ArchiveFormat::TAR_XZ,
        "files.tar.xz",
        {{"alpha.txt", "alpha"}, {"beta.txt", "beta"}}
    );

    EXPECT_TRUE(stdfs::exists(archive_path));
    EXPECT_TRUE(archive_contains_entries(archive_path, {"alpha.txt", "beta.txt"}));
}

TEST_F(ArchiveWriterTest, should_create_7z_with_files) {
    const auto archive_path = create_archive_with_files(
        archive::ArchiveFormat::SevenZip,
        "files.7z",
        {{"one.txt", "1"}, {"two.txt", "2"}}
    );

    EXPECT_TRUE(stdfs::exists(archive_path));
    EXPECT_TRUE(archive_contains_entries(archive_path, {"one.txt", "two.txt"}));
}

TEST_F(ArchiveWriterTest, should_add_directory_recursively) {
    const auto root = test_dir_ / "dir_src";
    stdfs::create_directories(root / "nested" / "deep");
    write_file(root / "root.txt", "root");
    write_file(root / "nested" / "leaf.txt", "leaf");
    write_file(root / "nested" / "deep" / "deep.txt", "deep");

    const auto archive_path = test_dir_ / "recursive.zip";
    archive::ArchiveWriter writer;
    ASSERT_TRUE(writer.create(archive_path.string(), archive::ArchiveFormat::ZIP).has_value());
    ASSERT_TRUE(writer.add_directory(root.string()).has_value());
    ASSERT_TRUE(writer.finalize().has_value());

    EXPECT_TRUE(archive_contains_entries(
        archive_path,
        {"dir_src/root.txt", "dir_src/nested/leaf.txt", "dir_src/nested/deep/deep.txt"}
    ));
}

TEST_F(ArchiveWriterTest, should_respect_compression_level) {
    std::string compressible(8 * 1024 * 1024, 'A');

    const auto archive_low = create_archive_with_files(
        archive::ArchiveFormat::TAR_GZ,
        "level1.tar.gz",
        {{"data.txt", compressible}},
        1
    );

    const auto archive_high = create_archive_with_files(
        archive::ArchiveFormat::TAR_GZ,
        "level9.tar.gz",
        {{"data.txt", compressible}},
        9
    );

    ASSERT_TRUE(stdfs::exists(archive_low));
    ASSERT_TRUE(stdfs::exists(archive_high));

    const auto low_size = stdfs::file_size(archive_low);
    const auto high_size = stdfs::file_size(archive_high);

    EXPECT_LE(high_size, low_size);
}

TEST_F(ArchiveWriterTest, should_respect_zip_compression_level) {
    std::string compressible(8 * 1024 * 1024, 'Z');

    const auto archive_low = create_archive_with_files(
        archive::ArchiveFormat::ZIP,
        "level1.zip",
        {{"data.txt", compressible}},
        1
    );

    const auto archive_high = create_archive_with_files(
        archive::ArchiveFormat::ZIP,
        "level9.zip",
        {{"data.txt", compressible}},
        9
    );

    ASSERT_TRUE(stdfs::exists(archive_low));
    ASSERT_TRUE(stdfs::exists(archive_high));

    const auto low_size = stdfs::file_size(archive_low);
    const auto high_size = stdfs::file_size(archive_high);

    EXPECT_LE(high_size, low_size);
}

TEST_F(ArchiveWriterTest, should_handle_empty_archive) {
    const auto archive_path = test_dir_ / "empty.zip";

    archive::ArchiveWriter writer;
    ASSERT_TRUE(writer.create(archive_path.string(), archive::ArchiveFormat::ZIP).has_value());
    ASSERT_TRUE(writer.finalize().has_value());

    archive::ArchiveReader reader;
    ASSERT_TRUE(reader.open(archive_path.string()).has_value());
    const auto list_result = reader.list_entries();
    reader.close();

    ASSERT_TRUE(list_result.has_value()) << list_result.error().message;
    EXPECT_TRUE(list_result.value().empty());
}

TEST_F(ArchiveWriterTest, should_report_real_progress_from_libarchive_positions) {
    std::string large_payload(6 * 1024 * 1024, 'P');
    const auto source_dir = create_source_files(
        {{"large.bin", large_payload}, {"nested/small.txt", "small"}}
    );
    const auto archive_path = test_dir_ / "progress.tar.gz";

    const int64_t total_bytes =
        static_cast<int64_t>(large_payload.size() + std::string("small").size());
    const int total_files = 2;
    std::vector<std::tuple<std::string, int64_t, int64_t, int, int, int64_t>> progress_events;

    archive::ArchiveWriter writer;
    ASSERT_TRUE(
        writer.create(
            archive_path.string(),
            archive::ArchiveFormat::TAR_GZ,
            "",
            6,
            true,
            [&progress_events](const std::string& current_file,
                               int64_t bytes_read,
                               int64_t bytes_total,
                               int files_done,
                               int files_total,
                               int64_t compressed_bytes) {
                progress_events.emplace_back(
                    current_file,
                    bytes_read,
                    bytes_total,
                    files_done,
                    files_total,
                    compressed_bytes
                );
            },
            total_bytes,
            total_files
        ).has_value()
    );

    ASSERT_TRUE(writer.add_file((source_dir / "large.bin").string(), "large.bin").has_value());
    ASSERT_TRUE(
        writer.add_file((source_dir / "nested" / "small.txt").string(), "nested/small.txt").has_value()
    );
    ASSERT_TRUE(writer.finalize().has_value());

    ASSERT_FALSE(progress_events.empty());
    EXPECT_GT(progress_events.size(), 2U);

    int64_t previous_bytes_read = 0;
    for (const auto& event : progress_events) {
        const int64_t bytes_read = std::get<1>(event);
        EXPECT_GE(bytes_read, previous_bytes_read);
        previous_bytes_read = bytes_read;
        EXPECT_EQ(std::get<2>(event), total_bytes);
        EXPECT_EQ(std::get<4>(event), total_files);
    }

    const auto& last_event = progress_events.back();
    EXPECT_GE(std::get<1>(last_event), total_bytes);
    EXPECT_GE(std::get<3>(last_event), total_files);
}
