import PDFKit
import XCTest
@testable import TotumComXLApp

/// Размер страницы для Ghostscript — дешёвыми дорогами. Устройство `bbox` исполняет весь
/// файл: на настоящем «Дом и луна.ai» это 48 секунд, и просмотр выглядел так, будто не
/// грузится вовсе, — при том что сам рендер занимает секунду.
final class PostScriptRendererTests: XCTestCase {

    private var folder = ""

    override func setUpWithError() throws {
        folder = NSTemporaryDirectory() + "ps-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: folder)
        super.tearDown()
    }

    func test_pdfПодИменемAI_МеряетсяЧерезPDFKit() throws {
        let path = folder + "/рисунок.ai"
        // Настоящий PDF со страницей 300×500 — как пишет Illustrator в режиме совместимости.
        var box = CGRect(x: 0, y: 0, width: 300, height: 500)
        let context = try XCTUnwrap(CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()

        let started = Date()
        let size = try XCTUnwrap(PostScriptRenderer.pageSizePoints(path: path))
        XCTAssertEqual(size.w, 300, accuracy: 1)
        XCTAssertEqual(size.h, 500, accuracy: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "без Ghostscript, за миллисекунды")
    }

    func test_epsМеряетсяПоШапке() throws {
        let path = folder + "/знак.eps"
        let eps = "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 10 20 210 120\n%%HiResBoundingBox: 10.5 20 210.5 120\n%%EndComments\nshowpage\n"
        try eps.write(toFile: path, atomically: true, encoding: .ascii)

        let size = try XCTUnwrap(PostScriptRenderer.pageSizePoints(path: path))
        XCTAssertEqual(size.w, 200, accuracy: 0.01, "точная шапка в приоритете")
        XCTAssertEqual(size.h, 100, accuracy: 0.01)
    }
}
