import Combine
import XCTest
@testable import TotumComXLApp

/// Файлы с пометкой «скрытый» на медленном томе (сеть, внешний диск) — её ставит Windows на
/// desktop.ini, папку Default, корзину диска.
///
/// Чтение одних имён пометки не видит, а в подробном виде второй этап только дочитывал сведения
/// о строках — и скрытое оставалось в списке. Другая дорога (запомненный список, затем
/// перечитка целиком) скрытое убирала. Одна и та же сетевая папка показывала то один перечень,
/// то другой: открыл — одна папка, переключил вкладку и вернулся — к ней прибавились скрытые.
@MainActor
final class SlowVolumeHiddenFlagTests: XCTestCase {

    private var folder = ""
    private var other = ""
    private var bus: VolumeInterfaceInfo.BusType = .network

    private static let hiddenNames: Set<String> = ["Служебная", "служебный.ini"]

    override func setUp() async throws {
        try await super.setUp()
        folder = NSTemporaryDirectory() + "скрытое-\(UUID().uuidString)"
        other = NSTemporaryDirectory() + "соседняя-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder + "/Общая", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: folder + "/Служебная", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: other, withIntermediateDirectories: true)
        fm.createFile(atPath: folder + "/заметка.txt", contents: Data("x".utf8))
        fm.createFile(atPath: folder + "/служебный.ini", contents: Data("xy".utf8))
        fm.createFile(atPath: other + "/файл.txt", contents: Data("x".utf8))
        for name in Self.hiddenNames {
            XCTAssertEqual(chflags(folder + "/" + name, UInt32(UF_HIDDEN)), 0, "пометка «скрытый» на \(name)")
        }
        let base = folder
        VolumeInterfaceDetector.override = { [unowned self] path in
            guard path.hasPrefix(base) || path.hasPrefix("/private" + base) else { return nil }
            return VolumeInterfaceInfo(busType: self.bus, isFast: false, displayName: "",
                                       modeDescription: "", filesystem: "", isReadOnlyNTFS: false)
        }
    }

    override func tearDown() async throws {
        VolumeInterfaceDetector.override = nil
        try? FileManager.default.removeItem(atPath: folder)
        try? FileManager.default.removeItem(atPath: other)
        try await super.tearDown()
    }

    private func panel(showHidden: Bool = false) -> PanelViewModel {
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: NSHomeDirectory(),
                                pathDefaultsKey: "panel.path.скрытое.\(id)",
                                viewModeDefaultsKey: "panel.mode.скрытое.\(id)",
                                showHiddenFiles: showHidden)
        addTeardownBlock { [weak vm] in MainActor.assumeIsolated { vm?.stopWatching() } }
        vm.viewMode = .detailed
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

    /// Открыть папку и дождаться, пока улягутся оба этапа чтения.
    private func open(_ vm: PanelViewModel, _ path: String, expecting name: String) async throws {
        vm.loadDirectory(at: path)
        try await wait(vm) { vm.currentPath == path && self.names(vm).contains(name) }
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    /// Все перечни, что панель показывала, пока шло действие: скрытое не должно мелькать.
    private func shownWhile(_ vm: PanelViewModel, _ action: () async throws -> Void) async rethrows -> [[String]] {
        var seen: [[String]] = []
        let watch = vm.data.dataDidChange.sink { [unowned vm] in seen.append(vm.items.map(\.name)) }
        defer { watch.cancel() }
        try await action()
        return seen
    }

    private func assertNoHidden(_ lists: [[String]], _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let leaked = lists.filter { !Self.hiddenNames.isDisjoint(with: $0) }
        XCTAssertTrue(leaked.isEmpty, "\(message): \(leaked.first ?? [])", file: file, line: line)
    }

    // MARK: - Сетевая папка

    func test_сеть_первыйПоказ_скрытогоНетНиНаМиг() async throws {
        let vm = panel()
        let seen = try await shownWhile(vm) { try await open(vm, folder, expecting: "заметка.txt") }
        XCTAssertEqual(Set(names(vm)).subtracting([".."]), ["Общая", "заметка.txt"])
        XCTAssertTrue(vm.currentPathIsSlowVolume, "папка считается медленным томом")
        XCTAssertTrue(seen.contains { $0.contains("заметка.txt") }, "показ папки замечен")
        assertNoHidden(seen, "скрытое мелькнуло при открытии")
    }

    /// То, что увидел человек: ушёл на другую вкладку, вернулся — перечень тот же.
    func test_сеть_уходИВозврат_переченьТотЖе() async throws {
        let vm = panel()
        try await open(vm, folder, expecting: "заметка.txt")
        let first = names(vm)
        try await open(vm, other, expecting: "файл.txt")
        let seen = try await shownWhile(vm) { try await open(vm, folder, expecting: "заметка.txt") }
        XCTAssertEqual(names(vm), first)
        assertNoHidden(seen, "скрытое появилось после возврата")
    }

    func test_сеть_перечитка_скрытогоНеВозвращает() async throws {
        let vm = panel()
        try await open(vm, folder, expecting: "заметка.txt")
        let seen = try await shownWhile(vm) {
            for _ in 0..<2 {
                vm.reloadKeepingCursor()
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        XCTAssertEqual(Set(names(vm)).subtracting([".."]), ["Общая", "заметка.txt"])
        assertNoHidden(seen, "скрытое появилось при перечитке")
    }

    // MARK: - Внешний диск

    /// На внешнем диске имена встают сразу, сведения дочитываются: строка, оказавшаяся
    /// скрытой, из списка уходит.
    func test_внешнийДиск_скрытоеВСпискеНеОстаётся() async throws {
        bus = .usb2
        let vm = panel()
        try await open(vm, folder, expecting: "заметка.txt")
        XCTAssertTrue(vm.currentPathIsSlowVolume)
        XCTAssertEqual(Set(names(vm)).subtracting([".."]), ["Общая", "заметка.txt"])
    }

    func test_внешнийДиск_курсорНаСвоёмФайлеПослеУходаСкрытых() async throws {
        bus = .usb2
        let vm = panel()
        vm.loadDirectory(at: folder, preferredCursorPath: folder + "/заметка.txt")
        try await wait(vm) { vm.currentPath == self.folder && self.names(vm).contains("заметка.txt") }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(vm.cursorItem?.name, "заметка.txt")
        XCTAssertFalse(names(vm).contains("служебный.ini"))
    }

    func test_внешнийДиск_перечитка_скрытогоНеВозвращает() async throws {
        bus = .usb2
        let vm = panel()
        try await open(vm, folder, expecting: "заметка.txt")
        let seen = try await shownWhile(vm) {
            for _ in 0..<2 {
                vm.reloadKeepingCursor()
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        assertNoHidden(seen, "скрытое появилось при перечитке")
    }

    // MARK: - «Показывать скрытые» включено

    /// Скрытое показано, и панель знает, что оно скрытое, — как на быстром диске.
    func test_показСкрытыхВключён_скрытоеПомеченоСкрытым() async throws {
        for kind in [VolumeInterfaceInfo.BusType.network, .usb2] {
            bus = kind
            let vm = panel(showHidden: true)
            try await open(vm, folder, expecting: "служебный.ini")
            for name in Self.hiddenNames {
                let item = try XCTUnwrap(vm.items.first { $0.name == name }, "\(kind): \(name) в списке")
                XCTAssertTrue(item.isHidden, "\(kind): \(name) помечен скрытым")
            }
            XCTAssertEqual(vm.items.first { $0.name == "заметка.txt" }?.isHidden, false)
        }
    }
}
