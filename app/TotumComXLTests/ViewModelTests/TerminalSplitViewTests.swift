import AppKit
import XCTest
@testable import TotumComXLApp

/// Терминал из частей: настоящие оболочки во временной папке, окно без рамки.
@MainActor
final class TerminalSplitViewTests: XCTestCase {

    private var folder = ""
    private var window: NSWindow!
    private var split: TerminalSplitView!
    private var emptied = 0

    override func setUpWithError() throws {
        folder = NSTemporaryDirectory() + "части-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Оболочка тестов — со своими настройками и историей во временной папке: настоящий
        // ~/.zsh_history не трогаем (zsh переписывает его при выходе).
        setenv("ZDOTDIR", folder, 1)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                          styleMask: .borderless, backing: .buffered, defer: false)
        split = TerminalSplitView(directory: folder)
        split.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        split.onEmpty = { [weak self] in self?.emptied += 1 }
        window.contentView?.addSubview(split)
        split.start()
        split.layoutSubtreeIfNeeded()
    }

    override func tearDown() {
        split?.terminateAll()
        unsetenv("ZDOTDIR")
        try? FileManager.default.removeItem(atPath: folder)
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func test_whenCommandD_shouldSplitSideBySideAndFocusTheNewPart() throws {
        let first = split.activePane
        XCTAssertTrue(split.perform(keyCode: 2, modifiers: [.command]))
        XCTAssertEqual(split.paneCount, 2)
        let second = split.activePane
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(split.arrangement, .split(.sideBySide, [.pane(first), .pane(second)], [0.5, 0.5]))
        XCTAssertTrue(try XCTUnwrap(split.pane(second)).holdsKeyboard, "печатать — в новой части")
        XCTAssertGreaterThan(try XCTUnwrap(split.pane(second)).frame.minX, 390, "новая — справа")
    }

    func test_whenCommandShiftD_shouldSplitStacked() throws {
        let first = split.activePane
        XCTAssertTrue(split.perform(keyCode: 2, modifiers: [.command, .shift]))
        XCTAssertEqual(split.arrangement, .split(.stacked, [.pane(first), .pane(split.activePane)], [0.5, 0.5]))
        XCTAssertGreaterThan(try XCTUnwrap(split.pane(split.activePane)).frame.minY, 240, "новая — снизу")
    }

    /// ⌘W закрывает часть; последняя — сигнал владельцу закрыть вкладку.
    func test_whenCommandW_shouldClosePartsAndReportEmptyAtTheEnd() {
        let first = split.activePane
        split.perform(keyCode: 2, modifiers: [.command])
        XCTAssertTrue(split.perform(keyCode: 13, modifiers: [.command]))
        XCTAssertEqual(split.paneCount, 1)
        XCTAssertEqual(split.activePane, first, "фокус вернулся к оставшейся")
        XCTAssertEqual(split.arrangement, .pane(first))
        XCTAssertEqual(emptied, 0)
        split.perform(keyCode: 13, modifiers: [.command])
        XCTAssertEqual(emptied, 1, "последняя закрыта — вкладка закрывается")
    }

    func test_arrowsWithCommandOption_shouldMoveBetweenParts() {
        let left = split.activePane
        split.perform(keyCode: 2, modifiers: [.command])
        let right = split.activePane
        XCTAssertTrue(split.perform(keyCode: 123, modifiers: [.command, .option, .numericPad, .function]))
        XCTAssertEqual(split.activePane, left)
        XCTAssertTrue(split.perform(keyCode: 124, modifiers: [.command, .option]))
        XCTAssertEqual(split.activePane, right)
        XCTAssertFalse(split.moveFocus(.up), "выше никого нет")
    }

    /// ⌘T — новая вкладка у владельца; у нижней полосы вкладок нет — клавиша уходит дальше.
    func test_commandT_isPassedOnWithoutOwnerAndHandedToOwnerOtherwise() {
        XCTAssertFalse(split.perform(keyCode: 17, modifiers: [.command]))
        var asked: String?
        split.onNewTerminal = { asked = $0 }
        XCTAssertTrue(split.perform(keyCode: 17, modifiers: [.command]))
        XCTAssertNotNil(asked)
    }

    func test_otherKeys_arePassedOn() {
        XCTAssertFalse(split.perform(keyCode: 2, modifiers: [.control]), "⌃D — оболочке")
        XCTAssertFalse(split.perform(keyCode: 8, modifiers: [.command]), "⌘C — копированию")
        XCTAssertEqual(split.paneCount, 1)
    }

    /// `exit` в части закрывает её, как в iTerm.
    func test_whenShellExits_shouldCloseItsPart() throws {
        split.perform(keyCode: 2, modifiers: [.command])
        let second = split.activePane
        spin(0.5)
        try XCTUnwrap(split.pane(second)).sendBytes(Array("exit\n".utf8))
        let deadline = Date(timeIntervalSinceNow: 5)
        while split.paneCount > 1, Date() < deadline { spin() }
        XCTAssertEqual(split.paneCount, 1, "часть с вышедшей оболочкой закрылась")
        XCTAssertNil(split.pane(second))
        XCTAssertEqual(emptied, 0)
    }

    /// Новая часть открывается там, где оболочка стоит сейчас, а не где её запустили.
    func test_processDirectoryIsReadFromTheSystem() {
        XCTAssertEqual(SwiftTermContainerView.directory(ofProcess: getpid()),
                       FileManager.default.currentDirectoryPath)
        XCTAssertNil(SwiftTermContainerView.directory(ofProcess: 0))
    }

    // MARK: - Мышью

    private func item(_ menu: NSMenu, _ key: String) -> ShortcutMenuItem? {
        menu.items.compactMap { $0 as? ShortcutMenuItem }.first { $0.title == L(key) }
    }

    /// Меню правого щелчка: те же действия, что клавиши, с клавишами справа.
    func test_contextMenuOffersTheSameActionsWithTheirKeys() throws {
        let menu = split.contextMenu(for: split.activePane)
        XCTAssertEqual(item(menu, "terminal.splitSideBySide")?.shortcutHint, "⌘D")
        XCTAssertEqual(item(menu, "terminal.splitStacked")?.shortcutHint, "⇧⌘D")
        XCTAssertEqual(item(menu, "terminal.closePane")?.shortcutHint, "⌘W")
        XCTAssertEqual(item(menu, "terminal.copy")?.isEnabled, false, "нечего копировать")
        XCTAssertNil(item(menu, "terminal.newTab"), "у полосы без вкладок пункта нет")
        split.onNewTerminal = { _ in }
        XCTAssertNotNil(item(split.contextMenu(for: split.activePane), "terminal.newTab"))

        try XCTUnwrap(item(menu, "terminal.splitStacked")).run()
        XCTAssertEqual(split.paneCount, 2)
        XCTAssertEqual(split.arrangement.panes.count, 2)
        guard case .split(.stacked, _, _) = split.arrangement else { return XCTFail("не под низ") }
    }

    /// Пункт меню части действует на ЭТУ часть, даже если активна другая.
    func test_contextMenuActsOnItsOwnPart() throws {
        let first = split.activePane
        split.split(.sideBySide)
        let menu = split.contextMenu(for: first)
        try XCTUnwrap(item(menu, "terminal.closePane")).run()
        XCTAssertNil(split.pane(first))
        XCTAssertEqual(split.paneCount, 1)
    }

    /// Кнопки — в своей полоске над частью, а не поверх терминала: текст они не закрывают.
    func test_headerButtonsSitAboveThePartAndActOnIt() throws {
        let left = split.activePane
        split.split(.sideBySide)
        let right = split.activePane
        let leftHeader = try XCTUnwrap(split.header(left))
        let leftPane = try XCTUnwrap(split.pane(left))
        XCTAssertEqual(leftHeader.frame.height, TerminalSplitView.headerHeight)
        XCTAssertEqual(leftPane.frame.minY, leftHeader.frame.maxY, accuracy: 0.5, "терминал начинается под полоской")
        XCTAssertFalse(leftHeader.frame.intersects(leftPane.frame), "полоска не заходит на терминал")
        XCTAssertTrue(try XCTUnwrap(split.header(right)).isActive, "активная подкрашена")
        XCTAssertFalse(leftHeader.isActive)

        leftHeader.controls.buttons[1].performClick(nil)   // под низ — левую
        XCTAssertEqual(split.paneCount, 3)
        guard case .split(.sideBySide, let kids, _) = split.arrangement,
              case .split(.stacked, _, _) = kids[0] else { return XCTFail("делилась не левая") }

        try XCTUnwrap(split.header(right)).controls.buttons[2].performClick(nil)   // закрыть правую
        XCTAssertNil(split.pane(right))
        XCTAssertNil(split.header(right), "полоска уходит вместе с частью")
    }

    /// Одна часть — полоска есть (с неё делят), но не подкрашена: выбирать не из чего.
    func test_singlePartHasPlainHeader() throws {
        let header = try XCTUnwrap(split.header(split.activePane))
        XCTAssertFalse(header.isActive)
        XCTAssertFalse(header.controls.isHidden)
    }

    func test_registryStopsEveryPart() {
        split.perform(keyCode: 2, modifiers: [.command])
        let id = UUID()
        TerminalProcessRegistry.shared.register(split, for: id)
        TerminalProcessRegistry.shared.terminate(tabID: id)
        spin(0.3)
        XCTAssertEqual(emptied, 0, "остановка владельцем — не повод закрывать вкладку ещё раз")
    }
}
