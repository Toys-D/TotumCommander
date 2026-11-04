import AppKit
import XCTest
@testable import TotumComXLApp

/// The palette lives or dies on its ranking: type three letters and the command you meant has to be
/// the highlighted one, because Return runs whatever is highlighted.
@MainActor
final class CommandMatcherTests: XCTestCase {

    private func command(_ title: String, group: String = "Инструменты") -> PaletteCommand {
        PaletteCommand(title: title, group: group, shortcut: "", symbolName: nil,
                       item: NSMenuItem(title: title, action: nil, keyEquivalent: ""))
    }

    private func titles(_ query: String, _ names: [String]) -> [String] {
        CommandMatcher.rank(names.map { command($0) }, query: query).map(\.title)
    }

    // MARK: - Matching

    func test_emptyQueryKeepsEveryCommandInMenuOrder() {
        let names = ["Сравнить папки", "Контрольные суммы", "Разбить файл"]
        XCTAssertEqual(titles("", names), names)
        XCTAssertEqual(titles("   ", names), names, "whitespace is not a query")
    }

    func test_matchesAFragmentFromAnywhereInTheName() {
        XCTAssertEqual(titles("папк", ["Сравнить папки", "Разбить файл"]), ["Сравнить папки"])
    }

    /// The reason for a subsequence match rather than "contains": people type initials.
    func test_matchesInitialsAcrossWords() {
        let found = titles("сп", ["Сравнить папки", "Контрольные суммы"])
        XCTAssertEqual(found.first, "Сравнить папки")
    }

    func test_charactersMustAppearInOrder() {
        XCTAssertTrue(titles("икп", ["Сравнить папки"]).isEmpty,
                      "letters out of order must not match")
    }

    func test_matchingIgnoresCase() {
        XCTAssertEqual(titles("СРАВ", ["Сравнить папки"]), ["Сравнить папки"])
    }

    func test_nonMatchingQueryReturnsNothing() {
        XCTAssertTrue(titles("zzzz", ["Сравнить папки", "Разбить файл"]).isEmpty)
    }

    // MARK: - Ranking

    /// A name that STARTS with what was typed is what the user meant, even when a longer name
    /// contains the same letters somewhere in the middle.
    func test_aNameThatStartsWithTheQueryWinsOverOneThatMerelyContainsIt() {
        XCTAssertEqual(titles("раз", ["Отобразить размеры", "Разбить файл"]).first,
                       "Разбить файл")
    }

    /// Adjacent letters are a stronger signal than the same letters scattered about. Compared at
    /// equal name length, so the length tie-breaker cannot be what decides it.
    func test_aRunOfAdjacentLettersOutranksScatteredOnes() {
        let run = CommandMatcher.score("абв", against: "абвгде")
        let scattered = CommandMatcher.score("абв", against: "агбдве")
        XCTAssertNotNil(run)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(run ?? 0, scattered ?? 0)
    }

    /// Between two equally good matches the shorter name is the likelier target.
    func test_theShorterOfTwoEqualMatchesComesFirst() {
        XCTAssertEqual(titles("файл", ["Файлы", "Файлы и папки текущего каталога"]).first, "Файлы")
    }

    /// Typing a menu's name lists what is in it — but a command whose own name matches wins.
    func test_theGroupNameMatchesButScoresBelowTheCommandName() {
        let commands = [command("Разбить файл", group: "Инструменты"),
                        command("Инструменты разработчика", group: "Вид")]
        let ranked = CommandMatcher.rank(commands, query: "инстру").map(\.title)
        XCTAssertEqual(ranked.first, "Инструменты разработчика",
                       "a hit on the command's own name must beat a hit on its menu")
        XCTAssertEqual(ranked.count, 2, "the group match should still be listed")
    }

    /// A query longer than the name cannot be a subsequence of it — and must not crash trying.
    func test_aQueryLongerThanTheNameIsSafe() {
        XCTAssertNil(CommandMatcher.score("сравнить папки целиком", against: "Файл"))
    }

    // MARK: - The registry

    /// The palette reads the real menu bar, so a menu built at runtime must yield commands with
    /// their menu's name attached.
    func test_registryReadsTitlesAndGroupsFromTheMenuTree() {
        // Touching NSApplication.shared first: NSApp is nil in a bare test bundle, and it is an
        // implicitly unwrapped optional, so reading it would crash rather than fail the test.
        let app = NSApplication.shared
        let previous = app.mainMenu
        defer { app.mainMenu = previous }

        let main = NSMenu()
        main.addItem(NSMenuItem(title: "AppName", action: nil, keyEquivalent: ""))

        let toolsItem = NSMenuItem(title: "Инструменты", action: nil, keyEquivalent: "")
        let tools = NSMenu(title: "Инструменты")
        tools.addItem(NSMenuItem(title: "Сравнить папки",
                                 action: #selector(NSApplication.hide(_:)), keyEquivalent: ""))
        tools.addItem(NSMenuItem.separator())
        tools.addItem(NSMenuItem(title: "Без действия", action: nil, keyEquivalent: ""))
        toolsItem.submenu = tools
        main.addItem(toolsItem)
        app.mainMenu = main

        let commands = CommandRegistry.commands()
        XCTAssertEqual(commands.map(\.title), ["Сравнить папки"],
                       "separators, actionless items and the app menu must all be skipped")
        XCTAssertEqual(commands.first?.group, "Инструменты")
    }

    /// macOS appends its own items to the Edit menu the first time it is used — Start Dictation,
    /// Emoji & Symbols, AutoFill. Freezing that menu's contents is what tells them from ours.
    func test_itemsTheSystemAddsToTheEditMenuAreNotOfferedAsCommands() {
        let app = NSApplication.shared
        let previous = app.mainMenu
        defer { app.mainMenu = previous }

        let main = NSMenu()
        main.addItem(NSMenuItem(title: "AppName", action: nil, keyEquivalent: ""))
        let editItem = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Правка")
        edit.addItem(NSMenuItem(title: "Копировать",
                                action: #selector(NSApplication.hide(_:)), keyEquivalent: "c"))
        editItem.submenu = edit
        main.addItem(editItem)
        app.mainMenu = main

        CommandRegistry.markSystemExtended(edit)

        // Now the system barges in, exactly as it does at runtime.
        edit.addItem(NSMenuItem(title: "Start Dictation",
                                action: #selector(NSApplication.hide(_:)), keyEquivalent: ""))
        edit.addItem(NSMenuItem(title: "Emoji & Symbols",
                                action: #selector(NSApplication.hide(_:)), keyEquivalent: ""))

        XCTAssertEqual(CommandRegistry.commands().map(\.title), ["Копировать"],
                       "items macOS added after the menu was built must not become commands")
    }

    /// The other half of the same rule, and the reason the freeze is per menu rather than global:
    /// a command the app adds later — recent folders, saved connections — must reach the palette
    /// with nothing to remember. A blanket snapshot would have dropped it without a word.
    func test_aCommandTheAppAddsLaterStillReachesThePalette() {
        let app = NSApplication.shared
        let previous = app.mainMenu
        defer { app.mainMenu = previous }

        let main = NSMenu()
        main.addItem(NSMenuItem(title: "AppName", action: nil, keyEquivalent: ""))
        let toolsItem = NSMenuItem(title: "Инструменты", action: nil, keyEquivalent: "")
        let tools = NSMenu(title: "Инструменты")
        toolsItem.submenu = tools
        main.addItem(toolsItem)
        app.mainMenu = main

        let editOnly = NSMenu(title: "Правка")
        CommandRegistry.markSystemExtended(editOnly)   // a different menu is frozen

        tools.addItem(NSMenuItem(title: "Новая команда",
                                 action: #selector(NSApplication.hide(_:)), keyEquivalent: ""))

        XCTAssertEqual(CommandRegistry.commands().map(\.title), ["Новая команда"],
                       "a command added to an unfrozen menu must appear on its own")
    }

    func test_registryDescendsIntoNestedMenusKeepingTheTopLevelGroup() {
        // Touching NSApplication.shared first: NSApp is nil in a bare test bundle, and it is an
        // implicitly unwrapped optional, so reading it would crash rather than fail the test.
        let app = NSApplication.shared
        let previous = app.mainMenu
        defer { app.mainMenu = previous }

        let main = NSMenu()
        main.addItem(NSMenuItem(title: "AppName", action: nil, keyEquivalent: ""))

        let toolsItem = NSMenuItem(title: "Инструменты", action: nil, keyEquivalent: "")
        let tools = NSMenu(title: "Инструменты")
        let nestedItem = NSMenuItem(title: "Архивы", action: nil, keyEquivalent: "")
        let nested = NSMenu(title: "Архивы")
        nested.addItem(NSMenuItem(title: "Упаковать",
                                  action: #selector(NSApplication.hide(_:)), keyEquivalent: ""))
        nestedItem.submenu = nested
        tools.addItem(nestedItem)
        toolsItem.submenu = tools
        main.addItem(toolsItem)
        app.mainMenu = main

        let commands = CommandRegistry.commands()
        // Имя подменю входит в название: «Сортировать по › Имя» и «Столбцы › Имя» — разные
        // команды, и голое «Имя» их бы смешало. Группа же — верхнее меню, как и была.
        XCTAssertEqual(commands.map(\.title), ["Архивы › Упаковать"])
        XCTAssertEqual(commands.first?.group, "Инструменты",
                       "a nested menu belongs to the top-level menu it hangs from")
    }
}
