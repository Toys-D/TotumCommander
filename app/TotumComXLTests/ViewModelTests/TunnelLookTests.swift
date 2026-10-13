import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Как выглядит туннель. Рисуется в картинку — это и проверка, что вид собирается:
/// SwiftUI умеет разваливаться только в работе.
@MainActor
final class TunnelLookTests: XCTestCase {

    private static var folder: String {
        ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] ?? NSTemporaryDirectory()
    }

    func test_туннельРисуетсяУзкимИШироким() throws {
        for (name, width) in [("узкий", 40.0), ("широкий", 130.0)] {
            UserDefaults.standard.set(width, forKey: "centerDividerWidth")
            let view = CenterDividerView(
                activePanelPath: NSHomeDirectory() + "/Documents",
                isLeftPanelActive: true,
                splitRatio: 0.5,
                onSwap: {}, onCopy: {}, onMove: {}, onDelete: {},
                onMkdir: {}, onView: {}, onEdit: {},
                onQuickLink: { _ in })
                .frame(height: 720)
                .background(Color(white: 0.15))
                .environment(\.colorScheme, .dark)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, "туннель нарисовался (\(name))")
            XCTAssertGreaterThan(image.size.height, 100)

            let data = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: data)?
                .representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: Self.folder + "/туннель-\(name).png"))
        }
        UserDefaults.standard.removeObject(forKey: "centerDividerWidth")
    }
}

/// Кайма туннеля видна на любом фоне: на светлом — цветом заголовка, на тёмном — белая.
final class TunnelBorderTests: XCTestCase {

    private func hex(_ value: String) -> NSColor {
        PanelAppearanceSettings.nsColor(from: value, fallback: .clear)
    }

    func test_наСветломФонеКаймаЦветомЗаголовкаСмешаннымСФоном() throws {
        let color = try XCTUnwrap(TunnelBorder.color(background: hex("#DADADA"), titlebar: hex("#5A666F"),
                                                     opacity: 0.45).usingColorSpace(.sRGB))
        let titlebar = try XCTUnwrap(hex("#5A666F").usingColorSpace(.sRGB))
        let background = try XCTUnwrap(hex("#DADADA").usingColorSpace(.sRGB))
        let mix = TunnelBorder.lightMix
        XCTAssertEqual(color.redComponent, titlebar.redComponent * mix + background.redComponent * (1 - mix),
                       accuracy: 0.01, "мягкий серый: цвет заголовка, смешанный с фоном")
        XCTAssertLessThan(mix, 0.5, "светлее, чем пополам")
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01, "сплошная, не прозрачная")
    }

    func test_наТёмномФонеКаймаБелая() throws {
        let color = try XCTUnwrap(TunnelBorder.color(background: hex("#434343"), titlebar: hex("#434343"),
                                                     opacity: 0.45).usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(color.alphaComponent, 0.45, accuracy: 0.01, "как была")
    }

    func test_безСвоегоЗаголовкаИлиСливающийся_тёмноСерая() throws {
        for titlebar in [nil, hex("#D6D6D6")] {
            let color = try XCTUnwrap(TunnelBorder.color(background: hex("#DADADA"), titlebar: titlebar,
                                                         opacity: 0.15).usingColorSpace(.sRGB))
            XCTAssertEqual(color.redComponent, 0xDA / 255.0 * (1 - TunnelBorder.lightMix), accuracy: 0.01,
                           "чёрный, смешанный с фоном")
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01, "видна и при малой прозрачности из набора")
        }
    }
}

/// Нижняя черта над полосой кнопок — того же цвета, что кайма туннеля.
@MainActor
final class TunnelBorderLineTests: XCTestCase {
    func test_чертаРисуетсяЦветомКаймы() throws {
        let line = TunnelBorderLine(frame: NSRect(x: 0, y: 0, width: 20, height: 1))
        let rep = try XCTUnwrap(line.bitmapImageRepForCachingDisplay(in: line.bounds))
        line.cacheDisplay(in: line.bounds, to: rep)
        let drawn = try XCTUnwrap(rep.colorAt(x: 5, y: 0)?.usingColorSpace(.sRGB))
        let expected = try XCTUnwrap(TunnelBorderLine.currentColor.usingColorSpace(.sRGB))
        XCTAssertEqual(drawn.redComponent, expected.redComponent, accuracy: 0.02)
        XCTAssertEqual(drawn.alphaComponent, expected.alphaComponent, accuracy: 0.02)
    }
}
