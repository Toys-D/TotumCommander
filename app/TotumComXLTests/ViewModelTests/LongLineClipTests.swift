import XCTest

@testable import TotumComXLApp

/// Сверхдлинная строка в просмотре: строку в 8 миллионов знаков (ответ сервера в .har одной
/// строкой) macOS раскладывает целиком на главном потоке — 40 секунд и больше программа не
/// отвечала. Просмотр показывает её начало и пометку, сколько осталось; файл не меняется.
final class LongLineClipTests: XCTestCase {

    func test_обычныйТекст_неМеняется() {
        let text = "первая строка\nвторая\r\nтретья"
        XCTAssertEqual(LongLineClip.clip(text, limit: 100), text)
    }

    func test_длиннаяСтрока_обрезанаСПометкой() {
        let long = String(repeating: "я", count: 250)
        let clipped = LongLineClip.clip("до\n" + long + "\nпосле", limit: 100)
        let lines = clipped.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3, "строк столько же")
        XCTAssertEqual(lines[0], "до")
        XCTAssertEqual(lines[2], "после")
        XCTAssertTrue(lines[1].hasPrefix(String(repeating: "я", count: 100)))
        XCTAssertFalse(lines[1].hasPrefix(String(repeating: "я", count: 101)), "дальше предела — пометка")
        XCTAssertTrue(lines[1].contains(LongLineClip.marker(remaining: 150)), lines[1])
    }

    /// Предел не режет знак пополам: эмодзи на границе остаётся целым.
    func test_границаНеРежетЗнак() {
        let text = String(repeating: "a", count: 99) + "👍🏽" + String(repeating: "b", count: 50)
        let clipped = LongLineClip.clip(text, limit: 100)
        XCTAssertFalse(clipped.unicodeScalars.contains { $0.value == 0xFFFD })
        XCTAssertTrue(clipped.hasPrefix(String(repeating: "a", count: 99)))
        XCTAssertNotNil(clipped.data(using: .utf8), "строка цела")
    }

    /// Восемь миллионов знаков в одной строке обрезаются быстро — это и есть случай .har.
    func test_восемьМиллионовЗнаков_быстро() {
        let text = "{\n\"body\": \"" + String(repeating: "Q", count: 8_000_000) + "\"\n}\n"
        let started = Date()
        let clipped = LongLineClip.clip(text)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertLessThan((clipped as NSString).length, 20_000)
        XCTAssertTrue(clipped.hasPrefix("{\n\"body\": \"QQQ"))
        XCTAssertTrue(clipped.hasSuffix("\n}\n"))
    }

    // MARK: - Весь текст

    /// Просмотр показывает начало большого текста: 35 МБ в NSTextView — та же раскладка всего
    /// документа на главном потоке, только по строкам. Конец — по строке, с пометкой.
    func test_большойТекст_показаноНачалоСПометкой() {
        let line = String(repeating: "x", count: 99) + "\n"          // 100 знаков на строку
        let text = String(repeating: line, count: 1_000)             // 100 000 знаков
        let shown = LongLineClip.preview(text, lineLimit: 10_000, totalLimit: 25_050)
        let ns = shown as NSString
        XCTAssertTrue(shown.hasPrefix(line + line))
        XCTAssertTrue(shown.contains(LongLineClip.totalMarker(shown: 25_000, total: 100_000)), shown.suffix(200).description)
        XCTAssertLessThan(ns.length, 25_300)
        // Обрезано по концу строки: перед пометкой — целые строки.
        let body = ns.substring(to: 25_000)
        XCTAssertEqual(body.components(separatedBy: "\n").filter { !$0.isEmpty }.allSatisfy { $0.count == 99 }, true)
    }

    func test_небольшойТекст_целиком() {
        let text = "раз\nдва\nтри\n"
        XCTAssertEqual(LongLineClip.preview(text), text)
    }

    /// Случай .har: 35 миллионов знаков, одна строка в 8 миллионов — показ сразу и короткий.
    func test_тридцатьПятьМиллионов_быстроИКоротко() {
        let normal = String(repeating: String(repeating: "a", count: 139) + "\n", count: 180_000)
        let text = normal + "\"" + String(repeating: "Q", count: 8_000_000) + "\"\n" + normal
        let started = Date()
        let shown = LongLineClip.preview(text)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        XCTAssertLessThanOrEqual((shown as NSString).length, LongLineClip.defaultTotal + 500)
    }

    // MARK: - Порции для «Показать дальше»

    /// Порции идут подряд, режутся по концу строки и вместе дают весь текст.
    func test_порцииПодрядИВместеВесьТекст() {
        let text = (0..<3_000).map { "строка \($0) " + String(repeating: "ж", count: $0 % 50) }
            .joined(separator: "\n")
        let source = text as NSString
        var parts: [String] = []
        var offset = 0
        while offset < source.length {
            let part = LongLineClip.chunk(of: source, from: offset, totalLimit: 10_000, lineLimit: 100_000)
            XCTAssertGreaterThan(part.end, offset)
            if part.end < source.length {
                XCTAssertEqual(source.character(at: part.end - 1), 0x0A, "порция кончается концом строки")
            }
            parts.append(part.text)
            offset = part.end
        }
        XCTAssertGreaterThan(parts.count, 3)
        XCTAssertEqual(parts.joined(), text)
    }

    /// Строка длиннее порции режется по целому знаку, а длинные строки внутри порции — как в `clip`.
    func test_порцияВнутриОднойОгромнойСтроки() {
        let source = String(repeating: "Q", count: 50_000) as NSString
        let first = LongLineClip.chunk(of: source, from: 0, totalLimit: 20_000, lineLimit: 1_000)
        XCTAssertEqual(first.end, 20_000)
        XCTAssertTrue(first.text.contains(LongLineClip.marker(remaining: 19_000)))
    }
}

