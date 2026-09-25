import AppKit
import PDFKit
import XCTest

@testable import TotumComXLApp

/// Контекстное меню страницы PDF — своё, на языке программы. Системное приходило по-английски
/// и выглядело чужим.
@MainActor
final class PDFContextMenuTests: XCTestCase {

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    func test_безВыделенияМенюПроМасштабИСтраницы() {
        let view = FCXLPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        let menu = view.contextMenu(at: .zero)

        let names = titles(menu)
        XCTAssertEqual(names.first, L("viewer.pdf.menu.autoResize"), "без выделения — сразу масштаб")
        XCTAssertFalse(names.contains(L("viewer.pdf.menu.copy")), "копировать нечего")
        for name in names {
            XCTAssertFalse(name.hasPrefix("viewer.pdf"), "нет перевода: \(name)")
        }
        XCTAssertEqual(menu.items.first { $0.identifier?.rawValue == "pdf.autoResize" }?.state, .on)
        XCTAssertEqual(menu.items.first { $0.identifier?.rawValue == "pdf.singleContinuous" }?.state, .on)
        XCTAssertEqual(menu.items.first { $0.identifier?.rawValue == "pdf.twoUp" }?.state, .off)
        XCTAssertEqual(menu.items.first { $0.identifier?.rawValue == "pdf.nextPage" }?.isEnabled, false,
                       "без документа листать некуда")
    }

    func test_сВыделениемВпередиПоискИКопирование() throws {
        let path = NSTemporaryDirectory() + "fcxl-menu-\(UUID().uuidString).pdf"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try XCTUnwrap(CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = graphics
        NSAttributedString(string: "Сергей обнял Клару за плечи", attributes: [.font: NSFont.systemFont(ofSize: 18)])
            .draw(at: NSPoint(x: 20, y: 100))
        NSGraphicsContext.current = nil
        context.endPDFPage()
        context.closePDF()

        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))
        let page = try XCTUnwrap(document.page(at: 0))
        let view = FCXLPDFView()
        view.document = document
        view.setCurrentSelection(page.selection(for: page.bounds(for: .mediaBox)), animate: false)
        XCTAssertFalse((view.currentSelection?.string ?? "").isEmpty, "текст в PDF должен выделяться")

        let names = titles(view.contextMenu(at: .zero))
        XCTAssertTrue(names[0].contains("Сергей"), "первым — поиск по выделенному: \(names[0])")
        XCTAssertEqual(names[1], L("viewer.pdf.menu.searchWeb"))
        XCTAssertEqual(names[2], L("viewer.pdf.menu.copy"))
    }

    func test_выдержкаКороткаяИОднострочная() {
        XCTAssertEqual(FCXLPDFView.excerpt(of: "коротко"), "коротко")
        XCTAssertEqual(FCXLPDFView.excerpt(of: "первая строка\nвторая"), "первая строка вторая")
        let long = String(repeating: "слово ", count: 20)
        let cut = FCXLPDFView.excerpt(of: long)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertLessThanOrEqual(cut.count, 34)
    }
}
