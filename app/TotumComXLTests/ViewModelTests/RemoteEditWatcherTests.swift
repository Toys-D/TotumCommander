import XCTest
@testable import TotumComXLApp

/// Присмотр за копиями облачных файлов, открытыми во внешних программах.
///
/// Смысл: человек открыл .docx из Google Drive, поправил в Word, нажал Сохранить — Word
/// сохранил временную копию, а облако о правках не знает. Присмотр это замечает и
/// предлагает отправить обратно; без него правки молча пропадали при отключении.
@MainActor
final class RemoteEditWatcherTests: XCTestCase {

    /// Хранилище, запоминающее отправки.
    private final class RecordingFileSystem: RemoteFileSystemProtocol, @unchecked Sendable {
        var isConnected = true
        let protocolDisplayName = "ЗАПИСЬ"
        private(set) var uploads: [(local: String, remote: String)] = []
        var refuseUploads = false

        func connect() async throws {}
        func disconnect() {}
        func listDirectory(at path: String) async throws -> [FileItem] { [] }
        func createDirectory(at path: String, name: String) async throws {}
        func deleteItem(at path: String, isDirectory: Bool) async throws {}
        func rename(at path: String, to newName: String) async throws {}
        func moveItem(from sourcePath: String, to destinationPath: String) async throws {}
        func download(remotePath: String, to localPath: String,
                      progress: @escaping (Int64, Int64) -> Bool) async throws {}
        func upload(localPath: String, to remotePath: String,
                    progress: @escaping (Int64, Int64) -> Bool) async throws {
            if refuseUploads { throw RemoteFileSystemError.transferFailed("нет связи") }
            uploads.append((localPath, remotePath))
            _ = progress(1, 1)
        }
    }

    private var watcher: RemoteEditWatcher!
    private var fs: RecordingFileSystem!
    private var session: RemoteSession!
    private var copyPath = ""
    private var asked = 0
    private var answer = true

    override func setUp() {
        super.setUp()
        fs = RecordingFileSystem()
        session = RemoteSession(connection: RemoteConnection(label: "Google Drive",
                                                             proto: .rclone,
                                                             rcloneRemote: "гугл"),
                                fileSystem: fs)
        watcher = RemoteEditWatcher()
        watcher.makeProgress = { _, _ in nil }
        watcher.complain = { _, _ in }
        watcher.askToSend = { [weak self] _, _ in
            self?.asked += 1
            return self?.answer ?? false
        }
        copyPath = NSTemporaryDirectory() + "копия-\(UUID().uuidString).docx"
        try? Data("исходное".utf8).write(to: URL(fileURLWithPath: copyPath))
    }

    /// «Сохранить» в чужой программе — это новое время правки файла.
    private func пересохранить(_ text: String, secondsLater: TimeInterval) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: copyPath))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(secondsLater)],
            ofItemAtPath: copyPath)
    }

    private func item() -> FileItem {
        FileItem(path: "/папка/отчёт.docx", name: "отчёт.docx", fileExtension: "docx",
                 size: 8, isDirectory: false, isHidden: false, isSymlink: false,
                 permissions: "-rw-r--r--", dateModified: Date())
    }

    // MARK: - Основной путь

    func test_сохранённыеПравкиПредлагаетсяОтправить_иОниУезжают() async throws {
        watcher.watch(localPath: copyPath, item: item(), session: session)
        await watcher.checkNow()
        XCTAssertEqual(asked, 0, "нетронутый файл вопросов не вызывает")

        try пересохранить("правленое", secondsLater: 5)
        await watcher.checkNow()      // первое известие — ждём, пока сохранение утихнет
        XCTAssertEqual(asked, 0, "спрашивать на середине сохранения нельзя")

        await watcher.checkNow()      // время устоялось — вопрос
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(fs.uploads.count, 1, "правки уехали")
        XCTAssertEqual(fs.uploads.first?.remote, "/папка/отчёт.docx",
                       "ровно туда, откуда файл открыт")

        await watcher.checkNow()
        XCTAssertEqual(asked, 1, "после отправки вопрос не повторяется")
        XCTAssertTrue(watcher.dirtyNames(for: session.connection.id).isEmpty)
    }

    func test_отказОставляетПравкиПриСебе() async throws {
        answer = false
        watcher.watch(localPath: copyPath, item: item(), session: session)
        try пересохранить("правленое", secondsLater: 5)
        await watcher.checkNow()
        await watcher.checkNow()
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(fs.uploads.isEmpty, "человек сказал «нет» — ничего не уехало")

        // И вопрос снят насовсем: об этом сказано прямо в диалоге.
        try пересохранить("ещё правка", secondsLater: 10)
        await watcher.checkNow()
        await watcher.checkNow()
        XCTAssertEqual(asked, 1, "переспрашивать после отказа — значит донимать")
    }

    /// Второе сохранение после отправки — новый вопрос: правки-то новые.
    func test_новоеСохранениеСпрашиваетЗаново() async throws {
        watcher.watch(localPath: copyPath, item: item(), session: session)
        try пересохранить("правка раз", secondsLater: 5)
        await watcher.checkNow(); await watcher.checkNow()
        XCTAssertEqual(fs.uploads.count, 1)

        try пересохранить("правка два", secondsLater: 15)
        await watcher.checkNow(); await watcher.checkNow()
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(fs.uploads.count, 2)
    }

    // MARK: - Неудачи и отключение

    func test_неудавшаясяОтправкаНеДолбитВопросом_ноОстаётсяДолгом() async throws {
        fs.refuseUploads = true
        watcher.watch(localPath: copyPath, item: item(), session: session)
        try пересохранить("правленое", secondsLater: 5)
        await watcher.checkNow(); await watcher.checkNow()
        XCTAssertEqual(asked, 1)

        await watcher.checkNow()
        XCTAssertEqual(asked, 1, "то же сохранение не переспрашивается")
        XCTAssertEqual(watcher.dirtyNames(for: session.connection.id), ["отчёт.docx"],
                       "долг числится — при отключении о нём спросят")
    }

    func test_отправкаПередОтключениемУвозитВсёНесданное() async throws {
        watcher.watch(localPath: copyPath, item: item(), session: session)
        try пересохранить("правленое", secondsLater: 5)
        XCTAssertEqual(watcher.dirtyNames(for: session.connection.id), ["отчёт.docx"])

        await watcher.uploadDirty(for: session)
        XCTAssertEqual(fs.uploads.count, 1)
        XCTAssertTrue(watcher.dirtyNames(for: session.connection.id).isEmpty)
    }

    func test_забытоеПодключениеНичегоНеСпрашивает() async throws {
        watcher.watch(localPath: copyPath, item: item(), session: session)
        try пересохранить("правленое", secondsLater: 5)
        watcher.forget(connectionID: session.connection.id)
        await watcher.checkNow(); await watcher.checkNow()
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(watcher.dirtyNames(for: session.connection.id).isEmpty)
    }

    func test_исчезнувшаяКопияСнимаетПрисмотр() async throws {
        watcher.watch(localPath: copyPath, item: item(), session: session)
        try FileManager.default.removeItem(atPath: copyPath)
        await watcher.checkNow()
        XCTAssertTrue(watcher.dirtyNames(for: session.connection.id).isEmpty)
        XCTAssertEqual(asked, 0)
    }

    func test_папкаДляОбновленияПанели() {
        XCTAssertEqual(RemoteEditWatcher.parentFolder(of: "/папка/файл.txt"), "/папка")
        XCTAssertEqual(RemoteEditWatcher.parentFolder(of: "/файл.txt"), "/")
    }
}
