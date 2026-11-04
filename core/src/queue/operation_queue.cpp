#include "fcxl/queue/operation_queue.h"

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <unordered_map>

#include "fcxl/filesystem/operations.h"

namespace fcxl::queue {

// Internal representation of a queued operation
struct QueuedOperation {
    OperationId id = 0;
    common::OperationType type = common::OperationType::Copy;
    std::string source;
    std::string destination;
    ProgressUpdate on_progress;
    OperationDone on_done;
    std::atomic<bool> paused{false};
    std::atomic<bool> cancelled{false};
};

struct OperationQueue::Impl {
    std::mutex mutex;
    std::condition_variable cv;
    std::deque<std::shared_ptr<QueuedOperation>> pending;
    std::shared_ptr<QueuedOperation> current;
    std::unordered_map<OperationId, std::shared_ptr<QueuedOperation>> all_ops;
    std::thread worker;
    std::atomic<bool> shutdown{false};
    std::atomic<uint64_t> next_id{1};

    Impl() {
        worker = std::thread([this] { run(); });
    }

    ~Impl() {
        {
            std::lock_guard<std::mutex> lock(mutex);
            shutdown.store(true, std::memory_order_relaxed);
        }
        cv.notify_one();
        if (worker.joinable()) {
            worker.join();
        }
    }

    void run() {
        fs::Operations ops;

        while (true) {
            std::shared_ptr<QueuedOperation> op;

            {
                std::unique_lock<std::mutex> lock(mutex);
                cv.wait(lock, [this] {
                    return shutdown.load(std::memory_order_relaxed) || !pending.empty();
                });

                if (shutdown.load(std::memory_order_relaxed) && pending.empty()) {
                    return;
                }

                if (pending.empty()) {
                    continue;
                }

                op = pending.front();
                pending.pop_front();
                current = op;
            }

            if (op->cancelled.load(std::memory_order_relaxed)) {
                fire_done(op, common::Error::make(common::ErrorCode::Cancelled, "Operation cancelled"));
                clear_current(op->id);
                continue;
            }

            // Build a progress callback that respects pause/cancel
            auto progress_cb = [&op](const common::OperationProgress& p) -> bool {
                // Spin-wait while paused
                while (op->paused.load(std::memory_order_relaxed)) {
                    if (op->cancelled.load(std::memory_order_relaxed)) {
                        return false;
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                }

                if (op->cancelled.load(std::memory_order_relaxed)) {
                    return false;
                }

                if (op->on_progress) {
                    common::OperationProgress progress = p;
                    progress.is_paused = op->paused.load(std::memory_order_relaxed);
                    progress.is_cancelled = op->cancelled.load(std::memory_order_relaxed);
                    op->on_progress(op->id, progress);
                }

                return true;
            };

            common::Result<void> result = common::Result<void>();

            switch (op->type) {
                case common::OperationType::Copy:
                    result = ops.copy(op->source, op->destination,
                                      common::ConflictResolution::Ask, progress_cb);
                    break;
                case common::OperationType::Move:
                    result = ops.move(op->source, op->destination,
                                      common::ConflictResolution::Ask, progress_cb);
                    break;
                case common::OperationType::Delete:
                    result = ops.remove(op->source, true, progress_cb);
                    break;
                default:
                    result = common::Error::make(common::ErrorCode::NotSupported,
                                                  "Unsupported operation type");
                    break;
            }

            fire_done(op, std::move(result));
            clear_current(op->id);
        }
    }

    void fire_done(const std::shared_ptr<QueuedOperation>& op, common::Result<void> result) {
        if (op->on_done) {
            op->on_done(op->id, std::move(result));
        }
    }

    void clear_current(OperationId id) {
        std::lock_guard<std::mutex> lock(mutex);
        if (current && current->id == id) {
            current.reset();
        }
    }

    auto enqueue(common::OperationType type,
                 std::string source,
                 std::string dest,
                 ProgressUpdate on_progress,
                 OperationDone on_done) -> OperationId {
        auto op = std::make_shared<QueuedOperation>();
        op->id = next_id.fetch_add(1, std::memory_order_relaxed);
        op->type = type;
        op->source = std::move(source);
        op->destination = std::move(dest);
        op->on_progress = std::move(on_progress);
        op->on_done = std::move(on_done);

        {
            std::lock_guard<std::mutex> lock(mutex);
            all_ops[op->id] = op;
            pending.push_back(op);
        }
        cv.notify_one();

        return op->id;
    }

    auto find_op(OperationId id) -> std::shared_ptr<QueuedOperation> {
        std::lock_guard<std::mutex> lock(mutex);
        auto it = all_ops.find(id);
        if (it != all_ops.end()) {
            return it->second;
        }
        return nullptr;
    }
};

OperationQueue::OperationQueue() : impl_(std::make_unique<Impl>()) {}
OperationQueue::~OperationQueue() = default;

auto OperationQueue::enqueue_copy(std::string source, std::string dest,
                                   ProgressUpdate on_progress, OperationDone on_done) -> OperationId {
    return impl_->enqueue(common::OperationType::Copy,
                           std::move(source), std::move(dest),
                           std::move(on_progress), std::move(on_done));
}

auto OperationQueue::enqueue_move(std::string source, std::string dest,
                                   ProgressUpdate on_progress, OperationDone on_done) -> OperationId {
    return impl_->enqueue(common::OperationType::Move,
                           std::move(source), std::move(dest),
                           std::move(on_progress), std::move(on_done));
}

auto OperationQueue::enqueue_delete(std::string path,
                                     ProgressUpdate on_progress, OperationDone on_done) -> OperationId {
    return impl_->enqueue(common::OperationType::Delete,
                           std::move(path), std::string{},
                           std::move(on_progress), std::move(on_done));
}

void OperationQueue::pause(OperationId id) {
    auto op = impl_->find_op(id);
    if (op) {
        op->paused.store(true, std::memory_order_relaxed);
    }
}

void OperationQueue::resume(OperationId id) {
    auto op = impl_->find_op(id);
    if (op) {
        op->paused.store(false, std::memory_order_relaxed);
    }
}

void OperationQueue::cancel(OperationId id) {
    auto op = impl_->find_op(id);
    if (op) {
        op->cancelled.store(true, std::memory_order_relaxed);
        // If it's paused, un-pause so the operation loop can exit
        op->paused.store(false, std::memory_order_relaxed);
    }
}

void OperationQueue::cancel_all() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    for (auto& [id, op] : impl_->all_ops) {
        op->cancelled.store(true, std::memory_order_relaxed);
        op->paused.store(false, std::memory_order_relaxed);
    }
}

auto OperationQueue::pending_count() const -> uint64_t {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return static_cast<uint64_t>(impl_->pending.size());
}

}  // namespace fcxl::queue
