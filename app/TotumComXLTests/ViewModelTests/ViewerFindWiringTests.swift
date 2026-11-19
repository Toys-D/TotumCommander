import PDFKit
import SwiftUI
import WebKit
import XCTest
@testable import TotumComXLApp

/// Поиск по тексту — в настоящем просмотрщике: полоса находит движок того, что на экране
/// (текст, Markdown, страница HTML, PDF), подсветка появляется в самом виде, а другой файл под
/// курсором ищется тем же запросом.
@MainActor
final class ViewerFindWiringTests: XCTestCase {

    private var cleanup: [() -> Void] = []
    private var root = URL(fileURLWithPath: "/")

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("fcxl-find-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root
        cleanup.append { try? fm.removeItem(at: folder) }
    }

    override func tearDown() async throws {
        for step in cleanup.reversed() { step() }
        cleanup = []
        try await super.tearDown()
    }

    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = descendant(type, in: child) { return match }
        }
        return nil
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Просмотрщик над папкой проверки, курсор панели — на файле `name`. Окно прозрачное и
    /// сквозное, в углу экрана: человек его не видит.
    private func viewer(on name: String) throws -> (panel: PanelViewModel, host: NSView, find: ViewerFindModel) {
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: root.path,
                                pathDefaultsKey: "find.\(UUID().uuidString)",
                                viewModeDefaultsKey: "findm.\(UUID().uuidString)", showHiddenFiles: true)
        wait { vm.items.contains { $0.name == name } }
        vm.setCursor(index: try XCTUnwrap(vm.items.firstIndex { $0.name == name }))

        let host = NSHostingView(rootView: UnifiedFileViewer(viewModel: vm, onClose: nil, operations: nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(.zero)
        window.orderFrontRegardless()
        cleanup.append { [weak vm] in
            vm?.stopWatching()
            window.contentView = nil
            window.close()
        }
        var model: ViewerFindModel?
        wait {
            host.layoutSubtreeIfNeeded()
            model = ViewerFindModel.live.allObjects.first { $0.resolveEngine != nil }
            return model != nil
        }
        return (vm, host, try XCTUnwrap(model, "просмотрщик не подключил поиск"))
    }

    private func search(_ find: ViewerFindModel, _ text: String, expecting count: Int,
                        file: StaticString = #filePath, line: UInt = #line) {
        find.typingDelay = 0
        if !find.isVisible { find.open() }
        find.query = text
        wait { find.result.count == count && !find.isSearching }
        XCTAssertEqual(find.result.count, count, "«\(text)»: \(find.counterText)", file: file, line: line)
    }

    func test_текст_подсветкаВСамомВиде() throws {
        try write("заметки.txt", (1...60).map { $0 % 20 == 0 ? "строка \($0): привод" : "строка \($0)" }
            .joined(separator: "\n"))
        let (_, host, find) = try viewer(on: "заметки.txt")
        var view: NumberedTextView?
        wait { view = self.descendant(NumberedTextView.self, in: host); return view?.shownText.isEmpty == false }
        let text = try XCTUnwrap(view)

        search(find, "привод", expecting: 3)
        XCTAssertEqual(find.result.position, 1)
        let first = (text.string as NSString).range(of: "привод")
        XCTAssertNotNil(text.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: first.location,
                                                               effectiveRange: nil), "найденное подсвечено")
        XCTAssertTrue(host.subviews.count > 0)
        find.next()
        XCTAssertEqual(find.result.position, 2)

        find.close()
        XCTAssertNil(text.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: first.location,
                                                            effectiveRange: nil), "закрыли полосу — подсветки нет")
    }

    /// Полоса открыта, курсор панели ушёл на другой файл — тот же запрос ищется в нём.
    func test_другойФайлПодКурсором_ищетсяТемЖеЗапросом() throws {
        try write("а.txt", "привод привод")
        try write("б.txt", "привод, привод и ещё раз привод; и привод")
        let (panel, _, find) = try viewer(on: "а.txt")
        search(find, "привод", expecting: 2)

        panel.setCursor(index: try XCTUnwrap(panel.items.firstIndex { $0.name == "б.txt" }))
        wait { find.result.count == 4 }
        XCTAssertEqual(find.result.count, 4, find.counterText)
        XCTAssertTrue(find.isVisible, "полоса осталась открытой")
        XCTAssertEqual(find.query, "привод")
    }

    func test_markdown_ищетВОформленномТексте() throws {
        try write("описание.md", "# Привод\n\nПолный **привод** и *задний* привод.\n\n- привод\n")
        let (_, _, find) = try viewer(on: "описание.md")
        search(find, "привод", expecting: 4)
    }

    func test_страницаHTML_ищетНаСтранице() throws {
        // Кодировка названа: без неё местный файл читается как латиница, и на странице — и в
        // поиске — оказались бы «кракозябры» вместо слов.
        try write("страница.html", "<html><head><meta charset=\"utf-8\"></head><body><p>Полный привод.</p>"
                  + "<p>При<b>вод</b> задний.</p></body></html>")
        let (_, host, find) = try viewer(on: "страница.html")
        var web: WKWebView?
        wait { web = self.descendant(WKWebView.self, in: host); return web != nil && web?.isLoading == false }
        XCTAssertNotNil(web, "HTML показан страницей")
        search(find, "привод", expecting: 2)
    }

    func test_pdf_ищетВДокументе() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data as CFMutableData)),
                                              mediaBox: &box, nil))
        for text in ["search this page", "nothing here", "search again, search more"] {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(at: CGPoint(x: 20, y: 200), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: root.appendingPathComponent("руководство.pdf"))

        let (_, host, find) = try viewer(on: "руководство.pdf")
        var pdf: PDFView?
        wait { pdf = self.descendant(PDFView.self, in: host); return pdf?.document != nil }
        search(find, "search", expecting: 3)
        XCTAssertEqual(pdf?.highlightedSelections?.count, 3, "найденное подсвечено на страницах")
        find.next()
        XCTAssertEqual(find.result.position, 2)
        XCTAssertEqual(pdf?.currentPage.flatMap { pdf?.document?.index(for: $0) }, 2, "перешли на страницу совпадения")
    }

    /// Книга на экране по одной главе, а поиск идёт по всей: «Далее» за последним совпадением
    /// главы открывает следующую главу, где запрос есть.
    func test_книга_поискИдётПоВсемГлавам() throws {
        try write("повесть.fb2", """
        <?xml version="1.0" encoding="utf-8"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
        <description><title-info><book-title>Повесть</book-title></title-info></description>
        <body>
        <section><title><p>Глава первая</p></title><p>Полный привод и ещё привод.</p></section>
        <section><title><p>Глава вторая</p></title><p>Здесь тихо.</p></section>
        <section><title><p>Глава третья</p></title><p>Снова привод.</p></section>
        </body></FictionBook>
        """)
        let (_, _, find) = try viewer(on: "повесть.fb2")
        search(find, "привод", expecting: 2)
        XCTAssertTrue(find.result.more, "в книге есть ещё главы")
        XCTAssertEqual(find.result.position, 1)

        // Страница отвечает не сразу — ждём ответа на каждый шаг.
        find.next()
        wait { find.result.position == 2 }
        XCTAssertEqual(find.result.position, 2)
        find.next()
        wait { find.result.count == 1 && find.result.position == 1 }
        XCTAssertEqual(find.result, ViewerFindResult(count: 1, position: 1, more: true),
                       "третья глава: вторая, где запроса нет, пропущена")
        XCTAssertEqual(BookReaderBridge.shared.current?.loadedChapter, 2)
        XCTAssertTrue(find.isVisible)

        find.next()
        wait { find.result.count == 2 }
        XCTAssertEqual(find.result.position, 1, "за последним в книге — снова первая глава")
        XCTAssertEqual(BookReaderBridge.shared.current?.loadedChapter, 0)
    }

    func test_djvu_ищетПоТекстовомуСлою() throws {
        let fixture = FileManager.default.currentDirectoryPath + "/app/TotumComXLTests/Fixtures/DjVu/two-pages.djvu"
        try FileManager.default.copyItem(atPath: fixture, toPath: root.appendingPathComponent("скан.djvu").path)
        let (_, _, find) = try viewer(on: "скан.djvu")
        search(find, "мир", expecting: 2)
        find.next()
        XCTAssertEqual(find.result.position, 2)
        search(find, "commander", expecting: 1)
    }

    /// Таблица Excel показана своей страницей — и в ней ищется, по всем листам сразу. Раньше
    /// её рисовал Quick Look, и кнопки «Найти» у неё не было.
    func test_таблицаExcel_ищетПоВсемЛистам() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/qlmanage") else {
            throw XCTSkip("нет qlmanage")
        }
        let fixture = FileManager.default.currentDirectoryPath + "/app/TotumComXLTests/Fixtures/Sheets/orders.xlsx"
        try FileManager.default.copyItem(atPath: fixture, toPath: root.appendingPathComponent("заказы.xlsx").path)
        let (_, host, find) = try viewer(on: "заказы.xlsx")
        var web: WKWebView?
        wait { web = self.descendant(WKWebView.self, in: host); return web?.url != nil && web?.isLoading == false }
        XCTAssertEqual(web?.url?.lastPathComponent, SpreadsheetPreview.pageName, "таблица показана страницей")

        search(find, "привод", expecting: 3)
        find.next()
        wait { find.result.position == 2 }
        find.next()
        wait { find.result.position == 3 }
        XCTAssertEqual(find.result.position, 3, "третье — на втором листе")
        search(find, "заказы", expecting: 1)
    }

    /// В картинке искать не в чем — полоса так и говорит, а не «не найдено».
    func test_картинка_искатьНеВЧем() throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
            .representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("точка.png"))
        let (_, _, find) = try viewer(on: "точка.png")
        find.typingDelay = 0
        find.open()
        find.query = "привод"
        wait { find.result.note != nil }
        XCTAssertEqual(find.result.note, L("viewer.find.nothingToSearch"))
    }
}
