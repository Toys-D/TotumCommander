import XCTest
@testable import TotumComXLApp

/// Что панель делает, когда связь с хранилищем оборвалась.
///
/// Настоящий случай: программа перезапустилась, помощник ушёл вместе с ней, а вкладка с
/// облаком осталась. Список не загрузился — и человек увидел пустую панель без единого
/// слова о том, куда делись его файлы.
@MainActor
final class RemoteReconnectTests: XCTestCase {

    /// Хранилище, которое сперва «не подключено», а после подключения показывает файлы.
    private final class FlakyFileSystem: RemoteFileSystemProtocol, @unchecked Sendable {
        var isConnected = false
        let protocolDisplayName = "ПРОБА"
        var connectCount = 0
        var listCount = 0
        /// Сколько раз подключение обязано провалиться, прежде чем начнёт удаваться.
        var refuseConnects = 0

        func connect() async throws {
            connectCount += 1
            if refuseConnects > 0 {
                refuseConnects -= 1
                throw RemoteFileSystemError.connectionFailed("сервер молчит")
            }
            isConnected = true
        }
        func disconnect() { isConnected = false }
        func listDirectory(at path: String) async throws -> [FileItem] {
            listCount += 1
            guard isConnected else { throw RemoteFileSystemError.notConnected }
            return [FileItem(path: "/письмо.txt", name: "письмо.txt", fileExtension: "txt",
                             size: 10, isDirectory: false, isHidden: false, isSymlink: false,
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
                              pathDefaultsKey: "panel.path.reconnect.\(id)",
                              viewModeDefaultsKey: "panel.mode.reconnect.\(id)",
                              showHiddenFiles: false)
    }

    // MARK: - Восстановление связи

    /// Оборванная связь чинится сама: панель подключается заново и показывает файлы.
    func test_оборваннаяСвязьВосстанавливаетсяСама() async {
        let fs = FlakyFileSystem()
        let session = RemoteSession(connection: RemoteConnection(proto: .rclone, host: "х"),
                                    fileSystem: fs)
        let vm = panel()
        // Вход в хранилище сам запускает чтение папки — дожидаемся его, чтобы считать
        // только то подключение, которое сделает проверяемый вызов.
        vm.enterRemote(session: session)
        try? await Task.sleep(nanoseconds: 200_000_000)
        fs.connectCount = 0

        await vm.loadRemoteDirectory(at: "/")

        XCTAssertEqual(fs.connectCount, 0, "связь уже есть — заново не подключаемся")
        XCTAssertEqual(vm.items.map(\.name), ["письмо.txt"], "файлы на месте")
        XCTAssertNil(vm.errorMessage, "жаловаться не на что")
    }

    /// Если связь не вернулась — человек обязан прочитать, почему панель пуста.
    /// Пустая папка и оборванная связь выглядели одинаково, и в этом была вся беда.
    func test_еслиСвязьНеВернуласьПричинаНаписана() async {
        let fs = FlakyFileSystem()
        fs.refuseConnects = 5
        let session = RemoteSession(connection: RemoteConnection(proto: .rclone, host: "х"),
                                    fileSystem: fs)
        let vm = panel()
        vm.enterRemote(session: session)

        await vm.loadRemoteDirectory(at: "/")

        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertNotNil(vm.errorMessage, "причина названа, а не спрятана в журнал")
    }

    /// Пробуем связаться заново один раз, а не по кругу: сервер, который лежит, от
    /// настойчивости не поднимется, а панель зависнет на попытках.
    func test_попыткаТолькоОдна() async {
        let fs = FlakyFileSystem()
        fs.refuseConnects = 99
        let session = RemoteSession(connection: RemoteConnection(proto: .rclone, host: "х"),
                                    fileSystem: fs)
        let vm = panel()
        vm.enterRemote(session: session)
        try? await Task.sleep(nanoseconds: 200_000_000)
        fs.connectCount = 0

        await vm.loadRemoteDirectory(at: "/")
        XCTAssertEqual(fs.connectCount, 1, "одна попытка на одно чтение папки, а не круг")
    }

    // MARK: - Когда пробовать не надо

    func test_обрывСвязиСтоитПовтора_аОтказДоступаНет() {
        XCTAssertTrue(PanelViewModel.worthReconnecting(RemoteFileSystemError.notConnected))
        XCTAssertTrue(PanelViewModel.worthReconnecting(
            RemoteFileSystemError.connectionFailed("порвалось")))
        XCTAssertTrue(PanelViewModel.worthReconnecting(RemoteFileSystemError.timeout))

        // Эти доказывают, что сервер жив и уже ответил, — повтор ничего не изменит.
        XCTAssertFalse(PanelViewModel.worthReconnecting(
            RemoteFileSystemError.pathNotFound("/нет")))
        XCTAssertFalse(PanelViewModel.worthReconnecting(
            RemoteFileSystemError.permissionDenied("нельзя")))
    }
}
