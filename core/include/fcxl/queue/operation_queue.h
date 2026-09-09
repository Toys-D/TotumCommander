#pragma once
/// @file operation_queue.h
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include "fcxl/common/error.h"
#include "fcxl/common/types.h"
namespace fcxl::queue {
using OperationId = uint64_t;
using OperationDone = std::function<void(OperationId, common::Result<void>)>;
using ProgressUpdate = std::function<void(OperationId, const common::OperationProgress&)>;
class OperationQueue {
public:
    OperationQueue();
    ~OperationQueue();
    [[nodiscard]] auto enqueue_copy(std::string source, std::string dest, ProgressUpdate on_progress = nullptr, OperationDone on_done = nullptr) -> OperationId;
    [[nodiscard]] auto enqueue_move(std::string source, std::string dest, ProgressUpdate on_progress = nullptr, OperationDone on_done = nullptr) -> OperationId;
    [[nodiscard]] auto enqueue_delete(std::string path, ProgressUpdate on_progress = nullptr, OperationDone on_done = nullptr) -> OperationId;
    void pause(OperationId id);
    void resume(OperationId id);
    void cancel(OperationId id);
    void cancel_all();
    [[nodiscard]] auto pending_count() const -> uint64_t;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace fcxl::queue
