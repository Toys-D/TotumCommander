import XCTest
@testable import TotumComXLApp

/// Таблицы Excel в просмотре — своей страницей (SpreadsheetPreview): листы книги собираются в
/// одну страницу, и в ней работает поиск. Раньше таблицу рисовал Quick Look, и искать в ней
/// было нечем.
final class SpreadsheetPreviewTests: XCTestCase {

    func test_какиеФайлыОткрываютсяСтраницей() {
        for ext in ["xls", "xlsx", "XLSX", "xlsm", "xlt", "xltx"] {
            XCTAssertTrue(SpreadsheetPreview.isSpreadsheet(extension: ext), ext)
        }
        // Эти система отдаёт иначе (или это не таблицы) — они остаются как были.
        for ext in ["numbers", "ods", "csv", "docx", "pptx", "pdf", ""] {
            XCTAssertFalse(SpreadsheetPreview.isSpreadsheet(extension: ext), ext)
        }
    }

    private let tabsPage = """
    <html><head><title>книга.xlsx</title><script src="Attachment6.js"></script></head>
    <body onload="initTabViewsInPage();"><div id="wrapper"><iframe id="SheetFrame" src="Attachment8.html">
    </iframe></div><div class="TabView" id="tabs"><div class="TabViewItem selected">
    <div class="TabHeader">Заказы</div><a href="Attachment8.html"></a></div><div class="TabViewItem">
    <div class="TabHeader">Склад &amp; остатки</div><a href="Attachment1.html"></a></div></div></body></html>
    """

    private let sheetPage = """
    <html><head><meta charset="utf-8"><link href="Attachment4.css" rel="stylesheet" type="text/css">
    <style type="text/css">.s0.s0.s0 {font-family:Verdana;color:#000000;}
    .s1.s1.s1, .s2.s2.s2 {text-align:right;}
    </style></head><body><div><table style="width:128;" class="worksheet showGridlines">
    <tr><td class="s0">Товар</td><td class="s1">1500,5</td></tr></table></div></body></html>
    """

    func test_листыИзСтраницыСВкладками() {
        let sheets = SpreadsheetPreview.sheets(inPreview: tabsPage)
        XCTAssertEqual(sheets.map(\.name), ["Заказы", "Склад &amp; остатки"], "имя — как в разметке")
        XCTAssertEqual(sheets.map(\.file), ["Attachment8.html", "Attachment1.html"])
        XCTAssertTrue(SpreadsheetPreview.sheets(inPreview: sheetPage).isEmpty, "один лист — вкладок нет")
    }

    /// У листов классы ячеек называются одинаково, а значат разное: стили листа действуют
    /// только внутри его обёртки.
    func test_стилиЛистаПривязаныКЛисту() {
        let parts = SpreadsheetPreview.sheetParts(of: sheetPage, scope: "fcxl-sheet-2")
        XCTAssertEqual(parts.stylesheets, ["Attachment4.css"])
        XCTAssertTrue(parts.css.contains(".fcxl-sheet-2 .s0.s0.s0 {font-family:Verdana;color:#000000;}"), parts.css)
        XCTAssertTrue(parts.css.contains(".fcxl-sheet-2 .s1.s1.s1, .fcxl-sheet-2 .s2.s2.s2 {text-align:right;}"),
                      parts.css)
        XCTAssertTrue(parts.body.contains("<td class=\"s0\">Товар</td>"))
        XCTAssertFalse(parts.body.contains("<body"), "только содержимое тела")

        let nested = "@media screen { .s0 { color: red } }"
        XCTAssertEqual(SpreadsheetPreview.scoped(css: nested, under: "x"), nested, "вложенные правила — как есть")
        XCTAssertEqual(SpreadsheetPreview.scoped(css: "", under: "x"), "")
    }

    func test_страницаКниги_листыОдинПодДругим() {
        let first = SpreadsheetPreview.sheetParts(of: sheetPage, scope: SpreadsheetPreview.scope(0))
        let second = SpreadsheetPreview.sheetParts(of: sheetPage.replacingOccurrences(of: "Товар", with: "Остаток"),
                                                   scope: SpreadsheetPreview.scope(1))
        let page = SpreadsheetPreview.page(title: "книга <1>.xlsx",
                                           sheets: [("Заказы", first), ("Склад", second)])
        XCTAssertFalse(page.lowercased().contains("<!doctype"), "старый режим: ширины колонок без единиц")
        XCTAssertTrue(page.contains("<title>книга &lt;1&gt;.xlsx</title>"))
        XCTAssertEqual(page.components(separatedBy: "Attachment4.css").count - 1, 1, "общие стили — один раз")
        XCTAssertTrue(page.contains("<a href=\"#fcxl-sheet-1\">Склад</a>"), "полоса листов ведёт к листу")
        XCTAssertTrue(page.contains("data-fcxl-nofind"), "полоса листов — не текст книги")
        XCTAssertTrue(page.contains("<h2 class=\"fcxl-sheet-title\" id=\"fcxl-sheet-1\">Склад</h2>"))
        XCTAssertTrue(page.contains("<div class=\"fcxl-sheet fcxl-sheet-0\">"))
        let товар = try? XCTUnwrap(page.range(of: "Товар"))
        let остаток = try? XCTUnwrap(page.range(of: "Остаток"))
        XCTAssertNotNil(товар)
        XCTAssertNotNil(остаток)
        if let товар, let остаток { XCTAssertTrue(товар.lowerBound < остаток.lowerBound, "листы — по порядку") }

        let single = SpreadsheetPreview.page(title: "один.xls", sheets: [("", first)])
        XCTAssertFalse(single.contains("<div class=\"fcxl-tabs\""), "один лист — без полосы листов")
        XCTAssertFalse(single.contains("<h2"), "и без заголовка")
        XCTAssertTrue(single.contains("Товар"))
    }

    /// Настоящий файл XLSX из двух листов: система отдаёт их страницей, и на собранной странице
    /// есть содержимое обоих.
    func test_настоящийXLSX_всеЛистыНаОднойСтранице() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/qlmanage") else {
            throw XCTSkip("нет qlmanage")
        }
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath
                          + "/app/TotumComXLTests/Fixtures/Sheets/orders.xlsx")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("fcxl-sheets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }

        let page = try XCTUnwrap(SpreadsheetPreview.convert(fixture, cache: cache), "система не отдала страницу")
        XCTAssertEqual(page.lastPathComponent, SpreadsheetPreview.pageName)
        let html = try String(contentsOf: page, encoding: .utf8)
        for text in ["Заказы", "Склад", "Товар", "Привод передний", "Привод задний", "Привод на складе"] {
            XCTAssertTrue(html.contains(text), "на странице нет «\(text)»")
        }
        XCTAssertTrue(html.contains("fcxl-sheet-0") && html.contains("fcxl-sheet-1"))
        // Подключённые стили лежат рядом со страницей.
        let link = try XCTUnwrap(SpreadsheetPreview.sheetParts(of: html, scope: "x").stylesheets.first)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: page.deletingLastPathComponent().appendingPathComponent(link).path))

        // Второй раз — из кэша: тот же файл, не новый.
        let stamp = try page.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let again = try XCTUnwrap(SpreadsheetPreview.convert(fixture, cache: cache))
        XCTAssertEqual(again, page)
        XCTAssertEqual(try again.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, stamp)
    }

    func test_неТаблица_страницыНет() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/qlmanage") else {
            throw XCTSkip("нет qlmanage")
        }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("fcxl-sheets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let broken = cache.appendingPathComponent("битая.xlsx")
        try Data("это не таблица".utf8).write(to: broken)
        XCTAssertNil(SpreadsheetPreview.convert(broken, cache: cache), "битый файл — остаётся Quick Look")
    }
}
