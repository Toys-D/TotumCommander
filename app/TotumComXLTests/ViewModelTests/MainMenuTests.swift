import AppKit
import XCTest
@testable import TotumComXLApp

/// Строка меню — всё, что программа умеет.
///
/// Палитра (Cmd+P) и операции туннеля берут команды из строки меню, поэтому всё, что
/// есть на клавишах, кнопках и в контекстном меню, обязано быть и здесь. Список ниже —
/// опись, собранная по всей программе; выпавшая из меню команда роняет проверку.
@MainActor
final class MainMenuTests: XCTestCase {

    private var menu: NSMenu!

    override func setUp() {
        super.setUp()
        menu = AppDelegate.buildMainMenu()
    }

    /// Все пункты с действием, из всех уровней.
    private func commands(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            if let submenu = item.submenu { return commands(in: submenu) }
            return item.action == nil || item.isSeparatorItem ? [] : [item]
        }
    }

    private var titles: Set<String> { Set(commands(in: menu).map(\.title)) }

    /// Устойчивое имя команды — то, чем её записывают в своё контекстное меню.
    ///
    /// Названием звать нельзя: оно меняется вместе с языком, и человек, переключивший
    /// программу на английский, потерял бы всё, что собрал. Имя строится из действия, метки
    /// и вложенной строки — ни то, ни другое, ни третье от языка не зависит; проверка держит
    /// главное: у каждой команды имя есть, и ни одно не повторяется.
    func test_уКаждойКомандыСвоёУстойчивоеИмя() {
        var byID: [String: [String]] = [:]
        for item in commands(in: menu) {
            let id = CommandRegistry.stableID(of: item)
            XCTAssertNotNil(id, "«\(item.title)» нечем назвать")
            byID[id ?? item.title, default: []].append(item.title)
        }
        XCTAssertGreaterThan(byID.count, 130, "команд в меню полторы сотни")
        let clashes = byID.filter { $0.value.count > 1 }
        XCTAssertTrue(clashes.isEmpty, "одно имя на несколько команд: \(clashes)")
        for id in byID.keys {
            XCTAssertTrue(id.hasPrefix("cmd:"), "\(id)")
        }
    }

    func test_всеКомандыПрограммыЕстьВМеню() {
        // Из контекстного меню панели, футера, панели инструментов, туннеля и клавиш.
        let expected = [
            // Файл
            "tabs.newTab", "tabs.close", "menu.tabs.next", "menu.tabs.previous", "tabs.rename",
            "tabs.pin", "tabs.closeOthers", "tabs.closeAllUnpinned", "tabs.color.reset",
            "context.open", "context.openWith", "context.revealInFinder", "context.openInTerminal",
            "context.mkdir", "context.createTextFile", "context.view", "context.edit",
            "context.rename", "menu.file.copyTo", "menu.file.moveTo", "context.delete",
            "menu.file.deletePermanently", "context.pack", "context.unpack",
            "context.createSymlink", "context.createAlias", "context.createHardlink",
            "context.copyFilePath", "context.copyPath", "context.changeAttributes",
            "context.properties", "network.connectToServer", "menu.closeWindow",
            // Правка
            "menu.undo", "menu.redo", "menu.cut", "menu.copy", "menu.paste", "menu.selectAll",
            "menu.selectByMask", "menu.deselectByMask", "menu.invertSelection",
            "menu.selectSameType", "menu.edit.clearSelection",
            // Вид
            "mode.detailed", "mode.brief", "mode.thumbnails", "menu.view.sortDescending",
            "menu.view.hiddenFiles", "menu.view.branch", "context.refresh",
            "menu.view.folderSizes", "terminal.title", "monitor.toggle", "diskinfo.title",
            "trash.title", "stack.title", "menu.view.queue", "settings.appearance.toggleTooltip",
            // Переход
            "menu.go.up", "menu.go.back", "menu.go.forward", "menu.go.home", "quickLink.desktop",
            "quickLink.documents", "quickLink.downloads", "quickLink.applications",
            "quickLink.pictures", "quickLink.music", "quickLink.movies", "menu.go.root",
            "menu.favorites", "context.enterAppBundle", "context.followSymlink",
            "menu.go.switchPanel", "divider.swap", "divider.syncLeft", "divider.syncRight",
            "divider.center",
            // Инструменты
            "menu.tools.commandPalette", "button.f9.search", "vault.create.menu", "menu.tools.vault",
            "age.encrypt.menu", "age.decrypt.menu", "context.pdfMake", "context.pdfMerge",
            "context.pdfSplit", "context.pdfRotate", "context.convertImages",
            "context.recognizeText", "context.cleanMetadata", "menu.tools.applyRules",
            "menu.tools.rules", "menu.tools.multiRename", "menu.tools.checksum",
            "menu.tools.compare", "menu.tools.compareFiles", "menu.tools.split",
            "menu.tools.join", "context.tags.clear", "menu.tools.diskImage", "context.uninstall"
        ]
        let have = titles
        let missing = expected.filter { !have.contains(L($0)) }
        XCTAssertTrue(missing.isEmpty, "в меню нет: \(missing)")
        // Столбцы, поля сортировки, метки, форматы архива — по одному на каждый вариант.
        for column in PanelColumn.allCases where column != .name {
            XCTAssertTrue(have.contains(AppDelegate.columnTitle(column)), "столбец \(column)")
        }
        for tag in FinderTag.allCases {
            XCTAssertTrue(have.contains(tag.localizedName), "метка \(tag)")
        }
        for format in ArchiveFormat.allCases {
            XCTAssertTrue(have.contains(format.displayName), "формат \(format)")
        }
        XCTAssertGreaterThan(commands(in: menu).count, 120)
    }

    /// Две команды на одной клавише — одна из них молчит. Проверяем всю строку меню разом.
    func test_клавишиМенюНеПовторяются() {
        var seen: [String: String] = [:]
        var clashes: [String] = []
        for item in commands(in: menu) where !item.keyEquivalent.isEmpty {
            let key = "\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent)"
            if let other = seen[key] {
                clashes.append("«\(other)» и «\(item.title)»")
            }
            seen[key] = item.title
        }
        XCTAssertTrue(clashes.isEmpty, "одна клавиша у: \(clashes)")
    }

    /// F-клавиши — без ⌘: addItem вешает ⌘ по умолчанию, и F5 стал бы ⌘F5.
    func test_FКлавишиБезМодификаторов() {
        let byKey = Dictionary(grouping: commands(in: menu), by: \.keyEquivalent)
        func mask(_ title: String) -> NSEvent.ModifierFlags? {
            commands(in: menu).first { $0.title == L(title) }?.keyEquivalentModifierMask
        }
        XCTAssertEqual(mask("context.view"), [])
        XCTAssertEqual(mask("context.rename"), [])
        XCTAssertEqual(mask("menu.file.copyTo"), [])
        XCTAssertEqual(mask("context.delete"), [])
        XCTAssertEqual(mask("menu.file.deletePermanently"), [.shift])
        XCTAssertEqual(mask("context.pack"), [.command])
        XCTAssertEqual(mask("context.unpack"), [.command])
        XCTAssertEqual(byKey[AppDelegate.fkey(5)]?.count, 2, "F5 и ⌘F5 — две разные команды")
        // ⇧F4 — новый текстовый файл сразу в редактор, как в Total Commander.
        XCTAssertEqual(mask("context.edit"), [])
        XCTAssertEqual(mask("context.createTextFile"), [.shift])
        XCTAssertEqual(byKey[AppDelegate.fkey(4)]?.count, 2, "F4 и ⇧F4 — две разные команды")
    }

    /// ⌘? — это ⌘⇧/: пункт меню обязан ждать Shift, а монитор — узнавать клавишу по коду,
    /// чтобы справка открывалась и на русской раскладке, где та же клавиша даёт «,».
    func test_справкаОткрываетсяПоCmdShiftСлэш() {
        let help = commands(in: menu).first { $0.title == L("menu.help.guide") }
        XCTAssertEqual(help?.keyEquivalent, "?")
        XCTAssertEqual(help?.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertTrue(AppDelegate.isHelpKeystroke(keyCode: 44, flags: [.command, .shift]))
        XCTAssertTrue(AppDelegate.isHelpKeystroke(keyCode: 44, flags: [.command, .shift, .capsLock]),
                      "Caps Lock не мешает")
        XCTAssertFalse(AppDelegate.isHelpKeystroke(keyCode: 44, flags: [.command]), "без Shift — не справка")
        XCTAssertFalse(AppDelegate.isHelpKeystroke(keyCode: 44, flags: [.command, .shift, .option]))
        XCTAssertFalse(AppDelegate.isHelpKeystroke(keyCode: 3, flags: [.command, .shift]), "другая клавиша")
    }

    /// F1 — справка, как во всякой программе и как в Total Commander. Без модификаторов:
    /// F1 с ⌘ или ⌥ принадлежит не нам.
    func test_справкаОткрываетсяПоF1() {
        XCTAssertTrue(AppDelegate.isHelpKeystroke(keyCode: 122, flags: []))
        XCTAssertTrue(AppDelegate.isHelpKeystroke(keyCode: 122, flags: [.capsLock]), "Caps Lock не мешает")
        // Настоящая F-клавиша приходит с флагом .function — измерено на живом нажатии.
        XCTAssertTrue(AppDelegate.isHelpKeystroke(keyCode: 122, flags: [.function]))
        XCTAssertFalse(AppDelegate.isHelpKeystroke(keyCode: 122, flags: [.command]))
        XCTAssertFalse(AppDelegate.isHelpKeystroke(keyCode: 122, flags: [.option]))
        XCTAssertFalse(AppDelegate.isHelpKeystroke(keyCode: 120, flags: []), "F2 — переименование, не справка")
    }

    /// Реестр палитры различает пункты вложенных меню по имени подменю.
    func test_палитраВидитВложенныеПунктыСИменемПодменю() {
        let app = NSApplication.shared
        let previous = app.mainMenu
        app.mainMenu = menu
        defer { app.mainMenu = previous }
        let commands = CommandRegistry.commands()
        let view = L("menu.view")
        let sortByName = L("menu.view.sortBy") + " › " + L("column.name")
        let columnSize = L("menu.view.columns") + " › " + L("column.size")
        XCTAssertTrue(commands.contains { $0.group == view && $0.title == sortByName },
                      "нет «\(sortByName)» среди: \(commands.filter { $0.group == view }.map(\.title))")
        XCTAssertTrue(commands.contains { $0.group == view && $0.title == columnSize })
        XCTAssertGreaterThan(commands.count, 100)
    }
}
