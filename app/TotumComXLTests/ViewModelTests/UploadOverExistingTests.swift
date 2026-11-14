import XCTest
@testable import TotumComXLApp

/// Отправка поверх файла, который уже лежит на сервере. Черновик «…part» получает настоящее
/// имя в самом конце, а FTP на занятое имя не переименовывает — прежний файл надо убрать,
/// каким бы он ни был, в том числе пустым.
@MainActor
final class UploadOverExistingTests: XCTestCase {

    /// Сервер в памяти с повадками FTP: на занятое имя не переименовывает.
    private final class StrictServer: RemoteFileSystemProtocol, @unchecked Sendable {
        var isConnected = true
        let protocolDisplayName = "СТРОГИЙ"
        /// Путь → размер.
        var files: [String: Int64]
        private(set) var deleted: [String] = []
        /// По первому списку папки программа спрашивает о замене — модальным окном, на
        /// которое в тесте ответить некому. Поэтому прежний файл в этом списке не виден;
        /// дальше дорога та же, что после ответа «Заменить».
        private var isFirstListing = true

        init(_ files: [String: Int64]) { self.files = files }

        var supportsResume: Bool { true }

        func connect() async throws {}
        func disconnect() {}
        func listDirectory(at path: String) async throws -> [FileItem] {
            if isFirstListing {
                isFirstListing = false
                return []
            }
            return files.compactMap { entry -> FileItem? in
                guard parentPath(for: entry.key) == path else { return nil }
                let name = (entry.key as NSString).lastPathComponent
                return FileItem(path: entry.key, name: name,
                                fileExtension: (name as NSString).pathExtension,
                                size: UInt64(entry.value), isDirectory: false, isHidden: false,
                                isSymlink: false, permissions: "-rw-r--r--", dateModified: Date())
            }
        }
        func createDirectory(at path: String, name: String) async throws {}
        func deleteItem(at path: String, isDirectory: Bool) async throws {
            deleted.append(path)
            files[path] = nil
        }
        func rename(at path: String, to newName: String) async throws {
            let parent = parentPath(for: path)
            let target = (parent == "/" ? "/" : parent + "/") + newName
            guard let size = files[path], files[target] == nil else {
                throw NSError(domain: "StrictServer", code: 550,
                              userInfo: [NSLocalizedDescriptionKey: "имя занято"])
            }
            files[path] = nil
            files[target] = size
        }
        func moveItem(from sourcePath: String, to destinationPath: String) async throws {}
        func download(remotePath: String, to localPath: String,
                      progress: @escaping (Int64, Int64) -> Bool) async throws {}
        func upload(localPath: String, to remotePath: String,
                    progress: @escaping (Int64, Int64) -> Bool) async throws {
            let size = ((try? FileManager.default.attributesOfItem(atPath: localPath))?[.size]
                        as? Int64) ?? 0
            files[remotePath] = size
            _ = progress(size, size)
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

    private var folder = ""

    override func setUp() async throws {
        folder = NSTemporaryDirectory() + "отправка-поверх-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: folder)
    }

    /// Отправить «файл.txt» (10 байт) в корень сервера; вернуть ошибку отправки, если была.
    private func send(to server: StrictServer) async throws -> Error? {
        let path = folder + "/файл.txt"
        try Data("0123456789".utf8).write(to: URL(fileURLWithPath: path))
        let item = try XCTUnwrap(FileItem.fromPath(path))
        let session = RemoteSession(connection: RemoteConnection(proto: .ftp, host: "х"),
                                    fileSystem: server)
        let done = expectation(description: "отправка завершилась")
        var failure: Error?
        // С onFailure служба итогового окна не показывает — отчёт забирает тест.
        RemoteTransferService().uploadItems([item], to: session, remoteDestination: "/",
                                            reporter: SilentReporter(),
                                            onCompletion: { done.fulfill() },
                                            onFailure: { failure = $0 })
        await fulfillment(of: [done], timeout: 10)
        return failure
    }

    func test_отправкаПоверхПустогоФайла_ЧерновикПолучаетНастоящееИмя() async throws {
        let server = StrictServer(["/файл.txt": 0])

        let failure = try await send(to: server)

        XCTAssertNil(failure, "отправка не прошла: \(failure?.localizedDescription ?? "")")
        XCTAssertEqual(server.files["/файл.txt"], 10, "на сервере остался прежний пустой файл")
        XCTAssertNil(server.files["/файл.txt" + ResumableTransfer.partSuffix],
                     "на сервере остался черновик")
    }

    /// Закрепляющая проверка: непустой прежний файл заменяется, как и раньше.
    func test_отправкаПоверхНепустогоФайла_ПрежнийЗаменён() async throws {
        let server = StrictServer(["/файл.txt": 3])

        let failure = try await send(to: server)

        XCTAssertNil(failure)
        XCTAssertEqual(server.files["/файл.txt"], 10)
        XCTAssertNil(server.files["/файл.txt" + ResumableTransfer.partSuffix])
    }

    /// Закрепляющая проверка: когда прежнего файла нет, сервер не просят ничего удалять.
    func test_отправкаНаСвободноеИмя_НичегоНеУдаляется() async throws {
        let server = StrictServer([:])

        let failure = try await send(to: server)

        XCTAssertNil(failure)
        XCTAssertEqual(server.files["/файл.txt"], 10)
        XCTAssertEqual(server.deleted, [])
    }
}
