import AppKit
import CoreImage
import Vision

/// One word inside a found line, with its own place on the picture.
struct RecognizedWord: Equatable, Identifiable {
    let id: Int
    let text: String
    /// Vision's normalised box, like the line's: 0…1, origin at the BOTTOM left.
    let box: CGRect
}

/// One line of text found in a picture.
struct RecognizedLine: Equatable, Identifiable {
    /// Position in the reading order — stable, and enough to tell two identical lines apart.
    let id: Int
    let text: String
    /// Where it sits, in Vision's own normalised coordinates: 0…1, origin at the BOTTOM left.
    let box: CGRect
    /// How sure the recogniser is, 0…1.
    let confidence: Float
    /// The words of this line, each with its own box — so a click can copy one word rather than
    /// the whole line it happens to sit in. Empty when Vision could not place them.
    var words: [RecognizedWord] = []
}

/// Reading the text written inside a picture — the system's own recogniser, on this machine.
///
/// Vision ships with macOS and works without a network, which is the whole reason to use it here:
/// a file manager must not send someone's photographs anywhere to tell them what is written on
/// them. Everything below except `recognize` is pure arithmetic and text handling, so the parts
/// that decide WHAT is shown and WHERE can be tested without a camera or a scanner.
enum TextRecognitionService {

    /// What the person's own text is likely to be in. Russian and English are asked for by
    /// default — the two this program is spoken in — and anything the installed macOS cannot do
    /// is dropped rather than making the whole request fail.
    static let preferredLanguages = ["ru-RU", "en-US"]

    static func supportedLanguages() -> [String] {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
    }

    /// The languages actually asked of Vision: the wanted ones that this machine knows, in the
    /// order they were wanted. An empty answer means "let Vision choose", which is better than
    /// asking for nothing at all.
    static func languages(wanted: [String], supported: [String]) -> [String] {
        let known = Set(supported)
        var chosen = wanted.filter { known.contains($0) }
        if chosen.isEmpty {
            // A machine that spells them differently ("ru" instead of "ru-RU") still counts.
            chosen = wanted.compactMap { wanted in
                supported.first { $0.hasPrefix(String(wanted.prefix(2))) }
            }
        }
        return chosen
    }

    // MARK: - Reading

    /// Find the lines in one picture. Blocking — Vision does the work on the calling thread, so
    /// this belongs on a background queue, never on the one drawing the window.
    /// Read a picture, trying the negative as well when the picture is a dark one.
    ///
    /// Light letters on a dark ground are the recogniser's weak spot: a logo that plainly says
    /// ALLUMIERA came back as "LUMI", and the very same picture inverted came back right. So a
    /// dark picture is read both ways and the better reading wins. A white page — a scan, a
    /// document — is read once, as before: there is nothing to gain and a second pass to pay for.
    static func recognizeBestPolarity(_ image: CGImage,
                                      languages: [String] = []) throws -> [RecognizedLine] {
        let direct = try recognize(image, languages: languages)
        guard isDark(image), let negative = inverted(image) else { return direct }
        guard let other = try? recognize(negative, languages: languages) else { return direct }
        return score(other) > score(direct) ? other : direct
    }

    /// How much readable text a reading holds: characters, each weighted by how sure the
    /// recogniser was. A confident "ALLUMIERA" beats a hesitant "LUMI"; noise scores low because
    /// it is both short and unsure.
    static func score(_ lines: [RecognizedLine]) -> Double {
        lines.reduce(0) { $0 + Double($1.text.count) * Double($1.confidence) }
    }

    /// Is this mostly a dark picture? Measured on a thumbnail — the answer needs no detail.
    static func isDark(_ image: CGImage, threshold: Double = 0.45) -> Bool {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            // Plain luminance: green counts most, blue least, as the eye has it.
            total += 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1])
                + 0.0722 * Double(pixels[index + 2])
        }
        return total / Double(side * side) / 255 < threshold
    }

    /// The same picture with its colours turned round.
    static func inverted(_ image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIColorInvert") else { return nil }
        filter.setValue(source, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    static func recognize(_ image: CGImage, languages: [String] = []) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        // Accurate rather than fast: a photograph of a document is exactly the case where the
        // quick pass turns "Договор" into "Доroвop", and the wait is a second, not a minute.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let asked = languages.isEmpty
            ? self.languages(wanted: preferredLanguages, supported: supportedLanguages())
            : languages
        if !asked.isEmpty { request.recognitionLanguages = asked }

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        let found = observations.compactMap { observation -> Piece? in
            guard let best = observation.topCandidates(1).first else { return nil }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Piece(text: text, box: observation.boundingBox,
                         confidence: best.confidence, words: words(in: best))
        }
        return inReadingOrder(found)
    }

    /// The words of one recognised line, each asked for its own place on the picture.
    ///
    /// Vision hands back a string and one box around the whole line; where a particular word sits
    /// has to be asked for separately, by the range it occupies in that string.
    static func words(in candidate: VNRecognizedText) -> [RecognizedWord] {
        var result: [RecognizedWord] = []
        let text = candidate.string
        var index = 0
        for range in text.ranges(ofWordsSeparatedByWhitespace: ()) {
            let word = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            guard let box = try? candidate.boundingBox(for: range) else { continue }
            result.append(RecognizedWord(id: index, text: word, box: box.boundingBox))
            index += 1
        }
        return result
    }

    /// What one observation gave us, before the pieces are put in reading order.
    struct Piece {
        let text: String
        let box: CGRect
        let confidence: Float
        var words: [RecognizedWord] = []
    }

    /// Sort what Vision found the way a person reads it: down the page, and left to right
    /// within a line.
    ///
    /// Vision returns its observations in no promised order, and a receipt or a form scatters
    /// them across the page — sorting by the top edge alone puts a column heading between two
    /// halves of the line beside it.
    static func inReadingOrder(_ found: [Piece]) -> [RecognizedLine] {
        // Two pieces belong to the same line when their vertical middles are closer than half
        // the height of the shorter one.
        let sorted = found.sorted { left, right in
            let tolerance = min(left.box.height, right.box.height) / 2
            if abs(left.box.midY - right.box.midY) <= tolerance {
                return left.box.minX < right.box.minX
            }
            return left.box.midY > right.box.midY   // Vision counts Y upward: bigger is higher
        }
        return sorted.enumerated().map { index, piece in
            RecognizedLine(id: index, text: piece.text, box: piece.box,
                           confidence: piece.confidence, words: piece.words)
        }
    }

    /// The whole text as one string, ready for the clipboard or a .txt beside the picture.
    static func plainText(_ lines: [RecognizedLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }

    // MARK: - Putting the boxes back on the picture

    /// Vision's normalised box turned into a rectangle on a drawn picture.
    ///
    /// Vision counts from the BOTTOM left and in fractions of the image; a view counts from the
    /// TOP left and in points. Getting this backwards is the classic way to end up with the
    /// highlights mirrored down the page, so it lives here on its own and is tested.
    static func rect(for box: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width,
               y: (1 - box.maxY) * size.height,
               width: box.width * size.width,
               height: box.height * size.height)
    }

    /// The word under a point, if any — what a plain click copies.
    static func word(at point: CGPoint, lines: [RecognizedLine], in size: CGSize)
        -> RecognizedWord? {
        guard let line = self.line(at: point, lines: lines, in: size) else { return nil }
        return line.words.first { rect(for: $0.box, in: size).insetBy(dx: -2, dy: -2)
            .contains(point) }
    }

    // MARK: - Selecting a run of words

    /// One word of the picture, together with where it stands in the reading order.
    struct PlacedWord: Equatable {
        let lineID: Int
        let wordID: Int
        let text: String
        let rect: CGRect
        /// "<line>.<word>" — what the overlay uses to know which highlights are chosen.
        var key: String { "\(lineID).\(wordID)" }
    }

    /// Every word of the picture in reading order, already in view coordinates.
    static func placedWords(_ lines: [RecognizedLine], in size: CGSize) -> [PlacedWord] {
        lines.flatMap { line in
            line.words.map {
                PlacedWord(lineID: line.id, wordID: $0.id, text: $0.text,
                           rect: rect(for: $0.box, in: size))
            }
        }
    }

    /// The word a point belongs to when the finger is dragging: the one under it, or — if the
    /// drag is between words or off the end of a line — the nearest one.
    ///
    /// "Nearest" rather than "none", because a selection must not break the moment the pointer
    /// crosses a gap between two words; that is what makes dragging across a page feel like
    /// dragging across text.
    static func nearestWord(to point: CGPoint, among words: [PlacedWord]) -> PlacedWord? {
        if let hit = words.last(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) {
            return hit
        }
        return words.min { left, right in
            distance(from: point, to: left.rect) < distance(from: point, to: right.rect)
        }
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        // Vertical distance counts double: a pointer between two lines belongs to the line it is
        // closer to, not to whatever word happens to be nearest sideways on the other one.
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + (dy * 2) * (dy * 2)
    }

    /// Everything between two points, the way a text selection works: from the word where the
    /// drag began to the word where it is now, in reading order, whole lines in between included.
    static func selection(from start: CGPoint, to end: CGPoint,
                          lines: [RecognizedLine], in size: CGSize) -> (keys: Set<String>, text: String) {
        let words = placedWords(lines, in: size)
        guard let first = nearestWord(to: start, among: words),
              let last = nearestWord(to: end, among: words),
              let firstIndex = words.firstIndex(of: first),
              let lastIndex = words.firstIndex(of: last) else { return ([], "") }
        let range = firstIndex <= lastIndex ? firstIndex...lastIndex : lastIndex...firstIndex
        let chosen = Array(words[range])

        var text = ""
        var previousLine: Int?
        for word in chosen {
            if let previousLine, previousLine != word.lineID { text += "\n" }
            else if previousLine != nil { text += " " }
            text += word.text
            previousLine = word.lineID
        }
        return (Set(chosen.map(\.key)), text)
    }

    /// The line under a point on the drawn picture, if any. Used to copy one line by clicking it.
    static func line(at point: CGPoint, lines: [RecognizedLine], in size: CGSize)
        -> RecognizedLine? {
        // Reversed: later lines are drawn over earlier ones, so the topmost wins a tie.
        lines.reversed().first { rect(for: $0.box, in: size).contains(point) }
    }
}

extension String {
    /// Ranges of the words in this string — the pieces between runs of whitespace.
    ///
    /// Written out rather than taken from `components(separatedBy:)`, because Vision needs the
    /// RANGE of a word to say where it sits, and splitting into strings throws exactly that away.
    func ranges(ofWordsSeparatedByWhitespace _: Void = ()) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in indices {
            let isSpace = self[index].isWhitespace
            if !isSpace, start == nil { start = index }
            if isSpace, let began = start {
                ranges.append(began..<index)
                start = nil
            }
        }
        if let began = start { ranges.append(began..<endIndex) }
        return ranges
    }
}

// MARK: - Whole documents

import FCXLBridgeObjC
import FCXLDjVuUI
import PDFKit

extension TextRecognitionService {

    /// The text of one page of a document.
    struct DocumentPage: Equatable {
        /// 1-based, the way a person counts pages.
        let number: Int
        let text: String
        /// True when the page already carried its own text and nothing had to be recognised.
        /// A PDF made by a program has that text exactly right — recognising its picture instead
        /// would be slower AND worse.
        let fromTextLayer: Bool
    }

    /// What a whole file says, page by page.
    ///
    /// A picture is one page. A PDF is read page by page, and each page is only recognised when
    /// it has no text of its own — a scan. DjVu is always a scan and always recognised.
    static func text(ofFile path: String, maxPages: Int = 50,
                     shouldCancel: () -> Bool = { false },
                     onPage: ((Int, Int) -> Void)? = nil) -> [DocumentPage] {
        let category = fileCategory(extension: (path as NSString).pathExtension)
        switch category {
        case .pdf:
            return textInPDF(path: path, maxPages: maxPages,
                             shouldCancel: shouldCancel, onPage: onPage)
        case .djvu:
            return textInDjVu(path: path, maxPages: maxPages,
                              shouldCancel: shouldCancel, onPage: onPage)
        default:
            onPage?(0, 1)
            guard let image = NSImage(contentsOfFile: path),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let lines = try? recognizeBestPolarity(cgImage) else { return [] }
            onPage?(1, 1)
            let text = plainText(lines)
            return text.isEmpty ? [] : [DocumentPage(number: 1, text: text, fromTextLayer: false)]
        }
    }

    /// How many pages a document has. A picture is one page; anything unreadable is none.
    static func pageCount(ofFile path: String) -> Int {
        switch fileCategory(extension: (path as NSString).pathExtension) {
        case .pdf:
            return PDFDocument(url: URL(fileURLWithPath: path))?.pageCount ?? 0
        case .djvu:
            return (try? FCXLDjVuReader(path: path))?.pageCount ?? 0
        case .image:
            return 1
        default:
            return 0
        }
    }

    /// One page of a document as a picture — what the viewer puts on screen so the words can be
    /// marked on it and dragged over, exactly as on a photograph.
    static func renderPage(ofFile path: String, index: Int) -> NSImage? {
        switch fileCategory(extension: (path as NSString).pathExtension) {
        case .pdf:
            guard let document = PDFDocument(url: URL(fileURLWithPath: path)),
                  index >= 0, index < document.pageCount,
                  let page = document.page(at: index),
                  let rendered = render(page: page) else { return nil }
            return NSImage(cgImage: rendered,
                           size: NSSize(width: rendered.width, height: rendered.height))
        case .djvu:
            guard let reader = try? FCXLDjVuReader(path: path),
                  index >= 0, index < reader.pageCount else { return nil }
            let size = reader.pageSize(at: index)
            let scale = size.width > 1 ? (scanDPI * 8.5) / size.width : 1
            return DjVuPagesView.render(reader: reader, index: index,
                                        scale: max(1, min(scale, 4)))
        default:
            return NSImage(contentsOfFile: path)
        }
    }

    /// Can this file hold text a person would want read out of it? Pictures, PDFs and DjVu
    /// scans can; everything else already has its text where a text viewer can show it.
    static func canReadText(in path: String) -> Bool {
        switch fileCategory(extension: (path as NSString).pathExtension) {
        case .image, .pdf, .djvu: return true
        default: return false
        }
    }

    /// Is there anything in this document that recognition could add?
    ///
    /// A PDF made by a program already carries its text, and the viewer already lets a person
    /// select and copy it — offering to "recognise" it there promises a worse copy of what is
    /// on screen. A scan carries nothing, and a mixed document (a contract with a scanned
    /// signature page) carries something on some pages and nothing on others: one page without
    /// text of its own is reason enough to offer.
    ///
    /// Only the first pages are looked at: opening every page of a four-hundred-page book to
    /// decide whether to draw a button is not a trade worth making.
    static func needsRecognition(pdf path: String, checking limit: Int = 10) -> Bool {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return false }
        guard document.pageCount > 0 else { return false }
        for index in 0..<min(document.pageCount, limit) {
            guard let page = document.page(at: index) else { continue }
            let own = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if own.isEmpty { return true }
        }
        return false
    }

    /// The same question for any file the button might appear on.
    static func needsRecognition(file path: String) -> Bool {
        switch fileCategory(extension: (path as NSString).pathExtension) {
        case .pdf:   return needsRecognition(pdf: path)
        // A picture is always worth offering, and a DjVu is a scan by definition.
        case .image, .djvu: return true
        default:     return false
        }
    }

    /// Pages rendered for recognition at this many dots per inch. Below ~150 the letters of a
    /// scanned document stop being letters; above ~300 the wait grows without the reading getting
    /// better.
    static let scanDPI: CGFloat = 200

    static func textInPDF(path: String, maxPages: Int = 50,
                          shouldCancel: () -> Bool = { false },
                          onPage: ((Int, Int) -> Void)? = nil) -> [DocumentPage] {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return [] }
        let count = min(document.pageCount, maxPages)
        var pages: [DocumentPage] = []
        for index in 0..<count {
            if shouldCancel() { break }
            onPage?(index, count)
            guard let page = document.page(at: index) else { continue }
            // The page's own text first: a PDF made by a program carries it exactly right, and
            // recognising a picture of it instead would be both slower and worse.
            let own = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !own.isEmpty {
                pages.append(DocumentPage(number: index + 1, text: own, fromTextLayer: true))
                continue
            }
            guard let cgImage = render(page: page),
                  let lines = try? recognizeBestPolarity(cgImage) else { continue }
            let text = plainText(lines)
            if !text.isEmpty {
                pages.append(DocumentPage(number: index + 1, text: text, fromTextLayer: false))
            }
        }
        onPage?(count, count)
        return pages
    }

    /// A DjVu is a scan by definition — there is no text layer to prefer, every page is read.
    static func textInDjVu(path: String, maxPages: Int = 50,
                           shouldCancel: () -> Bool = { false },
                           onPage: ((Int, Int) -> Void)? = nil) -> [DocumentPage] {
        guard let reader = try? FCXLDjVuReader(path: path) else { return [] }
        let count = min(reader.pageCount, maxPages)
        var pages: [DocumentPage] = []
        for index in 0..<count {
            if shouldCancel() { break }
            onPage?(index, count)
            // The same renderer the viewer uses, asked for a scale that puts the page at about
            // the resolution a scanner would have produced.
            let size = reader.pageSize(at: index)
            let scale = size.width > 1 ? (scanDPI * 8.5) / size.width : 1
            guard let image = DjVuPagesView.render(reader: reader, index: index,
                                                   scale: max(1, min(scale, 4))),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let lines = try? recognizeBestPolarity(cgImage) else { continue }
            let text = plainText(lines)
            if !text.isEmpty {
                pages.append(DocumentPage(number: index + 1, text: text, fromTextLayer: false))
            }
        }
        onPage?(count, count)
        return pages
    }

    /// One PDF page as a picture big enough to read.
    static func render(page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let scale = scanDPI / 72          // PDF measures in points: 72 to the inch
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.white.setFill()       // a page is white; a transparent one reads as black
            rect.fill()
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

// MARK: - Searching pictures by what is written in them

extension TextRecognitionService {

    /// One line of one picture that answered the search.
    struct PictureHit: Equatable {
        let path: String
        /// 1-based line number within the picture, so a file with several answers shows them all.
        let line: Int
        let text: String
    }

    /// How many files one search may read. Reading a picture costs a fraction of a second, so a
    /// folder of ten thousand photographs would otherwise be an hour of work nobody asked for.
    static let searchFileLimit = 400

    /// Find pictures, scans and PDFs in which something is written.
    ///
    /// Everything else is skipped without being opened: a search that reads a .zip looking for
    /// words is only slow.
    static func search(_ query: String, useRegex: Bool = false, under root: String,
                       recursive: Bool = true, includeHidden: Bool = false,
                       excludes: [String] = [], limit: Int = searchFileLimit,
                       shouldCancel: () -> Bool = { false },
                       onFile: ((String) -> Void)? = nil)
        -> (hits: [PictureHit], examined: Int, reachedLimit: Bool) {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return ([], 0, false) }
        let expression = useRegex ? try? NSRegularExpression(pattern: wanted,
                                                             options: [.caseInsensitive]) : nil

        var hits: [PictureHit] = []
        var examined = 0
        var reachedLimit = false

        for path in candidates(under: root, recursive: recursive, includeHidden: includeHidden,
                               excludes: excludes) {
            if shouldCancel() { break }
            if examined >= limit { reachedLimit = true; break }
            examined += 1
            onFile?(path)
            let pages = text(ofFile: path, maxPages: 20, shouldCancel: shouldCancel)
            var number = 0
            for page in pages {
                for line in page.text.split(separator: "\n", omittingEmptySubsequences: true) {
                    number += 1
                    let text = String(line)
                    guard matches(text, wanted: wanted, expression: expression) else { continue }
                    hits.append(PictureHit(path: path, line: number, text: text))
                }
            }
        }
        return (hits, examined, reachedLimit)
    }

    /// Case and accents ignored, the way every other search in this program compares text.
    static func matches(_ text: String, wanted: String,
                        expression: NSRegularExpression?) -> Bool {
        if let expression {
            let range = NSRange(text.startIndex..., in: text)
            return expression.firstMatch(in: text, options: [], range: range) != nil
        }
        return text.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The files worth opening: pictures, scans and PDFs, in reading order of the folder.
    static func candidates(under root: String, recursive: Bool, includeHidden: Bool,
                           excludes: [String]) -> [String] {
        let manager = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = []
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }

        guard let walker = manager.enumerator(at: URL(fileURLWithPath: root),
                                              includingPropertiesForKeys: [.isDirectoryKey],
                                              options: options) else { return [] }
        var found: [String] = []
        for case let url as URL in walker {
            let path = url.path
            if isExcluded(path, by: excludes) {
                walker.skipDescendants()
                continue
            }
            guard canReadText(in: path) else { continue }
            found.append(path)
        }
        return found.sorted()
    }

    /// A path is excluded when any of its folders — or the file itself — matches an exclusion.
    /// The patterns are the panel's own ("node_modules", "*.tmp"), matched the same way.
    static func isExcluded(_ path: String, by excludes: [String]) -> Bool {
        guard !excludes.isEmpty else { return false }
        let parts = (path as NSString).pathComponents.filter { $0 != "/" }
        for pattern in excludes where !pattern.isEmpty {
            let predicate = NSPredicate(format: "SELF LIKE[cd] %@", pattern)
            if parts.contains(where: { predicate.evaluate(with: $0) }) { return true }
        }
        return false
    }
}
