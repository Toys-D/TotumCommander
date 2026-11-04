import XCTest
@testable import TotumComXLApp

/// Гонка чтений удалённой папки.
///
/// Настоящий случай с Google Drive: человек входит в подпапку, а его выбрасывает на
/// уровень вверх; курсор прыгает из папки в папку. Каждый вызов заводил свою задачу
/// чтения, и побеждало то, что ЗАКОНЧИЛОСЬ последним, а не то, что просили последним.
/// Диск отвечает по полсекунды и дольше — окно для гонки широкое.
@MainActor
final class RemoteNavigationRaceTests: XCTestCase {

    /// Хранилище, где каждая папка отвечает со своей задержкой.
    private final class SlowFileSystem: RemoteFileSystemProtocol, @unchecked Sendable {
        var isConnected = true
        let protocolDisplayName = "МЕДЛЕННО"
        /// Задержка ответа по пути, в наносекундах.
        var delays: [String: UInt64] = [:]
        /// Как настоящий rclone до исправления: снятый запрос отвечает «Ошибка подключения:
        /// отменено», а не тихой отменой.
        var failsWhenCancelled = false
        /// Сколько раз просили список — чтобы поймать чтение до подключения.
        var listCalls = 0

        func connect() async throws { isConnected = true }
        func disconnect() {}
        func listDirectory(at path: String) async throws -> [FileItem] {
            listCalls += 1
            guard isConnected else { throw RemoteFileSystemError.notConnected }
            if let wait = delays[path] {
                do { try await Task.sleep(nanoseconds: wait) } catch {
                    if failsWhenCancelled { throw RemoteFileSystemError.connectionFailed("отменено") }
                }
            }
            let имя = (path as NSString).lastPathComponent
            return [FileItem(path: path + "/содержимое-\(имя).txt",
                             name: "содержимое-\(имя).txt", fileExtension: "txt", size: 1,
                             isDirectory: false, isHidden: false, isSymlink: false,
                             permissions: "-rw-r--r--", dateModified: Date())]
        }
        func createDirectory(at path: String, name: String) async throws {}
        func deleteItem(at path: String, isDirectory: Bool) async throws {}
        func rename(at path: String, to newName: String) async throws {}
        func moveItem(from sourcePath: String, to destinationPath: String) async throws {}
        func download(remotePath: String, to localPath: String,
                      progress: @escaping (Int64, Int64) -> Bool) async throws {}
        func upload(localPath: String, to remotePath: String,
                    progress: @escaping (Int64, Int64) -> Bool) async throws {}
    }

    private func panel() -> PanelViewModel {
        let id = UUID().uuidString
        return PanelViewModel(service: CoreBridgeService(),
                              initialPath: NSHomeDirectory(),
                              pathDefaultsKey: "panel.path.race.\(id)",
                              viewModeDefaultsKey: "panel.mode.race.\(id)",
                              showHiddenFiles: false)
    }

    /// Медленное чтение, догнавшее быстрое, не должно перебивать его результат.
    func test_последнееПрошенноеПобеждает_дажеЕслиОтветилоПервым() async throws {
        let fs = SlowFileSystem()
        fs.delays["/медленная"] = 700_000_000     // 0,7 с — как задумчивый Диск
        fs.delays["/быстрая"] = 0

        let vm = panel()
        let session = RemoteSession(connection: RemoteConnection(proto: .rclone, host: "х"),
                                    fileSystem: fs)
        vm.enterRemote(session: session)
        _ = await vm.remoteLoadTask?.value

        // Человек вошёл в медленную папку и, не дождавшись, — в быструю.
        vm.startRemoteLoad(at: "/медленная")
        try await Task.sleep(nanoseconds: 50_000_000)
        vm.startRemoteLoad(at: "/быстрая")
        _ = await vm.remoteLoadTask?.value

        // Медленное чтение ещё в полёте — дождёмся, чтобы оно успело «победить», если может.
        try await Task.sleep(nanoseconds: 900_000_000)

        XCTAssertEqual(vm.currentPath, "/быстрая",
                       "панель там, куда просили последним, а не где ответ пришёл последним")
        XCTAssertTrue(vm.items.contains { $0.name == "содержимое-быстрая.txt" },
                      "и показывает содержимое именно этой папки: \(vm.items.map(\.name))")
    }

    /// Перебитое чтение — не ошибка. Google Drive: «Ошибка подключения: отменено» показывалось,
    /// хотя следом приходили файлы, а сессия объявлялась мёртвой.
    func test_перебитоеЧтениеНеОшибкаИНеУбиваетСессию() async throws {
        let fs = SlowFileSystem()
        fs.failsWhenCancelled = true
        fs.delays["/медленная"] = 700_000_000
        fs.delays["/быстрая"] = 0

        let vm = panel()
        let session = RemoteSession(connection: RemoteConnection(proto: .rclone, host: "х"),
                                    fileSystem: fs)
        vm.enterRemote(session: session)
        _ = await vm.remoteLoadTask?.value
        let wasReady = session.isReady

        vm.startRemoteLoad(at: "/медленная")
        try await Task.sleep(nanoseconds: 50_000_000)
        vm.startRemoteLoad(at: "/быстрая")
        _ = await vm.remoteLoadTask?.value
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(vm.errorMessage, "отмена своего же чтения — не ошибка")
        XCTAssertEqual(session.isReady, wasReady, "сессия не помечена мёртвой")
        XCTAssertEqual(vm.currentPath, "/быстрая")
    }

    /// Пока хранилище подключается, панель не просит список и не показывает «Нет подключения
    /// к серверу»: с Google Drive под ограничением квоты подключение идёт полминуты, и всё это
    /// время висела ошибка, а рядом с первым подключением затевалось второе.
    func test_доПодключенияСписокНеПросятИОшибкиНет() async throws {
        let fs = SlowFileSystem()
        fs.isConnected = false
        let vm = panel()
        let session = RemoteSession(connection: RemoteConnection(proto: .rclone, host: "х"),
                                    fileSystem: fs)
        vm.enterRemote(session: session)
        _ = await vm.remoteLoadTask?.value
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(fs.listCalls, 0, "до подключения список не просили")
        XCTAssertNil(vm.errorMessage, "и ошибки нет")
        XCTAssertNotNil(vm.connectingMessage, "зато сказано, что идёт подключение")
        XCTAssertTrue(vm.insideRemote)

        try await session.connect()
        vm.startRemoteLoad(at: session.currentRemotePath)
        _ = await vm.remoteLoadTask?.value
        XCTAssertEqual(fs.listCalls, 1)
        XCTAssertNil(vm.connectingMessage, "первый список снимает надпись")
        XCTAssertTrue(vm.items.contains { $0.name.hasPrefix("содержимое-") }, "после подключения список пришёл")
    }

    /// Уже виденная папка показывается из памяти сразу, до ответа хранилища, а свежий список
    /// приходит следом: с Google Drive под квотой «наверх» ждало по нескольку секунд.
    func test_запомненныйСписокПоказываетсяСразу() async throws {
        let fs = SlowFileSystem()
        fs.delays["/"] = 300_000_000
        let vm = panel()
        let session = RemoteSession(connection: RemoteConnection(proto: .rclone, host: "х"),
                                    fileSystem: fs)
        vm.enterRemote(session: session)
        _ = await vm.remoteLoadTask?.value                 // корень прочитан и запомнен
        vm.startRemoteLoad(at: "/папка")
        _ = await vm.remoteLoadTask?.value
        XCTAssertEqual(fs.listCalls, 2)
        XCTAssertEqual(vm.currentPath, "/папка")

        vm.goUpRemote()                                    // без ожидания ответа
        XCTAssertEqual(vm.currentPath, "/", "корень показан из памяти сразу")
        XCTAssertTrue(vm.items.contains { $0.name.hasPrefix("содержимое-") && !$0.name.contains("папка") },
                      "и это содержимое корня: \(vm.items.map(\.name))")
        XCTAssertEqual(fs.listCalls, 2, "свежий список ещё в пути")

        _ = await vm.remoteLoadTask?.value
        XCTAssertEqual(fs.listCalls, 3, "свежий список всё же запрошен")
        XCTAssertEqual(vm.currentPath, "/")
    }

    /// Обновление после операции память не использует: удалённое не должно мелькать.
    func test_обновлениеБерётТолькоСвежийСписок() async throws {
        let fs = SlowFileSystem()
        let vm = panel()
        let session = RemoteSession(connection: RemoteConnection(proto: .rclone, host: "х"),
                                    fileSystem: fs)
        vm.enterRemote(session: session)
        _ = await vm.remoteLoadTask?.value
        vm.startRemoteLoad(at: "/")                        // как после удаления
        XCTAssertEqual(fs.listCalls, 1, "из памяти ничего не показано — ждём хранилище")
        _ = await vm.remoteLoadTask?.value
        XCTAssertEqual(fs.listCalls, 2)
    }

    /// Дорога к местной папке из хранилища (избранное; диск без вкладок) выходит из него и
    /// ведёт туда, а не перечитывает корень хранилища: `loadDirectory` внутри хранилища
    /// принимал местный путь за удалённый.
    func test_переходКМестнойПапкеВыводитИзХранилища() async throws {
        let fs = SlowFileSystem()
        let vm = panel()
        let session = RemoteSession(connection: RemoteConnection(proto: .rclone, host: "х"),
                                    fileSystem: fs)
        vm.enterRemote(session: session)
        _ = await vm.remoteLoadTask?.value
        XCTAssertTrue(vm.insideRemote)

        let disk = NSTemporaryDirectory()
        vm.navigateToLocal(disk)
        let срок = Date().addingTimeInterval(3)
        while Date() < срок, (vm.currentPath as NSString).standardizingPath
                != (disk as NSString).standardizingPath {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(vm.insideRemote, "из хранилища вышли")
        XCTAssertEqual((vm.currentPath as NSString).standardizingPath,
                       (disk as NSString).standardizingPath, "и стоим на диске")
    }

    /// Обновление, начатое до входа в папку, не выбрасывает человека назад.
    func test_запоздалоеОбновлениеНеВыбрасываетНазад() async throws {
        let fs = SlowFileSystem()
        fs.delays["/"] = 700_000_000
        fs.delays["/папка"] = 0

        let vm = panel()
        let session = RemoteSession(connection: RemoteConnection(proto: .rclone, host: "х"),
                                    fileSystem: fs)
        vm.enterRemote(session: session)      // читает медленный корень
        try await Task.sleep(nanoseconds: 50_000_000)

        // Не дождавшись корня, человек уже жмёт Enter на папке.
        vm.startRemoteLoad(at: "/папка")
        _ = await vm.remoteLoadTask?.value
        try await Task.sleep(nanoseconds: 900_000_000)

        XCTAssertEqual(vm.currentPath, "/папка", "корень, ответивший позже, не перебил вход")
    }

    /// Местное чтение, докатившееся ПОСЛЕ входа в облако, не затирает панель.
    ///
    /// Настоящий случай с Google Drive: панель стояла на местной папке, человек
    /// подключился к Диску — и увидел пустоту без единого слова. Местное чтение,
    /// начатое до входа, доехало во время подключения, вернуло панели путь
    /// «/Users/…» — и облако читалось по этому местному пути: «нет такой папки».
    func test_местноеЧтениеНеЗатираетОблачнуюПанель() async throws {
        let fs = SlowFileSystem()
        fs.delays["/"] = 0

        let vm = panel()
        // Местное чтение домашней папки ещё идёт...
        vm.loadDirectory(at: NSHomeDirectory())

        // ...а человек уже вошёл в облако.
        let session = RemoteSession(connection: RemoteConnection(proto: .rclone, host: "х"),
                                    fileSystem: fs)
        vm.enterRemote(session: session)
        _ = await vm.remoteLoadTask?.value

        // Даём местному чтению доехать и попытаться применить свой результат.
        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertTrue(vm.insideRemote)
        XCTAssertEqual(vm.currentPath, "/", "путь остался облачным, не «/Users/…»")
        XCTAssertTrue(vm.items.contains { $0.name.hasPrefix("содержимое-") },
                      "в панели содержимое облака, а не домашней папки: \(vm.items.map(\.name))")
    }
}
