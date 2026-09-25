import AppKit
import XCTest
@testable import TotumComXLApp

/// Цвет выделенных файлов — свой, из «Дизайна»; пока не задан — акцент, как было.
final class SelectedNameColorTests: XCTestCase {

    private let keys = [PanelAppearanceSettings.selectedNameColorHexKey,
                        PanelAppearanceSettings.selectedNameColorHexLightKey,
                        PanelAppearanceSettings.selectedNameColorHexDarkKey]
    private var saved: [String: String?] = [:]

    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.string(forKey: key) }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] ?? nil { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func rgb(_ c: NSColor) -> [Int] {
        let s = c.usingColorSpace(.sRGB)!
        return [s.redComponent, s.greenComponent, s.blueComponent].map { Int(round($0 * 255)) }
    }

    func test_безНастройки_ЦветАкцента() {
        XCTAssertEqual(rgb(PanelAppearanceSettings.selectedNameNSColor),
                       rgb(PanelAppearanceSettings.accentNSColor))
    }

    func test_свойЦвет_БерётсяИзНастройки() {
        UserDefaults.standard.set("#1A2B3C", forKey: PanelAppearanceSettings.selectedNameColorHexKey)
        XCTAssertEqual(rgb(PanelAppearanceSettings.selectedNameNSColor), [0x1A, 0x2B, 0x3C])
    }

    /// Цвет входит в список «по темам»: при смене темы действующий ключ берётся из своего.
    func test_цветХранитсяОтдельноДляТем() {
        let triple = PanelAppearanceSettings.themedColorKeys.first {
            $0.effective == PanelAppearanceSettings.selectedNameColorHexKey
        }
        XCTAssertEqual(triple?.light, PanelAppearanceSettings.selectedNameColorHexLightKey)
        XCTAssertEqual(triple?.dark, PanelAppearanceSettings.selectedNameColorHexDarkKey)
    }
}
