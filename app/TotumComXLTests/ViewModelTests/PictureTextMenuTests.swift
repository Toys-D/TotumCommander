import AppKit
import XCTest

@testable import TotumComXLApp

/// Выделенный на картинке текст — в буфер, и правое меню над ним.
///
/// Жалоба: слова подсвечивались, тянулись мышью, но ⌘C ничего не копировал, а правого
/// меню не было вовсе. В буфер должно идти ровно то, что человек выделил САМ.
@MainActor
final class PictureTextMenuTests: XCTestCase {

    private func line(_ id: Int, _ words: [String]) -> RecognizedLine {
        RecognizedLine(id: id, text: words.joined(separator: " "),
                       box: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1,
                       words: words.enumerated().map { index, word in
                           RecognizedWord(id: index, text: word,
                                          box: CGRect(x: CGFloat(index) * 0.2, y: 0,
                                                      width: 0.2, height: 1))
                       })
    }

    private var lines: [RecognizedLine] {
        [line(0, ["Воздушный", "фильтр", "HENGST"]),
         line(1, ["Код:", "E1146L"]),
         line(2, ["529.94", "₴"])]
    }

    // MARK: - Выделение → текст

    /// Ровно выделенные слова, в порядке чтения, а не вся строка.
    func test_вБуферИдётТолькоВыделенное() {
        let text = TextRecognitionService.text(forKeys: ["0.1", "0.2"], lines: lines)
        XCTAssertEqual(text, "фильтр HENGST")
    }

    /// Порядок — как на картинке, а не как в множестве ключей.
    func test_порядокЧтенияНеЗависитОтПорядкаКлючей() {
        let text = TextRecognitionService.text(forKeys: ["2.0", "0.0", "1.1"], lines: lines)
        XCTAssertEqual(text, "Воздушный\nE1146L\n529.94", "строки — через перевод строки")
    }

    func test_пустоеВыделение_ПустаяСтрока() {
        XCTAssertEqual(TextRecognitionService.text(forKeys: [], lines: lines), "")
        XCTAssertEqual(TextRecognitionService.text(forKeys: ["9.9"], lines: lines), "",
                       "чужие ключи не находят слов")
    }

    func test_выделитьВсё_ЭтоВсеСлова() {
        let all = TextRecognitionService.allKeys(lines)
        XCTAssertEqual(all.count, 7)
        XCTAssertEqual(TextRecognitionService.text(forKeys: all, lines: lines),
                       "Воздушный фильтр HENGST\nКод: E1146L\n529.94 ₴")
    }

    // MARK: - Что в меню

    func test_безТекстаМенюПустое() {
        XCTAssertTrue(PictureTextMenu.actions(for: .init(hasText: false)).isEmpty)
    }

    /// Выделенное — первым: это то, за чем человек и пришёл.
    func test_сВыделениемИСловомПодКурсором() {
        let context = PictureTextMenu.Context(hasSelection: true, word: "HENGST",
                                              line: "Воздушный фильтр HENGST", hasText: true)
        XCTAssertEqual(PictureTextMenu.actions(for: context),
                       [.copySelection, .copyWord("HENGST"),
                        .copyLine("Воздушный фильтр HENGST"), .selectAll, .copyAll])
    }

    /// Курсор мимо слов: только общее — выделить всё, скопировать всё.
    func test_мимоСлов_ТолькоОбщиеПункты() {
        XCTAssertEqual(PictureTextMenu.actions(for: .init(hasText: true)),
                       [.selectAll, .copyAll])
    }

    /// Строка из одного слова не предлагается дважды.
    func test_строкаИзОдногоСлова_НеДублируется() {
        let context = PictureTextMenu.Context(word: "E1146L", line: "E1146L", hasText: true)
        XCTAssertEqual(PictureTextMenu.actions(for: context),
                       [.copyWord("E1146L"), .selectAll, .copyAll])
    }

    func test_менюСобираетсяИзПереведённыхПунктов() {
        var performed: [PictureTextMenu.Action] = []
        let context = PictureTextMenu.Context(hasSelection: true, word: "HENGST",
                                              line: "Воздушный фильтр HENGST", hasText: true)
        let menu = PictureTextMenu.menu(for: context) { performed.append($0) }
        let items = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items[0].identifier?.rawValue, "ocr.copySelection")
        XCTAssertEqual(items[0].title, L("viewer.ocr.menu.copySelection"))
        XCTAssertTrue(items[1].title.contains("HENGST"), "слово названо в пункте")
        XCTAssertTrue(menu.items.contains { $0.isSeparatorItem }, "общие пункты отделены")
        for item in items {
            XCTAssertFalse(item.title.hasPrefix("viewer.ocr"), "нет перевода: \(item.title)")
        }
        // Пункт срабатывает.
        _ = items[0].target?.perform(items[0].action, with: items[0])
        XCTAssertEqual(performed, [.copySelection])
    }

    func test_длинноеСловоВПунктеОбрезаетсяМноготочием() {
        XCTAssertEqual(PictureTextMenu.excerpt(of: "коротко"), "коротко")
        let long = String(repeating: "а", count: 60)
        XCTAssertTrue(PictureTextMenu.excerpt(of: long).hasSuffix("…"))
        XCTAssertLessThan(PictureTextMenu.excerpt(of: long).count, 40)
    }
}
