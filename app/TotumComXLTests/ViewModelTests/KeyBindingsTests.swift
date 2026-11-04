import SwiftUI
import AppKit
import XCTest
@testable import TotumComXLApp

/// Свои сочетания клавиш: что лежит в строке меню, как сочетание переходит от команды к
/// команде, что делают наборы Total Commander и Midnight Commander.
///
/// Настройки — отдельный набор на время проверки: настоящие сочетания человека не трогаются.
@MainActor
final class KeyBindingsTests: XCTestCase {

    private var saved: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        saved = KeyBindings.defaults
        suite = "fcxl.tests.keys.\(UUID().uuidString)"
        KeyBindings.defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        KeyBindings.defaults.removePersistentDomain(forName: suite)
        KeyBindings.defaults = saved
        super.tearDown()
    }

    /// Все устойчивые имена пунктов строки меню — с клавишей и без.
    private func allCommandIDs() -> Set<String> {
        var ids: Set<String> = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let id = CommandRegistry.stableID(of: item) { ids.insert(id) }
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(AppDelegate.buildMainMenu())
        return ids
    }

    func test_сочетанияПрограммыБерутсяИзМеню() {
        let base = KeyBindings.programDefaults
        XCTAssertEqual(base["cmd:menuCopy:"], .function(5))
        XCTAssertEqual(base["cmd:menuMove:"], .function(6))
        XCTAssertEqual(base["cmd:menuPack:"], .function(5, .command))
        XCTAssertNil(base["cmd:terminate:"], "выход — на своей настройке")
    }

    func test_уНаборовНетОпечатокВИменахКоманд() {
        let ids = allCommandIDs()
        for profile in KeyProfile.allCases {
            for id in profile.changes.keys {
                XCTAssertTrue(ids.contains(id), "\(profile): нет команды \(id)")
            }
        }
    }

    func test_сочетаниеПереходитКДругойКомандеИСнимаетсяТам() {
        let loser = KeyBindings.assign(.function(5), to: "cmd:menuMove:")
        XCTAssertEqual(loser, "cmd:menuCopy:")
        XCTAssertEqual(KeyBindings.current(for: "cmd:menuMove:"), .function(5))
        XCTAssertNil(KeyBindings.current(for: "cmd:menuCopy:"), "у копирования клавиши больше нет")
        XCTAssertEqual(KeyBindings.profile, .custom)

        KeyBindings.resetAll()
        XCTAssertEqual(KeyBindings.current(for: "cmd:menuCopy:"), .function(5))
        XCTAssertEqual(KeyBindings.profile, .totum)
    }

    func test_прежняяКлавишаПереехавшейКомандыЗамолкаетВПанели() throws {
        let f5 = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: AppDelegate.fkey(5), charactersIgnoringModifiers: AppDelegate.fkey(5),
            isARepeat: false, keyCode: 96))
        XCTAssertFalse(KeyBindings.isReleased(f5), "по умолчанию F5 — копирование в панели")
        KeyBindings.assign(KeyCombo(key: "c", modifiers: .control), to: "cmd:menuCopy:")
        XCTAssertTrue(KeyBindings.isReleased(f5), "копирование уехало на ⌃C — F5 молчит")
    }

    func test_наборTotalCommander() {
        KeyBindings.choose(.totalCommander)
        XCTAssertEqual(KeyBindings.profile, .totalCommander)
        XCTAssertEqual(KeyBindings.current(for: "cmd:menuSearch:"), .function(7, .option))
        XCTAssertEqual(KeyBindings.current(for: "cmd:menuRename:"), .function(6, .shift))
        XCTAssertEqual(KeyBindings.current(for: "cmd:menuCopy:"), .function(5), "остальное — как было")
        // Ни одно сочетание не досталось двум командам.
        let base = KeyBindings.programDefaults
        var owners: [KeyCombo: String] = [:]
        for id in Set(base.keys).union(KeyBindings.overrides.keys) {
            guard let combo = KeyBindings.current(for: id) else { continue }
            XCTAssertNil(owners[combo], "\(combo.text): \(owners[combo] ?? "") и \(id)")
            owners[combo] = id
        }
        KeyBindings.choose(.totum)
        XCTAssertTrue(KeyBindings.overrides.isEmpty)
    }

    func test_сочетанияЛожатсяНаСтрокуМеню() throws {
        KeyBindings.choose(.midnightCommander)
        let menu = AppDelegate.buildMainMenu()
        KeyBindings.apply(to: menu)
        var swap: NSMenuItem?
        func find(_ menu: NSMenu) {
            for item in menu.items {
                if CommandRegistry.stableID(of: item) == "cmd:menuSwapPanels:" { swap = item }
                if let sub = item.submenu { find(sub) }
            }
        }
        find(menu)
        let item = try XCTUnwrap(swap)
        XCTAssertEqual(item.keyEquivalent, "u")
        XCTAssertEqual(item.keyEquivalentModifierMask, .control)
    }

    func test_сочетаниеПишетсяИЧитаетсяОбратно() {
        let combo = KeyCombo(key: "D", modifiers: .command)
        XCTAssertEqual(combo.key, "d")
        XCTAssertTrue(combo.modifiers.contains(.shift), "заглавная буква — это Shift")
        XCTAssertEqual(KeyCombo(stored: combo.stored), combo)
        XCTAssertEqual(combo.text, "⇧⌘D")
        XCTAssertEqual(KeyCombo.function(7, .option).text, "⌥F7")
    }

    func test_голаяБукваНеГодится() {
        XCTAssertFalse(KeyCombo(key: "a", modifiers: []).isAssignable)
        XCTAssertFalse(KeyCombo(key: "\u{F701}", modifiers: []).isAssignable, "стрелка водит курсор")
        XCTAssertTrue(KeyCombo(key: "a", modifiers: .control).isAssignable)
        XCTAssertTrue(KeyCombo.function(9).isAssignable)
    }
}

/// Окно сочетаний: список не пустой, видно команды с клавишами — в обеих темах.
@MainActor
final class KeyBindingsEditorLookTests: XCTestCase {

    func test_списокКомандРисуется() throws {
        let folder = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] ?? NSTemporaryDirectory()
        let previous = NSApplication.shared.mainMenu
        NSApplication.shared.mainMenu = AppDelegate.buildMainMenu()
        defer { NSApplication.shared.mainMenu = previous }
        let commands = CommandRegistry.commands()
        XCTAssertGreaterThan(commands.count, 50, "в строке меню десятки команд")
        let view = KeyBindingsEditorView(session: FCXLDialogSession(), commands: Array(commands.prefix(30)))
        for (name, scheme) in [("светлая", ColorScheme.light), ("тёмная", ColorScheme.dark)] {
            let picture = VStack { view.listContent }
                .frame(width: 660, height: 900)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: picture)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.nsImage, name)
            let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
                .representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("сочетания-\(name).png"))
        }
    }
}
