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

        func connect() async throws {}
        func disconnect() {}
        func listDirectory(at path: String) async throws -> [FileItem] {
            if let wait = delays[path] { try? await Task.sleep(nanoseconds: wait) }
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
