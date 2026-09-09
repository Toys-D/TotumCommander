#include <gtest/gtest.h>

#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>

#include "fcxl/filesystem/watcher.h"

using namespace fcxl;
namespace stdfs = std::filesystem;

class WatcherTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        test_dir_ = stdfs::temp_directory_path() / ("fcxl_test_watcher_" + unique);
        stdfs::create_directories(test_dir_);
    }

    void TearDown() override {
        watcher_.stop();
        std::error_code ec;
        stdfs::remove_all(test_dir_, ec);
    }

    stdfs::path test_dir_;
    fs::Watcher watcher_;
};

TEST_F(WatcherTest, should_start_and_stop_watching) {
    const auto result = watcher_.watch(test_dir_.string(), [](const stdfs::path&, fs::WatchEvent) {});

    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE(watcher_.is_watching());

    watcher_.stop();
    EXPECT_FALSE(watcher_.is_watching());
}

TEST_F(WatcherTest, should_detect_file_creation) {
    std::mutex mutex;
    std::condition_variable condition;
    bool created_detected = false;

    const auto result = watcher_.watch(test_dir_.string(),
                                       [&](const stdfs::path& path, fs::WatchEvent event) {
                                           if (event != fs::WatchEvent::Created ||
                                               path.filename() != "created.txt") {
                                               return;
                                           }
                                           {
                                               std::lock_guard<std::mutex> lock(mutex);
                                               created_detected = true;
                                           }
                                           condition.notify_one();
                                       });
    ASSERT_TRUE(result.has_value());

    const auto created_file = test_dir_ / "created.txt";
    {
        std::ofstream ofs(created_file);
        ofs << "hello";
    }

    std::unique_lock<std::mutex> lock(mutex);
    const bool observed = condition.wait_for(
        lock, std::chrono::seconds(5), [&] { return created_detected; });

    EXPECT_TRUE(observed);
}

TEST_F(WatcherTest, should_return_error_for_nonexistent_path) {
    const auto missing = test_dir_ / "does_not_exist";

    const auto result = watcher_.watch(missing.string(), [](const stdfs::path&, fs::WatchEvent) {});

    ASSERT_FALSE(result.has_value());
    EXPECT_EQ(result.error().code, common::ErrorCode::NotFound);
}

TEST_F(WatcherTest, should_report_not_watching_after_stop) {
    const auto start_result = watcher_.watch(test_dir_.string(),
                                             [](const stdfs::path&, fs::WatchEvent) {});
    ASSERT_TRUE(start_result.has_value());
    ASSERT_TRUE(watcher_.is_watching());

    watcher_.stop();

    EXPECT_FALSE(watcher_.is_watching());
}
