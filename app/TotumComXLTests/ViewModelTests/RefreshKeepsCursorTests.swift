import XCTest
@testable import TotumComXLApp

/// Перечитка папки не возвращает курсор туда, где он был, когда она началась.
///
/// Сетевая папка, открыт просмотр снимков: просмотрщик читает файл с сервера, сервер сообщает
/// о чтении, панель перечитывает папку — сначала из кэша, потом свежим списком через сотни
/// миллисекунд. Человек за это время нажимал ↓, а пришедший список ставил курсор обратно.
@MainActor
final class RefreshKeepsCursorTests: XCTestCase {

    private var folder = ""

    override func setUp() {
        super.setUp()
        folder = NSTemporaryDirectory() + "refresh-cursor-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for i in 0..<10 {
            FileManager.default.createFile(atPath: folder + String(format: "/IMG_%02d.jpg", i),
                                           contents: Data(repeating: 0xFF, count: 100 + i))
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: folder)
        super.tearDown()
    }

    private func loadedPanel() -> PanelViewModel {
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: folder,
                                pathDefaultsKey: "panel.path.refreshcursor.\(id)",
                                viewModeDefaultsKey: "panel.mode.refreshcursor.\(id)", showHiddenFiles: false)
        vm.viewMode = .brief
        vm.loadFileSystemDirectory(at: folder, resetCursor: true)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, vm.items.filter({ $0.name != ".." }).count < 10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // Полный список с метаданными ложится в кэш — следующая перечитка пойдёт через него.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        // Слежка за папкой здесь лишняя: события о файлах, созданных в setUp, пришли бы
        // посреди проверки своей перечиткой. Перечитку тест вызывает сам.
        vm.stopWatching()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return vm
    }

    private func index(of name: String, in vm: PanelViewModel) throws -> Int {
        try XCTUnwrap(vm.items.firstIndex { $0.name == name })
    }

    /// Файл на сервере поменялся (размер), папка — нет: перечитка идёт через кэш, и пока
    /// свежий список в пути, человек сдвигает курсор. Курсор остаётся там, куда его сдвинули.
    func test_свежийСписокНеВозвращаетКурсор() throws {
        let vm = loadedPanel()
        vm.setCursor(index: try index(of: "IMG_02.jpg", in: vm))

        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: folder + "/IMG_07.jpg"))
        handle.seekToEndOfFile()
        handle.write(Data(repeating: 0xEE, count: 500))
        try handle.close()

        vm.reloadKeepingCursor()
        vm.setCursor(index: try index(of: "IMG_03.jpg", in: vm))   // ↓, пока список в пути
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        XCTAssertEqual(vm.cursorItem?.name, "IMG_03.jpg", "курсор там, куда его сдвинули")
        XCTAssertEqual(vm.items.first { $0.name == "IMG_07.jpg" }?.size, 607, "свежий размер на месте")
    }

    /// Ничего не изменилось (сервер лишь сообщил о чтении) — список не перекладывается.
    func test_тотЖеСписокНеТрогаетПанель() throws {
        let vm = loadedPanel()
        vm.setCursor(index: try index(of: "IMG_05.jpg", in: vm))
        let before = vm.sortToken
        vm.reloadKeepingCursor()
        // Показ из кэша — сразу, в этом же вызове; свежий список придёт позже.
        let shownFromCache = vm.sortToken
        XCTAssertNotEqual(shownFromCache, before, "перечитка пошла через кэш")
        vm.setCursor(index: try index(of: "IMG_06.jpg", in: vm))
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(vm.cursorItem?.name, "IMG_06.jpg")
        XCTAssertEqual(vm.sortToken, shownFromCache, "свежий список — тот же самый — не перекладывался")
    }

    func test_тотЖеСписокУзнаётся() throws {
        let service = CoreBridgeService()
        let listing = try service.listDirectoryFast(path: folder, showHidden: false)
        let up = FileItem(path: (folder as NSString).deletingLastPathComponent, name: "..", fileExtension: "",
                          size: 0, isDirectory: true, isHidden: false, isSymlink: false, permissions: "",
                          dateModified: Date())
        XCTAssertTrue(PanelViewModel.sameListing(listing, shown: [up] + listing.reversed()),
                      "тот же список в другом порядке и с «..» — тот же")
        XCTAssertFalse(PanelViewModel.sameListing(Array(listing.dropLast()), shown: listing), "файла не стало")

        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: folder + "/IMG_01.jpg"))
        handle.seekToEndOfFile()
        handle.write(Data([1, 2, 3]))
        try handle.close()
        let grown = try service.listDirectoryFast(path: folder, showHidden: false)
        XCTAssertFalse(PanelViewModel.sameListing(grown, shown: listing), "размер файла другой")
    }

    func test_кудаВстатьКурсору() {
        XCTAssertEqual(PanelViewModel.refreshCursorTarget(current: "b", atStart: "a", pending: nil), "b",
                       "сдвинули — остаётся, где сейчас")
        XCTAssertEqual(PanelViewModel.refreshCursorTarget(current: "a", atStart: "a", pending: "new"), "new",
                       "не двигали — на только что созданный файл")
        XCTAssertEqual(PanelViewModel.refreshCursorTarget(current: "b", atStart: "a", pending: "new"), "b",
                       "двигали — человек важнее запроса")
    }
}
