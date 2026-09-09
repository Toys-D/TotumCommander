import AppKit
import XCTest
@testable import TotumComXLApp

/// Содержимое туннеля: папки сверху, операции снизу — и то и другое своё.
@MainActor
final class TunnelStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "tunnel.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func store() -> TunnelStore { TunnelStore(defaults: defaults) }

    private func makeFolder() throws -> String {
        let path = NSTemporaryDirectory() + "туннель-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    // MARK: - Набор по умолчанию

    /// Как боковая панель Finder: пользовательские папки, сверху вниз.
    func test_поУмолчаниюНаборКакВFinder() {
        let home = NSHomeDirectory()
        XCTAssertEqual(store().folders.map(\.path),
                       ["/Applications", home + "/Desktop", home + "/Documents",
                        home + "/Downloads", home + "/Movies", home + "/Music",
                        home + "/Pictures"])
    }

    func test_поУмолчаниюШестьОпераций() {
        XCTAssertEqual(store().actions.map(\.key),
                       ["builtin:copy", "builtin:move", "builtin:delete",
                        "builtin:mkdir", "builtin:view", "builtin:edit"])
    }

    /// Подписи системных папок переводятся при показе, а не при сохранении: смена языка
    /// не должна оставлять надписи на старом.
    func test_подписьСистемнойПапкиПереводится() {
        let documents = store().folders.first { $0.path.hasSuffix("/Documents") }
        XCTAssertEqual(documents?.label, L("quickLink.documents"))
    }

    // MARK: - Правка папок

    func test_папкаДобавляетсяПеретаскиваниемИЗапоминается() throws {
        let path = try makeFolder()
        let first = store()
        XCTAssertTrue(first.addFolder(path: path))
        XCTAssertEqual(first.folders.last?.path, path)
        XCTAssertEqual(first.folders.last?.label, (path as NSString).lastPathComponent,
                       "подпись — имя папки")

        // Перезапуск программы: настройка пережила.
        XCTAssertEqual(store().folders.last?.path, path)
    }

    func test_файлИПовторВПапкиНеПопадают() throws {
        let path = try makeFolder()
        let file = path + "/файл.txt"
        FileManager.default.createFile(atPath: file, contents: Data())
        let s = store()
        XCTAssertFalse(s.addFolder(path: file), "файл — не папка")
        XCTAssertTrue(s.addFolder(path: path))
        XCTAssertFalse(s.addFolder(path: path), "второй раз та же папка не встаёт")
    }

    func test_папкаУбираетсяИПорядокДвигается() throws {
        let s = store()
        let было = s.folders.map(\.path)
        s.removeFolder(path: было[0])
        XCTAssertEqual(s.folders.count, было.count - 1)

        let первый = s.folders[0].path
        let второй = s.folders[1].path
        s.moveFolder(path: первый, up: false)
        XCTAssertEqual(s.folders[0].path, второй, "поменялись местами")
        s.moveFolder(path: первый, up: false)
        s.moveFolder(path: s.folders[0].path, up: true)  // у края — просьба не исполняется
        XCTAssertEqual(s.folders.count, было.count - 1, "края список не рвут")
    }

    /// Перетаскивание кладёт сразу на нужное место, через сколько угодно соседей.
    /// Бросили между второй и третьей — там и стоит, а не в конце.
    func test_папкаВстаётТудаКудаБросили() throws {
        let s = store()
        let новая = try makeFolder()
        XCTAssertTrue(s.addFolder(path: новая, at: 2))
        XCTAssertEqual(s.folders[2].path, новая)
        XCTAssertEqual(s.folders.count, 8)
        // Уже стоящая — переезжает, а не отвергается и не дублируется.
        XCTAssertTrue(s.addFolder(path: новая, at: 99))
        XCTAssertEqual(s.folders.last?.path, новая)
        XCTAssertEqual(s.folders.count, 8)
        XCTAssertTrue(s.addFolder(path: новая, at: 0))
        XCTAssertEqual(s.folders.first?.path, новая)
        XCTAssertEqual(store().folders.first?.path, новая, "порядок запоминается")
        XCTAssertFalse(s.addFolder(path: "/нет/такой/папки", at: 0))
    }

    func test_папкаИОперацияВстаютНаЛюбоеМесто() {
        let s = store()
        let первая = s.folders[0].path
        s.moveFolder(path: первая, to: s.folders.count - 1)
        XCTAssertEqual(s.folders.last?.path, первая)
        XCTAssertEqual(s.folders[0].path, TunnelStore.defaultFolders[1].path)
        s.moveFolder(path: первая, to: 99)              // мимо списка — не исполняется
        XCTAssertEqual(s.folders.last?.path, первая)
        s.moveFolder(path: первая, to: 0)
        XCTAssertEqual(s.folders.map(\.path), TunnelStore.defaultFolders.map(\.path))

        s.moveAction(key: "builtin:edit", to: 0)
        XCTAssertEqual(s.actions[0].key, "builtin:edit")
        XCTAssertEqual(s.actions[1].key, "builtin:copy")
        XCTAssertEqual(store().actions[0].key, "builtin:edit", "порядок запоминается")
    }

    /// Подпись своя: длинное название команды в узком туннеле режется, короткое помещается.
    func test_подписьМеняетсяИПустаяВозвращаетИсходную() {
        let s = store()
        let home = NSHomeDirectory()
        s.setFolderLabel(path: home + "/Documents", label: "  Доки ")
        XCTAssertEqual(s.folders[2].label, "Доки", "без лишних пробелов")
        XCTAssertEqual(s.folders[2].shortLabel, "Доки")
        XCTAssertEqual(store().folders[2].label, "Доки", "подпись запоминается")
        s.setFolderLabel(path: home + "/Documents", label: "")
        XCTAssertEqual(s.folders[2].label, L("quickLink.documents"), "пустая — обратно к переводу")

        s.addMenuAction(group: "Файл", title: "Упаковать в архив...")
        let key = "menu:Файл▸Упаковать в архив..."
        s.setActionLabel(key: key, label: "Zip")
        XCTAssertEqual(s.actions.last?.label, "Zip")
        s.setActionLabel(key: key, label: "   ")
        XCTAssertEqual(s.actions.last?.label, "Упаковать в архив...", "у команды меню исходная — её название")

        s.setActionLabel(key: "builtin:copy", label: "F5")
        XCTAssertEqual(s.actions[0].label, "F5")
        s.setActionLabel(key: "builtin:copy", label: "")
        XCTAssertEqual(s.actions[0].label, L("divider.label.copy"))
        s.setActionLabel(key: "нет такой", label: "x")           // чужой ключ — тишина
    }

    func test_значокМеняетсяИЖивётПослеПерезапуска() throws {
        let s = store()
        let path = s.folders[0].path
        s.setFolderIcon(path: path, icon: "heart")
        XCTAssertEqual(store().folders[0].icon, "heart")
    }

    func test_наборВозвращаетсяКПоУмолчанию() throws {
        let s = store()
        s.removeFolder(path: s.folders[0].path)
        s.resetFolders()
        XCTAssertEqual(s.folders, TunnelStore.defaultFolders)
    }

    // MARK: - Правка операций

    func test_командаМенюДобавляетсяИОпознаётся() {
        let s = store()
        XCTAssertTrue(s.addMenuAction(group: "Инструменты", title: "Запаковать"))
        XCTAssertFalse(s.addMenuAction(group: "Инструменты", title: "Запаковать"),
                       "второй раз та же команда не встаёт")
        let added = s.actions.last!
        XCTAssertFalse(added.isBuiltin)
        XCTAssertEqual(added.label, "Запаковать")
        XCTAssertEqual(added.menuTitle, "Запаковать")

        // Пережила перезапуск.
        XCTAssertEqual(store().actions.last?.key, "menu:Инструменты▸Запаковать")
    }

    func test_операцииУбираютсяДвигаютсяИВозвращаются() {
        let s = store()
        s.removeAction(key: "builtin:copy")
        XCTAssertEqual(s.actions.count, 5)
        let первый = s.actions[0].key
        s.moveAction(key: первый, up: false)
        XCTAssertEqual(s.actions[1].key, первый)
        s.setActionIcon(key: первый, icon: "star")
        XCTAssertEqual(s.actions.first { $0.key == первый }?.icon, "star")
        s.resetActions()
        XCTAssertEqual(s.actions, TunnelStore.defaultActions)
    }

    /// У своих операций подписи из тех же строк, что были у прошитых кнопок.
    func test_подписиСвоихОперацийПереводятся() {
        let copy = store().actions.first { $0.key == "builtin:copy" }
        XCTAssertEqual(copy?.label, L("divider.label.copy"))
        XCTAssertEqual(copy?.shortLabel, L("divider.short.copy"))
    }

    // MARK: - Библиотека значков

    func test_библиотекаЗначковНеПустаИБезПовторов() {
        XCTAssertGreaterThanOrEqual(TunnelIconLibrary.icons.count, 48,
                                    "есть из чего выбирать")
        XCTAssertEqual(Set(TunnelIconLibrary.icons).count, TunnelIconLibrary.icons.count,
                       "без повторов")
    }

    /// Значок Рабочего стола — монитор, как было всегда: человек его отстоял.
    /// Команда меню приходит в туннель со своим значком — «Упаковать» с коробкой, не с молнией.
    func test_командаМенюПриноситСвойЗначок() {
        let s = store()
        s.addMenuAction(group: "Файл", title: "Упаковать", icon: "archivebox")
        XCTAssertEqual(s.actions.last?.icon, "archivebox")
        s.addMenuAction(group: "Файл", title: "Без значка", icon: nil)
        XCTAssertEqual(s.actions.last?.icon, "bolt", "нет своего — молния, как раньше")
    }

    /// Первый раздел библиотеки — операции программы, и в нём есть значки архивов.
    func test_библиотекаНачинаетсяСОпераций() {
        let first = TunnelIconLibrary.sections[0]
        XCTAssertEqual(first.title, "tunnel.icons.operations")
        for icon in ["archivebox", "archivebox.fill", "doc.zipper", "doc.on.doc", "trash",
                     "scissors", "arrow.left.arrow.right", "textformat.abc", "magnifyingglass"] {
            XCTAssertTrue(first.icons.contains(icon), icon)
        }
        XCTAssertGreaterThanOrEqual(TunnelIconLibrary.icons.count, 150)
    }

    /// Значки команд живого меню, которых в библиотеке нет, добавляются в конец — без повторов
    /// и без тех, что уже есть.
    func test_значкиКомандМенюДополняютБиблиотеку() {
        let app = NSApplication.shared
        let previous = app.mainMenu
        defer { app.mainMenu = previous }
        app.mainMenu = AppDelegate.buildMainMenu()
        let extra = TunnelIconLibrary.menuIcons()
        XCTAssertEqual(Set(extra).count, extra.count, "без повторов")
        XCTAssertTrue(Set(extra).isDisjoint(with: TunnelIconLibrary.icons), "только новые")
        let menuSymbols = Set(CommandRegistry.commands().compactMap(\.symbolName))
        XCTAssertTrue(menuSymbols.isSubset(of: Set(TunnelIconLibrary.icons).union(extra)),
                      "каждый значок меню либо в библиотеке, либо в добавке")
    }

    /// Несуществующее имя значка — пустая клетка в окне выбора. Каждое имя обязано рисоваться.
    func test_всеЗначкиБиблиотекиСуществуют() {
        let missing = TunnelIconLibrary.icons.filter {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil
        }
        XCTAssertTrue(missing.isEmpty, "нет таких значков: \(missing)")
    }

    func test_уРабочегоСтолаЗначокМонитор() {
        let desktop = store().folders.first { $0.path.hasSuffix("/Desktop") }
        XCTAssertEqual(desktop?.icon, "desktopcomputer")
    }

    /// Сохранённый набор из сборки 2112 с недолгим чужим значком чинится сам: выбрать
    /// тот значок рукой было нельзя — в библиотеке его не было.
    func test_чужойЗначокРабочегоСтолаЧинитсяПриЗагрузке() throws {
        let s = store()
        _ = s // записи по умолчанию ещё нет — подсунем старую сохранёнку
        var folders = TunnelStore.defaultFolders
        let desktop = folders.firstIndex { $0.path.hasSuffix("/Desktop") }!
        folders[desktop].icon = "menubar.dock.rectangle"
        defaults.set(try JSONEncoder().encode(folders), forKey: TunnelStore.foldersKey)

        let reloaded = store()
        XCTAssertEqual(reloaded.folders[desktop].icon, "desktopcomputer")
    }
}
