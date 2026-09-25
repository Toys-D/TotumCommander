import AppKit
import XCTest

@testable import TotumComXLApp

/// Reading the text written inside a picture. The arithmetic and the ordering are checked on
/// made-up boxes; the recogniser itself is checked against a picture drawn here and now, because
/// a wrapper around Vision that has never seen a real letter proves nothing.
final class TextRecognitionTests: XCTestCase {

    // MARK: - Where the highlight lands

    /// Vision counts from the BOTTOM left in fractions; a view counts from the TOP left in
    /// points. Getting it backwards mirrors every highlight down the page.
    func testABoxIsTurnedIntoARectangleOnTheDrawnPicture() {
        let size = CGSize(width: 200, height: 100)
        // A box across the TOP half of the picture, in Vision's terms.
        let top = CGRect(x: 0.1, y: 0.6, width: 0.5, height: 0.3)
        let rect = TextRecognitionService.rect(for: top, in: size)
        XCTAssertEqual(rect.origin.x, 20, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 10, accuracy: 0.001, "верх картинки — малый Y в виде")
        XCTAssertEqual(rect.width, 100, accuracy: 0.001)
        XCTAssertEqual(rect.height, 30, accuracy: 0.001)

        let bottom = CGRect(x: 0, y: 0, width: 1, height: 0.2)
        XCTAssertEqual(TextRecognitionService.rect(for: bottom, in: size).origin.y, 80,
                       accuracy: 0.001, "низ картинки — большой Y в виде")
    }

    func testTheLineUnderThePointIsFound() {
        let lines = [
            RecognizedLine(id: 0, text: "верх", box: CGRect(x: 0, y: 0.8, width: 1, height: 0.15),
                           confidence: 1),
            RecognizedLine(id: 1, text: "низ", box: CGRect(x: 0, y: 0.05, width: 1, height: 0.15),
                           confidence: 1),
        ]
        let size = CGSize(width: 100, height: 100)
        XCTAssertEqual(TextRecognitionService.line(at: CGPoint(x: 50, y: 10), lines: lines,
                                                   in: size)?.text, "верх")
        XCTAssertEqual(TextRecognitionService.line(at: CGPoint(x: 50, y: 90), lines: lines,
                                                   in: size)?.text, "низ")
        XCTAssertNil(TextRecognitionService.line(at: CGPoint(x: 50, y: 50), lines: lines,
                                                  in: size), "между строками — ничего")
    }

    // MARK: - Reading order

    /// Vision promises no order at all, and a receipt scatters its pieces over the page. Sorting
    /// by the top edge alone drops a heading between two halves of the line beside it.
    func testPiecesAreSortedTheWayAPersonReads() {
        let found = [
            TextRecognitionService.Piece(
                text: "справа", box: CGRect(x: 0.6, y: 0.80, width: 0.3, height: 0.08),
                confidence: 1),
            TextRecognitionService.Piece(
                text: "нижняя", box: CGRect(x: 0.1, y: 0.20, width: 0.3, height: 0.08),
                confidence: 1),
            TextRecognitionService.Piece(
                text: "слева", box: CGRect(x: 0.1, y: 0.81, width: 0.3, height: 0.08),
                confidence: 1),
        ]
        let lines = TextRecognitionService.inReadingOrder(found)
        XCTAssertEqual(lines.map(\.text), ["слева", "справа", "нижняя"])
        XCTAssertEqual(lines.map(\.id), [0, 1, 2], "порядок и есть номер строки")
        XCTAssertEqual(TextRecognitionService.plainText(lines), "слева\nсправа\nнижняя")
    }

    // MARK: - Words

    func testWordRangesAreFoundWithoutLosingTheirPlaces() {
        XCTAssertEqual("Артикул: 1111311".ranges().map { String("Артикул: 1111311"[$0]) },
                       ["Артикул:", "1111311"])
        XCTAssertEqual("  два   пробела  ".ranges().map { String("  два   пробела  "[$0]) },
                       ["два", "пробела"], "лишние пробелы не рождают пустых слов")
        XCTAssertTrue("".ranges().isEmpty)
    }

    /// A click has to hit the WORD, not just the line it sits in — that is the whole point of
    /// copying one price out of a page.
    func testTheWordUnderThePointIsFound() {
        let line = RecognizedLine(
            id: 0, text: "Артикул 1111311",
            box: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1), confidence: 1,
            words: [
                RecognizedWord(id: 0, text: "Артикул",
                               box: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.1)),
                RecognizedWord(id: 1, text: "1111311",
                               box: CGRect(x: 0.6, y: 0.5, width: 0.3, height: 0.1)),
            ])
        let size = CGSize(width: 100, height: 100)
        XCTAssertEqual(TextRecognitionService.word(at: CGPoint(x: 20, y: 45), lines: [line],
                                                    in: size)?.text, "Артикул")
        XCTAssertEqual(TextRecognitionService.word(at: CGPoint(x: 70, y: 45), lines: [line],
                                                    in: size)?.text, "1111311")
        XCTAssertNil(TextRecognitionService.word(at: CGPoint(x: 52, y: 45), lines: [line],
                                                  in: size), "между словами — ничего")
        XCTAssertNotNil(TextRecognitionService.line(at: CGPoint(x: 52, y: 45), lines: [line],
                                                     in: size), "но строка там есть")
    }

    // MARK: - Dragging across the words

    /// Two lines of three words each, laid out like a page: the top line at the top.
    private func page() -> [RecognizedLine] {
        func line(_ id: Int, _ words: [String], y: CGFloat) -> RecognizedLine {
            let placed = words.enumerated().map { index, text in
                RecognizedWord(id: index, text: text,
                               box: CGRect(x: 0.05 + CGFloat(index) * 0.3, y: y,
                                           width: 0.25, height: 0.08))
            }
            return RecognizedLine(id: id, text: words.joined(separator: " "),
                                  box: CGRect(x: 0.05, y: y, width: 0.85, height: 0.08),
                                  confidence: 1, words: placed)
        }
        return [line(0, ["Отримати", "сьогодні", "09:30"], y: 0.8),
                line(1, ["Кур'єром", "за", "адресою"], y: 0.5)]
    }

    private let canvas = CGSize(width: 1000, height: 1000)

    /// Point at the middle of a word, in view coordinates.
    private func middle(_ line: Int, _ word: Int, _ lines: [RecognizedLine]) -> CGPoint {
        let box = lines[line].words[word].box
        let rect = TextRecognitionService.rect(for: box, in: canvas)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func testDraggingAcrossWordsTakesEverythingBetweenThem() {
        let lines = page()
        let picked = TextRecognitionService.selection(
            from: middle(0, 0, lines), to: middle(0, 2, lines), lines: lines, in: canvas)
        XCTAssertEqual(picked.text, "Отримати сьогодні 09:30")
        XCTAssertEqual(picked.keys.count, 3)
    }

    /// Dragging onto the next line takes the rest of the first one and the start of the second —
    /// the way a selection in a text works, not a rectangle over the page.
    func testASelectionAcrossLinesFollowsTheReadingOrder() {
        let lines = page()
        let picked = TextRecognitionService.selection(
            from: middle(0, 1, lines), to: middle(1, 0, lines), lines: lines, in: canvas)
        XCTAssertEqual(picked.text, "сьогодні 09:30\nКур'єром", "перенос строки на месте")
    }

    func testDraggingBackwardsSelectsTheSameRun() {
        let lines = page()
        let forward = TextRecognitionService.selection(
            from: middle(0, 0, lines), to: middle(1, 2, lines), lines: lines, in: canvas)
        let backward = TextRecognitionService.selection(
            from: middle(1, 2, lines), to: middle(0, 0, lines), lines: lines, in: canvas)
        XCTAssertEqual(forward.text, backward.text, "тянуть вверх — то же, что вниз")
        XCTAssertEqual(forward.keys, backward.keys)
    }

    /// A pointer between two words must not break the selection — that is what makes dragging
    /// across a page feel like dragging across text.
    func testAPointerInAGapStillBelongsToAWord() {
        let lines = page()
        let gap = CGPoint(x: middle(0, 0, lines).x + 145, y: middle(0, 0, lines).y)
        XCTAssertNotNil(TextRecognitionService.nearestWord(
            to: gap, among: TextRecognitionService.placedWords(lines, in: canvas)))
        let picked = TextRecognitionService.selection(from: middle(0, 0, lines), to: gap,
                                                      lines: lines, in: canvas)
        XCTAssertFalse(picked.text.isEmpty)
    }

    /// A pointer below the last line belongs to the line above it, not to whatever word is
    /// nearest sideways somewhere else.
    func testTheNearestWordPrefersTheRightLine() {
        let lines = page()
        let belowSecondLine = CGPoint(x: middle(1, 1, lines).x, y: middle(1, 1, lines).y + 60)
        let word = TextRecognitionService.nearestWord(
            to: belowSecondLine, among: TextRecognitionService.placedWords(lines, in: canvas))
        XCTAssertEqual(word?.text, "за")
    }

    // MARK: - Light letters on a dark ground

    /// The recogniser's weak spot, and the reason for the second pass: a logo that plainly says
    /// ALLUMIERA came back as "LUMI" — and the very same picture inverted came back right.
    func testALightLegendOnADarkGroundIsReadFromTheNegative() throws {
        let size = NSSize(width: 900, height: 300)
        let picture = NSImage(size: size)
        picture.lockFocus()
        NSColor(calibratedRed: 0.55, green: 0.03, blue: 0.08, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        ("ALLUMIERA" as NSString).draw(
            at: NSPoint(x: 40, y: 110),
            withAttributes: [.font: NSFont.systemFont(ofSize: 90, weight: .light),
                             .foregroundColor: NSColor(calibratedRed: 0.98, green: 0.80,
                                                        blue: 0.60, alpha: 1)])
        picture.unlockFocus()
        guard let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return XCTFail("картинка не получилась")
        }
        XCTAssertTrue(TextRecognitionService.isDark(image), "тёмная картинка распознана как тёмная")
        let lines = try TextRecognitionService.recognizeBestPolarity(image)
        XCTAssertTrue(TextRecognitionService.plainText(lines).uppercased().contains("ALLUMIERA"),
                      "прочитано: «\(TextRecognitionService.plainText(lines))»")
    }

    /// A white page is read once — a second pass over a scan would only cost time.
    func testAWhitePageIsNotConsideredDark() throws {
        let picture = NSImage(size: NSSize(width: 400, height: 200))
        picture.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 200).fill()
        ("СЧЁТ" as NSString).draw(at: NSPoint(x: 20, y: 60),
                                  withAttributes: [.font: NSFont.systemFont(ofSize: 64),
                                                   .foregroundColor: NSColor.black])
        picture.unlockFocus()
        let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        XCTAssertFalse(TextRecognitionService.isDark(image))
    }

    /// The better reading wins, and "better" means more letters the recogniser was sure of.
    func testTheScoreRewardsConfidentLetters() {
        let sure = [RecognizedLine(id: 0, text: "ALLUMIERA", box: .zero, confidence: 0.9)]
        let unsure = [RecognizedLine(id: 0, text: "LUMI", box: .zero, confidence: 0.9)]
        XCTAssertGreaterThan(TextRecognitionService.score(sure),
                             TextRecognitionService.score(unsure))
        let doubtful = [RecognizedLine(id: 0, text: "ALLUMIERA", box: .zero, confidence: 0.1)]
        XCTAssertLessThan(TextRecognitionService.score(doubtful),
                          TextRecognitionService.score(unsure), "неуверенное длинное не побеждает")
    }

    // MARK: - Pages as pictures

    func testPageCountAndRenderingOfADocument() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-pages-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(atPath: path) }
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil) else {
            return XCTFail("PDF не создался")
        }
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()

        XCTAssertEqual(TextRecognitionService.pageCount(ofFile: path), 3)
        let page = TextRecognitionService.renderPage(ofFile: path, index: 2)
        XCTAssertNotNil(page, "третья страница рисуется")
        XCTAssertGreaterThan(page?.size.width ?? 0, 400, "и не в размер точек, а в размер скана")
        XCTAssertNil(TextRecognitionService.renderPage(ofFile: path, index: 9),
                     "за последней страницей ничего нет")
        XCTAssertEqual(TextRecognitionService.pageCount(ofFile: "/нет/такого.pdf"), 0)
    }

    // MARK: - Searching pictures by what is written in them

    /// A folder with two pictures and a decoy: only the picture that says the word answers, and
    /// the .txt is never opened by this search — the ordinary content search already finds it.
    func testSearchFindsThePictureThatSaysTheWord() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-find-\(UUID().uuidString)")
        let nested = (root as NSString).appendingPathComponent("вложенная")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        func write(_ word: String, to path: String) throws {
            let picture = NSImage(size: NSSize(width: 600, height: 200))
            picture.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 600, height: 200).fill()
            (word as NSString).draw(at: NSPoint(x: 20, y: 60),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 64,
                                                                              weight: .semibold),
                                                     .foregroundColor: NSColor.black])
            picture.unlockFocus()
            let rep = NSBitmapImageRep(data: picture.tiffRepresentation!)!
            try rep.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: path))
        }
        try write("НАКЛАДНАЯ", to: (root as NSString).appendingPathComponent("первая.png"))
        try write("ДОГОВОР", to: (nested as NSString).appendingPathComponent("вторая.png"))
        try "накладная".write(toFile: (root as NSString).appendingPathComponent("записка.txt"),
                              atomically: true, encoding: .utf8)

        var visited: [String] = []
        let found = TextRecognitionService.search("накладная", under: root,
                                                  onFile: { visited.append($0) })
        XCTAssertEqual(found.hits.count, 1)
        XCTAssertEqual((found.hits.first?.path as NSString?)?.lastPathComponent, "первая.png")
        XCTAssertTrue(found.hits.first?.text.uppercased().contains("НАКЛАДНАЯ") ?? false)
        XCTAssertEqual(found.examined, 2, "прочитаны обе картинки и только они")
        XCTAssertFalse(visited.contains { $0.hasSuffix(".txt") }, "текстовый файл не открывался")
        XCTAssertFalse(found.reachedLimit)

        // Without descending, the picture in the subfolder is out of reach.
        let shallow = TextRecognitionService.search("договор", under: root, recursive: false)
        XCTAssertTrue(shallow.hits.isEmpty)
        XCTAssertEqual(TextRecognitionService.search("договор", under: root).hits.count, 1)
    }

    /// The limit is what keeps a folder of ten thousand photographs from becoming an hour of
    /// work — and when it stops early it says so instead of pretending that was everything.
    func testTheLimitStopsTheSearchAndSaysSo() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let picture = NSImage(size: NSSize(width: 80, height: 40))
        picture.lockFocus(); NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 80, height: 40).fill(); picture.unlockFocus()
        let data = NSBitmapImageRep(data: picture.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!
        for index in 0..<4 {
            try data.write(to: URL(fileURLWithPath:
                (root as NSString).appendingPathComponent("п\(index).png")))
        }
        let found = TextRecognitionService.search("что угодно", under: root, limit: 2)
        XCTAssertEqual(found.examined, 2)
        XCTAssertTrue(found.reachedLimit, "остановка на пределе названа вслух")
    }

    func testExcludedFoldersAreNotWalked() {
        XCTAssertTrue(TextRecognitionService.isExcluded("/дом/node_modules/значок.png",
                                                        by: ["node_modules"]))
        XCTAssertTrue(TextRecognitionService.isExcluded("/дом/кэш.tmp", by: ["*.tmp"]))
        XCTAssertFalse(TextRecognitionService.isExcluded("/дом/снимок.png", by: ["node_modules"]))
        XCTAssertFalse(TextRecognitionService.isExcluded("/дом/снимок.png", by: []))
    }

    /// An empty query answers nothing rather than everything — the same rule the rules engine
    /// follows for an empty mask.
    func testAnEmptyQueryFindsNothing() {
        let found = TextRecognitionService.search("   ", under: NSTemporaryDirectory())
        XCTAssertTrue(found.hits.isEmpty)
        XCTAssertEqual(found.examined, 0, "и ни одного файла не открывает")
    }

    // MARK: - Whether recognition is worth offering at all

    /// Draw a PDF whose pages either carry text or are pictures of it.
    private func makeDocument(pages: [Bool]) throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-need-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        guard let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil)
        else { throw XCTSkip("PDF не создался") }
        for hasText in pages {
            context.beginPDFPage(nil)
            if hasText {
                let graphics = NSGraphicsContext(cgContext: context, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                ("Договор поставки" as NSString).draw(
                    at: NSPoint(x: 40, y: 90),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 22),
                                     .foregroundColor: NSColor.black])
                NSGraphicsContext.restoreGraphicsState()
            } else {
                // A page that is only a picture — a scan.
                let picture = NSImage(size: NSSize(width: 400, height: 200))
                picture.lockFocus()
                NSColor.white.setFill()
                NSRect(x: 0, y: 0, width: 400, height: 200).fill()
                ("СКАН" as NSString).draw(at: NSPoint(x: 40, y: 80),
                                          withAttributes: [.font: NSFont.systemFont(ofSize: 48),
                                                           .foregroundColor: NSColor.black])
                picture.unlockFocus()
                if let cgImage = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    context.draw(cgImage, in: box)
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
        return path
    }

    /// A document that already carries its text can be selected and copied as it is — offering
    /// to "recognise" it promises a worse copy of what is on screen.
    func testADocumentWithItsOwnTextNeedsNothing() throws {
        let path = try makeDocument(pages: [true, true])
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertFalse(TextRecognitionService.needsRecognition(pdf: path))
        XCTAssertFalse(TextRecognitionService.needsRecognition(file: path))
    }

    func testAScanNeedsRecognition() throws {
        let path = try makeDocument(pages: [false, false])
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(TextRecognitionService.needsRecognition(pdf: path))
    }

    /// A contract with a scanned signature page: one page without text of its own is reason
    /// enough to offer.
    func testOnePageWithoutTextIsEnough() throws {
        let path = try makeDocument(pages: [true, false, true])
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(TextRecognitionService.needsRecognition(pdf: path))
    }

    /// Only the first pages are opened: deciding whether to draw a button must not cost a walk
    /// through a four-hundred-page book.
    func testOnlyTheFirstPagesAreLookedAt() throws {
        let path = try makeDocument(pages: [true, true, false])
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(TextRecognitionService.needsRecognition(pdf: path, checking: 3))
        XCTAssertFalse(TextRecognitionService.needsRecognition(pdf: path, checking: 2),
                       "дальше второй страницы не смотрели — и не должны были")
    }

    func testPicturesAndRubbish() {
        XCTAssertTrue(TextRecognitionService.needsRecognition(file: "/x/снимок.jpg"),
                      "у картинки своего текста не бывает")
        XCTAssertTrue(TextRecognitionService.needsRecognition(file: "/x/книга.djvu"))
        XCTAssertFalse(TextRecognitionService.needsRecognition(file: "/x/архив.zip"))
        XCTAssertFalse(TextRecognitionService.needsRecognition(pdf: "/нет/такого.pdf"),
                       "нечитаемый файл ничего не просит")
    }

    // MARK: - Which files are offered at all

    /// The menu item appears only where there can BE text to read; on a .zip it would answer
    /// "nothing found" every time.
    func testOnlyPicturesScansAndPDFsAreOffered() {
        for path in ["/x/снимок.jpg", "/x/скан.png", "/x/договор.pdf", "/x/книга.djvu",
                     "/x/ФОТО.HEIC"] {
            XCTAssertTrue(TextRecognitionService.canReadText(in: path), path)
        }
        for path in ["/x/архив.zip", "/x/записка.txt", "/x/кино.mp4", "/x/папка"] {
            XCTAssertFalse(TextRecognitionService.canReadText(in: path), path)
        }
    }

    // MARK: - Whole documents

    /// A PDF page carrying its own text is READ, not recognised: a document made by a program
    /// has that text exactly right, and a picture of it would be both slower and worse.
    func testAPDFWithATextLayerIsReadRatherThanRecognised() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-ocr-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(atPath: path) }
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil) else {
            return XCTFail("PDF не создался")
        }
        context.beginPDFPage(nil)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        ("Договор поставки № 42" as NSString).draw(
            at: NSPoint(x: 60, y: 700),
            withAttributes: [.font: NSFont.systemFont(ofSize: 24),
                             .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        let pages = TextRecognitionService.text(ofFile: path)
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages.first?.fromTextLayer ?? false, "слой текста взят как есть")
        XCTAssertTrue(pages.first?.text.contains("Договор") ?? false, "«\(pages.first?.text ?? "")»")
    }

    /// A scan — a page that is only a picture — is recognised, and says so.
    func testAScannedPageIsRecognised() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-scan-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(atPath: path) }

        // A picture of text, drawn into a PDF as an image — exactly what a scanner produces.
        let pageSize = NSSize(width: 600, height: 300)
        let picture = NSImage(size: pageSize)
        picture.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: pageSize).fill()
        ("СКАН 2026" as NSString).draw(at: NSPoint(x: 40, y: 120),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 72,
                                                                                 weight: .bold),
                                                        .foregroundColor: NSColor.black])
        picture.unlockFocus()

        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil),
              let cgPicture = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return XCTFail("PDF не создался")
        }
        context.beginPDFPage(nil)
        context.draw(cgPicture, in: box)
        context.endPDFPage()
        context.closePDF()

        var seen: [(Int, Int)] = []
        let pages = TextRecognitionService.text(ofFile: path, onPage: { done, total in
            seen.append((done, total))
        })
        XCTAssertEqual(pages.count, 1)
        XCTAssertFalse(pages.first?.fromTextLayer ?? true, "у скана своего текста нет")
        XCTAssertTrue(pages.first?.text.contains("2026") ?? false, "«\(pages.first?.text ?? "")»")
        XCTAssertEqual(seen.last?.1, 1, "о ходе работы сообщается")
    }

    /// A picture is one page, and a file nobody can read gives nothing rather than throwing.
    func testAPictureIsOnePageAndRubbishIsSilent() throws {
        let folder = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-ocr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }

        let picture = NSImage(size: NSSize(width: 500, height: 160))
        picture.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 500, height: 160).fill()
        ("НАКЛАДНАЯ" as NSString).draw(at: NSPoint(x: 20, y: 50),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 56,
                                                                                 weight: .semibold),
                                                        .foregroundColor: NSColor.black])
        picture.unlockFocus()
        let imagePath = (folder as NSString).appendingPathComponent("скан.png")
        let rep = NSBitmapImageRep(data: picture.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: imagePath))

        let pages = TextRecognitionService.text(ofFile: imagePath)
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages.first?.text.uppercased().contains("НАКЛАДНАЯ") ?? false,
                      "«\(pages.first?.text ?? "")»")

        let broken = (folder as NSString).appendingPathComponent("ломаный.pdf")
        try Data("не PDF вовсе".utf8).write(to: URL(fileURLWithPath: broken))
        XCTAssertTrue(TextRecognitionService.text(ofFile: broken).isEmpty,
                      "нечитаемый файл молча даёт пусто")
    }

    // MARK: - Languages

    func testOnlyTheLanguagesThisMachineKnowsAreAsked() {
        let chosen = TextRecognitionService.languages(
            wanted: ["ru-RU", "en-US", "kl-GL"], supported: ["en-US", "ru-RU", "de-DE"])
        XCTAssertEqual(chosen, ["ru-RU", "en-US"], "порядок пожеланий сохраняется")
    }

    /// A macOS that spells them shorter still counts — asking for nothing would leave Vision
    /// guessing at every picture.
    func testAShorterSpellingStillCounts() {
        let chosen = TextRecognitionService.languages(wanted: ["ru-RU"], supported: ["ru", "en"])
        XCTAssertEqual(chosen, ["ru"])
        XCTAssertTrue(TextRecognitionService.languages(wanted: ["zz-ZZ"], supported: ["en"]).isEmpty)
    }

    func testThisMachineCanReadRussianAndEnglish() {
        let supported = TextRecognitionService.supportedLanguages()
        XCTAssertFalse(supported.isEmpty, "система вообще умеет распознавать текст")
        let chosen = TextRecognitionService.languages(
            wanted: TextRecognitionService.preferredLanguages, supported: supported)
        XCTAssertEqual(chosen.count, 2, "русский и английский доступны из коробки: \(supported)")
    }

    // MARK: - Against a real picture

    /// A picture drawn here, read back by Vision. Slow by the standards of the other tests
    /// (about a second), and the only one that proves the wrapper actually reads letters.
    func testTextDrawnIntoAPictureIsReadBack() throws {
        let size = NSSize(width: 900, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        ("ДОГОВОР" as NSString).draw(at: NSPoint(x: 40, y: 180), withAttributes: attributes)
        ("Invoice 2026" as NSString).draw(at: NSPoint(x: 40, y: 60), withAttributes: attributes)
        image.unlockFocus()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return XCTFail("картинка не собралась")
        }

        let lines = try TextRecognitionService.recognize(cgImage)
        let text = TextRecognitionService.plainText(lines).lowercased()
        XCTAssertTrue(text.contains("договор"), "русское слово прочитано: «\(text)»")
        XCTAssertTrue(text.contains("2026"), "английская строка прочитана: «\(text)»")
        // Drawn lower on the page, so it must come second in the reading order.
        XCTAssertTrue(lines.first?.text.lowercased().contains("договор") ?? false,
                      "верхняя строка идёт первой")
        XCTAssertTrue(lines.allSatisfy { $0.box.width > 0 && $0.box.height > 0 })

        // And the words of a line are placed inside it, left to right.
        guard let invoice = lines.first(where: { $0.text.lowercased().contains("2026") }) else {
            return XCTFail("строка со счётом не найдена")
        }
        XCTAssertGreaterThanOrEqual(invoice.words.count, 2, "строка разобрана на слова")
        let boxes = invoice.words.map(\.box)
        XCTAssertEqual(boxes, boxes.sorted { $0.minX < $1.minX }, "слова идут слева направо")
        for box in boxes {
            XCTAssertTrue(invoice.box.insetBy(dx: -0.02, dy: -0.02).contains(box),
                          "слово лежит внутри своей строки")
        }
    }
}
