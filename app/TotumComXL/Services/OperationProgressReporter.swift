import Foundation

protocol OperationProgressReporter: AnyObject {
    nonisolated var isCancelled: Bool { get }
    nonisolated var isPaused: Bool { get }
    /// True when the user pressed "Send to queue" and this dialog has closed.
    nonisolated var isSentToQueue: Bool { get }
    /// Block the CALLING (background) thread while the operation is paused; returns
    /// true if it was cancelled. Reporters that can't be paused return immediately.
    nonisolated func waitWhilePaused() -> Bool
    @MainActor func update(currentFile: String, progress: Double,
                bytesDone: Int64, bytesTotal: Int64,
                filesDone: Int, filesTotal: Int)
    /// One operation-specific line under the counters — packing uses it for the format, the
    /// compression level and the live size estimate. Reporters with nowhere to put it ignore it.
    @MainActor func setDetail(_ text: String)
    /// Something is WRONG and the operation is waiting rather than working: the link dropped
    /// and the transfer is counting down to another try. It takes the place of the time
    /// estimate, which at that moment would be counting down to nothing.
    ///
    /// Nobody has to clear it by hand — the next real progress report does, because bytes
    /// moving again IS the news that the trouble is over.
    @MainActor func setTrouble(_ text: String?)
    @MainActor func close()
}

extension OperationProgressReporter {
    /// Default: no pause support — never blocks, just reports the cancel state.
    nonisolated func waitWhilePaused() -> Bool { isCancelled }
    /// Default: nowhere to show it.
    @MainActor func setDetail(_ text: String) {}
    @MainActor func setTrouble(_ text: String?) {}
}

// MARK: - ProgressController conformance

extension ProgressController: @preconcurrency OperationProgressReporter {
    // Was hardcoded to false with no waitWhilePaused override, i.e. the progress dialog had no
    // pause at all — only the queue did. That is why a confirmation could not hold the work.
    nonisolated var isPaused: Bool { isPausedFlagValue }
    nonisolated func waitWhilePaused() -> Bool { waitWhilePausedImpl() }
    // isSentToQueue is already a stored property on ProgressController
}

// MARK: - SwappableProgressReporter

/// A thread-safe wrapper that can swap the underlying reporter at runtime.
/// Used when the user clicks "Send to queue" — the ProgressController is replaced
/// with a QueueOperationReporter while the background work continues uninterrupted.
final class SwappableProgressReporter: OperationProgressReporter, @unchecked Sendable {
    private let lock = NSLock()
    private var _inner: OperationProgressReporter

    init(_ inner: OperationProgressReporter) {
        _inner = inner
    }

    /// Atomically swap the underlying reporter.
    func swap(to newReporter: OperationProgressReporter) {
        lock.lock()
        _inner = newReporter
        lock.unlock()
    }

    private var inner: OperationProgressReporter {
        lock.lock()
        let r = _inner
        lock.unlock()
        return r
    }

    nonisolated var isCancelled: Bool { inner.isCancelled }
    nonisolated var isPaused: Bool { inner.isPaused }
    nonisolated var isSentToQueue: Bool { inner.isSentToQueue }
    nonisolated func waitWhilePaused() -> Bool { inner.waitWhilePaused() }

    @MainActor
    func update(currentFile: String, progress: Double,
                bytesDone: Int64, bytesTotal: Int64,
                filesDone: Int, filesTotal: Int) {
        inner.update(currentFile: currentFile, progress: progress,
                     bytesDone: bytesDone, bytesTotal: bytesTotal,
                     filesDone: filesDone, filesTotal: filesTotal)
    }

    @MainActor
    func setDetail(_ text: String) {
        inner.setDetail(text)
    }

    @MainActor
    func setTrouble(_ text: String?) {
        inner.setTrouble(text)
    }

    @MainActor
    func close() {
        inner.close()
    }
}

// MARK: - QueueOperationReporter

final class QueueOperationReporter: OperationProgressReporter, @unchecked Sendable {
    private let operationId: UUID
    private weak var queueService: OperationQueueService?
    private let cancelLock = NSLock()
    private var _isCancelled = false
    private var _isPaused = false
    private let pauseSemaphore = DispatchSemaphore(value: 0)

    init(operationId: UUID, queueService: OperationQueueService) {
        self.operationId = operationId
        self.queueService = queueService
    }

    nonisolated var isCancelled: Bool {
        cancelLock.lock()
        let val = _isCancelled
        cancelLock.unlock()
        return val
    }

    /// Queue reporter is never "sent to queue" — it IS the queue.
    nonisolated var isSentToQueue: Bool { false }

    nonisolated var isPaused: Bool {
        cancelLock.lock()
        let val = _isPaused
        cancelLock.unlock()
        return val
    }

    func markCancelled() {
        cancelLock.lock()
        _isCancelled = true
        _isPaused = false
        cancelLock.unlock()
        pauseSemaphore.signal()
    }

    func markPaused(_ paused: Bool) {
        cancelLock.lock()
        let wasPaused = _isPaused
        _isPaused = paused
        cancelLock.unlock()
        // Wake up waiting thread when unpausing
        if wasPaused && !paused {
            pauseSemaphore.signal()
        }
    }

    /// Block the calling thread while paused. Returns true if cancelled.
    func waitWhilePaused() -> Bool {
        while isPaused {
            if isCancelled { return true }
            _ = pauseSemaphore.wait(timeout: .now() + 0.1)
        }
        return isCancelled
    }

    @MainActor
    func update(currentFile: String, progress: Double,
                bytesDone: Int64, bytesTotal: Int64,
                filesDone: Int, filesTotal: Int) {
        queueService?.updateOperationProgress(
            id: operationId,
            currentFile: currentFile,
            progress: progress,
            bytesDone: bytesDone,
            bytesTotal: bytesTotal,
            filesDone: filesDone,
            filesTotal: filesTotal
        )
    }

    @MainActor
    func setTrouble(_ text: String?) {
        queueService?.updateOperationTrouble(id: operationId, text: text)
    }

    @MainActor
    func close() {
        // No panel to close — queue panel manages its own lifecycle
    }
}
