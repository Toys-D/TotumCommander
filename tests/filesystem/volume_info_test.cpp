#include <gtest/gtest.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <string>

#include "fcxl/filesystem/volume_info.h"

using namespace fcxl;
namespace stdfs = std::filesystem;

class VolumeInfoProviderTest : public ::testing::Test {
protected:
    fs::VolumeInfoProvider provider_;
};

TEST_F(VolumeInfoProviderTest, should_return_at_least_one_volume) {
    const auto result = provider_.get_volumes();

    ASSERT_TRUE(result.has_value());
    EXPECT_FALSE(result.value().empty());
}

TEST_F(VolumeInfoProviderTest, should_have_root_volume) {
    const auto result = provider_.get_volumes();
    ASSERT_TRUE(result.has_value());

    const auto& volumes = result.value();
    const auto it = std::find_if(volumes.begin(), volumes.end(), [](const common::VolumeInfo& volume) {
        return volume.mount_point == "/";
    });

    EXPECT_NE(it, volumes.end());
}

TEST_F(VolumeInfoProviderTest, should_return_valid_sizes) {
    const auto result = provider_.get_volume_for_path("/");

    ASSERT_TRUE(result.has_value());
    const auto& volume = result.value();
    EXPECT_GT(volume.total_bytes, static_cast<uint64_t>(0));
    EXPECT_LE(volume.free_bytes, volume.total_bytes);
    EXPECT_LE(volume.available_bytes, volume.total_bytes);
}

TEST_F(VolumeInfoProviderTest, should_get_volume_for_home_path) {
    const char* home = std::getenv("HOME");
    ASSERT_NE(home, nullptr);
    ASSERT_NE(*home, '\0');

    const auto result = provider_.get_volume_for_path(home);

    ASSERT_TRUE(result.has_value());
    EXPECT_FALSE(result.value().mount_point.empty());
    EXPECT_GT(result.value().total_bytes, static_cast<uint64_t>(0));
}

TEST_F(VolumeInfoProviderTest, should_return_error_for_nonexistent_path) {
    const auto missing = stdfs::temp_directory_path() /
                         ("fcxl_missing_volume_info_path_" +
                          std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));

    const auto result = provider_.get_volume_for_path(missing.string());

    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::NotFound);
}
