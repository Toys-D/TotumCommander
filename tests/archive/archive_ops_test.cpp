#include <gtest/gtest.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "fcxl/archive/archive_ops.h"
#include "fcxl/archive/archive_reader.h"
#include "fcxl/archive/archive_writer.h"

using namespace fcxl;
namespace stdfs = std::filesystem;

class ArchiveOpsTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        test_dir_ = stdfs::temp_directory_path() / ("fcxl_test_archive_ops_" + unique);
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

    auto create_archive(std::string_view archive_name,
                        archive::ArchiveFormat format,
                        const std::vector<std::pair<std::string, std::string>>& files = {
                            {"file.txt", "content"}
                        }) -> stdfs::path {
        const auto source_root = test_dir_ / "source";
        stdfs::create_directories(source_root);

        const auto archive_path = test_dir_ / archive_name;
        archive::ArchiveWriter writer;
        EXPECT_TRUE(writer.create(archive_path.string(), format).has_value());

        for (const auto& [name, content] : files) {
            const auto source_file = source_root / name;
            write_file(source_file, content);
            EXPECT_TRUE(writer.add_file(source_file.string(), name).has_value());
        }

        EXPECT_TRUE(writer.finalize().has_value());
        return archive_path;
    }

    static auto normalize_entry(std::string value) -> std::string {
        while (value.rfind("./", 0) == 0) {
            value.erase(0, 2);
        }
        while (!value.empty() && value.front() == '/') {
            value.erase(value.begin());
        }
        return value;
    }

    auto list_entries(const stdfs::path& archive_path) -> std::vector<std::string> {
        archive::ArchiveReader reader;
        EXPECT_TRUE(reader.open(archive_path.string()).has_value());
        const auto list_result = reader.list_entries();
        EXPECT_TRUE(list_result.has_value()) << list_result.error().message;

        std::vector<std::string> entries;
        if (list_result.has_value()) {
            entries.reserve(list_result.value().size());
            for (const auto& entry : list_result.value()) {
                entries.push_back(normalize_entry(entry.path));
            }
        }
        reader.close();
        return entries;
    }

    static auto contains_entry(const std::vector<std::string>& entries, std::string_view target) -> bool {
        const std::string normalized_target = normalize_entry(std::string(target));
        return std::find(entries.begin(), entries.end(), normalized_target) != entries.end();
    }

    stdfs::path test_dir_;
};

TEST_F(ArchiveOpsTest, should_detect_zip_format) {
    const auto archive_path = create_archive("detect.zip", archive::ArchiveFormat::ZIP);

    archive::ArchiveOps ops;
    const auto result = ops.detect_format(archive_path.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_EQ(result.value(), archive::ArchiveFormat::ZIP);
}

TEST_F(ArchiveOpsTest, should_detect_tar_gz_format) {
    const auto archive_path = create_archive("detect.tar.gz", archive::ArchiveFormat::TAR_GZ);

    archive::ArchiveOps ops;
    const auto result = ops.detect_format(archive_path.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_EQ(result.value(), archive::ArchiveFormat::TAR_GZ);
}

TEST_F(ArchiveOpsTest, should_detect_tar_xz_format) {
    const auto archive_path = test_dir_ / "detect.tar.xz";
    std::ofstream ofs(archive_path, std::ios::binary);
    const unsigned char header[] = {0xFD, '7', 'z', 'X', 'Z', 0x00};
    ofs.write(reinterpret_cast<const char*>(header), sizeof(header));
    std::string padding(512, '\0');
    ofs.write(padding.data(), static_cast<std::streamsize>(padding.size()));
    ofs.close();

    archive::ArchiveOps ops;
    const auto result = ops.detect_format(archive_path.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_EQ(result.value(), archive::ArchiveFormat::TAR_XZ);
}

TEST_F(ArchiveOpsTest, should_detect_7z_format) {
    const auto archive_path = create_archive("detect.7z", archive::ArchiveFormat::SevenZip);

    archive::ArchiveOps ops;
    const auto result = ops.detect_format(archive_path.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_EQ(result.value(), archive::ArchiveFormat::SevenZip);
}

TEST_F(ArchiveOpsTest, should_detect_rar_format) {
    const auto rar_path = test_dir_ / "sample.rar";
    std::ofstream ofs(rar_path, std::ios::binary);
    const char header[] = {'R', 'a', 'r', '!', '\x1A', '\x07', '\x00'};
    ofs.write(header, sizeof(header));
    std::string padding(1024, '\0');
    ofs.write(padding.data(), static_cast<std::streamsize>(padding.size()));
    ofs.close();

    archive::ArchiveOps ops;
    const auto result = ops.detect_format(rar_path.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_EQ(result.value(), archive::ArchiveFormat::RAR);
}

TEST_F(ArchiveOpsTest, should_test_integrity_of_valid_archive) {
    const auto archive_path = create_archive("valid.zip", archive::ArchiveFormat::ZIP);

    archive::ArchiveOps ops;
    const auto result = ops.test_integrity(archive_path.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_TRUE(result.value());
}

TEST_F(ArchiveOpsTest, should_fail_integrity_for_corrupted_archive) {
    const auto archive_path = create_archive("corrupted.zip", archive::ArchiveFormat::ZIP);

    const auto original_size = stdfs::file_size(archive_path);
    ASSERT_GT(original_size, 0U);

    std::ifstream ifs(archive_path, std::ios::binary);
    std::string data(static_cast<std::size_t>(original_size), '\0');
    ifs.read(data.data(), static_cast<std::streamsize>(data.size()));
    ifs.close();

    const auto truncated_size = std::max<std::size_t>(1U, data.size() / 2U);
    std::ofstream ofs(archive_path, std::ios::binary | std::ios::trunc);
    ofs.write(data.data(), static_cast<std::streamsize>(truncated_size));
    ofs.close();

    archive::ArchiveOps ops;
    const auto result = ops.test_integrity(archive_path.string());

    ASSERT_TRUE(result.has_value()) << result.error().message;
    EXPECT_FALSE(result.value());
}

TEST_F(ArchiveOpsTest, should_add_file_to_zip_archive) {
    const auto archive_path = create_archive(
        "mutate_add.zip",
        archive::ArchiveFormat::ZIP,
        {{"existing.txt", "old"}}
    );

    const auto new_file_path = test_dir_ / "input" / "added.txt";
    write_file(new_file_path, "new-content");

    archive::ArchiveOps ops;
    const auto add_result = ops.add_files(
        archive_path.string(),
        {new_file_path.string()},
        "",
        nullptr,
        nullptr
    );

    ASSERT_TRUE(add_result.has_value()) << add_result.error().message;
    const auto entries = list_entries(archive_path);
    EXPECT_TRUE(contains_entry(entries, "existing.txt"));
    EXPECT_TRUE(contains_entry(entries, "added.txt"));
}

TEST_F(ArchiveOpsTest, should_delete_file_from_zip_archive) {
    const auto archive_path = create_archive(
        "mutate_delete.zip",
        archive::ArchiveFormat::ZIP,
        {{"keep.txt", "keep"}, {"remove.txt", "remove"}}
    );

    archive::ArchiveOps ops;
    const auto delete_result = ops.delete_entries(
        archive_path.string(),
        {"remove.txt"},
        nullptr,
        nullptr
    );

    ASSERT_TRUE(delete_result.has_value()) << delete_result.error().message;
    const auto entries = list_entries(archive_path);
    EXPECT_TRUE(contains_entry(entries, "keep.txt"));
    EXPECT_FALSE(contains_entry(entries, "remove.txt"));
}

TEST_F(ArchiveOpsTest, should_rename_file_inside_zip_archive) {
    const auto archive_path = create_archive(
        "mutate_rename.zip",
        archive::ArchiveFormat::ZIP,
        {{"old.txt", "rename-me"}}
    );

    archive::ArchiveOps ops;
    const auto rename_result = ops.rename_entry(
        archive_path.string(),
        "old.txt",
        "new.txt",
        nullptr,
        nullptr
    );

    ASSERT_TRUE(rename_result.has_value()) << rename_result.error().message;
    const auto entries = list_entries(archive_path);
    EXPECT_FALSE(contains_entry(entries, "old.txt"));
    EXPECT_TRUE(contains_entry(entries, "new.txt"));
}

TEST_F(ArchiveOpsTest, should_add_file_to_tar_gz_archive_via_rebuild) {
    const auto archive_path = create_archive(
        "mutate_add.tar.gz",
        archive::ArchiveFormat::TAR_GZ,
        {{"existing.txt", "old"}}
    );

    const auto new_file_path = test_dir_ / "input" / "tar_added.txt";
    write_file(new_file_path, "tar-new");

    archive::ArchiveOps ops;
    const auto add_result = ops.add_files(
        archive_path.string(),
        {new_file_path.string()},
        "subdir",
        nullptr,
        nullptr
    );

    ASSERT_TRUE(add_result.has_value()) << add_result.error().message;
    const auto entries = list_entries(archive_path);
    EXPECT_TRUE(contains_entry(entries, "existing.txt"));
    EXPECT_TRUE(contains_entry(entries, "subdir/tar_added.txt"));
}

TEST_F(ArchiveOpsTest, should_keep_tar_archive_intact_when_rebuild_cancelled) {
    const auto archive_path = create_archive(
        "mutate_cancel.tar.gz",
        archive::ArchiveFormat::TAR_GZ,
        {{"existing.txt", "old"}}
    );

    const auto new_file_path = test_dir_ / "input" / "cancel_added.txt";
    write_file(new_file_path, "cancel-new");

    std::atomic<bool> cancelled(true);
    archive::ArchiveOps ops;
    const auto add_result = ops.add_files(
        archive_path.string(),
        {new_file_path.string()},
        "",
        &cancelled,
        nullptr
    );

    ASSERT_FALSE(add_result.has_value());
    EXPECT_EQ(add_result.error().code, common::ErrorCode::Cancelled);

    const auto entries = list_entries(archive_path);
    EXPECT_TRUE(contains_entry(entries, "existing.txt"));
    EXPECT_FALSE(contains_entry(entries, "cancel_added.txt"));
}
