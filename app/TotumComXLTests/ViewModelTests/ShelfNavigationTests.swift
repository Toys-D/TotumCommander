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

/// Полка целиком, на живой панели: положить папку, войти в неё с полки, выйти «..» —
/// и оказаться снова на полке.
///
/// Первая правка проверяла это только правилом, а вход в папку шёл в обход того места,
/// где правило применялось. Поэтому теперь — весь путь, как его проходит человек.
@MainActor
final class ShelfReturnNavigationTests: XCTestCase {

    private var root = ""
    private var folder = ""
    private var nested = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "fcxl-полка-" + UUID().uuidString
        folder = root + "/Проект"
        nested = folder + "/Черновики"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try "x".write(toFile: folder + "/заметка.txt", atomically: true, encoding: .utf8)
        // На полку — только своя папка; чужое на ней не трогаем и после себя убираем.
        DropStackStore.add([folder])
    }

    override func tearDown() {
        DropStackStore.remove([folder])
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    private func panel() -> PanelViewModel {
        let id = UUID().uuidString
        return PanelViewModel(service: CoreBridgeService(),
                              initialPath: root,
                              pathDefaultsKey: "panel.path.полка.\(id)",
                              viewModeDefaultsKey: "panel.mode.полка.\(id)",
                              showHiddenFiles: false)
    }

    private func подождать(_ условие: @escaping () -> Bool) async throws {
        let срок = Date().addingTimeInterval(3)
        while Date() < срок, !условие() {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Та самая жалоба.
    func test_изПапкиПолки_НаверхВозвращаетНаПолку() async throws {
        let vm = panel()
        vm.loadDirectory(at: root)
        try await подождать { vm.currentPath == self.root }

        vm.loadStackDirectory()
        try await подождать { vm.state.insideStack && vm.items.contains { $0.path == self.folder } }
        let shelved = try XCTUnwrap(vm.items.first { $0.path == folder })

        XCTAssertTrue(vm.open(shelved), "вошли в папку с полки")
        try await подождать { vm.currentPath == self.folder && !vm.state.insideStack }
        XCTAssertEqual(vm.currentPath, folder)

        vm.goUp()
        try await подождать { vm.state.insideStack }
        XCTAssertTrue(vm.state.insideStack, "«..» из папки полки ведёт на полку, а не к родителю")
        XCTAssertEqual(vm.currentPath, DropStackStore.stackRoot)
        XCTAssertEqual(vm.cursorItem?.path, folder, "курсор — на той папке, из которой вышли")
    }

    /// Из вложенной — на уровень выше как обычно, и только потом на полку. А с полки —
    /// туда, откуда её открыли.
    func test_изВложенной_ШагЗаШагом_АПотомНаПолкуИДомой() async throws {
        let vm = panel()
        vm.loadDirectory(at: root)
        try await подождать { vm.currentPath == self.root }
        vm.loadStackDirectory()
        try await подождать { vm.state.insideStack && vm.items.contains { $0.path == self.folder } }
        XCTAssertTrue(vm.open(try XCTUnwrap(vm.items.first { $0.path == folder })))
        try await подождать { vm.currentPath == self.folder && vm.items.contains { $0.path == self.nested } }

        XCTAssertTrue(vm.open(try XCTUnwrap(vm.items.first { $0.path == nested })))
        try await подождать { vm.currentPath == self.nested }

        vm.goUp()
        try await подождать { vm.currentPath == self.folder }
        XCTAssertFalse(vm.state.insideStack, "из вложенной — на уровень выше, не на полку")

        vm.goUp()
        try await подождать { vm.state.insideStack }
        XCTAssertEqual(vm.currentPath, DropStackStore.stackRoot)

        vm.goUp()
        try await подождать { vm.currentPath == self.root }
        XCTAssertEqual(vm.currentPath, root, "с полки — туда, откуда её открыли")
        XCTAssertFalse(vm.state.insideStack)
    }

    /// Ушли из папки полки по адресу — полка забыта, «..» снова обычное.
    func test_уходПоАдресу_ПолкаЗабывается() async throws {
        let vm = panel()
        vm.loadDirectory(at: root)
        try await подождать { vm.currentPath == self.root }
        vm.loadStackDirectory()
        try await подождать { vm.state.insideStack && vm.items.contains { $0.path == self.folder } }
        XCTAssertTrue(vm.open(try XCTUnwrap(vm.items.first { $0.path == folder })))
        try await подождать { vm.currentPath == self.folder }

        vm.loadDirectory(at: NSHomeDirectory())
        try await подождать { vm.currentPath == NSHomeDirectory() }
        vm.loadDirectory(at: folder)
        try await подождать { vm.currentPath == self.folder }

        vm.goUp()
        try await подождать { vm.currentPath == self.root }
        XCTAssertEqual(vm.currentPath, root, "пришли не с полки — и уходим не на полку")
    }
}
