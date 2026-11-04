import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Цвет вкладки: чип должен понимать всё, что ему может записать панель выбора цвета,
/// а не только шесть знаков из набора. Панель пишет #RRGGBBAA — и такой цвет
/// сбрасывал вкладку на акцентный.
final class TabColorTests: XCTestCase {

    func test_цветИзПанелиВыбораПонимается() {
        let fromPicker = PanelAppearanceSettings.hexString(hue: 0.1, saturation: 0.8, brightness: 0.9)
        XCTAssertEqual(fromPicker.count, 9, "панель пишет #RRGGBBAA — таков вход")
        XCTAssertNotNil(TabColor.nsColor(fromHex: fromPicker))
        XCTAssertNotNil(TabColor.color(fromHex: fromPicker))
    }

    func test_цветПипеткиПонимается() {
        let sampled = PanelAppearanceSettings.hexString(from: NSColor(srgbRed: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        let parsed = try? XCTUnwrap(TabColor.nsColor(fromHex: sampled)?.usingColorSpace(.sRGB))
        XCTAssertEqual(parsed?.redComponent ?? -1, 0.2, accuracy: 0.01)
        XCTAssertEqual(parsed?.blueComponent ?? -1, 0.7, accuracy: 0.01)
    }

    func test_наборИзШестиЗнаковПонимается() {
        for preset in TabColor.presets {
            XCTAssertNotNil(TabColor.nsColor(fromHex: preset.hex), preset.hex)
        }
        XCTAssertNotNil(TabColor.nsColor(fromHex: PanelTab.terminalDefaultColorHex))
        XCTAssertNotNil(TabColor.nsColor(fromHex: PanelTab.remoteDefaultColorHex))
        XCTAssertNotNil(TabColor.nsColor(fromHex: "ff3b30"), "без решётки и в нижнем регистре")
    }

    func test_мусорНеЦвет() {
        XCTAssertNil(TabColor.nsColor(fromHex: ""))
        XCTAssertNil(TabColor.nsColor(fromHex: "#12345"))
        XCTAssertNil(TabColor.nsColor(fromHex: "#GGGGGG"))
    }
}
