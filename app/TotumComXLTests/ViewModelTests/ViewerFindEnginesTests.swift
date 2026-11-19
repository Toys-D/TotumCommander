import PDFKit
import WebKit
import XCTest
import FCXLBridgeObjC
import FCXLDjVuUI
@testable import TotumComXLApp

/// Поиск по тексту в просмотре — на настоящих видах: PDF, страница (HTML, документ Word, глава
/// книги) и DjVu с текстовым слоем.
@MainActor
final class ViewerFindEnginesTests: XCTestCase {

    private func query(_ text: String, matchCase: Bool = false, wholeWord: Bool = false) -> ViewerFindQuery {
        ViewerFindQuery(text: text, matchCase: matchCase, wholeWord: wholeWord)
    }

    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func search(_ engine: ViewerFindEngine, _ query: ViewerFindQuery) -> ViewerFindResult {
        var answer: ViewerFindResult?
        engine.search(query) { answer = $0 }
        wait { answer != nil }
        XCTAssertNotNil(answer, "поиск не ответил")
        return answer ?? ViewerFindResult()
    }

    private func step(_ engine: ViewerFindEngine, _ direction: Int) -> ViewerFindResult {
        var answer: ViewerFindResult?
        engine.step(direction) { answer = $0 }
        wait { answer != nil }
        XCTAssertNotNil(answer, "шаг не ответил")
        return answer ?? ViewerFindResult()
    }

    // MARK: - PDF

    /// PDF с настоящим текстом на страницах (пустая строка — страница без текста, как у скана).
    private func pdf(pages: [String]) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            if text.isEmpty {
                NSColor.gray.setFill()
                NSRect(x: 40, y: 40, width: 100, height: 100).fill()
            } else {
                (text as NSString).draw(at: CGPoint(x: 20, y: 200),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    private func pdfView(_ document: PDFDocument) -> PDFView {
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.document = document
        return view
    }

    func test_pdf_находитНаВсехСтраницах_иХодитПоНим() throws {
        let document = try pdf(pages: ["Система полного привода", "Привод и проводка", "Ничего", "привод сзади"])
        let view = pdfView(document)
        let engine = PDFFindEngine(pdfView: view)

        var answer = search(engine, query("привод"))
        XCTAssertEqual(answer, ViewerFindResult(count: 3, position: 1))
        XCTAssertEqual(view.highlightedSelections?.count, 3, "все совпадения подсвечены")
        XCTAssertEqual(view.currentSelection?.string?.lowercased(), "привод", "текущее выделено — ⌘C его копирует")

        answer = step(engine, 1)
        XCTAssertEqual(answer.position, 2)
        XCTAssertEqual(view.currentPage.map(document.index(for:)), 1, "просмотр перешёл на страницу совпадения")
        answer = step(engine, 1)
        answer = step(engine, 1)
        XCTAssertEqual(answer.position, 1, "за последним — первое")
        answer = step(engine, -1)
        XCTAssertEqual(answer.position, 3)
        XCTAssertEqual(view.currentPage.map(document.index(for:)), 3)

        engine.clear()
        XCTAssertNil(view.highlightedSelections)
    }

    func test_pdf_регистрИСловоЦеликом() throws {
        // Латиницей: строчную «к» системный шрифт кладёт в PDF знаком «ĸ», и текст такой
        // страницы читается уже не тем, что на ней написано, — это свойство проверочного PDF.
        let view = pdfView(try pdf(pages: ["Code codex CODE recode"]))
        let engine = PDFFindEngine(pdfView: view)
        XCTAssertEqual(search(engine, query("code")).count, 4)
        XCTAssertEqual(search(engine, query("code", wholeWord: true)).count, 2, "«codex» и «recode» — не слово «code»")
        XCTAssertEqual(search(engine, query("CODE", matchCase: true)).count, 1)
        XCTAssertEqual(search(engine, query("нет такого")), ViewerFindResult())
    }

    /// Поиск идёт от страницы, что на экране.
    func test_pdf_поискОтСтраницыНаЭкране() throws {
        let document = try pdf(pages: ["привод раз", "пусто тут", "привод два", "привод три"])
        let view = pdfView(document)
        view.go(to: try XCTUnwrap(document.page(at: 2)))
        let engine = PDFFindEngine(pdfView: view)
        XCTAssertEqual(search(engine, query("привод")), ViewerFindResult(count: 3, position: 2))
    }

    /// У скана текста нет — «не найдено» было бы неправдой: искать не в чем.
    func test_pdf_безТекста_говоритЧтоИскатьНеВЧем() throws {
        let view = pdfView(try pdf(pages: ["", ""]))
        let answer = search(PDFFindEngine(pdfView: view), query("привод"))
        XCTAssertEqual(answer.note, L("viewer.find.noTextLayer"))
        XCTAssertEqual(answer.count, 0)
    }

    // MARK: - Страница

    private func page(_ body: String) -> WKWebView {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        load(body, into: web)
        return web
    }

    private func load(_ body: String, into web: WKWebView) {
        var loaded = false
        web.loadHTMLString("<html><head><style>p{margin:0 0 400px}</style><title>привод в заголовке</title>"
                           + "</head><body>\(body)</body></html>", baseURL: nil)
        wait { !web.isLoading }
        // Страница на месте, когда у неё есть тело.
        web.evaluateJavaScript("document.body ? document.body.childNodes.length : 0") { _, _ in loaded = true }
        wait { loaded }
    }

    private func js(_ web: WKWebView, _ script: String, world: WKContentWorld = .page) -> Any? {
        var result: Any?
        var done = false
        web.evaluateJavaScript(script, in: nil, in: world) { answer in
            if case .success(let value) = answer { result = value }
            done = true
        }
        wait { done }
        return result
    }

    func test_страница_находитИПодсвечивает_дажеСловоРазрезанноеРазметкой() {
        let web = page("<p>Полный привод.</p><p>При<b>вод</b> задний и <i>ПРИВОД</i> передний.</p>"
                       + "<script>var x = 'привод в скрипте';</script>")
        let engine = WebFindEngine(webView: web)
        var answer = search(engine, query("привод"))
        XCTAssertEqual(answer, ViewerFindResult(count: 3, position: 1),
                       "три в тексте; заголовок окна и скрипт — не текст страницы")
        XCTAssertEqual(js(web, "document.querySelectorAll('mark.fcxl-view-find').length") as? Int, 4,
                       "разрезанное разметкой слово подсвечено двумя кусками")
        XCTAssertEqual(js(web, "document.querySelectorAll('mark.fcxl-view-find-current').length") as? Int, 1)

        answer = step(engine, 1)
        XCTAssertEqual(answer.position, 2)
        XCTAssertEqual(js(web, "document.querySelectorAll('mark.fcxl-view-find-current').length") as? Int, 2,
                       "текущее — то самое, из двух кусков")
        XCTAssertGreaterThan((js(web, "window.scrollY") as? NSNumber)?.doubleValue ?? 0, 0,
                             "страница прокручена к текущему")
        answer = step(engine, 1)
        answer = step(engine, 1)
        XCTAssertEqual(answer.position, 1, "по кругу")
        answer = step(engine, -1)
        XCTAssertEqual(answer.position, 3)
    }

    func test_страница_снятаяПодсветкаВозвращаетСтраницуКакБыла() {
        let body = "<p>Полный привод.</p><p>При<b>вод</b> задний.</p>"
        let web = page(body)
        let before = js(web, "document.body.innerHTML") as? String
        let engine = WebFindEngine(webView: web)
        XCTAssertEqual(search(engine, query("привод")).count, 2)
        XCTAssertNotEqual(js(web, "document.body.innerHTML") as? String, before)
        engine.clear()
        wait { (self.js(web, "document.querySelectorAll('mark').length") as? Int) == 0 }
        XCTAssertEqual(js(web, "document.body.innerHTML") as? String, before)
        // Новый запрос ищет в чистой странице, а не в остатках прежней подсветки.
        XCTAssertEqual(search(engine, query("задний")).count, 1)
        XCTAssertEqual(js(web, "document.querySelectorAll('mark.fcxl-view-find').length") as? Int, 1)
    }

    func test_страница_регистрИСловоЦеликом() {
        let web = page("<p>Код кодекс КОД пере<b>код</b> штрих-код</p>")
        let engine = WebFindEngine(webView: web)
        XCTAssertEqual(search(engine, query("код")).count, 5)
        XCTAssertEqual(search(engine, query("код", wholeWord: true)).count, 3)
        XCTAssertEqual(search(engine, query("КОД", matchCase: true)).count, 1)
        XCTAssertEqual(search(engine, query("\"кавычки\" и \\ косая")).count, 0, "запрос доходит как есть")
        XCTAssertEqual(search(engine, query("нет такого")), ViewerFindResult())
    }

    /// Код страницы поиска не видит: он живёт в своём, отдельном мире.
    func test_страница_поискНеВиденКодуСтраницы() {
        let web = page("<p>привод</p>")
        XCTAssertEqual(search(WebFindEngine(webView: web), query("привод")).count, 1)
        XCTAssertEqual(js(web, "typeof window.fcxlViewFind") as? String, "undefined")
        XCTAssertEqual(js(web, "typeof window.fcxlViewFind", world: .defaultClient) as? String, "object")
    }

    // MARK: - Книга: главы

    /// Книга на экране по одной главе. Шаг за последнее совпадение главы открывает следующую
    /// главу, где запрос есть, — и пропускает те, где его нет.
    func test_книга_поискИдётПоГлавам() {
        let chapters = ["<p>Глава первая, привод.</p>", "<p>Глава вторая, пусто.</p>",
                        "<p>Глава третья: привод и ещё привод.</p>"]
        let web = page(chapters[0])
        var current = 0
        var opened: [Int] = []
        let engine = WebFindEngine(webView: web, chapters: WebFindEngine.Chapters(
            count: { chapters.count },
            current: { current },
            text: { WebFindEngine.plainText(ofHTML: chapters[$0]) },
            isSamePage: { $0 == $1 },
            open: { index, done in
                opened.append(index)
                current = index
                self.load(chapters[index], into: web)
                done()
            }))

        var answer = search(engine, query("привод"))
        XCTAssertEqual(answer, ViewerFindResult(count: 1, position: 1, more: true))

        answer = step(engine, 1)
        XCTAssertEqual(opened, [2], "вторая глава без запроса пропущена")
        XCTAssertEqual(answer, ViewerFindResult(count: 2, position: 1, more: true), "в новой главе — с первого")
        answer = step(engine, 1)
        XCTAssertEqual(answer.position, 2)
        XCTAssertEqual(opened, [2], "внутри главы главу не меняем")

        answer = step(engine, 1)
        XCTAssertEqual(opened, [2, 0], "за последним в книге — снова первая глава")
        XCTAssertEqual(answer.position, 1)

        answer = step(engine, -1)
        XCTAssertEqual(opened, [2, 0, 2], "назад от первого — в последнюю главу с запросом")
        XCTAssertEqual(answer, ViewerFindResult(count: 2, position: 2, more: true), "и на её последнее совпадение")
    }

    func test_книга_запросТолькоВОткрытойГлаве_ходитПоКругуВНей() {
        let chapters = ["<p>привод и привод</p>", "<p>пусто</p>"]
        let web = page(chapters[0])
        var opened: [Int] = []
        let engine = WebFindEngine(webView: web, chapters: WebFindEngine.Chapters(
            count: { chapters.count }, current: { 0 },
            text: { WebFindEngine.plainText(ofHTML: chapters[$0]) },
            isSamePage: { $0 == $1 },
            open: { index, done in opened.append(index); done() }))
        XCTAssertEqual(search(engine, query("привод")).count, 2)
        _ = step(engine, 1)
        let answer = step(engine, 1)
        XCTAssertEqual(answer.position, 1)
        XCTAssertTrue(opened.isEmpty, "в других главах запроса нет — никуда не уходим")
    }

    func test_текстГлавыБезРазметки() {
        let html = "<html><head><title>привод</title><style>p{color:red}</style></head><body>"
            + "<p>Пол&shy;ный при<b>вод</b> &amp; &laquo;мост&raquo;</p><script>var привод = 1;</script></body></html>"
        let text = WebFindEngine.plainText(ofHTML: html)
        XCTAssertTrue(text.contains("привод & «мост»"), text)
        XCTAssertFalse(text.contains("color"), "стили — не текст")
        XCTAssertFalse(text.contains("var "), "скрипты — не текст")
        XCTAssertEqual(ViewerTextSearch.ranges(of: query("привод"), in: text as NSString).count, 1,
                       "заголовок из head не считается")
    }

    // MARK: - DjVu

    private func fixture(_ name: String) -> String {
        FileManager.default.currentDirectoryPath + "/app/TotumComXLTests/Fixtures/DjVu/" + name
    }

    /// Читатель отдаёт слова текстового слоя с рамками в точках страницы, от верхнего левого
    /// угла — в том же пространстве, в каком страница рисуется.
    func test_djvu_читательОтдаётСловаСРамками() throws {
        let reader = try FCXLDjVuReader(path: fixture("two-pages.djvu"))
        defer { reader.close() }
        XCTAssertEqual(reader.pageCount, 2)
        XCTAssertEqual(reader.pageSize(at: 0), CGSize(width: 288, height: 384), "600×800 при 150 dpi")

        let words = reader.words(at: 0)
        XCTAssertEqual(words.compactMap { $0["text"] as? String }, ["Привет", "мир", "Totum", "Commander"])
        let first = DjVuPageText(words: words).words[0].box
        XCTAssertEqual(first.minX, 24, accuracy: 0.01)
        XCTAssertEqual(first.minY, 33.6, accuracy: 0.01, "сверху: 800 − 730 точек картинки")
        XCTAssertEqual(first.width, 48, accuracy: 0.01)
        XCTAssertEqual(first.height, 14.4, accuracy: 0.01)
        XCTAssertEqual(reader.words(at: 1).compactMap { $0["text"] as? String }, ["Второй", "мир"])
        XCTAssertEqual(reader.words(at: 5).count, 0, "нет такой страницы")
    }

    func test_djvu_текстСтраницы_иРамкиНайденного() {
        let page = DjVuPageText(words: [
            ["text": "Полный", "x": 10, "y": 20, "w": 30, "h": 8],
            ["text": "привод", "x": 45, "y": 20, "w": 30, "h": 8],
            ["text": "", "x": 0, "y": 0, "w": 0, "h": 0],
            ["text": "сзади", "x": 10, "y": 32, "w": 25, "h": 8],
        ])
        XCTAssertEqual(page.text, "Полный привод сзади")
        let text = page.text as NSString
        XCTAssertEqual(page.boxes(for: text.range(of: "привод")), [CGRect(x: 45, y: 20, width: 30, height: 8)])
        XCTAssertEqual(page.boxes(for: text.range(of: "привод сзади")).count, 2, "запрос из двух слов — обе рамки")
        XCTAssertEqual(page.boxes(for: text.range(of: "иво")).count, 1, "часть слова подсвечивает слово")
        XCTAssertEqual(DjVuPageText.empty.text, "")
    }

    func test_djvu_поискПоТекстовомуСлою() throws {
        let reader = try FCXLDjVuReader(path: fixture("two-pages.djvu"))
        defer { reader.close() }
        let pages = DjVuPagesView(reader: reader)
        let engine = DjVuFindEngine(reader: reader, pages: pages)

        var answer = search(engine, query("мир"))
        XCTAssertEqual(answer, ViewerFindResult(count: 2, position: 1), "по одному на каждой странице")
        answer = step(engine, 1)
        XCTAssertEqual(answer.position, 2)
        answer = step(engine, 1)
        XCTAssertEqual(answer.position, 1)

        XCTAssertEqual(search(engine, query("totum commander")).count, 1, "запрос из двух слов")
        XCTAssertEqual(search(engine, query("при", wholeWord: true)).count, 0)
        XCTAssertEqual(search(engine, query("ПРИВЕТ", matchCase: true)).count, 0)
        XCTAssertEqual(search(engine, query("нет такого")), ViewerFindResult())
    }

    func test_djvu_безТекстовогоСлоя_говоритЧтоИскатьНеВЧем() throws {
        let reader = try FCXLDjVuReader(path: fixture("no-text.djvu"))
        defer { reader.close() }
        let engine = DjVuFindEngine(reader: reader, pages: DjVuPagesView(reader: reader))
        XCTAssertEqual(search(engine, query("мир")).note, L("viewer.find.noTextLayer"))
    }
}
