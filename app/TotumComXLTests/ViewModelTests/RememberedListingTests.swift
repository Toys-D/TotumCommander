import Combine
import XCTest
@testable import TotumComXLApp

/// Запомненный список папки показывается сразу только тогда, когда ему можно верить.
///
/// Панель помнит списки последних папок: «..» и возврат назад рисуют папку сразу, а чтение с
/// диска идёт следом. После долгого простоя это давало на миг старый перечень: в фоне слежка за
/// папкой спит, а запомненное считалось годным, пока не менялась дата самой папки — причём
/// дата бралась в момент ухода из папки, а не чтения списка.
@MainActor
final class RememberedListingTests: XCTestCase {

    private var folder = ""

    override func setUp() async throws {
        try await super.setUp()
        folder = NSTemporaryDirectory() + "память-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder + "/альфа", withIntermediateDirectories: true)
        for name in ["один.txt", "два.txt"] {
            FileManager.default.createFile(atPath: folder + "/" + name, contents: Data("x".utf8))
        }
        FileManager.default.createFile(atPath: folder + "/альфа/внутри.txt", contents: Data("x".utf8))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: folder)
        try await super.tearDown()
    }

    private func panel() async throws -> PanelViewModel {
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: NSHomeDirectory(),
                                pathDefaultsKey: "panel.path.память.\(id)",
                                viewModeDefaultsKey: "panel.mode.память.\(id)",
                                showHiddenFiles: false)
        addTeardownBlock { [weak vm] in MainActor.assumeIsolated { vm?.stopWatching() } }
        vm.loadDirectory(at: folder)
        try await settle(vm) { vm.items.contains { $0.name == "два.txt" } }
        return vm
    }

    /// Ждать, пока условие станет верным, и ещё немного — чтобы второй проход чтения тоже пришёл.
    private func settle(_ vm: PanelViewModel, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !condition() {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertTrue(condition(), "папка не прочиталась")
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    private func enterChild(_ vm: PanelViewModel) async throws {
        vm.loadDirectory(at: folder + "/альфа")
        try await settle(vm) { vm.items.contains { $0.name == "внутри.txt" } }
    }

    private func names(_ vm: PanelViewModel) -> [String] { vm.items.map(\.name) }

    /// Вошёл в подпапку и сразу вышел — папка рисуется из памяти, не дожидаясь диска.
    func test_быстрыйВозврат_списокСразуИзПамяти() async throws {
        let vm = try await panel()
        try await enterChild(vm)
        vm.goUp()
        XCTAssertEqual(vm.currentPath, folder, "запомненный список встаёт сразу")
        XCTAssertTrue(names(vm).contains("два.txt"))
    }

    /// Слежка спала (программа была в фоне), в папке стёрли файл и положили новый, а человек
    /// ушёл в подпапку раньше, чем панель перечитала список. Старый перечень, оставшийся на
    /// экране, не должен запомниться как годный: при выходе наверх стёртый файл на миг не
    /// возвращается.
    func test_уходСУстаревшимСписком_старыйПереченьНеВозвращается() async throws {
        let vm = try await panel()
        vm.stopWatching()
        try FileManager.default.removeItem(atPath: folder + "/один.txt")
        FileManager.default.createFile(atPath: folder + "/три.txt", contents: Data("x".utf8))
        try await enterChild(vm)

        vm.goUp()
        XCTAssertFalse(names(vm).contains("один.txt"), "стёртый файл не показывается и на миг")
        try await settle(vm) { names(vm).contains("три.txt") }
        XCTAssertFalse(names(vm).contains("один.txt"))
        XCTAssertEqual(vm.currentPath, folder)
    }

    /// Дата самой папки не меняется, когда растёт файл внутри неё. Давно запомненный список
    /// показал бы на миг прежний размер — папка читается заново, как при первом входе.
    func test_запомненноеСтаршеМинуты_сразуНеПоказывается() async throws {
        let vm = try await panel()
        try await enterChild(vm)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: folder + "/один.txt"))
        handle.seekToEndOfFile()
        handle.write(Data(repeating: 0x78, count: 4096))
        handle.closeFile()
        vm.listingClock = { Date().addingTimeInterval(PanelViewModel.listingMemory + 1) }

        vm.goUp()
        XCTAssertNotEqual(vm.items.first { $0.name == "один.txt" }?.size, 1, "прежний размер не показывается и на миг")
        try await settle(vm) { vm.items.first { $0.name == "один.txt" }?.size == 4097 }
        XCTAssertEqual(vm.currentPath, folder)
    }

    /// Программа побывала в фоне — слежка спала, запомненному на быстром диске веры нет.
    func test_послеФона_запомненноеЗабыто() async throws {
        let vm = try await panel()
        try await enterChild(vm)
        vm.pauseFSWatcher()
        vm.resumeFSWatcher()
        try await Task.sleep(nanoseconds: 400_000_000)

        vm.goUp()
        XCTAssertNotEqual(vm.currentPath, folder, "не из памяти: папка читается с диска")
        try await settle(vm) { vm.currentPath == folder && names(vm).contains("два.txt") }
    }

    /// «В панель» и «Ветвь» кладут в панель не список папки. Уйдя оттуда в другую папку,
    /// плоский список нельзя запомнить под именем папки — он показался бы при возврате.
    func test_списокНаходок_неЗапоминаетсяКакСписокПапки() async throws {
        let vm = try await panel()
        vm.showFoundFiles([folder + "/альфа/внутри.txt"], root: folder)
        try await settle(vm) { vm.isFoundList && names(vm).contains { $0.hasSuffix("внутри.txt") } }
        XCTAssertFalse(names(vm).contains("два.txt"), "на экране находки, а не папка")
        try await enterChild(vm)

        vm.goUp()
        XCTAssertFalse(vm.currentPath == folder && !names(vm).contains("два.txt"),
                       "плоский список находок за список папки не выдаётся")
        try await settle(vm) { vm.currentPath == folder && names(vm).contains("два.txt") }
    }

    /// Первый показ папки на быстром диске — сразу готовый: с размерами и датами, в порядке
    /// выбранной сортировки. Раньше сначала вставали одни имена, а следом полный список: при
    /// сортировке по дате добавления перечень на глазах менялся — «старый, потом обычный».
    func test_первыйПоказПапки_сразуГотовый() async throws {
        let vm = try await panel()
        var sizesSeen: [UInt64] = []
        let watch = vm.data.dataDidChange.sink { [unowned vm] in
            if let inside = vm.items.first(where: { $0.name == "внутри.txt" }) { sizesSeen.append(inside.size) }
        }
        defer { watch.cancel() }
        try await enterChild(vm)
        XCTAssertFalse(sizesSeen.isEmpty, "папка показана")
        XCTAssertEqual(Set(sizesSeen), [1], "файл ни на миг не стоит в списке без размера: \(sizesSeen)")
    }

    func test_когдаЗапомненноеПоказываетсяСразу() {
        let now = Date()
        let shows = { (age: TimeInterval, slow: Bool) in
            PanelViewModel.showsRemembered(readAt: now.addingTimeInterval(-age), now: now, slowVolume: slow)
        }
        XCTAssertTrue(shows(5, false), "только что были здесь")
        XCTAssertFalse(shows(PanelViewModel.listingMemory + 1, false), "давно — читать заново")
        XCTAssertTrue(shows(3600, true), "на медленном томе запомненное выручает всегда")
    }
}
