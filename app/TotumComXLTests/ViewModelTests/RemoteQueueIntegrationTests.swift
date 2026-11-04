import Foundation
import XCTest

@testable import TotumComXLApp

/// Tests that remote operations can be enqueued with RemoteTransferParams.
/// Does NOT test actual execution (that requires a live FTP server).
@MainActor
final class RemoteQueueIntegrationTests: XCTestCase {

    private var queue: OperationQueueService!
    private let connectionID = UUID()

    override func setUp() async throws {
        try await super.setUp()
        let fileOps = FileOperationsService(bridgeService: CoreBridgeService())
        queue = OperationQueueService(fileOps: fileOps)
    }

    // MARK: - Helpers

    private func makeItem(name: String = "file.txt") -> FileItem {
        let ext = (name as NSString).pathExtension
        return FileItem(
            path: "/tmp/\(name)",
            name: name,
            fileExtension: ext,
            size: 1024,
            isDirectory: false,
            isHidden: false,
            isSymlink: false,
            permissions: "644",
            dateModified: Date()
        )
    }

    private func makeRemoteParams(localPath: String = "/tmp/local",
                                  remotePath: String = "/remote") -> RemoteTransferParams {
        RemoteTransferParams(
            connectionID: connectionID,
            connectionLabel: "Test FTP",
            remotePath: remotePath,
            localPath: localPath
        )
    }

    // MARK: - remoteDownload enqueue

    func test_enqueueRemote_download_createsOperationWithCorrectKind() {
        let params = makeRemoteParams()
        let id = queue.enqueueRemote(
            kind: .remoteDownload,
            items: [makeItem()],
            destination: nil,
            remoteParams: params
        )

        let op = queue.operations.first { $0.id == id }
        XCTAssertNotNil(op, "enqueued operation should exist in queue")
        XCTAssertEqual(op?.kind, .remoteDownload)
    }

    func test_enqueueRemote_download_storesRemoteParams() {
        let params = makeRemoteParams(localPath: "/Users/test/Downloads", remotePath: "/pub/files")
        let id = queue.enqueueRemote(
            kind: .remoteDownload,
            items: [makeItem()],
            destination: nil,
            remoteParams: params
        )

        let op = queue.operations.first { $0.id == id }
        XCTAssertNotNil(op?.remoteParams, "remoteParams should be stored on operation")
        XCTAssertEqual(op?.remoteParams?.connectionID, connectionID)
        XCTAssertEqual(op?.remoteParams?.localPath, "/Users/test/Downloads")
        XCTAssertEqual(op?.remoteParams?.remotePath, "/pub/files")
        XCTAssertEqual(op?.remoteParams?.connectionLabel, "Test FTP")
    }

    func test_enqueueRemote_download_operationIsQueued() {
        let params = makeRemoteParams()
        let id = queue.enqueueRemote(
            kind: .remoteDownload,
            items: [makeItem()],
            destination: nil,
            remoteParams: params
        )

        // Cancel immediately so the real execution cannot proceed
        queue.cancel(id)

        let op = queue.operations.first { $0.id == id }
        XCTAssertTrue(op?.isFinished ?? false, "cancelled operation should be finished")
    }

    // MARK: - remoteUpload enqueue

    func test_enqueueRemote_upload_createsOperationWithCorrectKind() {
        let params = makeRemoteParams()
        let id = queue.enqueueRemote(
            kind: .remoteUpload,
            items: [makeItem(name: "photo.jpg")],
            destination: nil,
            remoteParams: params
        )

        let op = queue.operations.first { $0.id == id }
        XCTAssertNotNil(op, "enqueued operation should exist in queue")
        XCTAssertEqual(op?.kind, .remoteUpload)
    }

    func test_enqueueRemote_upload_storesItemCount() {
        let params = makeRemoteParams()
        let items = [makeItem(name: "a.txt"), makeItem(name: "b.txt"), makeItem(name: "c.txt")]
        let id = queue.enqueueRemote(
            kind: .remoteUpload,
            items: items,
            destination: nil,
            remoteParams: params
        )

        let op = queue.operations.first { $0.id == id }
        XCTAssertEqual(op?.filesTotal, 3)
        XCTAssertEqual(op?.items.count, 3)
    }

    // MARK: - remoteDelete enqueue

    func test_enqueueRemote_delete_createsOperationWithCorrectKind() {
        let params = makeRemoteParams()
        let id = queue.enqueueRemote(
            kind: .remoteDelete,
            items: [makeItem()],
            destination: nil,
            remoteParams: params
        )

        let op = queue.operations.first { $0.id == id }
        XCTAssertNotNil(op, "enqueued operation should exist in queue")
        XCTAssertEqual(op?.kind, .remoteDelete)
    }

    // MARK: - Completion callback

    func test_enqueueRemote_download_callsCompletionOnCancel() {
        let params = makeRemoteParams()
        var completionFired = false
        let id = queue.enqueueRemote(
            kind: .remoteDownload,
            items: [makeItem()],
            destination: nil,
            remoteParams: params,
            onCompletion: { completionFired = true }
        )

        queue.cancel(id)
        XCTAssertTrue(completionFired, "onCompletion should fire when operation is cancelled")
    }

    // MARK: - Cleanup

    func test_removeCompleted_removesFinishedRemoteOperations() {
        let params = makeRemoteParams()
        let id = queue.enqueueRemote(
            kind: .remoteDownload,
            items: [makeItem()],
            destination: nil,
            remoteParams: params
        )
        queue.cancel(id)
        queue.removeCompleted()

        XCTAssertTrue(queue.operations.isEmpty, "finished operations should be removed")
    }
}
