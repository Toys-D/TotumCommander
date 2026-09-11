import AppKit
import XCTest
@testable import TotumComXLApp

/// Где стоят картинка и имя внутри квадратной ячейки вида «Эскизы».
///
/// Курсор закрашивает всю ячейку; пока содержимое прижималось к верху, пустой остаток
/// оставался снизу — и подсветка выглядела сдвинутой вниз.
final class ThumbnailCellLayoutTests: XCTestCase {

    private let nameArea = ThumbnailCellLayout.nameHeight(font: .systemFont(ofSize: 11))

    func test_имяЗанимаетСтрокуШрифта() {
        let font = NSFont.systemFont(ofSize: 11)
        let line = (font.ascender - font.descender + font.leading).rounded(.up)
        // По умолчанию одна строка: имя в эскизах обрезается многоточием, а не переносится.
        XCTAssertEqual(ThumbnailCellLayout.nameHeight(font: font), line)
        XCTAssertEqual(ThumbnailCellLayout.nameHeight(font: font, lines: 2), line * 2)
        // Крупнее шрифт — выше место под имя.
        XCTAssertGreaterThan(ThumbnailCellLayout.nameHeight(font: .systemFont(ofSize: 16)),
                             ThumbnailCellLayout.nameHeight(font: font))
    }

    /// Пустое место делится пополам: сверху ровно столько же, сколько снизу.
    func test_содержимоеСтоитВСередине() {
        let cell: CGFloat = 210
        let preview: CGFloat = 134
        let inset = ThumbnailCellLayout.topInset(cellSize: cell, previewSize: preview, nameHeight: nameArea)
        let content = preview + ThumbnailCellLayout.iconToName + nameArea
        let below = cell - inset - content
        XCTAssertEqual(inset, below, accuracy: 1, "сверху и снизу — поровну")
        XCTAssertGreaterThan(inset, ThumbnailCellLayout.minimumTopInset,
                             "при 210 пустого места хватает на настоящий отступ")
    }

    /// Мелкая ячейка: содержимое выше неё самой — тогда прижимаем к верху, а не срезаем
    /// картинке шапку.
    func test_когдаСодержимоеНеВлезает_ПрижимаетсяКВерху() {
        let inset = ThumbnailCellLayout.topInset(cellSize: 60, previewSize: 38, nameHeight: nameArea)
        XCTAssertEqual(inset, ThumbnailCellLayout.minimumTopInset)
        XCTAssertEqual(ThumbnailCellLayout.topInset(cellSize: 0, previewSize: 134, nameHeight: nameArea),
                       ThumbnailCellLayout.minimumTopInset)
    }

    /// Прежнее поведение — постоянные шесть точек сверху — на крупной ячейке уводило
    /// содержимое вверх, и это то, что было видно на экране.
    func test_прежнийПостоянныйОтступБылМеньшеСерединного() {
        for cell in [stride(from: 120.0, through: 240.0, by: 10.0)].flatMap({ $0 }) {
            let preview = (CGFloat(cell) * 0.64).rounded()
            let inset = ThumbnailCellLayout.topInset(cellSize: CGFloat(cell),
                                                     previewSize: preview, nameHeight: nameArea)
            XCTAssertGreaterThanOrEqual(inset, ThumbnailCellLayout.minimumTopInset,
                                        "размер \(cell)")
        }
        XCTAssertGreaterThan(ThumbnailCellLayout.topInset(cellSize: 210, previewSize: 134,
                                                          nameHeight: nameArea),
                             ThumbnailCellLayout.minimumTopInset)
    }
}

/// Признак картинки и признак раскраски — врозь.
///
/// Они жили одной строкой, и правило «гаснущая свежесть» (перекраска раз в пятнадцать
/// секунд) выбрасывало все готовые эскизы: картинки мигали сами по себе.
final class ThumbnailAppearanceTokenTests: XCTestCase {

    private func picture(previewSize: CGFloat = 134, quickLook: Bool = true,
                         folderTint: String = "none", scale: CGFloat = 1,
                         weight: CGFloat = 0, symbol: String = "arrow.up") -> String {
        ThumbnailAppearance.pictureToken(previewSize: previewSize, quickLook: quickLook,
                                        folderTint: folderTint, upIconScale: scale,
                                        upIconWeight: weight, upIconSymbol: symbol)
    }

    private func paint(generation: Int, cursorName: NSColor = .systemOrange) -> String {
        ThumbnailAppearance.paintToken(folderName: .systemYellow, fileName: .labelColor,
                                       cursorName: cursorName, cursorBackground: nil,
                                       generation: generation)
    }

    /// Главное: шаг угасания меняет раскраску и НЕ трогает признак картинки.
    func test_счётчикПерекрасок_НеВыбрасываетЭскизы() {
        XCTAssertEqual(picture(), picture(), "картинка от счётчика не зависит вовсе")
        XCTAssertNotEqual(paint(generation: 1), paint(generation: 2))
    }

    /// А то, что действительно меняет картинку, признак меняет.
    func test_признакКартинки_МеняетсяОтРазмераИПредпросмотра() {
        XCTAssertNotEqual(picture(), picture(previewSize: 96))
        XCTAssertNotEqual(picture(), picture(quickLook: false))
        XCTAssertNotEqual(picture(), picture(folderTint: "FF8800"))
        XCTAssertNotEqual(picture(), picture(scale: 1.4))
        XCTAssertNotEqual(picture(), picture(weight: 2))
        XCTAssertNotEqual(picture(), picture(symbol: "arrowshape.up"))
    }

    /// Цвет курсора — раскраска: эскизы при его смене остаются.
    func test_цветаИдутВРаскраску() {
        XCTAssertNotEqual(paint(generation: 1), paint(generation: 1, cursorName: .systemPink))
    }
}
