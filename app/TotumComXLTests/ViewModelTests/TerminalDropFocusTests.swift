import AppKit
import XCTest
@testable import TotumComXLApp

/// Бросил папку в терминал — дальше печатаешь там же: путь вставлен, и клавиатура у терминала,
/// а не у списка, откуда тащили.
@MainActor
final class TerminalDropFocusTests: XCTestCase {

    private var folder = ""
    private var container: SwiftTermContainerView!
    private var window: NSWindow!

    override func setUpWithError() throws {
        folder = NSTemporaryDirectory() + "бросок-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Оболочка тестов — со своими настройками и историей во временной папке: настоящий
        // ~/.zsh_history не трогаем (zsh переписывает его при выходе).
        setenv("ZDOTDIR", folder, 1)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: .borderless, backing: .buffered, defer: false)
        container = SwiftTermContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(container)
        container.startTerminal(directory: folder)
        // Терминал при старте сам берёт фокус — следующим тактом; пусть возьмёт, потом отнимем.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    override func tearDown() {
        container?.terminateProcess()
        unsetenv("ZDOTDIR")
        try? FileManager.default.removeItem(atPath: folder)
        super.tearDown()
    }

    private var terminal: NSView? {
        container.subviews.first { $0.className.contains("TerminalView") }
    }

    func test_whenFolderDroppedFromPanel_shouldGiveKeyboardToTerminal() throws {
        let list = NSTextView(frame: NSRect(x: 400, y: 0, width: 200, height: 300))
        window.contentView?.addSubview(list)
        window.makeFirstResponder(list)
        XCTAssertTrue(window.firstResponder === list, "клавиатура у списка, откуда тащат")

        XCTAssertTrue(container.insertDroppedPaths([URL(fileURLWithPath: folder)], fromAnotherApp: false))

        let terminal = try XCTUnwrap(terminal)
        XCTAssertTrue(window.firstResponder === terminal, "после броска печатают в терминале")
    }

    func test_whenNothingDropped_shouldLeaveFocusAlone() {
        let list = NSTextView(frame: NSRect(x: 400, y: 0, width: 200, height: 300))
        window.contentView?.addSubview(list)
        window.makeFirstResponder(list)
        XCTAssertFalse(container.insertDroppedPaths([], fromAnotherApp: false))
        XCTAssertTrue(window.firstResponder === list)
    }
}
