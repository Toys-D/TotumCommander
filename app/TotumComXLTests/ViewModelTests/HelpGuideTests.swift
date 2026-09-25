import AppKit
import XCTest
@testable import TotumComXLApp

/// Полная справка в окне ⌘?: лежит в бандле на обоих языках, ищется по разделам,
/// собирается в страницу в цветах программы.
final class HelpGuideTests: XCTestCase {

    func test_справкаЕстьНаОбоихЯзыкахИОдинаковоУстроена() {
        let ru = HelpGuide.markdown(language: "ru")
        let en = HelpGuide.markdown(language: "en")
        XCTAssertGreaterThan(ru.count, 20_000, "русская справка в бандле")
        XCTAssertGreaterThan(en.count, 20_000, "английская справка в бандле")
        let ruSections = MarkdownLite.sections(of: ru).map(\.title).filter { !$0.isEmpty }
        let enSections = MarkdownLite.sections(of: en).map(\.title).filter { !$0.isEmpty }
        XCTAssertEqual(ruSections.count, enSections.count,
                       "разделов поровну: \(ruSections.count) и \(enSections.count)")
        XCTAssertGreaterThanOrEqual(ruSections.count, 17)
        // Оба перевода описывают одно и то же: главы идут под теми же номерами.
        for (r, e) in zip(ruSections, enSections) {
            XCTAssertEqual(r.prefix { $0.isNumber || $0 == "." }, e.prefix { $0.isNumber || $0 == "." },
                           "«\(r)» против «\(e)»")
        }
    }

    func test_чужойЯзыкПадаетНаРусский() {
        XCTAssertEqual(HelpGuide.markdown(language: "xx"), HelpGuide.markdown(language: "ru"))
    }

    func test_поискОставляетТолькоРазделыСоСловом() {
        let text = "# Титул\nвступление\n\n## 1. Панель\nкурсор и выделение\n\n## 2. Архивы\nупаковать и распаковать"
        XCTAssertEqual(HelpGuide.sections(matching: "", in: text).count, 3, "без запроса — всё, со вступлением")
        let found = HelpGuide.sections(matching: "УПАКОВАТЬ", in: text)
        XCTAssertEqual(found.map(\.title), ["2. Архивы"], "регистр не важен, вступление в поиск не попадает")
        XCTAssertTrue(HelpGuide.sections(matching: "нет такого", in: text).isEmpty)
    }

    func test_страницаВЦветахПрограммы() {
        let page = HelpGuide.page(markdown: "## Раздел\nтекст", query: "", dark: true,
                                  accent: .systemPurple, background: .black, noResults: "пусто")
        XCTAssertTrue(page.contains("<h2 id=\"раздел\">Раздел</h2>"))
        XCTAssertTrue(page.contains(HelpGuide.cssColor(.systemPurple)), "акцент в стилях")
        XCTAssertTrue(page.contains("rgba(0,0,0,1.000)"), "фон окна")
        let empty = HelpGuide.page(markdown: "## Раздел\nтекст", query: "чего нет", dark: false,
                                   accent: .systemBlue, background: .white, noResults: "пусто")
        XCTAssertTrue(empty.contains("<p class=\"empty\">пусто</p>"))
    }

    /// Страница целиком в обеих темах — в папку FCXL_LOOK_DIR, чтобы посмотреть глазами.
    func test_страницаСохраняетсяДляПросмотра() throws {
        guard let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] else { return }
        for (name, dark, language) in [("help-dark", true, "ru"), ("help-light", false, "en")] {
            let page = HelpGuide.page(markdown: HelpGuide.markdown(language: language), query: "",
                                      dark: dark, accent: .systemPurple,
                                      background: dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1),
                                      noResults: "—")
            try page.write(toFile: dir + "/\(name).html", atomically: true, encoding: .utf8)
        }
    }

    func test_разделыСправкиПереводятсяВHTMLБезПотерь() {
        // Каждая таблица и каждый заголовок настоящей справки должны дойти до страницы.
        let ru = HelpGuide.markdown(language: "ru")
        let html = MarkdownLite.html(from: ru)
        let tables = ru.components(separatedBy: "\n").filter { $0.hasPrefix("|---") }.count
        XCTAssertEqual(html.components(separatedBy: "<table>").count - 1, tables, "все таблицы")
        let headings = ru.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }.count
        XCTAssertEqual(html.components(separatedBy: "<h2 ").count - 1, headings, "все главы")
        XCTAssertFalse(html.contains("**"), "жирный переведён")
    }
}
