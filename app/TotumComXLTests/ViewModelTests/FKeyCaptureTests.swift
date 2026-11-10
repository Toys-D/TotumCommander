import AppKit
import ApplicationServices
import XCTest
@testable import TotumComXLApp

/// F-клавиши — этой программе, пока она впереди, даже если их держит другая (заменитель
/// Launchpad на F4). Только назначенные командам и только без ⌘ и ⌃.
@MainActor
final class FKeyCaptureTests: XCTestCase {

    // MARK: - Какие нажатия наши

    func test_голаяИСоШифтомИОпциейF4НаАСКомандойИКонтроломНет() {
        XCTAssertEqual(FKeyCapture.combo(code: 118, flags: []), KeyCombo.function(4))
        XCTAssertEqual(FKeyCapture.combo(code: 118, flags: .maskShift), KeyCombo.function(4, .shift))
        XCTAssertEqual(FKeyCapture.combo(code: 98, flags: .maskAlternate), KeyCombo.function(7, .option))
        XCTAssertEqual(FKeyCapture.combo(code: 118, flags: .maskSecondaryFn), KeyCombo.function(4),
                       "физическая Fn сочетание не меняет")
        XCTAssertNil(FKeyCapture.combo(code: 96, flags: .maskCommand), "⌘F5 — VoiceOver, не наше")
        XCTAssertNil(FKeyCapture.combo(code: 120, flags: .maskControl), "⌃F2 — строка меню, не наше")
        XCTAssertNil(FKeyCapture.combo(code: 0, flags: []), "буква A — не F-клавиша")
        XCTAssertNil(FKeyCapture.combo(code: 177, flags: []), "Spotlight на F4 без Fn — не F-клавиша")
    }

    func test_берутсяТеFклавишиЧтоНаПунктахМеню() {
        let menu = AppDelegate.buildMainMenu()
        let bound = FKeyCapture.boundFunctionCombos(in: menu)
        for number in 2...8 {
            XCTAssertTrue(bound.contains(KeyCombo.function(number)), "F\(number) — команда панели")
        }
        XCTAssertTrue(bound.contains(KeyCombo.function(4, .shift)), "⇧F4 — новый текстовый файл")
        XCTAssertFalse(bound.contains(KeyCombo.function(11)), "F11 ни на чём — не наше, это «Рабочий стол»")
    }

    func test_переназначенноеСочетаниеИдётЗаМеню() throws {
        let menu = AppDelegate.buildMainMenu()
        let edit = try XCTUnwrap(item(in: menu) { KeyCombo(item: $0) == KeyCombo.function(4) })
        edit.keyEquivalent = AppDelegate.fkey(10)
        let bound = FKeyCapture.boundFunctionCombos(in: menu)
        XCTAssertTrue(bound.contains(KeyCombo.function(10)), "правку отдали F10 — F10 и забираем")
    }

    // MARK: - Настоящий перехват

    /// Перехватчик забирает нажатие, и дальше по системе оно не идёт: стоящий за ним (как и
    /// владелец глобальной клавиши) его не видит, а программа получает. F19 — клавиша, которой
    /// ни у кого нет: если перехват не сработает, она уйдёт программе впереди и ничего не сделает.
    func test_забранноеНажатиеДальшеНеИдётАПрограммаЕгоПолучает() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "нужен «Универсальный доступ» у процесса тестов")
        let f19: Int64 = 80
        var delivered: [Int64] = []
        let capture = FKeyCapture(isWanted: { code, _ in code == f19 },
                                  isActive: { true },
                                  deliver: { delivered.append($0.getIntegerValueField(.keyboardEventKeycode)) })
        let behind = TailCounter(keyCode: f19)
        XCTAssertTrue(behind.install())
        defer { behind.uninstall() }

        XCTAssertTrue(capture.install())
        post(f19)
        spin(0.6)
        capture.uninstall()
        XCTAssertEqual(delivered, [f19, f19], "нажатие и отпускание — программе")
        XCTAssertEqual(behind.seen, 0, "дальше по системе не ушло")

        // Без перехвата то же нажатие доходит до стоящего за ним — значит, проверка честная.
        post(f19)
        spin(0.6)
        XCTAssertEqual(behind.seen, 2)
    }

    func test_вФонеНеЗабирает() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "нужен «Универсальный доступ» у процесса тестов")
        let f19: Int64 = 80
        var delivered = 0
        let capture = FKeyCapture(isWanted: { code, _ in code == f19 },
                                  isActive: { false },
                                  deliver: { _ in delivered += 1 })
        let behind = TailCounter(keyCode: f19)
        XCTAssertTrue(behind.install())
        defer { behind.uninstall() }
        XCTAssertTrue(capture.install())
        defer { capture.uninstall() }
        post(f19)
        spin(0.6)
        XCTAssertEqual(delivered, 0, "программа в фоне — клавиши чужие")
        XCTAssertEqual(behind.seen, 2)
    }

    // MARK: - Соглашение для заменителей Launchpad

    func test_launchShСтавитКлючUsesFunctionKeys() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/launch.sh"), encoding: .utf8)
        let key = FKeyCapture.infoPlistKey
        XCTAssertTrue(script.contains("Set :\(key) true"))
        XCTAssertTrue(script.contains("Add :\(key) bool true"))
    }

    // MARK: - Помощники

    private func item(in menu: NSMenu, where match: (NSMenuItem) -> Bool) -> NSMenuItem? {
        for item in menu.items {
            if match(item) { return item }
            if let sub = item.submenu, let found = self.item(in: sub, where: match) { return found }
        }
        return nil
    }

    private func post(_ code: Int64) {
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

/// Перехватчик в самом конце очереди: считает, сколько нажатий клавиши до него дошло.
private final class TailCounter {
    let keyCode: Int64
    var seen = 0
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(keyCode: Int64) { self.keyCode = keyCode }

    func install() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                eventsOfInterest: mask, callback: { _, _, event, info in
            if let info {
                let counter = Unmanaged<TailCounter>.fromOpaque(info).takeUnretainedValue()
                if event.getIntegerValueField(.keyboardEventKeycode) == counter.keyCode { counter.seen += 1 }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func uninstall() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
    }
}
