import Foundation
import PDFKit

/// Putting PDFs together, taking them apart and turning their pages.
///
/// The page arithmetic lives in pure functions: which pages a person means when they type
/// "1-3, 7, 12-", and what the results are called. Both are where a document editor quietly
/// ruins someone's afternoon — a page dropped from a contract, or a result written over the
/// original — so both are decided here and checked without a single file on disk.
enum PDFEditService {

    enum EditError: LocalizedError {
        case unreadable(String)
        case unwritable(String)
        case noPages

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return String(format: L("pdf.error.unreadable"), name)
            case .unwritable(let name): return String(format: L("pdf.error.unwritable"), name)
            case .noPages: return L("pdf.error.noPages")
            }
        }
    }

    // MARK: - Which pages

    /// Read "1-3, 7, 12-" the way a person writes it: pages counted from ONE, ranges inclusive,
    /// an open end meaning "to the last page". Anything outside the document is clipped rather
    /// than refused — a range typed for a longer file should still do what it plainly means.
    ///
    /// Answers page indexes counted from zero, in order, without repeats.
    static func pages(from text: String, pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Empty means the whole document: the field is a narrowing, and an empty narrowing
        // narrows nothing.
        guard !trimmed.isEmpty else { return Array(0..<pageCount) }

        var chosen: Set<Int> = []
        var order: [Int] = []
        func add(_ index: Int) {
            guard index >= 0, index < pageCount, chosen.insert(index).inserted else { return }
            order.append(index)
        }

        for piece in trimmed.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let part = piece.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }
            // A dash may be typed as a hyphen, an en dash or an em dash.
            let bounds = part.split(whereSeparator: { $0 == "-" || $0 == "—" || $0 == "–" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let hasDash = part.contains("-") || part.contains("—") || part.contains("–")

            if !hasDash {
                if let single = Int(part) { add(single - 1) }
                continue
            }
            // Which side the dash hangs on decides what is open: "8-" runs to the last page,
            // "-3" starts at the first. Splitting alone cannot tell them apart — both leave a
            // single number behind.
            let opensAtStart = part.hasPrefix("-") || part.hasPrefix("–") || part.hasPrefix("—")
            let first = bounds.first.flatMap { Int($0) }
            let second = bounds.count > 1 ? Int(bounds[1]) : nil
            let from = opensAtStart ? 1 : (first ?? 1)
            let to = opensAtStart ? (first ?? pageCount) : (second ?? pageCount)
            guard from <= to else {
                // Written backwards ("7-3") means the same pages, in the same order as the
                // document: nobody writing that wants the file reversed.
                for index in (to - 1)...(from - 1) { add(index) }
                continue
            }
            for index in (from - 1)...(to - 1) { add(index) }
        }
        return order
    }

    /// The pages a "every N pages" split puts in each part.
    static func chunks(pageCount: Int, size: Int) -> [[Int]] {
        guard pageCount > 0, size > 0 else { return [] }
        return stride(from: 0, to: pageCount, by: size).map { start in
            Array(start..<min(start + size, pageCount))
        }
    }

    // MARK: - Naming

    /// A free path near `path`, with a suffix — never over anything already there.
    static func freePath(near path: String, suffix: String, extension ext: String = "pdf",
                         taken: Set<String> = [],
                         fileExists: (String) -> Bool = {
                             FileManager.default.fileExists(atPath: $0)
                         }) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var candidate = (folder as NSString).appendingPathComponent("\(stem)\(suffix).\(ext)")
        var index = 2
        while taken.contains(candidate) || fileExists(candidate) {
            candidate = (folder as NSString)
                .appendingPathComponent("\(stem)\(suffix) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    /// The file a typed name means, in the folder of `near`.
    ///
    /// The name is taken as written, minus the things a file name cannot hold; an empty one
    /// falls back to the suggestion. The ".pdf" is added when it is missing — nobody should have
    /// to remember it — and an occupied name gets a number rather than eating what is there.
    static func target(named typed: String, near path: String, fallback: String,
                       fileExists: (String) -> Bool = {
                           FileManager.default.fileExists(atPath: $0)
                       }) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        var name = typed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = fallback }
        if (name as NSString).pathExtension.lowercased() != "pdf" { name += ".pdf" }

        var candidate = (folder as NSString).appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension
        var index = 2
        while fileExists(candidate) {
            candidate = (folder as NSString).appendingPathComponent("\(stem) \(index).pdf")
            index += 1
        }
        return candidate
    }

    // MARK: - Doing the work

    /// Put several PDFs into one, in the order given.
    @discardableResult
    static func merge(_ paths: [String], into target: String) throws -> String {
        let result = PDFDocument()
        var written = 0
        for path in paths {
            guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
                throw EditError.unreadable((path as NSString).lastPathComponent)
            }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                result.insert(page, at: written)
                written += 1
            }
        }
        guard written > 0 else { throw EditError.noPages }
        guard result.write(to: URL(fileURLWithPath: target)) else {
            throw EditError.unwritable((target as NSString).lastPathComponent)
        }
        return target
    }

    // MARK: - Making one

    /// The page a picture is put on.
    enum PageSize: String, CaseIterable {
        /// The page IS the picture: no margins, nothing cropped, nothing added.
        case picture
        /// A4 upright, the picture fitted inside with a small margin — for printing.
        case a4

        var localizedName: String { L("pdf.make.size.\(rawValue)") }
    }

    /// A4 in points, the unit a PDF measures in: 72 to the inch.
    static let a4 = CGSize(width: 595, height: 842)
    private static let a4Margin: CGFloat = 28

    /// Where a picture sits on an A4 page: fitted whole, centred, never enlarged past its own
    /// pixels — a small photograph blown up to fill a page only looks worse on paper.
    static func placement(for picture: CGSize, on page: CGSize,
                          margin: CGFloat) -> CGRect {
        guard picture.width > 0, picture.height > 0 else { return .zero }
        let room = CGSize(width: max(1, page.width - margin * 2),
                          height: max(1, page.height - margin * 2))
        let scale = min(room.width / picture.width, room.height / picture.height, 1)
        let size = CGSize(width: picture.width * scale, height: picture.height * scale)
        return CGRect(x: (page.width - size.width) / 2, y: (page.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Make one PDF out of pictures — and out of PDFs, which are taken in whole, page by page,
    /// so a set of scans and a covering letter can be bound together in one go.
    @discardableResult
    static func makePDF(from paths: [String], into target: String,
                        pageSize: PageSize = .picture) throws -> String {
        let result = PDFDocument()
        var written = 0
        for path in paths {
            if fileCategory(extension: (path as NSString).pathExtension) == .pdf {
                guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
                    throw EditError.unreadable((path as NSString).lastPathComponent)
                }
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                    result.insert(page, at: written)
                    written += 1
                }
                continue
            }
            guard let image = NSImage(contentsOfFile: path) else {
                throw EditError.unreadable((path as NSString).lastPathComponent)
            }
            guard let page = self.page(from: image, size: pageSize) else { continue }
            result.insert(page, at: written)
            written += 1
        }
        guard written > 0 else { throw EditError.noPages }
        guard result.write(to: URL(fileURLWithPath: target)) else {
            throw EditError.unwritable((target as NSString).lastPathComponent)
        }
        return target
    }

    /// One picture as one page.
    static func page(from image: NSImage, size: PageSize) -> PDFPage? {
        switch size {
        case .picture:
            return PDFPage(image: image)
        case .a4:
            // Drawn onto a page of its own, because a PDFPage takes the picture's size and
            // nothing else — the fitting has to happen while the page is being drawn.
            let box = CGRect(origin: .zero, size: a4)
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
            var mediaBox = box
            guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                return nil
            }
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let frame = placement(for: CGSize(width: cgImage.width, height: cgImage.height),
                                      on: a4, margin: a4Margin)
                context.draw(cgImage, in: frame)
            }
            context.endPDFPage()
            context.closePDF()
            guard let document = PDFDocument(data: data as Data) else { return nil }
            return document.page(at: 0)
        }
    }

    /// Take a document apart. Each part is written as its own file; the paths are answered in
    /// order. The original is never touched.
    @discardableResult
    static func split(_ path: String, parts: [[Int]]) throws -> [String] {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            throw EditError.unreadable((path as NSString).lastPathComponent)
        }
        var made: [String] = []
        var taken: Set<String> = []
        for (number, pages) in parts.enumerated() where !pages.isEmpty {
            let piece = PDFDocument()
            var at = 0
            for index in pages {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                piece.insert(page, at: at)
                at += 1
            }
            guard at > 0 else { continue }
            let target = freePath(near: path,
                                  suffix: String(format: L("pdf.split.suffix"), number + 1),
                                  taken: taken)
            guard piece.write(to: URL(fileURLWithPath: target)) else {
                throw EditError.unwritable((target as NSString).lastPathComponent)
            }
            taken.insert(target)
            made.append(target)
        }
        guard !made.isEmpty else { throw EditError.noPages }
        return made
    }

    /// Turn pages. `degrees` is 90, 180 or 270, clockwise; `pages` counted from zero.
    /// Written to `target`, which may be the original.
    @discardableResult
    static func rotate(_ path: String, degrees: Int, pages: [Int],
                       target: String) throws -> String {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            throw EditError.unreadable((path as NSString).lastPathComponent)
        }
        guard !pages.isEmpty else { throw EditError.noPages }
        for index in pages {
            guard let page = document.page(at: index) else { continue }
            // PDFKit keeps the rotation as a multiple of 90 in either direction; adding is what
            // turning a page a second time means.
            page.rotation = normalized(page.rotation + degrees)
        }
        guard document.write(to: URL(fileURLWithPath: target)) else {
            throw EditError.unwritable((target as NSString).lastPathComponent)
        }
        return target
    }

    /// Bring any angle into 0, 90, 180 or 270 — the only values a PDF page understands.
    static func normalized(_ degrees: Int) -> Int {
        let quarters = ((degrees / 90) % 4 + 4) % 4
        return quarters * 90
    }

    /// How many pages a document has, without keeping it open.
    static func pageCount(of path: String) -> Int {
        PDFDocument(url: URL(fileURLWithPath: path))?.pageCount ?? 0
    }
}
