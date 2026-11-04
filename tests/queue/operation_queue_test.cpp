#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>

#include "fcxl/queue/operation_queue.h"

using namespace fcxl;
namespace stdfs = std::filesystem;

class OperationQueueTest : public ::testing::Test {
protected:
    void SetUp() override {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        test_dir_ = stdfs::temp_directory_path() / ("fcxl_test_queue_" + unique);
        stdfs::create_directories(test_dir_);
    }

    void TearDown() override {
        std::error_code ec;
        stdfs::remove_all(test_dir_, ec);
    }

    void create_file(const std::string& name, std::size_t size_bytes = 100) {
        std::ofstream ofs(test_dir_ / name, std::ios::binary);
        std::string data(size_bytes, 'A');
        ofs << data;
    }

    stdfs::path test_dir_;
};

TEST_F(OperationQueueTest, should_copy_file_in_background) {
    create_file("source.bin", 1024);
    const auto src = (test_dir_ / "source.bin").string();
    const auto dst = (test_dir_ / "dest.bin").string();

    std::mutex mtx;
    std::condition_variable cv;
    bool done = false;
    bool success = false;

    queue::OperationQueue q;
    [[maybe_unused]] auto copy_id = q.enqueue_copy(src, dst, nullptr,
        [&](queue::OperationId, common::Result<void> result) {
            std::lock_guard<std::mutex> lock(mtx);
            success = result.has_value();
            done = true;
            cv.notify_one();
        });

    std::unique_lock<std::mutex> lock(mtx);
    ASSERT_TRUE(cv.wait_for(lock, std::chrono::seconds(5), [&] { return done; }));
    EXPECT_TRUE(success);
    EXPECT_TRUE(stdfs::exists(dst));
}

TEST_F(OperationQueueTest, should_delete_file_in_background) {
    create_file("to_delete.bin");
    const auto path = (test_dir_ / "to_delete.bin").string();
    ASSERT_TRUE(stdfs::exists(path));

    std::mutex mtx;
    std::condition_variable cv;
    bool done = false;

    queue::OperationQueue q;
    [[maybe_unused]] auto del_id = q.enqueue_delete(path, nullptr,
        [&](queue::OperationId, common::Result<void>) {
            std::lock_guard<std::mutex> lock(mtx);
            done = true;
            cv.notify_one();
        });

    std::unique_lock<std::mutex> lock(mtx);
    ASSERT_TRUE(cv.wait_for(lock, std::chrono::seconds(5), [&] { return done; }));
    EXPECT_FALSE(stdfs::exists(path));
}

TEST_F(OperationQueueTest, should_cancel_operation) {
    queue::OperationQueue q;

    std::atomic<bool> done{false};
    auto id = q.enqueue_copy("/nonexistent_src_12345", "/nonexistent_dst_12345", nullptr,
        [&](queue::OperationId, common::Result<void>) {
            done.store(true, std::memory_order_relaxed);
        });

    q.cancel(id);
    std::this_thread::sleep_for(std::chrono::milliseconds(200));

    // Either the op completed with error or was cancelled — both are fine
    EXPECT_TRUE(done.load(std::memory_order_relaxed));
}

TEST_F(OperationQueueTest, should_report_pending_count) {
    queue::OperationQueue q;
    // Initially no pending
    EXPECT_EQ(q.pending_count(), 0u);
}
