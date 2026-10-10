import AppKit
import XCTest
@testable import TotumComXLApp

/// Ореол курсора под ползунком размытия: растёт ровно, без дрожи.
@MainActor
final class FeatheredCursorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FeatheredCursor.dropCache()
    }

    override func tearDown() {
        FeatheredCursor.dropCache()
        super.tearDown()
    }

    func test_размытиеПечётсяПолушагами() {
        XCTAssertEqual(FeatheredCursor.quantized(12.6), 12.5)
        XCTAssertEqual(FeatheredCursor.quantized(12.76), 13)
        XCTAssertEqual(FeatheredCursor.quantized(0), 0)
        let bar = NSSize(width: 300, height: 19)
        let a = FeatheredCursor.image(barSize: bar, color: .systemBlue, blur: 12.6, corner: 8)
        XCTAssertTrue(a === FeatheredCursor.image(barSize: bar, color: .systemBlue, blur: 12.7, corner: 8),
                      "одно и то же значение с точностью до полпункта — та же картинка")
        XCTAssertFalse(a === FeatheredCursor.image(barSize: bar, color: .systemBlue, blur: 13.3, corner: 8),
                       "следующие полпункта — новая выпечка")
    }

    /// Между выпечками ползунок двигается, а картинка — одна и та же: рисоваться она обязана
    /// одинаково, пиксель в пиксель. Раньше прямоугольник пересчитывался от текущего значения,
    /// и картинку растягивало в него — курсор дышал под ползунком.
    func test_междуВыпечкамиКурсорНеДышит() throws {
        func render(blur: CGFloat) throws -> Data {
            let size = NSSize(width: 360, height: 120)
            let image = NSImage(size: size, flipped: true) { rect in
                FeatheredCursor.draw(cellFrame: NSRect(x: 20, y: 50, width: 320, height: 20),
                                     color: .systemBlue, blur: blur, corner: 8,
                                     widthFraction: 1, heightFraction: 0.8,
                                     anchorX: 0.5, anchorY: 0.5, offsetX: 0, offsetY: 0)
                return true
            }
            return try XCTUnwrap(image.tiffRepresentation)
        }
        XCTAssertEqual(try render(blur: 13.3), try render(blur: 13.6), "та же выпечка — тот же рисунок")
        XCTAssertNotEqual(try render(blur: 13.3), try render(blur: 13.8), "новые полпункта — ореол шире")
    }

    /// Картинка рисуется в своём размере: ни растяжения, ни сжатия при любом размытии.
    func test_картинкаРисуетсяВСвоёмРазмере() {
        for blur in [0, 3.2, 12.6, 29.9] as [CGFloat] {
            let bar = NSSize(width: 300, height: 19)
            let image = FeatheredCursor.image(barSize: bar, color: .systemBlue, blur: blur, corner: 8)
            let pad = FeatheredCursor.padding(for: FeatheredCursor.quantized(blur))
            XCTAssertEqual(image.size.width, bar.width + 2 * pad, accuracy: 0.001, "\(blur)")
            XCTAssertEqual(image.size.height, bar.height + 2 * pad, accuracy: 0.001, "\(blur)")
        }
    }
}
