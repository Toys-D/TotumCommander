import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Папка, в которой стоит панель, в туннеле должна быть видна с первого взгляда — при
/// любом акценте. Серо-синий акцент светлой темы (#59676F) на значке неотличим от
/// обычного серого, поэтому мерка не цвет, а «чернила»: у значка «вы здесь» их заметно
/// больше — он жирнее и крупнее. Картинки — в FCXL_LOOK_DIR, чтобы посмотреть глазами.
@MainActor
final class TunnelButtonLookTests: XCTestCase {

    private func render(_ view: some View, name: String) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "кнопка нарисовалась (\(name))")
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
        if let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
        }
        return bitmap
    }

    /// Пиксели, отличные от фона, — по сырым байтам: NSColor при переводе между
    /// пространствами уводит оттенок, а фон в картинке лежит ровно тем цветом, что задан.
    private func ink(of bitmap: NSBitmapImageRep, background: Int) -> Int {
        guard let data = bitmap.bitmapData else { return 0 }
        let samples = bitmap.samplesPerPixel
        let alphaFirst = bitmap.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            let row = data + y * bitmap.bytesPerRow
            for x in 0..<bitmap.pixelsWide {
                let px = row + x * samples + alphaFirst
                if abs(Int(px[0]) - background) > 16 || abs(Int(px[1]) - background) > 16
                    || abs(Int(px[2]) - background) > 16 {
                    count += 1
                }
            }
        }
        return count
    }

    func test_папкаГдеСтоишьЗаметноЖирнееВОбеихТемах() throws {
        let key = PanelAppearanceSettings.accentColorHexKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        for (theme, scheme, accent, back) in [("светлая", ColorScheme.light, "#59676FFF", 245),
                                              ("тёмная", .dark, "#86A67CFF", 41)] {
            UserDefaults.standard.set(accent, forKey: key)
            let ground = Color(white: Double(back) / 255)

            func button(_ icon: String, _ label: String?, active: Bool) -> some View {
                DividerButtonView(icon: icon, tooltip: label ?? icon, subtitle: label,
                                  isActive: active, action: {})
                    .frame(width: 56)
                    .padding(6)
                    .background(ground)
                    .environment(\.colorScheme, scheme)
            }

            // Только значок: подпись одинаковая у обеих и лишь размыла бы мерку.
            let idle = try render(button("doc", nil, active: false),
                                  name: "тоннель-значок-обычный-\(theme)")
            let active = try render(button("doc", nil, active: true),
                                    name: "тоннель-значок-вы-здесь-\(theme)")
            let idleInk = ink(of: idle, background: back)
            let activeInk = ink(of: active, background: back)
            XCTAssertGreaterThan(idleInk, 0, "значок нарисовался (\(theme))")
            XCTAssertGreaterThan(Double(activeInk), Double(idleInk) * 1.3,
                                 "«вы здесь» жирнее и крупнее: \(activeInk) против \(idleInk) (\(theme))")

            // Ряд целиком — посмотреть, как соседствуют.
            let row = VStack(spacing: 4) {
                button("a.square.fill", "Программы", active: false)
                button("doc", "Документы", active: true)
                button("arrow.down.circle", "Загрузки", active: false)
            }
            .background(ground)
            _ = try render(row, name: "тоннель-ряд-\(theme)")
        }
    }
}
