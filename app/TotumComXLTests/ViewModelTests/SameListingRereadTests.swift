import XCTest
@testable import TotumComXLApp

/// Перечитка папки, после которой на экране ничего не изменилось, панель не трогает.
///
/// Слежение за папкой видит изменения во всей её глубине и через 300 мс перечитывает её. В
/// домашней папке что-то пишется постоянно — кэши, журналы, скрытые файлы, — и каждая
/// перечитка заменяла список и сдвигала признак порядка: обе панели строили видимые строки
/// заново, 60–170 мс главного потока, и курсор, который ведут стрелкой, спотыкался.
@MainActor
final class SameListingRereadTests: XCTestCase {

    private var folder = ""

    override func setUp() async throws {
        try await super.setUp()
        folder = NSTemporaryDirectory() + "перечитка-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder + "/альфа/глубже", withIntermediateDirectories: true)
        for name in ["один.txt", "два.txt"] {
            FileManager.default.createFile(atPath: folder + "/" + name, contents: Data("x".utf8))
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: folder)
        try await super.tearDown()
    }

    private func panel() async throws -> PanelViewModel {
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: NSHomeDirectory(),
                                pathDefaultsKey: "panel.path.перечитка.\(id)",
                                viewModeDefaultsKey: "panel.mode.перечитка.\(id)",
                                showHiddenFiles: false)
        addTeardownBlock { [weak vm] in MainActor.assumeIsolated { vm?.stopWatching() } }
        vm.loadDirectory(at: folder)
        try await settle(vm) { vm.items.contains { $0.name == "два.txt" } }
        vm.setCursor(index: try XCTUnwrap(vm.items.firstIndex { $0.name == "два.txt" }))
        return vm
    }

    /// Ждать, пока условие станет верным, и ещё немного — чтобы второй проход чтения
    /// (подробности) тоже успел прийти.
    private func settle(_ vm: PanelViewModel, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !condition() {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertTrue(condition(), "папка не прочиталась")
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    private func assertUntouched(by change: () throws -> Void, _ title: String) async throws {
        let vm = try await panel()
        let token = vm.sortToken
        let items = vm.items
        let cursor = vm.cursorIndex
        try change()
        vm.reloadKeepingCursor()
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(vm.sortToken, token, "\(title): список не менялся — панель не перестраивается")
        XCTAssertEqual(vm.items, items, title)
        XCTAssertEqual(vm.cursorIndex, cursor, title)
    }

    func test_скрытыйФайл_панельНеПерестраивается() async throws {
        try await assertUntouched(by: {
            FileManager.default.createFile(atPath: folder + "/.скрытый", contents: Data())
        }, "скрытый файл")
    }

    func test_глубокоВнутриПодпапки_панельНеПерестраивается() async throws {
        try await assertUntouched(by: {
            FileManager.default.createFile(atPath: folder + "/альфа/глубже/файл", contents: Data())
        }, "глубоко в подпапке")
    }

    /// Видимое изменение по-прежнему доходит до экрана.
    func test_новыйФайл_появляется() async throws {
        let vm = try await panel()
        let token = vm.sortToken
        FileManager.default.createFile(atPath: folder + "/три.txt", contents: Data("x".utf8))
        vm.reloadKeepingCursor()
        try await settle(vm) { vm.items.contains { $0.name == "три.txt" } }
        XCTAssertNotEqual(vm.sortToken, token)
        XCTAssertEqual(vm.cursorItem?.name, "два.txt", "курсор остался на своём файле")
    }

    /// Изменился сам файл (размер) — строка должна показать новое.
    func test_изменённыйФайл_обновляется() async throws {
        let vm = try await panel()
        try Data(repeating: 7, count: 5000).write(to: URL(fileURLWithPath: folder + "/один.txt"))
        vm.reloadKeepingCursor()
        try await settle(vm) { vm.items.first { $0.name == "один.txt" }?.size == 5000 }
    }

    /// Какие события диска вообще ведут к перечитке.
    func test_событияГлубжеВнукаСписокНеМеняют() {
        let home = "/Users/кто"
        let can = { (path: String) in PanelViewModel.eventCanChangeListing(path, in: home) }
        XCTAssertTrue(can(home), "сама папка")
        XCTAssertTrue(can(home + "/новый.txt"), "ребёнок")
        XCTAssertTrue(can(home + "/Documents/файл"), "внук: у Documents сменились дата и число вложенного")
        XCTAssertFalse(can(home + "/Library/Biome/tmp/.tmp.x"), "глубже внука")
        XCTAssertFalse(can(home + "/Library/Caches/Google/Chrome/Default/Cache/x"))
        XCTAssertTrue(can("/private" + home + "/x/y/z"), "не под папкой — на всякий случай да")
        XCTAssertTrue(PanelViewModel.eventCanChangeListing("/Users/кто/a/b", in: "/Users/кто/"), "косая в конце")
    }
}
