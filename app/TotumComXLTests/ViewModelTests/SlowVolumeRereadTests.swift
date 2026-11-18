import XCTest
@testable import TotumComXLApp

/// Перечитка папки на медленном томе (сеть, внешний диск) видит новое и не держит удалённое.
///
/// В подробном виде второй этап чтения на таком томе не перечитывает список — он только
/// дочитывает сведения о строках, которые уже на экране. Перечитка той же папки первый этап
/// (имена) пропускала, и перечень оставался прежним: скопированное в сетевую папку Windows не
/// появлялось, пока человек не переключал вкладку.
@MainActor
final class SlowVolumeRereadTests: XCTestCase {

    private var folder = ""

    override func setUp() async throws {
        try await super.setUp()
        folder = NSTemporaryDirectory() + "медленный-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder + "/альфа", withIntermediateDirectories: true)
        for name in ["один.txt", "два.txt"] {
            FileManager.default.createFile(atPath: folder + "/" + name, contents: Data("x".utf8))
        }
        let base = folder
        // Внешний диск по USB 2: медленный и без слежки — перечитка только по команде.
        VolumeInterfaceDetector.override = { path in
            guard path.hasPrefix(base) || path.hasPrefix("/private" + base) else { return nil }
            return VolumeInterfaceInfo(busType: .usb2, isFast: false, displayName: "USB 2.0",
                                       modeDescription: "", filesystem: "exFAT", isReadOnlyNTFS: false)
        }
    }

    override func tearDown() async throws {
        VolumeInterfaceDetector.override = nil
        try? FileManager.default.removeItem(atPath: folder)
        try await super.tearDown()
    }

    private func panel(_ mode: ViewMode) async throws -> PanelViewModel {
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: NSHomeDirectory(),
                                pathDefaultsKey: "panel.path.медленный.\(id)",
                                viewModeDefaultsKey: "panel.mode.медленный.\(id)",
                                showHiddenFiles: false)
        addTeardownBlock { [weak vm] in MainActor.assumeIsolated { vm?.stopWatching() } }
        vm.viewMode = mode
        vm.loadDirectory(at: folder)
        try await wait(vm) { self.names(vm).contains("два.txt") }
        XCTAssertTrue(vm.currentPathIsSlowVolume, "папка считается медленным томом")
        try await Task.sleep(nanoseconds: 500_000_000)
        return vm
    }

    private func names(_ vm: PanelViewModel) -> [String] { vm.items.map(\.name) }

    private func wait(_ vm: PanelViewModel, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !condition() {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertTrue(condition(), "не дождались: на экране \(names(vm))")
    }

    private func changeFolder() throws {
        FileManager.default.createFile(atPath: folder + "/три.txt", contents: Data("xyz".utf8))
        try FileManager.default.removeItem(atPath: folder + "/один.txt")
    }

    func test_подробныйВид_перечиткаПоказываетНовоеИУбираетУдалённое() async throws {
        let vm = try await panel(.detailed)
        try changeFolder()
        vm.reloadKeepingCursor()
        try await wait(vm) { self.names(vm).contains("три.txt") }
        XCTAssertFalse(names(vm).contains("один.txt"), "удалённого в списке нет")
        try await wait(vm) { vm.items.first { $0.name == "три.txt" }?.size == 3 }
    }

    func test_краткийВид_перечиткаПоказываетНовоеИУбираетУдалённое() async throws {
        let vm = try await panel(.brief)
        try changeFolder()
        vm.reloadKeepingCursor()
        try await wait(vm) { self.names(vm).contains("три.txt") }
        XCTAssertFalse(names(vm).contains("один.txt"))
    }

    /// Ничего не поменялось — перечитка список не перекладывает: курсор и порядок на месте.
    func test_подробныйВид_безПеремен_списокНеПерекладывается() async throws {
        let vm = try await panel(.detailed)
        vm.setCursor(index: try XCTUnwrap(vm.items.firstIndex { $0.name == "два.txt" }))
        // Первая перечитка может уточнить сведения (число вложенного у папок) — это один раз.
        vm.reloadKeepingCursor()
        try await Task.sleep(nanoseconds: 700_000_000)
        let token = vm.sortToken
        let shown = vm.items
        for _ in 0..<3 {
            vm.reloadKeepingCursor()
            try await Task.sleep(nanoseconds: 600_000_000)
        }
        XCTAssertEqual(vm.items, shown)
        XCTAssertEqual(vm.sortToken, token, "тот же перечень — панель не перестраивается")
        XCTAssertEqual(vm.cursorItem?.name, "два.txt")
    }
}
