import AppKit
import PDFKit
import XCTest

@testable import TotumComXLApp

/// Печать: что можно напечатать, и что выделенные файлы собираются в одно задание — страницы
/// всех подряд, а испорченный файл называется, а не пропадает молча. Окно печати здесь не
/// открывается: проверяется то, что ушло бы в него.
@MainActor
final class PrintServiceTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "печать-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    private func path(_ name: String) -> String { root + "/" + name }

    func test_чтоПечатается() {
        for name in ["отчёт.pdf", "фото.JPG", "заметки.txt", "readme.md", "договор.docx", "письмо.rtf",
                     "скан.djvu", "схема.eps", "логотип.svg", "код.swift"] {
            XCTAssertTrue(PrintService.canPrint("/x/" + name), name)
        }
        for name in ["архив.zip", "фильм.mp4", "песня.mp3", "таблица.xlsx", "модель.obj", "Программа.app"] {
            XCTAssertFalse(PrintService.canPrint("/x/" + name), name)
        }
    }

    func test_длинныйТекстНаНесколькоЛистов() throws {
        let short = try XCTUnwrap(PrintService.paginate(PrintService.plainText("одна строка")))
        XCTAssertEqual(short.pageCount, 1)
        // Строка — вверху листа и тёмная: не перевёрнута и не белая тёмной темы.
        let page = try XCTUnwrap(short.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        let picture = page.thumbnail(of: NSSize(width: bounds.width, height: bounds.height), for: .mediaBox)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(picture.tiffRepresentation)))
        func darkRows(_ rows: Range<Int>) -> Int {
            var count = 0
            for y in rows {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.4, c.alphaComponent > 0.5 {
                        count += 1
                        break
                    }
                }
            }
            return count
        }
        XCTAssertGreaterThan(darkRows(0..<rep.pixelsHigh / 5), 0, "текст вверху листа")
        XCTAssertEqual(darkRows(rep.pixelsHigh / 2..<rep.pixelsHigh), 0, "внизу пусто")
        let long = (1...400).map { "строка \($0) — текст, который должен лечь на бумагу" }.joined(separator: "\n")
        let pages = try XCTUnwrap(PrintService.paginate(PrintService.plainText(long)))
        XCTAssertGreaterThan(pages.pageCount, 3, "400 строк не помещаются на один лист")
    }

    func test_выделенноеОднимЗаданием_испорченныйНазван() async throws {
        try "простой текст".write(toFile: path("a.txt"), atomically: true, encoding: .utf8)
        try "# Заголовок\n\nабзац **жирный**".write(toFile: path("b.md"), atomically: true, encoding: .utf8)
        let rtf = NSAttributedString(string: "оформленный текст", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        try rtf.data(from: NSRange(location: 0, length: rtf.length),
                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            .write(to: URL(fileURLWithPath: path("c.rtf")))
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
            .representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path("d.png")))
        let twoPages = PDFDocument()
        for _ in 0..<2 { twoPages.insert(PDFPage(image: image)!, at: twoPages.pageCount) }
        XCTAssertTrue(twoPages.write(toFile: path("e.pdf")))
        try "это не PDF".write(toFile: path("broken.pdf"), atomically: true, encoding: .utf8)

        let files = ["a.txt", "b.md", "c.rtf", "d.png", "e.pdf", "broken.pdf"].map(path)
        let (document, failed) = await PrintService.assemble(files)
        XCTAssertEqual(document.pageCount, 6, "текст, Markdown, RTF, картинка — по листу, PDF — два")
        XCTAssertEqual(failed, [path("broken.pdf")])
    }
}
