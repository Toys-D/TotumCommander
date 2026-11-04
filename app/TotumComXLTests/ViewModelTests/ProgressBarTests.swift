import AppKit
import XCTest

@testable import TotumComXLApp

/// Полоска выполнения: своя, в цвете программы. Системная всегда синяя — акцент у неё
/// общесистемный, а не наш.
@MainActor
final class ProgressBarTests: XCTestCase {

    func test_доляНеВыходитЗаПределы() {
        let bar = FCXLProgressBar()
        bar.value = 0.5
        XCTAssertEqual(bar.value, 0.5)
        bar.value = 2
        XCTAssertEqual(bar.value, 1, "больше единицы — ошибка счёта, а не повод рисовать за краем")
        bar.value = -1
        XCTAssertEqual(bar.value, 0)
    }

    func test_бегунокНеопределённостиПроходитДорожкуИНачинаетСнова() {
        let start = FCXLProgressBar.runnerOrigin(tick: 0, ticksPerRun: 45)
        XCTAssertEqual(start, -Double(FCXLProgressBar.runnerWidth), accuracy: 0.001,
                       "в начале бегунок весь за левым краем")
        let middle = FCXLProgressBar.runnerOrigin(tick: 22, ticksPerRun: 45)
        XCTAssertGreaterThan(middle, 0)
        XCTAssertLessThan(middle, 1)
        XCTAssertEqual(FCXLProgressBar.runnerOrigin(tick: 45, ticksPerRun: 45), start, accuracy: 0.001,
                       "круг замкнулся")
        // Движение всегда вперёд внутри круга.
        var previous = start
        for tick in 1..<45 {
            let now = FCXLProgressBar.runnerOrigin(tick: tick, ticksPerRun: 45)
            XCTAssertGreaterThan(now, previous)
            previous = now
        }
    }

    /// Заливка — цветом акцента программы, а не системным синим.
    func test_заливкаВЦветеАкцента() throws {
        let key = PanelAppearanceSettings.accentColorHexKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("#FF0000", forKey: key)

        let bar = FCXLProgressBar(frame: NSRect(x: 0, y: 0, width: 100, height: 14))
        let colour = try XCTUnwrap(bar.fillColor.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(colour.redComponent, 0.9, "заливка берёт акцент: \(colour)")
        XCTAssertLessThan(colour.greenComponent, 0.1)
        XCTAssertEqual(colour.redComponent,
                       PanelAppearanceSettings.accentNSColor.usingColorSpace(.sRGB)!.redComponent,
                       accuracy: 0.001)
    }

    func test_геометрияЗаливкиИБегунка() {
        let bounds = NSRect(x: 0, y: 0, width: 200, height: 14)
        let track = FCXLProgressBar.trackRect(in: bounds)
        XCTAssertEqual(track.height, 6, accuracy: 0.001, "дорожка в шесть точек по центру")
        XCTAssertEqual(track.midY, bounds.midY, accuracy: 0.001)

        XCTAssertTrue(FCXLProgressBar.fillRect(track: track, value: 0).isEmpty, "ноль — не рисуем")
        XCTAssertEqual(FCXLProgressBar.fillRect(track: track, value: 0.5).width, 100, accuracy: 0.001)
        XCTAssertEqual(FCXLProgressBar.fillRect(track: track, value: 1).width, 200, accuracy: 0.001)
        XCTAssertEqual(FCXLProgressBar.fillRect(track: track, value: 2).width, 200, accuracy: 0.001,
                       "за край не вылезаем")
        XCTAssertEqual(FCXLProgressBar.fillRect(track: track, value: 0.001).width, track.height,
                       accuracy: 0.001, "совсем узкая заливка не вырождается в точку")

        // Бегунок целиком за левым краем не рисуется, в середине — виден и не шире своей доли.
        XCTAssertTrue(FCXLProgressBar.runnerRect(track: track, origin: -0.3).isEmpty)
        let middle = FCXLProgressBar.runnerRect(track: track, origin: 0.4)
        XCTAssertEqual(middle.width, track.width * FCXLProgressBar.runnerWidth, accuracy: 0.001)
        XCTAssertTrue(track.contains(middle))
    }
}
