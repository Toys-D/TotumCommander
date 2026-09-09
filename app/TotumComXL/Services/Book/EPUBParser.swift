import Foundation

/// EPUB — a zip of XHTML. The reading order is NOT the file order inside the archive: it is
/// the `spine` of the package file, and following anything else scrambles the book.
enum EPUBParser {

    /// Unpack an EPUB and work out its chapters. `unpacked` must already hold the extracted
    /// archive — extraction goes through the app's own zip, not a second implementation.
    static func build(unpacked root: URL, sourcePath: String) throws -> BookDocument {
        guard let packagePath = findPackage(in: root) else { throw BookError.notABook }
        let packageURL = root.appendingPathComponent(packagePath)
        guard let data = try? Data(contentsOf: packageURL) else { throw BookError.unreadable }

        let package = PackageDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = package
        guard parser.parse() else { throw BookError.unreadable }

        // Hrefs in the package are relative to the package file's own folder.
        let base = packageURL.deletingLastPathComponent()
        let titles = readNavigationTitles(package: package, base: base, root: root)

        var chapters: [BookChapter] = []
        for id in package.spine {
            guard let href = package.manifest[id] else { continue }
            let file = base.appendingPathComponent(href).standardizedFileURL
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let declared = titles[href] ?? titles[file.lastPathComponent] ?? ""
            chapters.append(BookChapter(
                id: id, title: usefulTitle(declared, in: file),
                file: file, fragment: nil, level: 0))
        }
        guard !chapters.isEmpty else { throw BookError.empty }

        let cover = package.coverHref.map { base.appendingPathComponent($0).standardizedFileURL }
        return BookDocument(
            sourcePath: sourcePath, format: .epub, root: root,
            title: package.title.isEmpty
                ? (sourcePath as NSString).lastPathComponent : package.title,
            author: package.author,
            cover: cover.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
            chapters: chapters)
    }

    /// The name a person can actually use.
    ///
    /// Books in the wild often number their chapters "0", "1", "2" in the table of contents
    /// while the page itself says "ГЛАВА 1" — showing the file's own numbering is honest and
    /// useless. When the declared name is empty or a bare number, the first heading INSIDE the
    /// chapter is the better answer, because that is what the reader will see on the page.
    static func usefulTitle(_ declared: String, in file: URL) -> String {
        let trimmed = declared.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBareNumber = !trimmed.isEmpty && trimmed.allSatisfy { $0.isNumber }
        guard trimmed.isEmpty || isBareNumber else { return trimmed }
        if let heading = firstHeading(in: file), !heading.isEmpty { return heading }
        return trimmed
    }

    /// The text of the first <h1>…<h4> in an XHTML file, tags stripped.
    static func firstHeading(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data.prefix(200_000), encoding: .utf8)
                ?? String(data: data.prefix(200_000), encoding: .windowsCP1251)
        else { return nil }
        for level in 1...4 {
            guard let open = text.range(of: "<h\(level)", options: .caseInsensitive),
                  let bodyStart = text.range(of: ">", range: open.upperBound..<text.endIndex),
                  let close = text.range(of: "</h\(level)", options: .caseInsensitive,
                                         range: bodyStart.upperBound..<text.endIndex)
            else { continue }
            let inner = String(text[bodyStart.upperBound..<close.lowerBound])
            let clean = inner.replacingOccurrences(of: "<[^>]+>", with: "",
                                                   options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        return nil
    }

    /// META-INF/container.xml names the package file; guessing its location is how readers
    /// break on books that keep it somewhere unusual.
    private static func findPackage(in root: URL) -> String? {
        let container = root.appendingPathComponent("META-INF/container.xml")
        if let data = try? Data(contentsOf: container),
           let text = String(data: data, encoding: .utf8),
           let range = text.range(of: "full-path=\"") {
            let rest = text[range.upperBound...]
            if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
        }
        // A malformed container is not the end: the .opf is findable by extension.
        if let enumerator = FileManager.default.enumerator(at: root,
                                                           includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "opf" {
                return url.path.replacingOccurrences(of: root.path + "/", with: "")
            }
        }
        return nil
    }

    /// Chapter names live in the navigation document — nav.xhtml (EPUB 3) or toc.ncx (2).
    /// Without them the contents strip is a list of file names, which helps nobody.
    private static func readNavigationTitles(package: PackageDelegate, base: URL,
                                             root: URL) -> [String: String] {
        var titles: [String: String] = [:]
        var candidates: [URL] = []
        if let nav = package.navHref { candidates.append(base.appendingPathComponent(nav)) }
        if let ncx = package.ncxHref { candidates.append(base.appendingPathComponent(ncx)) }

        for url in candidates {
            guard let data = try? Data(contentsOf: url) else { continue }
            let delegate = NavigationDelegate()
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.delegate = delegate
            guard parser.parse() else { continue }
            for (href, title) in delegate.titles where titles[href] == nil {
                // "text/ch1.xhtml#part2" and "ch1.xhtml" must both find their chapter.
                let clean = href.components(separatedBy: "#").first ?? href
                titles[clean] = title
                titles[(clean as NSString).lastPathComponent] = title
            }
            if !titles.isEmpty { break }
        }
        return titles
    }

    // MARK: - The package file

    final class PackageDelegate: NSObject, XMLParserDelegate {
        var manifest: [String: String] = [:]      // id → href
        var spine: [String] = []                  // idrefs, in reading order
        var title = ""
        var author = ""
        var coverHref: String?
        var navHref: String?
        var ncxHref: String?

        private var collecting: String?
        private var coverID: String?
        private var manifestProperties: [String: String] = [:]

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch element {
            case "item":
                guard let id = attributes["id"], let href = attributes["href"] else { break }
                manifest[id] = href
                let properties = attributes["properties"] ?? ""
                if properties.contains("nav") { navHref = href }
                if properties.contains("cover-image") { coverHref = href }
                if (attributes["media-type"] ?? "") == "application/x-dtbncx+xml" {
                    ncxHref = href
                }
                manifestProperties[id] = properties
            case "itemref":
                if let idref = attributes["idref"] { spine.append(idref) }
            case "meta":
                if (attributes["name"] ?? "") == "cover" { coverID = attributes["content"] }
            case "title", "creator":
                collecting = element
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters text: String) {
            switch collecting {
            case "title": title += text
            case "creator": author += text
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName: String?) {
            if collecting == element { collecting = nil }
            if element == "package", coverHref == nil, let id = coverID {
                coverHref = manifest[id]
            }
        }
    }

    /// Both navigation formats at once: nav.xhtml is `<a href>` inside `<nav>`, toc.ncx is
    /// `<navPoint>` with `<text>` and `<content src>`.
    final class NavigationDelegate: NSObject, XMLParserDelegate {
        var titles: [String: String] = [:]

        private var pendingHref: String?
        private var pendingText = ""
        private var inText = false
        private var ncxSrc: String?

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch element {
            case "a":
                pendingHref = attributes["href"]
                pendingText = ""
            case "text":
                inText = true
                pendingText = ""
            case "content":
                ncxSrc = attributes["src"]
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters text: String) {
            if pendingHref != nil || inText { pendingText += text }
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let clean = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "a":
                if let href = pendingHref, !clean.isEmpty { titles[href] = clean }
                pendingHref = nil
            case "text":
                inText = false
            case "navPoint":
                if let src = ncxSrc, !clean.isEmpty { titles[src] = clean }
                ncxSrc = nil
            default:
                break
            }
        }
    }
}
