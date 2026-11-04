import XCTest
@testable import TotumComXLApp

/// Куда именно кладётся файл при отправке: под черновым именем «…part» с переименованием
/// в конце — или сразу под настоящим.
///
/// Черновик нужен там, где обрыв оставляет полуфайл под правильным именем: человек увидел
/// бы законченный с виду файл вместо огрызка. У S3 такой беды нет — незавершённая отправка
/// вообще не показывается в списке, зато переименование стоит копии всего объекта на
/// сервере и упирается в пять гигабайт. Поэтому туда кладут сразу набело.
@MainActor
final class UploadTargetNameTests: XCTestCase {

    /// Запоминает, под каким именем к ней пришли и просили ли переименовать.
    private final class RecordingFileSystem: RemoteFileSystemProtocol, @unchecked Sendable {
        var isConnected = true
        let protocolDisplayName = "ЗАПИСЬ"
        let resumesItself: Bool
        private(set) var uploadedTo: [String] = []
        private(set) var renames: [String] = []

        init(resumesItself: Bool) { self.resumesItself = resumesItself }

        var supportsResume: Bool { true }
        var uploadResumesItself: Bool { resumesItself }

        func connect() async throws {}
        func disconnect() {}
        func listDirectory(at path: String) async throws -> [FileItem] { [] }
        func createDirectory(at path: String, name: String) async throws {}
        func deleteItem(at path: String, isDirectory: Bool) async throws {}
        func rename(at path: String, to newName: String) async throws { renames.append(path) }
        func moveItem(from sourcePath: String, to destinationPath: String) async throws {}
        func download(remotePath: String, to localPath: String,
                      progress: @escaping (Int64, Int64) -> Bool) async throws {}
        func upload(localPath: String, to remotePath: String,
                    progress: @escaping (Int64, Int64) -> Bool) async throws {
            uploadedTo.append(remotePath)
            _ = progress(1, 1)
        }
    }

    private final class SilentReporter: OperationProgressReporter, @unchecked Sendable {
        nonisolated var isCancelled: Bool { false }
        nonisolated var isPaused: Bool { false }
        nonisolated var isSentToQueue: Bool { false }
        func update(currentFile: String, progress: Double, bytesDone: Int64,
                    bytesTotal: Int64, filesDone: Int, filesTotal: Int) {}
        func setDetail(_ text: String) {}
        func setTrouble(_ text: String?) {}
        func close() {}
    }

    private func sendOneFile(to fileSystem: RecordingFileSystem) async throws {
        let path = NSTemporaryDirectory() + "отправка-\(UUID().uuidString).txt"
        try Data("текст".utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let item = try XCTUnwrap(FileItem.fromPath(path))
        let session = RemoteSession(connection: RemoteConnection(proto: .ftp, host: "х"),
                                    fileSystem: fileSystem)
        let done = expectation(description: "отправка завершилась")
        RemoteTransferService().uploadItems([item], to: session, remoteDestination: "/",
                                            reporter: SilentReporter()) { done.fulfill() }
        await fulfillment(of: [done], timeout: 10)
    }

    func test_plainServer_getsADraftAndARename() async throws {
        let fileSystem = RecordingFileSystem(resumesItself: false)
        try await sendOneFile(to: fileSystem)
        XCTAssertEqual(fileSystem.uploadedTo.count, 1)
        XCTAssertTrue(fileSystem.uploadedTo[0].hasSuffix(ResumableTransfer.partSuffix),
                      "файл шёл под черновым именем: \(fileSystem.uploadedTo)")
        XCTAssertEqual(fileSystem.renames.count, 1, "и получил настоящее имя в конце")
    }

    func test_selfResumingStorage_getsTheRealNameAtOnce() async throws {
        let fileSystem = RecordingFileSystem(resumesItself: true)
        try await sendOneFile(to: fileSystem)
        XCTAssertEqual(fileSystem.uploadedTo.count, 1)
        XCTAssertFalse(fileSystem.uploadedTo[0].hasSuffix(ResumableTransfer.partSuffix),
                       "имя настоящее с первого байта: \(fileSystem.uploadedTo)")
        XCTAssertTrue(fileSystem.renames.isEmpty,
                      "переименования нет — иначе это копия всего объекта на сервере")
    }

    /// Само хранилище об этом и говорит.
    func test_s3SaysItResumesItself() {
        let s3 = S3RemoteFileSystem(
            connection: RemoteConnection(proto: .s3, host: "х", s3Bucket: "ведро"),
            password: "ключ")
        XCTAssertTrue(s3.uploadResumesItself)
    }
}
