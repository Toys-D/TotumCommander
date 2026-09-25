import XCTest

@testable import TotumComXLApp

/// Tests for the pure display/estimation logic of `QueuedOperation` — the model behind the
/// operation-queue UI (badge count, ETA, elapsed time, status). No queue service, no file I/O,
/// no async: every value here is derived deterministically from the struct's fields.
final class QueuedOperationTests: XCTestCase {

    private func item(_ name: String) -> FileItem {
        FileItem(path: "/tmp/\(name)", name: name, fileExtension: "", size: 0,
                 isDirectory: false, isHidden: false, isSymlink: false,
                 permissions: "rw-r--r--", dateModified: Date(timeIntervalSince1970: 0))
    }

    private func op(_ kind: OperationKind,
                    items: [FileItem] = [],
                    status: OperationStatus = .queued,
                    progress: Double = 0,
                    startedAt: Date? = nil,
                    completedAt: Date? = nil) -> QueuedOperation {
        var o = QueuedOperation(id: UUID(), kind: kind, items: items,
                                destinationPath: nil, createdAt: Date(timeIntervalSince1970: 0))
        o.status = status
        o.progress = progress
        o.startedAt = startedAt
        o.completedAt = completedAt
        return o
    }

    // MARK: - isActive / isFinished (drive the queue badge counter)

    func test_isActive_trueForQueuedRunningPaused() {
        for s in [OperationStatus.queued, .running, .paused] {
            XCTAssertTrue(op(.copy, status: s).isActive, "\(s) should be active")
            XCTAssertFalse(op(.copy, status: s).isFinished, "\(s) should not be finished")
        }
    }

    func test_isFinished_trueForCompletedFailedCancelled() {
        for s in [OperationStatus.completed, .failed, .cancelled] {
            XCTAssertTrue(op(.copy, status: s).isFinished, "\(s) should be finished")
            XCTAssertFalse(op(.copy, status: s).isActive, "\(s) should not be active")
        }
    }

    // MARK: - elapsedTime

    func test_elapsed_zeroWhenNeverStarted() {
        XCTAssertEqual(op(.copy).elapsedTime, 0, accuracy: 0.0001)
    }

    func test_elapsed_exactBetweenStartAndCompletion() {
        let o = op(.move, status: .completed,
                   startedAt: Date(timeIntervalSince1970: 100),
                   completedAt: Date(timeIntervalSince1970: 130))
        XCTAssertEqual(o.elapsedTime, 30, accuracy: 0.0001)
    }

    func test_elapsed_countsFromStartWhileRunning() {
        let o = op(.copy, status: .running, progress: 0.4,
                   startedAt: Date().addingTimeInterval(-5))
        // No completedAt → measured against "now"; ~5s with a generous tolerance for test timing.
        XCTAssertEqual(o.elapsedTime, 5, accuracy: 2)
    }

    // MARK: - remainingTime (linear ETA extrapolation)

    func test_remaining_nilWhilePreparing() {
        // progress at/under the 0.02 threshold → still "preparing", no estimate yet.
        let o = op(.copy, status: .running, progress: 0.01,
                   startedAt: Date().addingTimeInterval(-10))
        XCTAssertNil(o.remainingTime)
    }

    func test_remaining_nilWhenPaused() {
        let o = op(.copy, status: .paused, progress: 0.5,
                   startedAt: Date().addingTimeInterval(-10))
        XCTAssertNil(o.remainingTime)
    }

    func test_remaining_nilWhenFinished() {
        let o = op(.copy, status: .completed, progress: 1.0,
                   startedAt: Date(timeIntervalSince1970: 100),
                   completedAt: Date(timeIntervalSince1970: 130))
        XCTAssertNil(o.remainingTime)
    }

    func test_remaining_nilWhenBarelyStarted() {
        // elapsed under 0.5s → too early to extrapolate.
        let o = op(.copy, status: .running, progress: 0.5, startedAt: Date())
        XCTAssertNil(o.remainingTime)
    }

    func test_remaining_extrapolatesFromProgress() throws {
        // elapsed ≈ 12s at 25% done → ~36s left (elapsed/progress - elapsed).
        let o = op(.copy, status: .running, progress: 0.25,
                   startedAt: Date().addingTimeInterval(-12))
        let remaining = try XCTUnwrap(o.remainingTime)
        XCTAssertTrue(remaining.isFinite)
        XCTAssertEqual(remaining, 36, accuracy: 4)
    }

    func test_remaining_nilAtFullProgress() {
        // progress == 1.0 → elapsed/progress - elapsed == 0 → not > 0 → nil.
        let o = op(.copy, status: .running, progress: 1.0,
                   startedAt: Date().addingTimeInterval(-10))
        XCTAssertNil(o.remainingTime)
    }

    func test_remaining_tinyPositiveJustBeforeComplete() throws {
        // progress 0.999 → a small but positive estimate, not nil.
        let o = op(.copy, status: .running, progress: 0.999,
                   startedAt: Date().addingTimeInterval(-10))
        let remaining = try XCTUnwrap(o.remainingTime)
        XCTAssertGreaterThan(remaining, 0)
        XCTAssertLessThan(remaining, 1)
    }

    // MARK: - displayTitle (localised, branches on single vs multiple)

    func test_displayTitle_nonEmptyForEveryKind() {
        let kinds: [OperationKind] = [.copy, .move, .delete, .pack, .unpack,
                                      .archiveDelete, .archiveRename,
                                      .remoteDownload, .remoteUpload, .remoteDelete]
        for k in kinds {
            let title = op(k, items: [item("a.txt")]).displayTitle
            XCTAssertFalse(title.isEmpty, "\(k) produced an empty title")
        }
    }

    func test_displayTitle_singleDiffersFromMultiple() {
        let single = op(.copy, items: [item("a.txt")]).displayTitle
        let multiple = op(.copy, items: [item("a.txt"), item("b.txt"), item("c.txt")]).displayTitle
        XCTAssertNotEqual(single, multiple)
        XCTAssertFalse(single.isEmpty)
        XCTAssertFalse(multiple.isEmpty)
    }
}
