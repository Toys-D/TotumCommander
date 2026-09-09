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

    func test_переносыСтрокСохраняются() throws {
        let text = try XCTUnwrap(MarkdownStyler.render("первая\nвторая\n\nтретья"))
        XCTAssertEqual(text.string.components(separatedBy: "\n").count, 4, "абзацы не склеиваются")
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
