import XCTest
@testable import TotumComXLApp

/// Как программа сносит папку на сервере.
///
/// Настоящий случай: удаление папки из Google Drive шло минутами, и по окну нельзя было
/// понять, идёт ли дело вообще. Мы обходили дерево сами и слали запрос на каждый файл —
/// при том, что у rclone и S3 есть действие «снести папку целиком» за одно обращение.
@MainActor
final class RemoteDeleteTests: XCTestCase {

    /// Считает, сколько раз её просили что-нибудь удалить.
    private final class CountingFileSystem: RemoteFileSystemProtocol, @unchecked Sendable {
        var isConnected = true
        let protocolDisplayName = "СЧЁТ"
        let treesAtOnce: Bool
        private(set) var deleteCalls: [(path: String, isDirectory: Bool)] = []
        private(set) var listCalls = 0

        init(treesAtOnce: Bool) { self.treesAtOnce = treesAtOnce }
        var deletesTreesItself: Bool { treesAtOnce }

        func connect() async throws {}
        func disconnect() {}
        /// Папка с тремя файлами и одной вложенной папкой, в которой ещё два.
        func listDirectory(at path: String) async throws -> [FileItem] {
            listCalls += 1
            func файл(_ имя: String, _ где: String) -> FileItem {
                FileItem(path: где + "/" + имя, name: имя, fileExtension: "bin", size: 1,
                         isDirectory: false, isHidden: false, isSymlink: false,
                         permissions: "-rw-r--r--", dateModified: Date())
            }
            if path == "/папка" {
                return [файл("один.bin", path), файл("два.bin", path), файл("три.bin", path),
                        FileItem(path: "/папка/вложенная", name: "вложенная", fileExtension: "",
                                 size: 0, isDirectory: true, isHidden: false, isSymlink: false,
                                 permissions: "drwxr-xr-x", dateModified: Date())]
            }
            if path == "/папка/вложенная" {
                return [файл("четыре.bin", path), файл("пять.bin", path)]
            }
            return []
        }
        func createDirectory(at path: String, name: String) async throws {}
        func deleteItem(at path: String, isDirectory: Bool) async throws {
            deleteCalls.append((path, isDirectory))
        }
        func rename(at path: String, to newName: String) async throws {}
        func moveItem(from sourcePath: String, to destinationPath: String) async throws {}
        func download(remotePath: String, to localPath: String,
                      progress: @escaping (Int64, Int64) -> Bool) async throws {}
        func upload(localPath: String, to remotePath: String,
                    progress: @escaping (Int64, Int64) -> Bool) async throws {}
    }

    private var папка: FileItem {
        FileItem(path: "/папка", name: "папка", fileExtension: "", size: 0,
                 isDirectory: true, isHidden: false, isSymlink: false,
                 permissions: "drwxr-xr-x", dateModified: Date())
    }

    private func снести(_ fs: CountingFileSystem) async {
        let session = RemoteSession(connection: RemoteConnection(proto: .rclone, host: "х"),
                                    fileSystem: fs)
        let готово = expectation(description: "удаление закончилось")
        RemoteTransferService().deleteRemoteItems([папка], from: session) { готово.fulfill() }
        await fulfillment(of: [готово], timeout: 10)
    }

    /// Облако сносит папку одним обращением — и ни один файл не перечисляется поимённо.
    func test_облакоСноситПапкуОднимОбращением() async {
        let fs = CountingFileSystem(treesAtOnce: true)
        await снести(fs)

        XCTAssertEqual(fs.deleteCalls.count, 1, "одно обращение, а не по одному на файл")
        XCTAssertEqual(fs.deleteCalls.first?.path, "/папка")
        XCTAssertEqual(fs.deleteCalls.first?.isDirectory, true)
        XCTAssertEqual(fs.listCalls, 0, "дерево даже не обходили")
    }

    /// А обычному серверу папку сперва освобождают: непустую он удалить не даст.
    func test_обычныйСерверОсвобождаетПапкуПередУдалением() async {
        let fs = CountingFileSystem(treesAtOnce: false)
        await снести(fs)

        let файлы = fs.deleteCalls.filter { !$0.isDirectory }.map(\.path)
        XCTAssertEqual(файлы.sorted(),
                       ["/папка/вложенная/пять.bin", "/папка/вложенная/четыре.bin",
                        "/папка/два.bin", "/папка/один.bin", "/папка/три.bin"].sorted(),
                       "вынесено всё содержимое, включая вложенную папку")
        // Сами папки удаляются последними — сначала внутренняя, потом внешняя.
        let папки = fs.deleteCalls.filter { $0.isDirectory }.map(\.path)
        XCTAssertEqual(папки, ["/папка/вложенная", "/папка"])
    }
}
