import AppKit
import PDFKit
import XCTest

@testable import TotumComXLApp

/// Merging, splitting and turning PDFs. The page arithmetic — what "1-3, 7, 12-" means — is
/// where a document editor quietly ruins an afternoon, so it is checked in full; the writing is
/// checked end to end on real documents.
final class PDFEditTests: XCTestCase {

    private typealias Service = PDFEditService

    // MARK: - Which pages

    func testRangesAreReadTheWayAPersonWritesThem() {
        // Counted from ONE, ranges inclusive.
        XCTAssertEqual(Service.pages(from: "1-3", pageCount: 10), [0, 1, 2])
        XCTAssertEqual(Service.pages(from: "2", pageCount: 10), [1])
        XCTAssertEqual(Service.pages(from: "1-2, 5", pageCount: 10), [0, 1, 4])
        XCTAssertEqual(Service.pages(from: "8-", pageCount: 10), [7, 8, 9], "открытый конец — до последней")
        XCTAssertEqual(Service.pages(from: "-3", pageCount: 10), [0, 1, 2], "открытое начало — с первой")
    }

    /// An empty field is a narrowing that narrows nothing: the whole document.
    func testEmptyMeansEverything() {
        XCTAssertEqual(Service.pages(from: "", pageCount: 4), [0, 1, 2, 3])
        XCTAssertEqual(Service.pages(from: "   ", pageCount: 4), [0, 1, 2, 3])
        XCTAssertTrue(Service.pages(from: "1-3", pageCount: 0).isEmpty, "у пустого документа нет страниц")
    }

    /// A range typed for a longer file should still do what it plainly means.
    func testPagesOutsideTheDocumentAreClippedNotRefused() {
        XCTAssertEqual(Service.pages(from: "3-99", pageCount: 5), [2, 3, 4])
        XCTAssertEqual(Service.pages(from: "99", pageCount: 5), [], "одной несуществующей — ничего")
        XCTAssertEqual(Service.pages(from: "0-2", pageCount: 5), [0, 1], "нулевой страницы не бывает")
    }

    func testRepeatsAndBackwardsRangesBehave() {
        XCTAssertEqual(Service.pages(from: "1,1,2,1", pageCount: 5), [0, 1], "повторы не удваивают страницу")
        XCTAssertEqual(Service.pages(from: "5-3", pageCount: 8), [2, 3, 4],
                       "задом наперёд — те же страницы в порядке документа")
        XCTAssertEqual(Service.pages(from: "3, 1", pageCount: 5), [2, 0],
                       "а вот порядок перечисления сохраняется — его писали намеренно")
    }

    func testDashesOfEveryKind() {
        let hyphen = Service.pages(from: "2-4", pageCount: 6)
        XCTAssertEqual(Service.pages(from: "2–4", pageCount: 6), hyphen, "короткое тире")
        XCTAssertEqual(Service.pages(from: "2—4", pageCount: 6), hyphen, "длинное тире")
        XCTAssertEqual(Service.pages(from: "мусор", pageCount: 6), [], "непонятное — ничего")
    }

    func testEveryNPages() {
        XCTAssertEqual(Service.chunks(pageCount: 7, size: 3), [[0, 1, 2], [3, 4, 5], [6]])
        XCTAssertEqual(Service.chunks(pageCount: 4, size: 1), [[0], [1], [2], [3]])
        XCTAssertTrue(Service.chunks(pageCount: 4, size: 0).isEmpty, "по нулю страниц не делят")
    }

    func testAnglesAreBroughtIntoTheFourTheFormatKnows() {
        XCTAssertEqual(Service.normalized(90), 90)
        XCTAssertEqual(Service.normalized(360), 0)
        XCTAssertEqual(Service.normalized(450), 90)
        XCTAssertEqual(Service.normalized(-90), 270, "поворот влево — это три четверти вправо")
    }

    // MARK: - Naming

    func testResultsNeverLandOnSomethingThatExists() {
        let busy = "/дом/договор — часть 1.pdf"
        XCTAssertEqual(Service.freePath(near: "/дом/договор.pdf", suffix: " — часть 1",
                                        fileExists: { $0 == busy }),
                       "/дом/договор — часть 1 2.pdf")
        XCTAssertEqual(Service.freePath(near: "/дом/договор.pdf", suffix: " — часть 1",
                                        taken: [busy], fileExists: { _ in false }),
                       "/дом/договор — часть 1 2.pdf", "и на результат того же захода — тоже")
    }

    /// The name a person types is taken as written — minus what a file name cannot hold — and
    /// ".pdf" is added for them.
    func testATypedNameIsUsedAsWritten() {
        let near = "/дом/Сканы/IMG_1107.PNG"
        XCTAssertEqual(PDFEditService.target(named: "Договор", near: near, fallback: "PDF",
                                             fileExists: { _ in false }),
                       "/дом/Сканы/Договор.pdf")
        XCTAssertEqual(PDFEditService.target(named: "Договор.pdf", near: near, fallback: "PDF",
                                             fileExists: { _ in false }),
                       "/дом/Сканы/Договор.pdf", "расширение не удваивается")
        XCTAssertEqual(PDFEditService.target(named: "  ", near: near, fallback: "Итог",
                                             fileExists: { _ in false }),
                       "/дом/Сканы/Итог.pdf", "пустое имя — подсказанное")
        XCTAssertEqual(PDFEditService.target(named: "а/б:в", near: near, fallback: "PDF",
                                             fileExists: { _ in false }),
                       "/дом/Сканы/а-б-в.pdf", "косая черта и двоеточие имени не по зубам")
        XCTAssertEqual(PDFEditService.target(named: "...тайна", near: near, fallback: "PDF",
                                             fileExists: { _ in false }),
                       "/дом/Сканы/тайна.pdf", "точки впереди прячут файл — они убираются")
    }

    func testATypedNameNeverEatsAnExistingFile() {
        let busy = "/дом/Договор.pdf"
        XCTAssertEqual(PDFEditService.target(named: "Договор", near: "/дом/скан.png",
                                             fallback: "PDF", fileExists: { $0 == busy }),
                       "/дом/Договор 2.pdf")
    }

    // MARK: - Real documents

    /// A PDF whose pages say which page they are, so a shuffled result is recognisable.
    private func makePDF(_ path: String, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        guard let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil)
        else { throw XCTSkip("PDF не создался") }
        for number in 1...pages {
            context.beginPDFPage(nil)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            ("страница \(number)" as NSString).draw(
                at: NSPoint(x: 30, y: 90),
                withAttributes: [.font: NSFont.systemFont(ofSize: 24),
                                 .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func text(of path: String, page: Int) -> String {
        PDFDocument(url: URL(fileURLWithPath: path))?.page(at: page)?.string ?? ""
    }

    func testMergingKeepsTheOrderGiven() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let first = (root as NSString).appendingPathComponent("первый.pdf")
        let second = (root as NSString).appendingPathComponent("второй.pdf")
        try makePDF(first, pages: 2)
        try makePDF(second, pages: 1)

        let target = (root as NSString).appendingPathComponent("вместе.pdf")
        _ = try Service.merge([second, first], into: target)
        XCTAssertEqual(Service.pageCount(of: target), 3)
        XCTAssertTrue(text(of: target, page: 0).contains("страница 1"))
        XCTAssertEqual(Service.pageCount(of: first), 2, "исходные не тронуты")
    }

    func testSplittingWritesEachPartAndLeavesTheOriginal() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = (root as NSString).appendingPathComponent("документ.pdf")
        try makePDF(path, pages: 5)

        let parts = try Service.split(path, parts: Service.chunks(pageCount: 5, size: 2))
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(Service.pageCount(of: parts[0]), 2)
        XCTAssertEqual(Service.pageCount(of: parts[2]), 1, "последняя часть — сколько осталось")
        XCTAssertTrue(text(of: parts[1], page: 0).contains("страница 3"))
        XCTAssertEqual(Service.pageCount(of: path), 5, "оригинал целый")
    }

    func testSplittingByARangeTakesOnlyWhatWasAsked() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-range-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = (root as NSString).appendingPathComponent("длинный.pdf")
        try makePDF(path, pages: 6)

        let chosen = Service.pages(from: "2-3, 6", pageCount: 6)
        let parts = try Service.split(path, parts: [chosen])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(Service.pageCount(of: parts[0]), 3)
        XCTAssertTrue(text(of: parts[0], page: 0).contains("страница 2"))
        XCTAssertTrue(text(of: parts[0], page: 2).contains("страница 6"))
    }

    func testTurningPagesAddsUpAndTouchesOnlyTheChosenOnes() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-rotate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = (root as NSString).appendingPathComponent("боком.pdf")
        try makePDF(path, pages: 3)

        let target = Service.freePath(near: path, suffix: " — повёрнут")
        _ = try Service.rotate(path, degrees: 90, pages: [0, 2], target: target)
        let document = PDFDocument(url: URL(fileURLWithPath: target))
        XCTAssertEqual(document?.page(at: 0)?.rotation, 90)
        XCTAssertEqual(document?.page(at: 1)?.rotation, 0, "нетронутая страница осталась прямой")
        XCTAssertEqual(document?.page(at: 2)?.rotation, 90)

        // Turned again — the turns add up rather than replace one another.
        _ = try Service.rotate(target, degrees: 90, pages: [0], target: target)
        XCTAssertEqual(PDFDocument(url: URL(fileURLWithPath: target))?.page(at: 0)?.rotation, 180)
    }

    // MARK: - Making a PDF out of pictures

    private func makePicture(_ path: String, width: Int, height: Int) throws {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw XCTSkip("не создался растр")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("не вышел PNG")
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Fitted whole, centred — and never blown up past its own pixels: a small photograph
    /// stretched to fill a page only looks worse on paper.
    func testAPictureIsFittedOntoThePageWithoutBeingEnlarged() {
        let page = PDFEditService.a4
        let wide = PDFEditService.placement(for: CGSize(width: 2000, height: 1000),
                                            on: page, margin: 28)
        XCTAssertEqual(wide.width, page.width - 56, accuracy: 0.5, "по ширине — впритык к полям")
        XCTAssertEqual(wide.midX, page.width / 2, accuracy: 0.5, "и по центру")
        XCTAssertEqual(wide.height / wide.width, 0.5, accuracy: 0.01, "пропорции целы")

        let tiny = PDFEditService.placement(for: CGSize(width: 100, height: 80),
                                            on: page, margin: 28)
        XCTAssertEqual(tiny.size, CGSize(width: 100, height: 80), "маленькое не растягивается")
        XCTAssertEqual(PDFEditService.placement(for: .zero, on: page, margin: 28), .zero)
    }

    func testPicturesBecomePagesOfTheirOwnSize() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-make-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let wide = (root as NSString).appendingPathComponent("широкая.png")
        let tall = (root as NSString).appendingPathComponent("высокая.png")
        try makePicture(wide, width: 400, height: 200)
        try makePicture(tall, width: 200, height: 400)

        let target = (root as NSString).appendingPathComponent("сборник.pdf")
        _ = try PDFEditService.makePDF(from: [wide, tall], into: target, pageSize: .picture)
        let document = PDFDocument(url: URL(fileURLWithPath: target))
        XCTAssertEqual(document?.pageCount, 2)
        let first = document?.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
        let second = document?.page(at: 1)?.bounds(for: .mediaBox) ?? .zero
        XCTAssertGreaterThan(first.width, first.height, "широкая осталась широкой")
        XCTAssertGreaterThan(second.height, second.width, "высокая — высокой")
    }

    func testAPageOfA4IsAlwaysA4() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-a4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let picture = (root as NSString).appendingPathComponent("снимок.png")
        try makePicture(picture, width: 1200, height: 400)

        let target = (root as NSString).appendingPathComponent("на печать.pdf")
        _ = try PDFEditService.makePDF(from: [picture], into: target, pageSize: .a4)
        let bounds = PDFDocument(url: URL(fileURLWithPath: target))?
            .page(at: 0)?.bounds(for: .mediaBox) ?? .zero
        XCTAssertEqual(bounds.width, PDFEditService.a4.width, accuracy: 1)
        XCTAssertEqual(bounds.height, PDFEditService.a4.height, accuracy: 1)
    }

    /// A set of scans and a covering letter, bound in one go: the PDF in the list is taken in
    /// whole, page by page.
    func testAPDFInTheListIsTakenInWhole() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-mix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let picture = (root as NSString).appendingPathComponent("скан.png")
        let letter = (root as NSString).appendingPathComponent("письмо.pdf")
        try makePicture(picture, width: 300, height: 300)
        try makePDF(letter, pages: 2)

        let target = (root as NSString).appendingPathComponent("всё вместе.pdf")
        _ = try PDFEditService.makePDF(from: [letter, picture], into: target)
        XCTAssertEqual(PDFEditService.pageCount(of: target), 3, "две страницы письма и снимок")
        XCTAssertTrue(text(of: target, page: 0).contains("страница 1"))
    }

    func testMakingFromNothingUsableComplains() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-bad-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("не картинка".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try PDFEditService.makePDF(from: [path],
                                                        into: path + ".pdf"))
    }

    func testRubbishIsRefusedRatherThanWrittenOver() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-nope-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("это не PDF".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try Service.merge([path], into: path + "-out.pdf"))
        XCTAssertThrowsError(try Service.split(path, parts: [[0]]))
        XCTAssertThrowsError(try Service.rotate(path, degrees: 90, pages: [0], target: path))
        XCTAssertEqual(try? String(contentsOfFile: path, encoding: .utf8), "это не PDF",
                       "файл остался как был")
    }
}
