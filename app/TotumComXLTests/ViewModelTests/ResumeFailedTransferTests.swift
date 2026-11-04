import Foundation
import XCTest

@testable import TotumComXLApp

/// Continuing a transfer that broke: which operations may be picked up at all, what pressing
/// "continue" does to a failed one, and the speed ceiling that rides along with them.
@MainActor
final class ResumeFailedTransferTests: XCTestCase {

    private var queue: OperationQueueService!
    private let connectionID = UUID()

    override func setUp() async throws {
        try await super.setUp()
        queue = OperationQueueService(fileOps: FileOperationsService(bridgeService: CoreBridgeService()))
        // Hold this server's only transfer slot for the whole test: these tests are about the
        // queue's bookkeeping, and letting an operation actually START would send it looking
        // for a connection that does not exist — and waiting for it forever.
        UserDefaults.standard.set(1, forKey: "fcxl.maxConcurrentTransfers")
        ConnectionManagerService.shared.retainTransferConnection(for: connectionID)
    }

    override func tearDown() async throws {
        ConnectionManagerService.shared.releaseTransferConnection(for: connectionID)
        UserDefaults.standard.removeObject(forKey: "fcxl.maxConcurrentTransfers")
        try await super.tearDown()
    }

    private func makeItem(_ name: String = "film.mkv") -> FileItem {
        FileItem(path: "/tmp/\(name)", name: name,
                 fileExtension: (name as NSString).pathExtension,
                 size: 4_000_000, isDirectory: false, isHidden: false, isSymlink: false,
                 permissions: "644", dateModified: Date())
    }

    private func makeParams() -> RemoteTransferParams {
        RemoteTransferParams(connectionID: connectionID, connectionLabel: "Test",
                             remotePath: "/remote/film.mkv", localPath: "/tmp/film.mkv")
    }

    // MARK: - Which operations can be continued

    func test_failedDownload_canBeContinued() {
        let id = queue.enqueueRemote(kind: .remoteDownload, items: [makeItem()],
                                     destination: "/tmp", remoteParams: makeParams())
        queue.markOperationCompleted(id, error: RemoteFileSystemError.transferFailed("link died"))

        let op = queue.operations.first { $0.id == id }
        XCTAssertEqual(op?.status, .failed)
        XCTAssertTrue(op?.canBeResumed == true)
    }

    /// Only the two transfers leave a half-finished twin behind. A remote DELETE that failed
    /// has nothing to continue — it either happened or it did not.
    func test_failedRemoteDelete_cannotBeContinued() {
        let id = queue.enqueueRemote(kind: .remoteDelete, items: [makeItem()],
                                     destination: nil, remoteParams: makeParams())
        queue.markOperationCompleted(id, error: RemoteFileSystemError.transferFailed("refused"))

        let op = queue.operations.first { $0.id == id }
        XCTAssertEqual(op?.status, .failed)
        XCTAssertFalse(op?.canBeResumed == true)
    }

    /// Stopping a transfer on purpose and coming back to it later is ordinary use of a slow
    /// line — the bytes that arrived are still there.
    func test_cancelledDownload_canBeContinued() {
        let id = queue.enqueueRemote(kind: .remoteDownload, items: [makeItem()],
                                     destination: "/tmp", remoteParams: makeParams())
        queue.cancel(id)

        let op = queue.operations.first { $0.id == id }
        XCTAssertEqual(op?.status, .cancelled)
        XCTAssertTrue(op?.canBeResumed == true)
    }

    func test_continue_worksAfterACancel() {
        let id = queue.enqueueRemote(kind: .remoteDownload, items: [makeItem()],
                                     destination: "/tmp", remoteParams: makeParams())
        queue.cancel(id)

        queue.continueTransfer(id)

        XCTAssertEqual(queue.operations.first { $0.id == id }?.status, .queued)
    }

    func test_finishedDownload_offersNothingToContinue() {
        let id = queue.enqueueRemote(kind: .remoteDownload, items: [makeItem()],
                                     destination: "/tmp", remoteParams: makeParams())
        queue.markOperationCompleted(id, error: nil)
        XCTAssertFalse(queue.operations.first { $0.id == id }?.canBeResumed == true)
    }

    // MARK: - Pressing continue

    func test_continue_takesTheTransferOutOfTheFailedState() {
        let id = queue.enqueueRemote(kind: .remoteDownload, items: [makeItem()],
                                     destination: "/tmp", remoteParams: makeParams())
        queue.markOperationCompleted(id, error: RemoteFileSystemError.transferFailed("link died"))

        queue.continueTransfer(id)

        let op = queue.operations.first { $0.id == id }
        XCTAssertEqual(op?.status, .queued, "a continued transfer goes back in line")
        XCTAssertNil(op?.error, "the old failure must not linger next to a live transfer")
    }

    /// The guard holds: an operation with nothing to continue is left exactly as it was.
    func test_continue_leavesAnUnresumableOperationAlone() {
        let id = queue.enqueueRemote(kind: .remoteDelete, items: [makeItem()],
                                     destination: nil, remoteParams: makeParams())
        queue.markOperationCompleted(id, error: RemoteFileSystemError.transferFailed("refused"))

        queue.continueTransfer(id)

        let op = queue.operations.first { $0.id == id }
        XCTAssertEqual(op?.status, .failed)
        XCTAssertNotNil(op?.error)
    }

    // MARK: - The speed ceiling

    func test_speedLimit_defaultIsNoCeiling() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: TransferSpeedLimit.key)
        defer { defaults.set(saved, forKey: TransferSpeedLimit.key) }

        defaults.removeObject(forKey: TransferSpeedLimit.key)
        XCTAssertEqual(TransferSpeedLimit.bytesPerSecond, 0)
        XCTAssertEqual(TransferSpeedLimit.choices.first, 0)
    }

    func test_speedLimit_kilobytesBecomeBytes() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: TransferSpeedLimit.key)
        defer { defaults.set(saved, forKey: TransferSpeedLimit.key) }

        defaults.set(512, forKey: TransferSpeedLimit.key)
        XCTAssertEqual(TransferSpeedLimit.bytesPerSecond, 512 * 1024)
    }

    /// Every preset reads differently, and the big ones read as megabytes — 10240 КБ/с is a
    /// number nobody parses at a glance.
    func test_speedLimit_everyPresetHasItsOwnLabel() {
        let labels = TransferSpeedLimit.choices.map(TransferSpeedLimit.label(forKilobytesPerSecond:))
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertTrue(TransferSpeedLimit.label(forKilobytesPerSecond: 2048).contains("2"))
        XCTAssertFalse(TransferSpeedLimit.label(forKilobytesPerSecond: 2048).contains("2048"))
    }
}
