import SwiftUI
import AppKit
import XCTest
@testable import TotumComXLApp

/// Окно «Сочетания клавиш» открывают кнопкой в настройках — и его кнопки должны нажиматься.
///
/// Проверка щёлкает мышью, как человек (MouseLikeAPerson): по «Настроить сочетания…» в разделе
/// «Клавиши», потом по кнопкам открывшегося окна. Окно, открытое прямо из действия кнопки,
/// а не через `fcxlPresentModal`, выходило с мёртвыми кнопками: «Закрыть» нажималась, а окно
/// стояло.
///
/// Настройки — отдельный набор на время проверки: настоящие сочетания человека не трогаются.
@MainActor
final class KeyBindingsEditorClickTests: XCTestCase {

    private var saved: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        MouseLikeAPerson.setAccessibility(true)
        saved = KeyBindings.defaults
        suite = "fcxl.tests.keys.click.\(UUID().uuidString)"
        KeyBindings.defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        MouseLikeAPerson.setAccessibility(false)
        KeyBindings.defaults.removePersistentDomain(forName: suite)
        KeyBindings.defaults = saved
        super.tearDown()
    }

    func test_окноИзНастроекЗакрываетсяКнопкойЗакрыть() throws {
        let outcome = try openEditorFromSettings { modal in
            MouseLikeAPerson.press(L("button.close"), in: modal)
        }
        XCTAssertTrue(outcome.opened, "окно сочетаний не открылось")
        XCTAssertTrue(outcome.pressed, "в окне нет кнопки «Закрыть»")
        XCTAssertFalse(outcome.stuck, "«Закрыть» нажата, а окно не закрылось")
        XCTAssertNil(NSApp.modalWindow)
    }

    /// Остальные кнопки окна живы так же: «Все команды» переключает список, щелчок по клавише
    /// команды ставит её на запись, «Отмена» снимает запись.
    func test_вОкнеИзНастроекНажимаютсяИДругиеКнопки() throws {
        NSApp.mainMenu = AppDelegate.buildMainMenu()
        let press = L("settings.keys.editor.press")
        var stage = 0
        let outcome = try openEditorFromSettings { modal in
            switch stage {
            case 0:     // «Все команды» — в списке появляются команды без клавиши
                if MouseLikeAPerson.press(Self.prefix(of: "settings.keys.editor.all"), in: modal, prefix: true) { stage = 1 }
            case 1:
                if MouseLikeAPerson.element(L("settings.keys.editor.assign"), in: modal) != nil { stage = 2 }
            case 2:     // щелчок по первой видимой клавише — она ждёт нажатия
                if let cap = Self.visibleKeyCap(in: modal) {
                    MouseLikeAPerson.click(cap, in: modal)
                    stage = 3
                }
            case 3:
                if MouseLikeAPerson.element(press, in: modal) != nil { stage = 4 }
            case 4:     // «Отмена» — запись снята
                if MouseLikeAPerson.press(L("button.cancel"), in: modal) { stage = 5 }
            case 5:
                if MouseLikeAPerson.element(press, in: modal) == nil { stage = 6 }
            default:
                return MouseLikeAPerson.press(L("button.close"), in: modal)
            }
            return false
        }
        XCTAssertGreaterThan(stage, 0, "нет вкладки «Все команды»")
        XCTAssertGreaterThan(stage, 1, "«Все команды» не переключила список")
        XCTAssertGreaterThan(stage, 2, "в списке не видно ни одной клавиши")
        XCTAssertGreaterThan(stage, 3, "щелчок по клавише не поставил команду на запись")
        XCTAssertGreaterThan(stage, 4, "нет кнопки «Отмена» у записи")
        XCTAssertGreaterThan(stage, 5, "«Отмена» не сняла запись")
        XCTAssertTrue(outcome.pressed, "нет кнопки «Закрыть»")
        XCTAssertFalse(outcome.stuck, "«Закрыть» нажата, а окно не закрылось")
        XCTAssertTrue(KeyBindings.overrides.isEmpty, "сочетания поменялись сами")
    }

    // MARK: - Как человек

    private struct Outcome {
        var opened = false
        var pressed = false
        var stuck = false
    }

    /// Ставит раздел «Клавиши» в окно, щёлкает «Настроить сочетания…» и, пока окно сочетаний
    /// открыто, раз в десятую секунды отдаёт его `step`. `step` говорит «нажал последнее» —
    /// после этого окно обязано закрыться; не закрылось за шесть секунд — значит, застряло,
    /// и проверка закрывает его сама, чтобы не повиснуть.
    private func openEditorFromSettings(_ step: @escaping @MainActor (NSWindow) -> Bool) throws -> Outcome {
        let settings = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 720),
                                styleMask: [.titled], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        settings.contentView = NSHostingView(rootView: SettingsKeysView())
        settings.makeKeyAndOrderFront(nil)
        defer { settings.orderOut(nil) }
        settings.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        var outcome = Outcome()
        var started: Date?
        // Часы на общих режимах крутятся и внутри модального окна — ими и нажимаем.
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let modal = NSApp.modalWindow else { return }
                outcome.opened = true
                let since = started ?? Date()
                started = since
                if !outcome.pressed { outcome.pressed = step(modal) }
                if Date().timeIntervalSince(since) > 6 {
                    outcome.stuck = true
                    NSApp.abortModal()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }

        XCTAssertTrue(MouseLikeAPerson.press(L("settings.keys.edit"), in: settings), "нет кнопки «Настроить сочетания…»")

        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, !(outcome.opened && NSApp.modalWindow == nil) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // Окно сжимается и закрывается за 0,18 с — дождёмся, чтобы не мешало следующей проверке.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return outcome
    }

    /// Начало строки до первой подстановки: «Все команды: %d» → «Все команды:».
    private static func prefix(of key: String) -> String {
        String(L(key).prefix { $0 != "%" })
    }

    /// Первая клавиша команды, которую видно в окне: список длинный, остальные — под краем
    /// прокрутки, и щелчок по ним ушёл бы мимо. Клавишу выдаёт подсказка, а не надпись —
    /// надпись у каждой своя. Снизу окна — полоса кнопок, над ней и ищется.
    private static func visibleKeyCap(in window: NSWindow) -> NSRect? {
        MouseLikeAPerson.elements(withHelp: L("settings.keys.editor.capTip"), in: window)
            .first { window.frame.contains(NSPoint(x: $0.midX, y: $0.midY)) && $0.minY > window.frame.minY + 90 }
    }
}
