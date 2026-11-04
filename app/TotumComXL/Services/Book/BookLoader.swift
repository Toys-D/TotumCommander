import Foundation

/// The one place that decides "is this a book, and which kind" — and the one door that turns
/// a file on disk into something the reader can show.
enum BookLoader {

    /// What the name says. `.fb2.zip` is why this takes a NAME and not an extension: its
    /// extension is "zip", and deciding by extension alone would send it to the archive
    /// browser instead of the reader.
    static func format(ofFileNamed name: String) -> BookFormat? {
        let lower = name.lowercased()
        if lower.hasSuffix(".fb2.zip") || lower.hasSuffix(".fbz") { return .fb2zip }
        if lower.hasSuffix(".fb2") { return .fb2 }
        if lower.hasSuffix(".epub") { return .epub }
        return nil
    }

    /// What the BYTES say, for a file whose name gives nothing away.
    static func probe(path: String) -> BookFormat? {
        if let byName = format(ofFileNamed: (path as NSString).lastPathComponent) {
            return byName
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 512)) ?? Data()
        if head.starts(with: Data([0x50, 0x4B, 0x03, 0x04])) {
            // A zip: an EPUB always begins with an uncompressed "mimetype" entry.
            if head.count > 38,
               let text = String(data: head.prefix(64), encoding: .isoLatin1),
               text.contains("mimetype"), text.contains("epub") {
                return .epub
            }
            return nil
        }
        if let text = String(data: head, encoding: .utf8), text.contains("<FictionBook") {
            return .fb2
        }
        return nil
    }

    static func isBook(path: String, name: String) -> Bool {
        format(ofFileNamed: name) != nil || probe(path: path) != nil
    }

    /// Read the book. Heavy — megabytes of parsing and writing; call it off the main thread.
    static func load(path: String, bridge: CoreBridgeService) throws -> BookDocument {
        guard let format = probe(path: path) else { throw BookError.notABook }
        let destination = BookCache.directory(for: path)

        // Already prepared and still matching the file: nothing to redo.
        if BookCache.isFresh(destination), let cached = try? reopen(destination, path: path,
                                                                    format: format) {
            return cached
        }
        try? FileManager.default.removeItem(at: destination)
        let staging = destination.appendingPathExtension("building")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let document: BookDocument
        switch format {
        case .fb2:
            document = try FB2Parser.build(from: path, sourcePath: path, into: staging)
        case .fb2zip:
            // The app's own zip: a second unzip implementation would mean a second set of
            // bugs over zip-slip, ZIP64 and non-UTF-8 names, all long since solved there.
            let unpacked = staging.appendingPathComponent("unpacked")
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try bridge.extractArchiveAll(archivePath: path, destinationPath: unpacked.path,
                                         overwriteExisting: true, progress: { _, _, _, _, _, _ in })
            guard let inner = firstFB2(in: unpacked) else { throw BookError.notABook }
            document = try FB2Parser.build(from: inner.path, sourcePath: path, into: staging)
        case .epub:
            try bridge.extractArchiveAll(archivePath: path, destinationPath: staging.path,
                                         overwriteExisting: true, progress: { _, _, _, _, _, _ in })
            document = try EPUBParser.build(unpacked: staging, sourcePath: path)
        }

        // Only a finished book is moved into place — an interrupted unpack must never be
        // mistaken for a prepared one on the next open.
        try? FileManager.default.moveItem(at: staging, to: destination)
        BookCache.markComplete(destination)
        BookCache.trim()
        return try reopen(destination, path: path, format: format)
    }

    /// Re-derive the document from an already-prepared folder.
    private static func reopen(_ folder: URL, path: String,
                               format: BookFormat) throws -> BookDocument {
        if format == .epub { return try EPUBParser.build(unpacked: folder, sourcePath: path) }
        // FB2: the chapters are our own files, named in order.
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("chapter-") && $0.hasSuffix(".html") }
            .sorted()
        guard !names.isEmpty else { throw BookError.empty }
        let meta = BookCache.readMeta(folder)
        let chapters = names.enumerated().map { index, name in
            BookChapter(id: "c\(index)", title: meta.titles[index] ?? "",
                        file: folder.appendingPathComponent(name), fragment: nil, level: 0)
        }
        return BookDocument(sourcePath: path, format: format, root: folder,
                            title: meta.title.isEmpty
                                ? (path as NSString).lastPathComponent : meta.title,
                            author: meta.author, cover: nil, chapters: chapters)
    }

    private static func firstFB2(in folder: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: folder,
                                                              includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "fb2" {
            return url
        }
        return nil
    }
}

/// Where prepared books live between openings — a big book should be parsed once, not on
/// every look.
enum BookCache {

    static var root: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TotumBooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Keyed by path AND modification time: an edited book is prepared afresh instead of
    /// showing yesterday's text.
    static func directory(for path: String) -> URL {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let stamp = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        var hash: UInt64 = 5381
        for byte in path.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return root.appendingPathComponent(
            String(format: "%llx-%llx-%.0f", hash, size, stamp), isDirectory: true)
    }

    private static let marker = ".fcxl-complete"

    static func isFresh(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(marker).path)
    }

    static func markComplete(_ folder: URL) {
        FileManager.default.createFile(atPath: folder.appendingPathComponent(marker).path,
                                       contents: Data())
    }

    struct Meta {
        var title = ""
        var author = ""
        var titles: [Int: String] = [:]
    }

    static func writeMeta(_ meta: Meta, to folder: URL) {
        var lines = ["title\t" + meta.title, "author\t" + meta.author]
        for (index, title) in meta.titles.sorted(by: { $0.key < $1.key }) {
            lines.append("chapter\t\(index)\t\(title)")
        }
        try? lines.joined(separator: "\n").write(
            to: folder.appendingPathComponent("book.meta"), atomically: true, encoding: .utf8)
    }

    static func readMeta(_ folder: URL) -> Meta {
        var meta = Meta()
        guard let text = try? String(contentsOf: folder.appendingPathComponent("book.meta"),
                                     encoding: .utf8) else { return meta }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            switch parts.first {
            case "title" where parts.count > 1: meta.title = String(parts[1])
            case "author" where parts.count > 1: meta.author = String(parts[1])
            case "chapter" where parts.count > 2:
                if let index = Int(parts[1]) { meta.titles[index] = String(parts[2]) }
            default: break
            }
        }
        return meta
    }

    /// Keep the last few books, not every book ever opened.
    static func trim(keeping: Int = 5) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys) else { return }
        let sorted = folders.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            return a > b
        }
        for folder in sorted.dropFirst(keeping) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
