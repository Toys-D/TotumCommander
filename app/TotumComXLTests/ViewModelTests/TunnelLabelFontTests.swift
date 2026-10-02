import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Шрифт подписей туннеля из настроек: одна настройка на все кнопки, в строку — на 3 pt
/// крупнее, при скрытых подписях не действует.
@MainActor
final class TunnelLabelFontTests: XCTestCase {

    func test_поУмолчаниюКакБыло_8ПодЗначком11ВСтроку() {
        XCTAssertEqual(TunnelLabelFont.size(TunnelLabelFont.defaultSize), 8)
        XCTAssertEqual(TunnelLabelFont.size(TunnelLabelFont.defaultSize, row: true), 11)
    }

    func test_настройкаМеняетОбаВида() {
        XCTAssertEqual(TunnelLabelFont.size(12), 12)
        XCTAssertEqual(TunnelLabelFont.size(12, row: true), 15)
    }

    func test_чужоеЗначениеВДиапазонеНастройки() {
        XCTAssertEqual(TunnelLabelFont.size(3), 7)
        XCTAssertEqual(TunnelLabelFont.size(40), 14)
        XCTAssertEqual(TunnelLabelFont.size(.nan), 8)
        XCTAssertEqual(TunnelLabelFont.size(.infinity), 8)
    }

    func test_подписиСкрыты_ПроцентыОбычногоРазмера() {
        XCTAssertEqual(TunnelLabelFont.size(12, labelsShown: false), 8)
    }

    func test_процентыСжимаютсяНеМельчеПрежнего() {
        XCTAssertEqual(TunnelLabelFont.readoutMinimumScale(8), 0.7, accuracy: 0.0001)
        for size in [CGFloat(9), 11, 14] {
            XCTAssertEqual(TunnelLabelFont.readoutMinimumScale(size) * size, 5.6, accuracy: 0.0001)
        }
        XCTAssertEqual(TunnelLabelFont.readoutMinimumScale(5), 1, "мелкий шрифт не растягивается")
    }

    /// Кнопка туннеля берёт размер из настройки: подпись крупнее — кнопка выше.
    func test_кнопкаТуннеляБерётРазмерИзНастройки() throws {
        let key = TunnelLabelFont.defaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        func height(_ stored: Double) throws -> CGFloat {
            UserDefaults.standard.set(stored, forKey: key)
            let renderer = ImageRenderer(content:
                DividerButtonView(icon: "folder", tooltip: "Загрузки", subtitle: "Загрузки", action: {})
                    .frame(width: 96))
            return try XCTUnwrap(renderer.nsImage, "кнопка нарисовалась").size.height
        }
        let small = try height(8)
        let large = try height(14)
        XCTAssertGreaterThan(large, small + 4, "подпись 14 pt выше подписи 8 pt")
    }

    /// Строка процентов наверху растёт вместе с настройкой. Раньше стопка туннеля сжимала её
    /// до предела по высоте, и при любом размере она была одинаково мелкой.
    func test_строкаПроцентовРастётВместеСНастройкой() throws {
        let keys = [TunnelLabelFont.defaultsKey, "centerDividerWidth", "dividerIconSpacing"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set(96.0, forKey: "centerDividerWidth")   // подписи видны
        // Сжатие проявлялось при просторной стопке — интервал 10, как в наборе по умолчанию.
        UserDefaults.standard.set(10.0, forKey: "dividerIconSpacing")

        func readoutInk(_ stored: Double) throws -> Int {
            UserDefaults.standard.set(stored, forKey: TunnelLabelFont.defaultsKey)
            let tunnel = CenterDividerView(activePanelPath: "/", isLeftPanelActive: true, splitRatio: 0.5,
                                           onSwap: {}, onCopy: {}, onMove: {}, onDelete: {}, onMkdir: {},
                                           onView: {}, onEdit: {}, onQuickLink: { _ in })
                .frame(width: 96, height: 900)
            let renderer = ImageRenderer(content: tunnel)
            renderer.scale = 2
            let bitmap = try XCTUnwrap(renderer.nsImage?.tiffRepresentation
                .flatMap { NSBitmapImageRep(data: $0) }, "туннель нарисовался")
            // Шапка: значок обмена, строка процентов, значок очереди. Значки от настройки
            // не зависят — разница в «чернилах» шапки целиком от строки процентов.
            let ground = try XCTUnwrap(bitmap.colorAt(x: 8, y: 8)?.usingColorSpace(.deviceRGB))
            var ink = 0
            for y in 0..<min(300, bitmap.pixelsHigh) {
                for x in 8..<(bitmap.pixelsWide - 8) {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if abs(c.redComponent - ground.redComponent) > 0.12
                        || abs(c.greenComponent - ground.greenComponent) > 0.12
                        || abs(c.blueComponent - ground.blueComponent) > 0.12 { ink += 1 }
                }
            }
            return ink
        }
        let small = try readoutInk(8)
        let large = try readoutInk(12)
        XCTAssertGreaterThan(Double(large), Double(small) * 1.15, "проценты при 12 pt крупнее, чем при 8 pt")
    }
}
