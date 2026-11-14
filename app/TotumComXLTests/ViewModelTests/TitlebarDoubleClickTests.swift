import AppKit
import XCTest

@testable import TotumComXLApp

/// Двойной щелчок по строке заголовка главного окна: на macOS 27 узкая панель его глотает,
/// и программа выполняет системное действие сама.
@MainActor
final class TitlebarDoubleClickTests: XCTestCase {

    /// Окно, устроенное как главное: узкая панель и ряд кнопок справа в строке заголовка.
    private func makeWindow() -> (NSWindow, NSButton) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 450),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        window.toolbar = NSToolbar(identifier: "titlebar.dblclick.\(UUID().uuidString)")
        let button = NSButton(title: "к", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 40, height: 28)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = button
        window.addTitlebarAccessoryViewController(accessory)
        addTeardownBlock { MainActor.assumeIsolated { window.contentView = nil; window.close() } }
        return (window, button)
    }

    private func click(_ window: NSWindow, at point: NSPoint, count: Int) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: count, pressure: 1)!
    }

    /// Точка в пустом месте строки заголовка — левее ряда кнопок, правее имени окна.
    private func emptyTitlebarPoint(_ window: NSWindow) -> NSPoint {
        NSPoint(x: window.frame.width * 0.6,
                y: (window.contentLayoutRect.maxY + window.frame.height) / 2)
    }

    func test_действиеПоНастройкеСистемы() {
        XCTAssertEqual(TitlebarDoubleClick.action(setting: "Maximize", legacyMinimize: false), .zoom)
        XCTAssertEqual(TitlebarDoubleClick.action(setting: "Fill", legacyMinimize: false), .zoom)
        XCTAssertEqual(TitlebarDoubleClick.action(setting: "Minimize", legacyMinimize: false), .minimize)
        XCTAssertEqual(TitlebarDoubleClick.action(setting: "None", legacyMinimize: false), .none)
        XCTAssertEqual(TitlebarDoubleClick.action(setting: nil, legacyMinimize: true), .minimize,
                       "нет новой настройки — старый флажок «свернуть»")
        XCTAssertEqual(TitlebarDoubleClick.action(setting: nil, legacyMinimize: false), .zoom)
    }

    func test_двойнойЩелчокПоПустомуЗаголовку_разворачивает() {
        let (window, _) = makeWindow()
        let before = window.frame
        let event = click(window, at: emptyTitlebarPoint(window), count: 2)
        XCTAssertTrue(TitlebarDoubleClick.handle(event, in: window, action: .zoom), "щелчок забран")
        XCTAssertNotEqual(window.frame, before, "окно развернулось")
    }

    func test_одинарныйЩелчок_неТрогает() {
        let (window, _) = makeWindow()
        let before = window.frame
        XCTAssertFalse(TitlebarDoubleClick.handle(click(window, at: emptyTitlebarPoint(window), count: 1),
                                                  in: window, action: .zoom))
        XCTAssertEqual(window.frame, before)
    }

    func test_щелчокВСодержимом_неТрогает() {
        let (window, _) = makeWindow()
        let before = window.frame
        let inside = NSPoint(x: 200, y: window.contentLayoutRect.midY)
        XCTAssertFalse(TitlebarDoubleClick.handle(click(window, at: inside, count: 2),
                                                  in: window, action: .zoom))
        XCTAssertEqual(window.frame, before)
    }

    func test_двойнойЩелчокПоКнопкеЗаголовка_неРазворачивает() throws {
        let (window, button) = makeWindow()
        window.layoutIfNeeded()
        let before = window.frame
        let onButton = try XCTUnwrap(button.superview).convert(
            NSPoint(x: button.frame.midX, y: button.frame.midY), to: nil)
        XCTAssertFalse(TitlebarDoubleClick.handle(click(window, at: onButton, count: 2),
                                                  in: window, action: .zoom),
                       "двойной щелчок по кнопке — дело кнопки")
        XCTAssertEqual(window.frame, before)
    }

    func test_ничего_неДелаетНоЩелчокЗабирает() {
        let (window, _) = makeWindow()
        let before = window.frame
        XCTAssertTrue(TitlebarDoubleClick.handle(click(window, at: emptyTitlebarPoint(window), count: 2),
                                                 in: window, action: .none))
        XCTAssertEqual(window.frame, before)
    }
}
