import Foundation

/// FB2 — one XML file holding the whole book, pictures and all, in base64 at the end.
///
/// Read in TWO passes on purpose. A single pass would hold every `<binary>` in memory as a
/// string while it walked the text: a 4 MB book with a few hundred pictures turns into
/// hundreds of megabytes of accumulated base64. So the first pass writes the chapters and
/// deliberately throws the picture bytes away; the second goes back for the pictures alone,
/// decoding and writing each one the moment its tag closes.
enum FB2Parser {

    /// Turn an FB2 file into a folder of chapters. Runs off the main thread — it reads and
    /// writes whole megabytes.
    static func build(from fb2Path: String, sourcePath: String,
                      into destination: URL) throws -> BookDocument {
        guard let data = FileManager.default.contents(atPath: fb2Path) else {
            throw BookError.unreadable
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Self.styleSheet.write(to: destination.appendingPathComponent("book.css"),
                                  atomically: true, encoding: .utf8)

        let structure = FB2StructureDelegate(destination: destination)
        try parse(data, delegate: structure)
        structure.finish()
        guard !structure.chapters.isEmpty else { throw BookError.empty }

        // Pictures second, and only if the text referred to any.
        if structure.sawBinaries {
            let images = FB2BinaryDelegate(destination: destination.appendingPathComponent("img"))
            try? parse(data, delegate: images)
        }

        // Remembered beside the chapters, so reopening a prepared book keeps its names.
        var meta = BookCache.Meta(title: structure.bookTitle, author: structure.author)
        for (index, chapter) in structure.chapters.enumerated() { meta.titles[index] = chapter.title }
        BookCache.writeMeta(meta, to: destination)

        return BookDocument(
            sourcePath: sourcePath, format: .fb2, root: destination,
            title: structure.bookTitle.isEmpty
                ? (fb2Path as NSString).lastPathComponent : structure.bookTitle,
            author: structure.author,
            cover: structure.coverName.flatMap {
                let url = destination.appendingPathComponent("img").appendingPathComponent($0)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            },
            chapters: structure.chapters)
    }

    /// Parse, coping with a file whose declared encoding is a lie.
    ///
    /// The raw bytes go to XMLParser first: libxml2 reads `encoding="windows-1251"` by itself,
    /// and most Russian FB2 files are exactly that. Only when it fails with "not proper UTF-8"
    /// is the encoding guessed — and then the DECLARATION MUST BE REWRITTEN, or the second
    /// parse quietly produces mojibake instead of text.
    private static func parse(_ data: Data, delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        if parser.parse() { return }

        // Which code comes back depends on WHERE the bad byte falls: 9 ("not proper UTF-8")
        // when it is in the text, 111 (invalid character reference) when libxml2 chokes
        // earlier. Measured on this machine with a cp1251 file declaring utf-8. Both mean the
        // same thing here — the declaration lied — so the encoding gets guessed either way.
        let failureCode = (parser.parserError as NSError?)?.code ?? 0
        guard failureCode == 9 || failureCode == 111 else { throw BookError.unreadable }
        var encoding: UInt = 0
        encoding = NSString.stringEncoding(for: data, encodingOptions: nil,
                                           convertedString: nil, usedLossyConversion: nil)
        guard encoding != 0,
              let text = String(data: data, encoding: String.Encoding(rawValue: encoding))
        else { throw BookError.unreadable }

        let fixed = rewriteDeclarationToUTF8(text)
        let second = XMLParser(data: Data(fixed.utf8))
        second.shouldProcessNamespaces = true
        second.delegate = delegate
        guard second.parse() else { throw BookError.unreadable }
    }

    private static func rewriteDeclarationToUTF8(_ text: String) -> String {
        guard let end = text.range(of: "?>") else { return text }
        let declaration = text[text.startIndex..<end.upperBound]
        guard declaration.contains("<?xml") else { return text }
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>" + text[end.upperBound...]
    }

    /// `l:href` in one book, `xlink:href` in the next — XMLParser does not resolve namespaces
    /// on ATTRIBUTES even when asked to resolve them on elements.
    static func href(_ attributes: [String: String]) -> String? {
        attributes["href"] ?? attributes.first { $0.key.hasSuffix(":href") }?.value
    }

    static let styleSheet = """
    :root { color-scheme: light dark; }
    body { font: 17px/1.6 -apple-system, "Helvetica Neue", serif; text-align: justify;
           hyphens: auto; }
    h1, h2, h3, h4 { text-align: center; font-weight: 600; break-after: avoid; }
    h1 { font-size: 1.5em; margin: 1.2em 0 0.8em; }
    h2 { font-size: 1.3em; margin: 1em 0 0.7em; }
    h3, h4 { font-size: 1.1em; margin: 0.9em 0 0.6em; }
    p { margin: 0 0 0.35em; text-indent: 1.4em; }
    p.empty { text-indent: 0; }
    .subtitle { text-align: center; font-style: italic; text-indent: 0; margin: 1em 0 0.6em; }
    blockquote { margin: 0.8em 2em; font-style: italic; }
    .text-author { text-align: right; font-style: italic; text-indent: 0; }
    .poem { margin: 0.8em 2em; }
    .stanza { margin-bottom: 0.6em; }
    .v { text-indent: 0; margin: 0; }
    img { max-width: 100%; height: auto; display: block; margin: 0.8em auto;
          break-inside: avoid; }
    """
}
