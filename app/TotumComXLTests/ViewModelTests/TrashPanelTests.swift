import XCTest

@testable import TotumComXLApp

/// The Trash as a panel: which columns it shows, and what those columns are called.
///
/// The panel used to show the ordinary set there — created and modified dates, which belong to the
/// original file and say nothing about the deletion — while the one date that matters had to be
/// switched on by hand and was still labelled "date added".
@MainActor
final class TrashColumnTests: XCTestCase {

    private func panel(insideTrash: Bool) -> PanelViewModel {
        let id = UUID().uuidString
        let vm = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: NSHomeDirectory(),
            pathDefaultsKey: "panel.path.trash.columns.test.\(id)",
            viewModeDefaultsKey: "panel.mode.trash.columns.test.\(id)",
            showHiddenFiles: false
        )
        vm.state.insideTrash = insideTrash
        return vm
    }

    // MARK: - The set

    func testTheTrashShowsWhenSomethingWentAndWhereItCameFrom() {
        let visible = panel(insideTrash: true).effectiveVisibleColumns
        XCTAssertTrue(visible.contains(.dateAdded), "the deletion date is the point of the Trash")
        XCTAssertTrue(visible.contains(.origin), "and where it would go back to")
        XCTAssertTrue(visible.contains(.name))
        XCTAssertTrue(visible.contains(.size))
    }

    /// The original file's own dates are not the deletion date, and three date columns side by
    /// side is exactly the clutter this replaces.
    func testTheOriginalFilesDatesStepAsideInTheTrash() {
        let visible = panel(insideTrash: true).effectiveVisibleColumns
        XCTAssertFalse(visible.contains(.dateCreated))
        XCTAssertFalse(visible.contains(.dateModified))
    }

    /// The user's own set must survive untouched — it is borrowed, not overwritten.
    func testTheUsersOwnSetIsUntouchedAndComesBack() {
        let vm = panel(insideTrash: false)
        vm.visibleColumns = [.name, .size, .dateModified, .permissions]
        let mine = vm.visibleColumns

        vm.state.insideTrash = true
        XCTAssertEqual(vm.effectiveVisibleColumns, PanelColumn.trashColumns)
        XCTAssertEqual(vm.visibleColumns, mine, "entering the Trash must not rewrite the set")

        vm.state.insideTrash = false
        XCTAssertEqual(vm.effectiveVisibleColumns, mine)
    }

    /// Outside the Trash "where it came from" means nothing, and it is not the user's to switch on.
    func testTheOriginColumnIsTrashOnly() {
        let vm = panel(insideTrash: false)
        vm.visibleColumns = Set(PanelColumn.allCases)
        XCTAssertFalse(vm.effectiveVisibleColumns.contains(.origin),
                       "it is normalized out of the ordinary set")
    }

    // MARK: - The name on the header

    /// Renamed rather than joined by a second date column: for something in the Trash, the moment
    /// it was added there IS the moment it was deleted.
    func testTheDateColumnIsCalledDeletedInsideTheTrash() {
        XCTAssertEqual(PanelColumn.dateAdded.localizedTitle(insideTrash: true),
                       L("column.dateDeleted"))
        XCTAssertEqual(PanelColumn.dateAdded.localizedTitle(insideTrash: false),
                       L("column.dateAdded"))
        XCTAssertNotEqual(L("column.dateDeleted"), L("column.dateAdded"),
                          "two different things need two different words")
    }

    func testEveryOtherColumnKeepsItsNameInTheTrash() {
        for column in PanelColumn.allCases where column != .dateAdded {
            XCTAssertEqual(column.localizedTitle(insideTrash: true),
                           column.localizedTitle(insideTrash: false),
                           "\(column.rawValue) has no business changing name in the Trash")
        }
    }

    /// A missing key shows up as the key itself — that would put "column.dateDeleted" on screen.
    func testTheNewTitleIsActuallyTranslated() {
        XCTAssertNotEqual(L("column.dateDeleted"), "column.dateDeleted")
    }

    /// Headers are drawn by SwiftUI from this set and the data columns by AppKit from the same
    /// one; if they ever read different sets, every header after the difference lands one column
    /// off its data.
    func testHeadersAndDataAgreeOnTheSameSet() {
        let vm = panel(insideTrash: true)
        let shown = PanelColumn.allCases.filter { vm.effectiveVisibleColumns.contains($0) }
        XCTAssertEqual(Set(shown), PanelColumn.trashColumns)
    }
}

/// Настоящая папка корзины — это Корзина.
///
/// Список корзины плоский: зашёл в лежащую в ней папку, вышел обратно «..» — и панель стоит на
/// ~/.Trash. Для программы это была обычная папка: обычные колонки, обычное меню с упаковкой и
/// переименованием, — хотя человек из корзины никуда не уходил.
@MainActor
final class RealTrashFolderTests: XCTestCase {

    private var trash: String { NSHomeDirectory() + "/.Trash" }

    private func panel() -> PanelViewModel {
        let id = UUID().uuidString
        let vm = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: NSHomeDirectory(),
            pathDefaultsKey: "panel.path.real.trash.test.\(id)",
            viewModeDefaultsKey: "panel.mode.real.trash.test.\(id)",
            showHiddenFiles: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return vm
    }

    // MARK: - Узнавание пути

    func test_корневаяПапкаКорзиныУзнаётся() {
        XCTAssertTrue(TrashService.isTrashFolder(trash))
        XCTAssertTrue(TrashService.isTrashFolder(trash + "/"), "хвостовая косая ничего не меняет")
        XCTAssertFalse(TrashService.isTrashFolder(trash + "/новая"), "папка ВНУТРИ корзины — не корень")
        XCTAssertFalse(TrashService.isTrashFolder(NSHomeDirectory()))
        XCTAssertFalse(TrashService.isTrashFolder(NSHomeDirectory() + "/.TrashKeeper"),
                       "похожее имя — ещё не корзина")
        XCTAssertFalse(TrashService.isTrashFolder("/Users/кто-то-другой/.Trash"), "чужая корзина не наша")
    }

    func test_путьВнутриКорзиныУзнаётся() {
        XCTAssertTrue(TrashService.isInsideTrashFolder(trash))
        XCTAssertTrue(TrashService.isInsideTrashFolder(trash + "/новая/глубже.txt"))
        XCTAssertFalse(TrashService.isInsideTrashFolder(NSHomeDirectory() + "/.TrashKeeper/файл"))
        XCTAssertFalse(TrashService.isInsideTrashFolder(NSHomeDirectory()))
    }

    // MARK: - Панель

    /// Панель, попавшая на настоящий путь корзины любой дверью, показывает Корзину.
    func test_настоящийПутьОткрываетКорзину() {
        let vm = panel()
        vm.loadFileSystemDirectory(at: trash, resetCursor: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        XCTAssertTrue(vm.state.insideTrash, "стоя в .Trash, панель в Корзине")
        XCTAssertEqual(vm.currentPath, TrashService.trashRoot, "и путь показывается как Корзина")
        XCTAssertTrue(vm.effectiveVisibleColumns.contains(.dateAdded), "и колонки корзинные")
    }

    /// Контекстное меню там — корзинное: восстановить, стереть, очистить, а не упаковать.
    func test_вНастоящейКорзинеМенюКорзинное() throws {
        let vm = panel()
        let tabsVM = PanelTabsViewModel(panelKey: "panel.tabs.real.trash.\(UUID().uuidString)",
                                        initialPath: NSHomeDirectory())
        let vc = PanelViewController(viewModel: vm, tabsVM: tabsVM, side: .left)
        vc.loadViewIfNeeded()

        vm.loadFileSystemDirectory(at: trash, resetCursor: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        let menu = NSMenu(title: "")
        vc.populateContextMenu(menu, for: vm.items.first { $0.name != ".." })
        let titles = menu.items.map { $0.attributedTitle?.string ?? $0.title }
        XCTAssertTrue(titles.contains(L("trash.empty")), "«очистить корзину» на месте: \(titles)")
        XCTAssertFalse(titles.contains(L("context.pack")), "упаковки в корзине нет")
    }

    /// Папку, в которой стоял человек, стёрли, пока он в ней был. Панель откатывается к
    /// ближайшей живой папке — а ею оказывается сама корзина.
    func test_откатКБлижайшейЖивойПапкеТожеВедётВКорзину() {
        let vm = panel()
        vm.loadFileSystemDirectory(at: trash + "/нет-такой-\(UUID().uuidString)", resetCursor: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        XCTAssertTrue(vm.state.insideTrash, "откат привёл в корзину, а не на сырой ~/.Trash")
        XCTAssertEqual(vm.currentPath, TrashService.trashRoot)
    }

    /// Человек вошёл в папку и, не дождавшись списка, нажал «Корзина». Незавершённое чтение
    /// папки не должно лечь поверх корзины: иначе путь снова папка, а признак «я в корзине»
    /// остаётся — и F8 там стирает насовсем.
    func test_незавершённоеЧтениеПапкиНеНакрываетКорзину() {
        let vm = panel()
        // Не под ~/Library: там лежит корзина iCloud Drive, и её файлы законно попадают в список.
        let folder = "/Applications"
        vm.loadFileSystemDirectory(at: folder, resetCursor: true)   // чтение ушло в фон
        vm.loadTrashDirectory()                                     // и тут же — корзина
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))     // фон дошёл

        XCTAssertEqual(vm.currentPath, TrashService.trashRoot, "корзина осталась корзиной")
        XCTAssertTrue(vm.state.insideTrash)
        XCTAssertFalse(vm.items.contains { $0.path.hasPrefix(folder + "/") },
                       "список папки не просочился в корзину")
    }

    /// Программу закрыли, когда панель стояла в Корзине. При запуске путь читается из памяти,
    /// а «/TRASH» файловой системе неизвестен — без перехвата панель уезжает в корень диска.
    func test_запомненнаяКорзинаОткрываетсяКорзиной() {
        let key = "panel.path.real.trash.restore.\(UUID().uuidString)"
        UserDefaults.standard.set(TrashService.trashRoot, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: NSHomeDirectory(),
                                pathDefaultsKey: key, viewModeDefaultsKey: key + ".mode",
                                showHiddenFiles: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        XCTAssertTrue(vm.state.insideTrash, "панель открылась там, где её закрыли")
        XCTAssertEqual(vm.currentPath, TrashService.trashRoot)
    }

    // MARK: - Двери, которые шли мимо

    /// Backspace ведёт наверх той же дорогой, что «..» и кнопка вверх. Свой расчёт родителя
    /// не знал про Корзину: родитель «/TRASH» — это «/», и панель уезжала в корень диска.
    func test_backspaceИзКорзиныВыводитНаружу() {
        let key = "fcxl.backspaceAsBack"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)

        let vm = panel()
        let tabsVM = PanelTabsViewModel(panelKey: "panel.tabs.backspace.\(UUID().uuidString)",
                                        initialPath: NSHomeDirectory())
        let vc = PanelViewController(viewModel: vm, tabsVM: tabsVM, side: .left)
        vc.loadViewIfNeeded()
        vc.isActivePanel = true   // клавиши разбирает только активная панель
        vm.loadDirectory(at: TrashService.trashRoot)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(vm.state.insideTrash)

        XCTAssertTrue(vc.handleKeyEvent(Self.backspace()), "клавишу разобрали")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        XCTAssertFalse(vm.state.insideTrash, "Backspace вывел из корзины")
        XCTAssertEqual(vm.currentPath, NSHomeDirectory(), "туда же, куда и «..», а не в корень диска")
    }

    private static func backspace() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: "\u{8}",
                         charactersIgnoringModifiers: "\u{8}", isARepeat: false, keyCode: 51)!
    }

    /// Переименование в корзине отнимает у файла путь возврата — запрет один для всех дверей,
    /// включая папку, ЛЕЖАЩУЮ в корзине: она глубже, и признак там снят.
    func test_переименованиеВКорзинеЗапрещено() {
        let vm = panel()
        let tabsVM = PanelTabsViewModel(panelKey: "panel.tabs.rename.\(UUID().uuidString)",
                                        initialPath: NSHomeDirectory())
        let vc = PanelViewController(viewModel: vm, tabsVM: tabsVM, side: .left)
        vc.loadViewIfNeeded()

        let ordinary = item(at: NSHomeDirectory() + "/файл.txt")
        XCTAssertFalse(vc.renameForbidden(ordinary), "обычный файл переименовывается как всегда")

        let deep = item(at: trash + "/папка/файл.txt")
        XCTAssertTrue(vc.renameForbidden(deep), "файл в лежащей в корзине папке — тоже корзина")

        vm.state.insideTrash = true
        XCTAssertTrue(vc.renameForbidden(ordinary), "в самой корзине — тем более")
    }

    /// В папке, ЛЕЖАЩЕЙ в корзине, меню остаётся обычным — но «Переименовать» в нём гаснет
    /// с подсказкой: строка, которая то есть, то нет, читается как сбой.
    func test_вПапкеИзКорзиныПереименованиеГаснет() throws {
        let vm = panel()
        let tabsVM = PanelTabsViewModel(panelKey: "panel.tabs.rename.menu.\(UUID().uuidString)",
                                        initialPath: NSHomeDirectory())
        let vc = PanelViewController(viewModel: vm, tabsVM: tabsVM, side: .left)
        vc.loadViewIfNeeded()

        let deep = item(at: trash + "/папка/файл.txt")
        let menu = NSMenu(title: "")
        vc.populateContextMenu(menu, for: deep)
        let rename = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "context.rename" },
                                   "меню обычное, пункт на месте")
        XCTAssertFalse(rename.isEnabled, "но переименовать нельзя")
        XCTAssertEqual(rename.toolTip, L("trash.rename.blocked"), "и сказано почему")

        let ordinary = item(at: NSHomeDirectory() + "/файл.txt")
        let plain = NSMenu(title: "")
        vc.populateContextMenu(plain, for: ordinary)
        let plainRename = try XCTUnwrap(plain.items.first { $0.identifier?.rawValue == "context.rename" })
        XCTAssertTrue(plainRename.isEnabled, "вне корзины пункт живой")
    }

    private func item(at path: String) -> FileItem {
        FileItem(path: path, name: (path as NSString).lastPathComponent, fileExtension: "txt",
                 size: 1, isDirectory: false, isHidden: false, isSymlink: false,
                 permissions: "rw-", dateModified: Date())
    }

    /// «..» из корзины выводит наружу. Если в корзину пришли «..» из лежащей в ней папки,
    /// возвращаться некуда — панель уходит домой, а не обратно в корзину по кругу.
    func test_возвратИзКорзиныНеВодитПоКругу() {
        let vm = panel()
        vm.state.currentPath = trash + "/новая"
        vm.loadTrashDirectory()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(vm.state.insideTrash)

        vm.goUp()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        XCTAssertFalse(vm.state.insideTrash, "«..» вывело из корзины")
        XCTAssertFalse(TrashService.isInsideTrashFolder(vm.currentPath),
                       "и не обратно в корзину: \(vm.currentPath)")
        XCTAssertEqual(vm.currentPath, NSHomeDirectory())
    }
}

/// The Trash's context menu, in every view mode.
///
/// The detailed table decided for itself and knew about the Trash; the brief and thumbnail grids
/// decided separately and did not — right-clicking there offered to pack, rename and copy things
/// that had already been thrown away. One decision now serves all three.
@MainActor
final class TrashContextMenuTests: XCTestCase {

    private var tmp: URL!

    private func makeController(insideTrash: Bool) -> (PanelViewController, PanelViewModel) {
        let id = UUID().uuidString
        let vm = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: tmp.path,
            pathDefaultsKey: "panel.path.trash.menu.test.\(id)",
            viewModeDefaultsKey: "panel.mode.trash.menu.test.\(id)",
            showHiddenFiles: true
        )
        let tabsVM = PanelTabsViewModel(panelKey: "panel.tabs.trash.menu.test.\(id)",
                                        initialPath: tmp.path)
        let vc = PanelViewController(viewModel: vm, tabsVM: tabsVM, side: .left)
        vc.loadViewIfNeeded()
        vm.allItems = [FileItem.fromPath(tmp.appendingPathComponent("файл.txt").path)].compactMap { $0 }
        vm.state.insideTrash = insideTrash
        return (vc, vm)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-trash-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("файл.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        try super.tearDownWithError()
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.attributedTitle?.string ?? $0.title }
    }

    /// The menu the brief and thumbnail grids are handed comes from the same call the table makes.
    func testTheTrashMenuIsTheSameWhicheverModeAsksForIt() {
        let (vc, vm) = makeController(insideTrash: true)
        let item = vm.items.first { $0.name != ".." }
        XCTAssertNotNil(item)

        let trashMenu = NSMenu(title: "")
        vc.populateContextMenu(trashMenu, for: item)
        let shown = titles(trashMenu)

        XCTAssertEqual(shown, [L("trash.restore"), L("delete.permanent.confirm"), "",
                               L("trash.empty")],
                       "put back, erase, empty — and nothing else")

        // Measured against the real file menu rather than against invented titles: a wrong key
        // would otherwise make every "does not contain" pass without proving anything.
        vm.state.insideTrash = false
        let fileMenu = NSMenu(title: "")
        vc.populateContextMenu(fileMenu, for: item)
        let ordinary = titles(fileMenu).filter { !$0.isEmpty }
        XCTAssertTrue(ordinary.contains(L("context.revealInFinder")),
                      "the ordinary menu is what we are comparing against, so it must be real")
        XCTAssertTrue(Set(ordinary).isDisjoint(with: Set(shown).subtracting([""])),
                      "the Trash menu shares no command with the file menu")
        XCTAssertLessThan(shown.count, ordinary.count / 2)
    }

    /// Right-clicking empty space in the Trash is still the Trash — not the ordinary background
    /// menu with "paste" and "new folder".
    func testEmptySpaceInTheTrashStillGetsTheTrashMenu() {
        let (vc, _) = makeController(insideTrash: true)
        let menu = NSMenu(title: "")
        vc.populateContextMenu(menu, for: nil)
        XCTAssertFalse(menu.items.isEmpty)
        XCTAssertFalse(titles(menu).contains(L("trash.restore")),
                       "nothing was clicked, so there is nothing to put back")
    }

    /// The ordinary menu must be untouched outside the Trash — this is the regression that would
    /// hurt most, since it is every right-click in the app.
    func testAnOrdinaryFolderKeepsItsFullMenu() {
        let (vc, vm) = makeController(insideTrash: false)
        let item = vm.items.first { $0.name != ".." }
        let menu = NSMenu(title: "")
        vc.populateContextMenu(menu, for: item)

        XCTAssertGreaterThan(menu.items.count, 5, "the full file menu, not the Trash's short one")
        XCTAssertTrue(titles(menu).contains(L("context.revealInFinder")))
        XCTAssertFalse(titles(menu).contains(L("trash.restore")))
    }
}

/// The deletion date reaching the panel. It showed "-" on every row: the data is there (macOS
/// reports addedToDirectoryDate for everything in the Trash) so something between the service and
/// the panel was dropping it.
@MainActor
final class TrashDeletionDateTests: XCTestCase {

    func testTheServiceReadsADeletionDate() throws {
        let items = TrashService.items()
        try XCTSkipIf(items.isEmpty, "nothing in the Trash to look at")
        let dated = items.filter { $0.dateAdded != nil }
        XCTAssertEqual(dated.count, items.count,
                       "macOS reports a date for everything in the Trash")
    }

    /// The panel is what the user actually looks at, and this is where "-" came from.
    func testThePanelKeepsTheDeletionDate() throws {
        let id = UUID().uuidString
        let vm = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: NSHomeDirectory(),
            pathDefaultsKey: "panel.path.trash.date.test.\(id)",
            viewModeDefaultsKey: "panel.mode.trash.date.test.\(id)",
            showHiddenFiles: false
        )
        try XCTSkipIf(TrashService.items().isEmpty, "nothing in the Trash to look at")

        vm.loadTrashDirectory()
        let listed = vm.items.filter { $0.name != ".." }
        XCTAssertFalse(listed.isEmpty)
        XCTAssertTrue(listed.allSatisfy { $0.dateAdded != nil },
                      "\(listed.filter { $0.dateAdded == nil }.count) of \(listed.count) rows lost it")
    }
}

/// Where the Trash panel actually stands, and what the table actually draws.
///
/// Two faults met here. The panel jumped out of the Trash onto a real volume every time the app
/// was returned to, and the deletion-date column showed a dash on every row.
@MainActor
final class TrashPanelStateTests: XCTestCase {

    /// The panel starts loading its initial directory the moment it is made, and that load lands
    /// asynchronously. Letting it finish first is what keeps this test about the Trash.
    private func settledPanel() -> PanelViewModel {
        let vm = panel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return vm
    }

    private func panel() -> PanelViewModel {
        let id = UUID().uuidString
        return PanelViewModel(
            service: CoreBridgeService(),
            initialPath: NSHomeDirectory(),
            pathDefaultsKey: "panel.path.trash.state.test.\(id)",
            viewModeDefaultsKey: "panel.mode.trash.state.test.\(id)",
            showHiddenFiles: false)
    }

    // MARK: - Reaching the Trash

    /// The Trash moved out of the drive bar and into the window toolbar. Wherever the button
    /// lives, it must travel the ORDINARY road: loadDirectory with the virtual /TRASH path,
    /// which the view model intercepts — not a separate call the rest of the app knows nothing
    /// about.
    func testTheToolbarButtonOpensTheTrashThroughTheOrdinaryRoad() {
        // No skip on an empty Trash: entering it is the thing under test, and an empty Trash is
        // still the Trash.
        let vm = settledPanel()

        vm.loadDirectory(at: MainWindowController.trashDestination())

        XCTAssertTrue(vm.state.insideTrash, "the panel must end up in the Trash")
        XCTAssertEqual(vm.currentPath, TrashService.trashRoot)
    }

    /// Pressing the toolbar's Trash a SECOND time puts the panel back where it stood — the same
    /// return path ".." uses, so there is one memory of it and not two.
    func testPressingTrashAgainGoesBackWhereThePanelWas() {
        let vm = settledPanel()
        let home = NSHomeDirectory()
        vm.loadDirectory(at: home)
        XCTAssertEqual(vm.currentPath, home)

        vm.loadDirectory(at: MainWindowController.trashDestination())
        XCTAssertTrue(vm.state.insideTrash)

        vm.goUp()   // what the second press does
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))   // the listing is async

        XCTAssertFalse(vm.state.insideTrash, "the panel must leave the Trash")
        XCTAssertEqual(vm.currentPath, home, "and land exactly where it came from")
    }

    // MARK: - Staying where the user put it

    /// Becoming active resumes the watchers, and every resume reloads the panel. "/TRASH" is no
    /// filesystem path, so the ordinary listing failed and left the panel on some real volume.
    /// Returning to the app must not move the panel. The network browser goes through the same
    /// branch; it is not tested here because reaching its root means real discovery on the wire.
    func testComingBackToTheAppLeavesThePanelInTheTrash() throws {
        let vm = settledPanel()
        try XCTSkipIf(TrashService.items().isEmpty, "nothing in the Trash to look at")

        vm.loadTrashDirectory()
        XCTAssertEqual(vm.currentPath, TrashService.trashRoot)

        vm.resumeFSWatcher()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))   // the reload is async

        XCTAssertTrue(vm.state.insideTrash, "the panel walked out of the Trash on its own")
        XCTAssertEqual(vm.currentPath, TrashService.trashRoot)
        XCTAssertFalse(vm.items.filter { $0.name != ".." }.isEmpty,
                       "and it must still be showing the Trash's contents")
    }

    /// Toggling hidden files went through the same dead end.
    func testShowingHiddenFilesDoesNotThrowThePanelOutOfTheTrash() throws {
        let vm = settledPanel()
        try XCTSkipIf(TrashService.items().isEmpty, "nothing in the Trash to look at")
        vm.loadTrashDirectory()

        vm.setShowHiddenFiles(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        XCTAssertTrue(vm.state.insideTrash)
        XCTAssertEqual(vm.currentPath, TrashService.trashRoot)
    }

    // MARK: - The table draws the columns it has headers for

    /// The headers are SwiftUI and swap the moment the panel enters the Trash; the columns are
    /// AppKit. While they disagreed, "date deleted" stood over the created column — which is
    /// empty for everything in the Trash, so every row showed a dash.
    func testTheTableShowsExactlyTheColumnsTheHeadersPromise() throws {
        let id = UUID().uuidString
        let vm = settledPanel()
        let tabsVM = PanelTabsViewModel(panelKey: "panel.tabs.trash.state.\(id)",
                                        initialPath: NSHomeDirectory())
        let vc = PanelViewController(viewModel: vm, tabsVM: tabsVM, side: .left)
        vc.loadViewIfNeeded()
        try XCTSkipIf(TrashService.items().isEmpty, "nothing in the Trash to look at")

        vm.loadTrashDirectory()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let table = try XCTUnwrap(vc.tableView)
        let shown = Set(table.tableColumns.filter { !$0.isHidden }
            .map { $0.identifier.rawValue }
            .filter { $0 != "icon" })
        let promised = Set(vm.effectiveVisibleColumns.map { $0.tableColumnIdentifier })
        XCTAssertEqual(shown, promised,
                       "a header over a column the table is not drawing shows the neighbour's data")

        // And the column itself carries the date, not a dash.
        let row = try XCTUnwrap(vm.items.firstIndex { $0.name != ".." })
        let added = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "added" })
        let cell = vc.tableView(table, viewFor: added, row: row)
        let text = (cell as? NSTableCellView)?.textField?.stringValue
            ?? cell?.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.first
        XCTAssertNotEqual(text, "-", "this dash is the bug: no deletion date reached the cell")
        XCTAssertNotNil(vm.items[row].dateAdded)
    }
}

/// Switching to brief and back to detailed lost the deletion dates again.
@MainActor
final class TrashViewModeSwitchTests: XCTestCase {

    private func addedCellText(_ vc: PanelViewController, _ vm: PanelViewModel) throws -> String? {
        let row = try XCTUnwrap(vm.items.firstIndex { $0.name != ".." })
        let col = try XCTUnwrap(vc.tableView.tableColumns.first { $0.identifier.rawValue == "added" })
        let cell = vc.tableView(vc.tableView, viewFor: col, row: row)
        return (cell as? NSTableCellView)?.textField?.stringValue
            ?? cell?.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.first
    }

    private func shownColumns(_ vc: PanelViewController) -> Set<String> {
        Set(vc.tableView.tableColumns.filter { !$0.isHidden }
            .map { $0.identifier.rawValue }.filter { $0 != "icon" })
    }

    func testTheDeletionDateSurvivesATripThroughBriefMode() throws {
        let id = UUID().uuidString
        let vm = PanelViewModel(
            service: CoreBridgeService(), initialPath: NSHomeDirectory(),
            pathDefaultsKey: "panel.path.trash.mode.\(id)",
            viewModeDefaultsKey: "panel.mode.trash.mode.\(id)",
            showHiddenFiles: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))   // let the initial load settle

        let tabsVM = PanelTabsViewModel(panelKey: "panel.tabs.trash.mode.\(id)",
                                        initialPath: NSHomeDirectory())
        let vc = PanelViewController(viewModel: vm, tabsVM: tabsVM, side: .left)
        vc.loadViewIfNeeded()
        try XCTSkipIf(TrashService.items().isEmpty, "nothing in the Trash to look at")

        vm.loadTrashDirectory()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let promised = Set(vm.effectiveVisibleColumns.map { $0.tableColumnIdentifier })
        XCTAssertEqual(shownColumns(vc), promised, "the Trash's own columns, before anything else")
        XCTAssertNotEqual(try addedCellText(vc, vm), "-")

        vm.viewMode = .brief
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        vm.viewMode = .detailed
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(shownColumns(vc), promised,
                       "coming back from brief mode must not leave the ordinary columns behind")
        XCTAssertNotEqual(try addedCellText(vc, vm), "-",
                          "this dash is the bug: the date column lost its date on the way back")
    }
}
