import XCTest
@testable import TotumComXLApp

/// Вход в папку с полки — и жизнь внутри неё.
///
/// Настоящий случай: человек положил папку на полку, вошёл в неё, скопировал файл или
/// переключил рабочие столы — и оказался выброшен из папки обратно на полку. Вход в папку
/// не снимал с панели признак «я на полке», а каждое перечитывание, увидев признак,
/// честно перерисовывало полку.
@MainActor
final class ShelfNavigationTests: XCTestCase {

    private var folder = ""
    private var savedShelf: [String] = []

    override func setUpWithError() throws {
        savedShelf = DropStackStore.paths
        folder = NSTemporaryDirectory() + "полка-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder + "/внутри",
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder + "/файл.txt",
                                       contents: Data("текст".utf8))
        DropStackStore.paths = [folder]
    }

    override func tearDown() {
        DropStackStore.paths = savedShelf
        try? FileManager.default.removeItem(atPath: folder)
        super.tearDown()
    }

    private func panel() -> PanelViewModel {
        let id = UUID().uuidString
        return PanelViewModel(service: CoreBridgeService(),
                              initialPath: NSHomeDirectory(),
                              pathDefaultsKey: "panel.path.полка.\(id)",
                              viewModeDefaultsKey: "panel.mode.полка.\(id)",
                              showHiddenFiles: false)
    }

    /// Чтение папки применяется асинхронно — дожидаемся, а не проверяем мгновенно.
    private func подождать(_ vm: PanelViewModel, пока условие: @escaping () -> Bool)
    async throws {
        let срок = Date().addingTimeInterval(3)
        while Date() < срок, !условие() {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func test_перечитываниеНеВыбрасываетИзПапкиОбратноНаПолку() async throws {
        let vm = panel()
        vm.loadStackDirectory()
        XCTAssertTrue(vm.state.insideStack, "панель на полке")

        // Человек вошёл в папку, лежащую на полке.
        let item = try XCTUnwrap(vm.items.first { $0.path == folder })
        XCTAssertTrue(vm.open(item), "папка открылась")
        try await подождать(vm) { vm.currentPath == self.folder }
        XCTAssertEqual(vm.currentPath, folder)
        XCTAssertFalse(vm.state.insideStack, "признак полки снят: панель в настоящей папке")

        // Перечитывание — как после копирования или возврата с другого рабочего стола.
        vm.reloadKeepingCursor()
        try await подождать(vm) { vm.items.contains { $0.name == "файл.txt" } }
        XCTAssertEqual(vm.currentPath, folder,
                       "панель осталась в папке, а не выброшена на полку")
        XCTAssertTrue(vm.items.contains { $0.name == "файл.txt" },
                      "и показывает содержимое папки: \(vm.items.map(\.name))")
    }

    /// «..» с самой полки по-прежнему ведёт туда, откуда на неё пришли, — снятие признака
    /// не должно сломать возврат.
    func test_сПолкиНаверхВозвращаетОткудаПришли() async throws {
        let vm = panel()
        let came = NSTemporaryDirectory()
        vm.loadDirectory(at: came)
        try await подождать(vm) {
            (vm.currentPath as NSString).standardizingPath
                == (came as NSString).standardizingPath
        }
        vm.loadStackDirectory()
        XCTAssertTrue(vm.state.insideStack)

        vm.goUp()
        try await подождать(vm) { !DropStackStore.isStackPath(vm.currentPath) }
        XCTAssertFalse(vm.state.insideStack)
        XCTAssertEqual((vm.currentPath as NSString).standardizingPath,
                       (came as NSString).standardizingPath,
                       "вернулись туда, откуда открывали полку")
    }

    /// Перечитывание, пока человек стоит НА полке, полку и показывает — снятие признака
    /// касается только входа в настоящую папку.
    func test_наСамойПолкеПеречитываниеОставляетПолку() {
        let vm = panel()
        vm.loadStackDirectory()
        vm.reloadKeepingCursor()
        XCTAssertTrue(vm.state.insideStack, "полка осталась полкой")
        XCTAssertEqual(vm.currentPath, DropStackStore.stackRoot)
    }
}
