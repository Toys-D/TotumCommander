import Foundation

/// First pass: the text. Chapters are written to disk as they are read, so the whole book
/// never sits in memory at once — and the base64 of the pictures is deliberately dropped on
/// the floor here (the second pass goes back for it).
final class FB2StructureDelegate: NSObject, XMLParserDelegate {

    private(set) var chapters: [BookChapter] = []
    private(set) var bookTitle = ""
    private(set) var author = ""
    private(set) var coverName: String?
    private(set) var sawBinaries = false

    private let destination: URL
    /// Roughly how much text goes into one file before it is cut. A book that is one giant
    /// section would otherwise become a single enormous DOM.
    private let softLimit = 200_000

    private var html = ""
    private var chapterTitle = ""
    private var titleDepth = 0            // >0 while inside <title>
    private var sectionDepth = 0
    private var inDescription = false
    private var inBinary = false
    private var descriptionPath: [String] = []
    private var authorParts: [String: String] = [:]
    private var pendingTitleText = ""
    private var chapterIndex = 0
    private var bodyIndex = -1
    private var inNotes = false

    init(destination: URL) {
        self.destination = destination
        super.init()
    }

    // MARK: - Elements

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch element {
        case "description":
            inDescription = true
        case "binary":
            // Thrown away here on purpose — see the class comment.
            inBinary = true
            sawBinaries = true
        case "body":
            // A new body ends whatever was being collected before it.
            if inNotes { endChapter() }
            bodyIndex += 1
            inNotes = (attributes["name"] ?? "") == "notes"
            if inNotes { chapterTitle = L("viewer.book.notes") }
        case "section":
            sectionDepth += 1
            // A top-level section starts a new chapter file — EXCEPT in the notes body, where
            // every footnote is its own tiny section. Fifteen chapters of which three are a
            // single line of footnote is not a table of contents, so notes gather into one.
            if sectionDepth == 1, !inNotes { startChapter() }
            else { html += "<section>" }
        case "title":
            titleDepth += 1
            pendingTitleText = ""
            if !inDescription { html += "<h\(min(sectionDepth + 1, 4))>" }
        case "subtitle":
            html += "<p class=\"subtitle\">"
        case "p":
            html += inDescription ? "" : "<p>"
        case "empty-line":
            html += "<p class=\"empty\">&#160;</p>"
        case "emphasis":
            html += "<em>"
        case "strong":
            html += "<strong>"
        case "strikethrough":
            html += "<s>"
        case "cite":
            html += "<blockquote>"
        case "text-author":
            html += "<p class=\"text-author\">"
        case "poem":
            html += "<div class=\"poem\">"
        case "stanza":
            html += "<div class=\"stanza\">"
        case "v":
            html += "<p class=\"v\">"
        case "image":
            guard let raw = FB2Parser.href(attributes) else { break }
            let name = Self.imageFileName(from: raw)
            if inDescription {
                if coverName == nil { coverName = name }
            } else {
                html += "<img src=\"img/\(name)\" alt=\"\"/>"
            }
        case "a":
            if let raw = FB2Parser.href(attributes), raw.hasPrefix("#") {
                html += "<a href=\"\(escape(raw))\">"
            } else {
                html += "<a>"
            }
        default:
            if inDescription { descriptionPath.append(element) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters text: String) {
        // The pictures' base64 is not kept: this is what keeps a big book from eating memory.
        guard !inBinary else { return }
        if inDescription {
            collectDescription(text)
            return
        }
        if titleDepth > 0 { pendingTitleText += text }
        html += escape(text)
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "description":
            inDescription = false
            author = [authorParts["first-name"], authorParts["last-name"]]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case "binary":
            inBinary = false
        case "section":
            if sectionDepth == 1, !inNotes { endChapter() } else { html += "</section>" }
            sectionDepth = max(0, sectionDepth - 1)
        case "title":
            titleDepth -= 1
            if !inDescription {
                html += "</h\(min(sectionDepth + 1, 4))>"
                let clean = pendingTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
                if chapterTitle.isEmpty, !inNotes { chapterTitle = clean }
            }
        case "subtitle", "p", "text-author", "v":
            html += inDescription ? "" : "</p>"
        case "emphasis": html += "</em>"
        case "strong":   html += "</strong>"
        case "strikethrough": html += "</s>"
        case "cite":     html += "</blockquote>"
        case "poem", "stanza": html += "</div>"
        case "a":        html += "</a>"
        default:
            if inDescription, descriptionPath.last == element { descriptionPath.removeLast() }
        }
        // A single monstrous section is cut where a paragraph ends, never mid-tag.
        if element == "p", sectionDepth == 1, html.utf8.count > softLimit {
            endChapter()
            startChapter(continuing: true)
        }
    }

    // MARK: - Chapters

    private func startChapter(continuing: Bool = false) {
        html = ""
        if !continuing { chapterTitle = "" }
    }

    private func endChapter() {
        let body = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { html = ""; return }
        let name = String(format: "chapter-%03d.html", chapterIndex)
        let file = destination.appendingPathComponent(name)
        let page = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"/>
        <link rel="stylesheet" href="book.css"/></head>
        <body>\(body)</body></html>
        """
        try? page.write(to: file, atomically: true, encoding: .utf8)
        chapters.append(BookChapter(
            id: "b\(max(bodyIndex, 0)).c\(chapterIndex)",
            title: inNotes ? L("viewer.book.notes") : chapterTitle,
            file: file, fragment: nil, level: inNotes ? 1 : 0))
        chapterIndex += 1
        html = ""
    }

    /// Text that never sat inside a section still belongs to the book.
    func finish() {
        if !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { endChapter() }
    }

    // MARK: - Bits

    private func collectDescription(_ text: String) {
        guard let last = descriptionPath.last else { return }
        switch last {
        case "book-title": bookTitle += text
        case "first-name", "last-name", "middle-name":
            authorParts[last, default: ""] += text
        default: break
        }
    }

    /// "#img_1.jpg" and "img_1.jpg" both name the same picture; the name also has to be safe
    /// to use as a file name.
    static func imageFileName(from href: String) -> String {
        let bare = href.hasPrefix("#") ? String(href.dropFirst()) : href
        let safe = bare.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
            ? $0 : "_" }
        return String(safe)
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Second pass: the pictures alone. Each one is decoded and written the moment its tag ends,
/// so at most one picture is in memory at a time.
final class FB2BinaryDelegate: NSObject, XMLParserDelegate {

    private let destination: URL
    private var currentName: String?
    private var base64 = ""

    init(destination: URL) {
        self.destination = destination
        super.init()
        try? FileManager.default.createDirectory(at: destination,
                                                 withIntermediateDirectories: true)
    }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        guard element == "binary" else { return }
        currentName = attributes["id"].map { FB2StructureDelegate.imageFileName(from: $0) }
        base64 = ""
    }

    func parser(_ parser: XMLParser, foundCharacters text: String) {
        guard currentName != nil else { return }
        base64 += text
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        guard element == "binary", let name = currentName else { return }
        // .ignoreUnknownCharacters is not optional here: real books wrap base64 in newlines,
        // and without it every single picture decodes to nil.
        if let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
            try? bytes.write(to: destination.appendingPathComponent(name))
        }
        currentName = nil
        base64 = ""
    }
}
