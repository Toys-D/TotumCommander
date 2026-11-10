import AppKit
import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Полоса правки под картинкой в просмотре: двенадцать значков слева, «Было», «Сбросить»,
/// «Сохранить» справа. В панели шириной ~560 точек (окно 1200) всё в одну строку с обычным
/// зазором не входило, и недостачу забирали подписи: «Было» вставало столбиком по букве.
@MainActor
final class ToolbarRowLayoutTests: XCTestCase {

    private let icons = [CGFloat](repeating: 18, count: 12)
    private let buttons = CGSize(width: 260, height: 20)

    private func arrange(width: CGFloat?) -> FCXLToolbarRow.Arrangement {
        FCXLToolbarRow.arrange(iconWidths: icons, iconsHeight: 18, trailing: buttons, width: width,
                               spacing: 14, minSpacing: 4, rowSpacing: 6)
    }

    func test_простораДостаточно_обычныйЗазор() {
        let wide = arrange(width: 1000)
        XCTAssertFalse(wide.wraps)
        XCTAssertEqual(wide.iconSpacing, 14)
        XCTAssertEqual(wide.size, CGSize(width: 1000, height: 20))
        XCTAssertEqual(arrange(width: nil).size.width, 12 * 18 + 11 * 14 + 14 + 260, "по себе — с обычными зазорами")
    }

    /// Окно 1200: значки сходятся, кнопки справа — на своём размере, в той же строке.
    func test_тесно_значкиСходятся() {
        let tight = arrange(width: 536)
        XCTAssertFalse(tight.wraps)
        XCTAssertEqual(tight.iconSpacing, (536 - 216 - 260 - 14) / 11, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(tight.iconSpacing, 4)
    }

    /// Совсем узко — кнопки второй строкой, а не обрезанные подписи.
    func test_оченьУзко_кнопкиВтораяСтрока() {
        let narrow = arrange(width: 400)
        XCTAssertTrue(narrow.wraps)
        XCTAssertEqual(narrow.iconSpacing, 14, "в своей строке значкам места хватает")
        XCTAssertEqual(narrow.size.height, 18 + 6 + 20)
    }

    /// Слева один вид (группа целиком, как в полосе рисования): не помещается — группа справа
    /// всё равно уходит вниз, а не налезает.
    func test_одинВидСлева_тожеПереносится() {
        let fits = FCXLToolbarRow.arrange(iconWidths: [300], iconsHeight: 26, trailing: CGSize(width: 150, height: 26),
                                          width: 500, spacing: 8, minSpacing: 6, rowSpacing: 6)
        XCTAssertFalse(fits.wraps)
        let narrow = FCXLToolbarRow.arrange(iconWidths: [300], iconsHeight: 26, trailing: CGSize(width: 150, height: 26),
                                            width: 400, spacing: 8, minSpacing: 6, rowSpacing: 6)
        XCTAssertTrue(narrow.wraps)
        XCTAssertEqual(narrow.size.height, 26 + 6 + 26)
    }

    // MARK: - Живые виды

    private func fitting<V: View>(_ view: V) -> NSSize {
        let host = NSHostingView(rootView: view)
        host.layout()
        return host.fittingSize
    }

    private func chip(_ title: String) -> some View {
        FCXLChip(compact: true) { Text(title).lineLimit(1).fixedSize().frame(maxWidth: .infinity) }
    }

    /// Три кнопки — одной ширины, по самой широкой подписи.
    func test_кнопкиОднойШирины() {
        let widest = fitting(chip("Сохранить")).width
        XCTAssertGreaterThan(widest, fitting(chip("Было")).width)
        let row = fitting(FCXLEqualWidthRow(spacing: 8) { chip("Было"); chip("Сбросить"); chip("Сохранить") })
        XCTAssertEqual(row.width, widest * 3 + 16, accuracy: 0.5)
    }

    /// Полоса рисования: широко — с подписями в строку; уже — инструменты одними значками, но в
    /// строку; совсем узко — две строки. Высота никогда не больше двух рядов кнопок: подписи не
    /// встают столбиком, а ширина по себе не вылезает за предложенную.
    func test_полосаРисованияПомещаетсяБезОбрезанныхПодписей() {
        let toolbar = ImageAnnotationToolbar(tool: .constant(.arrow), colour: .constant(.red),
                                             canUndo: true, onUndo: {}, onDone: {})
        let oneRow: CGFloat = 26 + 10
        let wide = fitting(toolbar.frame(width: 1400))
        XCTAssertEqual(wide.height, oneRow, accuracy: 1, "широко — одна строка")
        let narrow = fitting(toolbar.frame(width: 300))
        XCTAssertEqual(narrow.height, 26 + 6 + 26 + 10, accuracy: 1, "узко — две строки")
        let ideal = fitting(toolbar)
        let withTitles = fitting(toolbar.frame(width: ideal.width))
        XCTAssertEqual(withTitles.height, oneRow, accuracy: 1, "по своей ширине — одна строка с подписями")
    }

    /// Узкая полоса не переносит подпись «Было»: высота полосы — строка значков и строка кнопок,
    /// а не столбик букв.
    func test_подписьНеПереноситсяВУзкойПолосе() {
        let oneChip = fitting(chip("Было")).height
        let bar = FCXLToolbarRow(spacing: 14) {
            ForEach(0..<12, id: \.self) { _ in Color.gray.frame(width: 16, height: 16) }
            FCXLEqualWidthRow(spacing: 8) { chip("Было"); chip("Сбросить"); chip("Сохранить") }
        }
        for width: CGFloat in [536, 300] {
            let height = fitting(bar.frame(width: width)).height
            XCTAssertLessThanOrEqual(height, 16 + 6 + oneChip + 0.5, "ширина \(width): \(height)")
        }
    }
}
