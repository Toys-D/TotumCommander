import XCTest
@testable import TotumComXLApp

/// Переводчик Markdown → HTML для справки: ровно то подмножество, которым она написана.
final class MarkdownLiteTests: XCTestCase {

    func test_заголовкиАбзацыИЛинейка() {
        let html = MarkdownLite.html(from: "# Титул\n\nСтрока раз\nстрока два\n\n---\n\n## Раздел\n### Подраздел")
        XCTAssertTrue(html.contains("<h1 id=\"титул\">Титул</h1>"))
        XCTAssertTrue(html.contains("<p>Строка раз строка два</p>"), "строки абзаца склеиваются")
        XCTAssertTrue(html.contains("<hr>"))
        XCTAssertTrue(html.contains("<h2 id=\"раздел\">Раздел</h2>"))
        XCTAssertTrue(html.contains("<h3 id=\"подраздел\">Подраздел</h3>"))
    }

    func test_спискиМаркированныеИНумерованные() {
        let html = MarkdownLite.html(from: "- один\n- два\n\n1. первый\n2. второй")
        XCTAssertTrue(html.contains("<ul><li>один</li><li>два</li></ul>"))
        XCTAssertTrue(html.contains("<ol><li>первый</li><li>второй</li></ol>"))
    }

    func test_таблицаСШапкой() {
        let html = MarkdownLite.html(from: "| Клавиша | Действие |\n|---|---|\n| F5 | Копировать |\n| F6 | Переместить |")
        XCTAssertTrue(html.contains("<thead><tr><th>Клавиша</th><th>Действие</th></tr></thead>"))
        XCTAssertTrue(html.contains("<tr><td>F5</td><td>Копировать</td></tr>"))
        XCTAssertTrue(html.contains("<tr><td>F6</td><td>Переместить</td></tr>"))
        XCTAssertFalse(html.contains("---"), "разделитель шапки — не строка таблицы")
    }

    func test_строчныеСтилиИЭкранирование() {
        let html = MarkdownLite.inline("**жирный**, `*.png&*.pdf`, [сайт](https://example.com) и <тег>")
        XCTAssertTrue(html.contains("<strong>жирный</strong>"))
        XCTAssertTrue(html.contains("<code>*.png&amp;*.pdf</code>"), "амперсанд экранирован внутри кода")
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">сайт</a>"))
        XCTAssertTrue(html.contains("&lt;тег&gt;"), "угловые скобки текста не становятся разметкой")
    }

    func test_разделыПоЗаголовкамВторогоУровня() {
        let sections = MarkdownLite.sections(of: "# Титул\nвступление\n\n## Один\nтекст один\n### внутри\n\n## Два\nтекст два")
        XCTAssertEqual(sections.map(\.title), ["", "Один", "Два"])
        XCTAssertTrue(sections[0].body.contains("вступление"))
        XCTAssertTrue(sections[1].body.contains("### внутри"), "подразделы остаются в своём разделе")
        XCTAssertTrue(sections[2].body.contains("текст два"))
    }
}
