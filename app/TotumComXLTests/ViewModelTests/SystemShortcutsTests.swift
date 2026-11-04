import XCTest
@testable import TotumComXLApp

/// Ярлык macOS «Показать рабочий стол» сидит на F11 и забирает клавишу раньше программ.
/// Разбор списка важен тем, что ОТСУТСТВИЕ записи означает включённый ярлык: список
/// заводится только при первой правке, а в свежей учётной записи его нет вовсе — именно
/// там человек и видит разъезжающиеся окна вместо громкости.
final class SystemShortcutsTests: XCTestCase {

    private func list(enabled: Bool?) -> [String: Any] {
        guard let enabled else { return [:] }
        return ["36": ["enabled": enabled,
                       "value": ["parameters": [65535, 103, 8_388_608], "type": "standard"]]]
    }

    func test_записиНетЗначитЯрлыкРаботает() {
        XCTAssertEqual(SystemShortcuts.heldKeys(in: list(enabled: nil)), ["F11"])
        XCTAssertEqual(SystemShortcuts.heldKeys(in: ["79": ["enabled": true]]), ["F11"],
                       "чужие записи не считаются за нашу")
    }

    func test_включённыйЯрлыкДержитКлавишу() {
        XCTAssertEqual(SystemShortcuts.heldKeys(in: list(enabled: true)), ["F11"])
    }

    func test_выключенныйЯрлыкКлавишуОтпускает() {
        XCTAssertTrue(SystemShortcuts.heldKeys(in: list(enabled: false)).isEmpty)
    }

    /// Числом macOS пишет это чаще, чем логическим значением.
    func test_состояниеЧисломПонимается() {
        let asNumber: [String: Any] = ["36": ["enabled": NSNumber(value: 0)]]
        XCTAssertTrue(SystemShortcuts.heldKeys(in: asNumber).isEmpty)
        XCTAssertEqual(SystemShortcuts.heldKeys(in: ["36": ["enabled": NSNumber(value: 1)]]), ["F11"])
    }

    /// Выключая, сохраняем клавишу ярлыка: человек включит его обратно в системных
    /// настройках, и F11 там останется F11.
    func test_выключеннаяЗаписьХранитКлавишу() throws {
        let hotkey = try XCTUnwrap(SystemShortcuts.onVolumeKeys.first)
        let entry = SystemShortcuts.disabledEntry(for: hotkey)
        XCTAssertEqual(entry["enabled"] as? Bool, false)
        let value = try XCTUnwrap(entry["value"] as? [String: Any])
        XCTAssertEqual(value["parameters"] as? [Int], [65535, 103, 8_388_608])
        XCTAssertEqual(value["type"] as? String, "standard")
        XCTAssertTrue(SystemShortcuts.heldKeys(in: ["36": entry]).isEmpty,
                      "своя же запись читается как выключенная")
    }

    func test_переводыКнопкиЕсть() {
        for key in ["settings.keys.sound", "settings.keys.sound.held",
                    "settings.keys.sound.free", "settings.keys.sound.ours"] {
            XCTAssertNotEqual(L(key), key, key)
        }
    }
}
