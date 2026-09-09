import AppKit
import XCTest

@testable import TotumComXLApp

/// Markdown в просмотрщике: разметка становится шрифтами, а документ на десятки тысяч слов
/// раскладывается за доли секунды, а не за десять.
final class MarkdownPreviewTests: XCTestCase {

    private func font(at index: Int, in text: NSAttributedString) -> NSFont? {
        text.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    func test_разметкаСтановитсяШрифтами() throws {
        let text = try XCTUnwrap(MarkdownStyler.render("**жирно** и *курсив*, `код`, [ссылка](https://example.org)"))
        let plain = text.string
        let bold = try XCTUnwrap(font(at: plain.distance(from: plain.startIndex, to: plain.range(of: "жирно")!.lowerBound), in: text))
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask), "**жирно** — жирным")
        let italic = try XCTUnwrap(font(at: plain.distance(from: plain.startIndex, to: plain.range(of: "курсив")!.lowerBound), in: text))
        XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask), "*курсив* — курсивом")
        let code = try XCTUnwrap(font(at: plain.distance(from: plain.startIndex, to: plain.range(of: "код")!.lowerBound), in: text))
        XCTAssertTrue(code.isFixedPitch, "`код` — моноширинным")
        let linkAt = plain.distance(from: plain.startIndex, to: plain.range(of: "ссылка")!.lowerBound)
        XCTAssertNotNil(text.attribute(.link, at: linkAt, effectiveRange: nil), "ссылка остаётся ссылкой")
        let normal = try XCTUnwrap(font(at: plain.distance(from: plain.startIndex, to: plain.range(of: " и ")!.lowerBound), in: text))
        XCTAssertFalse(NSFontManager.shared.traits(of: normal).contains(.boldFontMask), "обычный текст — обычным")
    }

    func test_переносСтрокиОстаётсяПереносом() throws {
        // Markdown считает одиночный перенос пробелом, но человек смотрит СВОЙ файл и ждёт
        // увидеть его строки. Пустая строка между абзацами при этом не нужна — её работу
        // делает отступ между ними.
        let text = try XCTUnwrap(MarkdownStyler.render("первая\nвторая\n\nтретья"))
        XCTAssertEqual(text.string.components(separatedBy: "\n").count, 3, "строки не склеиваются")
        XCTAssertFalse(text.string.contains("\n\n"), "пустых строк между абзацами нет")
    }

    private func style(at index: Int, in text: NSAttributedString) -> NSParagraphStyle? {
        text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    }

    private func index(of needle: String, in text: NSAttributedString) throws -> Int {
        let plain = text.string
        let range = try XCTUnwrap(plain.range(of: needle), "в разложенном тексте нет «\(needle)»")
        return plain.distance(from: plain.startIndex, to: range.lowerBound)
    }

    // MARK: - Блоки, а не решётки с палками

    func test_заголовокКрупнееИЖирнее() throws {
        let text = try XCTUnwrap(MarkdownStyler.render("# Заголовок\n\nобычный текст"))
        XCTAssertFalse(text.string.contains("#"), "решётка заголовка не показывается")
        let head = try XCTUnwrap(font(at: try index(of: "Заголовок", in: text), in: text))
        let body = try XCTUnwrap(font(at: try index(of: "обычный", in: text), in: text))
        XCTAssertGreaterThan(head.pointSize, body.pointSize)
        XCTAssertTrue(NSFontManager.shared.traits(of: head).contains(.boldFontMask))
    }

    func test_таблицаСтановитсяТаблицей() throws {
        let document = """
        | Что проверяли | Результат |
        |---|---|
        | Первое | Ответ один |
        """
        let text = try XCTUnwrap(MarkdownStyler.render(document))
        XCTAssertFalse(text.string.contains("|"), "палки разметки не показываются")
        XCTAssertFalse(text.string.contains("---"), "строка выравнивания не показывается")
        let cell = try XCTUnwrap(style(at: try index(of: "Ответ один", in: text), in: text))
        let block = try XCTUnwrap(cell.textBlocks.first as? NSTextTableBlock,
                                  "ячейка живёт в настоящей таблице")
        XCTAssertEqual(block.table.numberOfColumns, 2)
        XCTAssertEqual(block.startingColumn, 1)
        XCTAssertEqual(block.startingRow, 1, "шапка — нулевая строка")
    }

    func test_шапкаТаблицыЖирная() throws {
        let text = try XCTUnwrap(MarkdownStyler.render("| Имя | Тип |\n|---|---|\n| файл | .md |"))
        let head = try XCTUnwrap(font(at: try index(of: "Имя", in: text), in: text))
        XCTAssertTrue(NSFontManager.shared.traits(of: head).contains(.boldFontMask))
    }

    func test_списокПолучаетМаркеры() throws {
        let text = try XCTUnwrap(MarkdownStyler.render("- один\n- два"))
        XCTAssertTrue(text.string.contains("•"), "пункты помечены точкой")
        XCTAssertFalse(text.string.contains("- один"), "чёрточка разметки не показывается")
        let item = try XCTUnwrap(style(at: try index(of: "один", in: text), in: text))
        XCTAssertGreaterThan(item.headIndent, 0, "пункт с отступом")
    }

    func test_нумерованныйСписокСохраняетНомера() throws {
        let text = try XCTUnwrap(MarkdownStyler.render("1. первый\n2. второй"))
        XCTAssertTrue(text.string.contains("1. "), "номер остаётся номером")
        XCTAssertTrue(text.string.contains("2. "))
    }

    func test_блокКодаМоноширинныйИСФоном() throws {
        let text = try XCTUnwrap(MarkdownStyler.render("текст\n\n```swift\nlet x = 1\n```"))
        XCTAssertFalse(text.string.contains("```"), "заборчик кода не показывается")
        let code = try XCTUnwrap(font(at: try index(of: "let x", in: text), in: text))
        XCTAssertTrue(code.isFixedPitch)
        let block = try XCTUnwrap(style(at: try index(of: "let x", in: text), in: text))
        XCTAssertNotNil(block.textBlocks.first?.backgroundColor, "у кода своя подложка")
    }

    func test_цитатаОтступаетИБледнее() throws {
        let text = try XCTUnwrap(MarkdownStyler.render("> цитата"))
        XCTAssertFalse(text.string.contains(">"), "уголок цитаты не показывается")
        let quote = try XCTUnwrap(style(at: try index(of: "цитата", in: text), in: text))
        XCTAssertGreaterThan(quote.firstLineHeadIndent, 0)
        XCTAssertFalse(quote.textBlocks.isEmpty, "у цитаты есть полоска слева")
    }

    /// Документ размером с ТЗ (13 000 слов) — разбор, стиль и полная раскладка в NSTextView
    /// укладываются в секунду с большим запасом; SwiftUI Text на том же тексте шёл секундами.
    @MainActor
    func test_большойДокументРаскладываетсяБыстро() throws {
        let paragraph = "Слово **важное** и *заметное*, обычный текст с `кодом` и ещё несколько слов для длины строки. "
        let document = (1...900).map { "\($0). " + paragraph }.joined(separator: "\n")
        let started = Date()
        let text = try XCTUnwrap(MarkdownStyler.render(document))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView.textStorage?.setAttributedString(text)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(text.length, 80_000)
        XCTAssertLessThan(elapsed, 1.0, "разбор и раскладка заняли \(elapsed) с")
    }
}
