import AppKit
import SwiftUI
import XCTest

@testable import TotumComXLApp

/// Подписи и значки панели на цвете заголовка: тёмный цвет под светлой темой делал их
/// чёрными на грифельном — не прочесть. Облик выбирается по светлоте фона, порог — тот,
/// где белый текст начинает контрастировать лучше чёрного.
final class ContrastAppearanceTests: XCTestCase {

    private func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    func test_светлотаКрайнихЦветов() {
        XCTAssertEqual(ContrastAppearance.luminance(of: .white), 1, accuracy: 0.001)
        XCTAssertEqual(ContrastAppearance.luminance(of: .black), 0, accuracy: 0.001)
        XCTAssertEqual(ContrastAppearance.luminance(of: rgb(0x808080)), 0.216, accuracy: 0.005,
                       "средний серый: sRGB-кривая снята, а не поделено на 255")
    }

    func test_тёмныйЗаголовокПолучаетСветлыеПодписи() {
        let slate = rgb(0x5c6b73)   // цвет заголовка со снимка пользователя
        XCTAssertTrue(ContrastAppearance.isDark(slate))
        XCTAssertEqual(ContrastAppearance.appearance(on: slate)?.name, .darkAqua)
        XCTAssertEqual(ContrastAppearance.appearance(on: rgb(0x8b0000))?.name, .darkAqua, "тёмно-красный — тоже тёмный")
        XCTAssertEqual(ContrastAppearance.appearance(on: .black)?.name, .darkAqua)
    }

    func test_светлыйЗаголовокОставляетТёмныеПодписи() {
        XCTAssertEqual(ContrastAppearance.appearance(on: .white)?.name, .aqua)
        XCTAssertEqual(ContrastAppearance.appearance(on: rgb(0x808080))?.name, .aqua,
                       "на среднем сером чёрный текст контрастнее белого (5.3 против 3.9)")
        XCTAssertEqual(ContrastAppearance.appearance(on: rgb(0xffb6b6))?.name, .aqua, "светло-красный")
    }

    func test_безСвоегоЦветаКнопкиСледуютОкну() {
        XCTAssertNil(ContrastAppearance.appearance(on: nil))
    }

    // MARK: - Полосы окна (SwiftUI)

    func test_схемаПолосыПоЕёЦвету() {
        XCTAssertEqual(PanelAppearanceSettings.chromeColorScheme(hex: "#5c6b73", fallback: .light), .dark)
        XCTAssertEqual(PanelAppearanceSettings.chromeColorScheme(hex: "#f0f0f0", fallback: .dark), .light)
        XCTAssertEqual(PanelAppearanceSettings.chromeColorScheme(hex: "", fallback: .light), .light, "без цвета — как тема")
        XCTAssertEqual(PanelAppearanceSettings.chromeColorScheme(hex: "чепуха", fallback: .dark), .dark)
        XCTAssertEqual(PanelAppearanceSettings.colorScheme(on: rgb(0x5c6b73)), .dark)
        XCTAssertEqual(PanelAppearanceSettings.colorScheme(on: .white), .light)
    }

    /// Измерено, а не предположено: подмена схемы в поддереве действительно перекрашивает
    /// системные цвета — `Color.primary` под светлым обликом окна на тёмной полосе становится
    /// белым, а без своего цвета полосы остаётся чёрным.
    @MainActor
    func test_наТёмнойПолосеСистемныйЦветТекстаСветлеет() throws {
        let key = PanelAppearanceSettings.interfaceColorHexLightKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        func centerBrightness(hex: String) throws -> CGFloat {
            UserDefaults.standard.set(hex, forKey: key)
            let view = Rectangle().fill(Color.primary).frame(width: 40, height: 40).interfaceBackground()
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let pixel = try XCTUnwrap(rep.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
            return (pixel.redComponent + pixel.greenComponent + pixel.blueComponent) / 3
        }
        XCTAssertLessThan(try centerBrightness(hex: ""), 0.2, "светлая тема без своего цвета — чёрный текст")
        XCTAssertGreaterThan(try centerBrightness(hex: "#5c6b73"), 0.8, "на грифельной полосе — белый")
        XCTAssertLessThan(try centerBrightness(hex: "#f0f0f0"), 0.2, "на светлой полосе — чёрный")
    }
}
