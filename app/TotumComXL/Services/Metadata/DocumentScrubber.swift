import Compression
import Foundation
import PDFKit

/// Documents: PDF, and the zip-based office formats.
enum DocumentScrubber {

    // MARK: - PDF

    /// The comment kinds whose author and time are a person's; a form field's /T is its NAME,
    /// and a link has none — those are left as they are.
    private static let markup: Set<String> = [
        "Text", "FreeText", "Line", "Square", "Circle", "Polygon", "PolyLine", "Highlight",
        "Underline", "Squiggly", "StrikeOut", "Stamp", "Caret", "Ink", "FileAttachment",
        "Sound", "Redact",
    ]

    /// PDF: PDFKit writes the document anew without its properties and without the comments'
    /// authors, then `PDFSweep` takes out what PDFKit carries across regardless — the XMP, the
    /// notes inside every JPEG picture, the objects nothing refers to any more.
    static func writePDF(from path: String, to target: String) throws {
        let name = MetadataScrubber.fileName(path)
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            throw MetadataScrubber.Failure.unreadable(name)
        }
        // Written anew, a protected document would come out unprotected.
        guard !document.isEncrypted else { throw MetadataScrubber.Failure.locked(name) }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where markup.contains(annotation.type ?? "") {
                annotation.userName = nil
                annotation.modificationDate = nil
            }
        }
        document.documentAttributes = [:]
        guard document.write(to: URL(fileURLWithPath: target)),
              let written = FileManager.default.contents(atPath: target) else {
            throw MetadataScrubber.Failure.unwritable(name)
        }
        var bytes = [UInt8](written)
        guard PDFSweep.sweep(&bytes) else { throw MetadataScrubber.Failure.unwritable(name) }
        do {
            try Data(bytes).write(to: URL(fileURLWithPath: target))
        } catch {
            throw MetadataScrubber.Failure.unwritable(name)
        }
    }

    // MARK: - Office

    /// Word, Excel, PowerPoint: the package says through its relationships which parts hold
    /// the properties — the core ones (author, dates, revision), the application's (company,
    /// manager, template, editing time) and the custom ones. Each is replaced by its own root
    /// element, empty; every other part stays byte for byte.
    static func writeOffice(from path: String, to target: String) throws {
        let name = MetadataScrubber.fileName(path)
        guard let archive = ZipPackage(path: path), let rels = archive.contents(of: "_rels/.rels"),
              let relations = try? XMLDocument(data: rels) else {
            throw MetadataScrubber.Failure.unreadable(name)
        }
        var replacements: [String: Data] = [:]
        for relation in (try? relations.nodes(forXPath: "//*[local-name()='Relationship']")) ?? [] {
            guard let element = relation as? XMLElement,
                  let type = element.attribute(forName: "Type")?.stringValue,
                  let part = element.attribute(forName: "Target")?.stringValue,
                  propertyRelations.contains(where: { type.hasSuffix($0) }) else { continue }
            let entry = part.hasPrefix("/") ? String(part.dropFirst()) : part
            guard let original = archive.contents(of: entry),
                  let emptied = emptiedRoot(original) else { continue }
            replacements[entry] = emptied
        }
        // The folder the properties live in by custom holds others' too — macOS's own writer
        // leaves its name and version in a docProps/meta.xml no relationship mentions.
        for entry in archive.names
        where entry.hasPrefix("docProps/") && entry.hasSuffix(".xml") && replacements[entry] == nil {
            if let original = archive.contents(of: entry), let emptied = emptiedRoot(original) {
                replacements[entry] = emptied
            }
        }
        try write(archive, to: target, replacing: replacements, name: name)
    }

    private static let propertyRelations = [
        "/core-properties", "/extended-properties", "/extendedProperties",
        "/custom-properties", "/customProperties",
    ]

    /// OpenDocument: everything said about the document lives in meta.xml — kept as its root
    /// and an empty office:meta inside it.
    static func writeOpenDocument(from path: String, to target: String) throws {
        let name = MetadataScrubber.fileName(path)
        guard let archive = ZipPackage(path: path), archive.contents(of: "mimetype") != nil else {
            throw MetadataScrubber.Failure.unreadable(name)
        }
        var replacements: [String: Data] = [:]
        if let meta = archive.contents(of: "meta.xml") {
            guard let emptied = emptiedRoot(meta, keepingEmpty: "meta") else {
                throw MetadataScrubber.Failure.unreadable(name)
            }
            replacements["meta.xml"] = emptied
        }
        try write(archive, to: target, replacing: replacements, name: name)
    }

    private static func write(_ archive: ZipPackage, to target: String,
                              replacing replacements: [String: Data], name: String) throws {
        do {
            try archive.write(to: target, replacing: replacements)
        } catch {
            throw MetadataScrubber.Failure.unwritable(name)
        }
    }

    /// The same XML with its root element emptied — the root itself stays, namespaces and all,
    /// so the part is still what the package says it is. With `keepingEmpty`, the child of
    /// that name stays too, emptied in its turn.
    static func emptiedRoot(_ xml: Data, keepingEmpty child: String? = nil) -> Data? {
        guard let document = try? XMLDocument(data: xml), let root = document.rootElement() else {
            return nil
        }
        let kept = child.flatMap { name in
            root.children?.first { ($0 as? XMLElement)?.localName == name } as? XMLElement
        }
        kept?.detach()
        kept?.setChildren(nil)
        root.setChildren(kept.map { [$0] })
        document.characterEncoding = "UTF-8"
        document.isStandalone = true
        return document.xmlData(options: [.nodeCompactEmptyElement])
    }
}

/// After PDFKit has written a document: take out what it carries across regardless. All of it
/// in place and of the same length — the cross-reference table at the end of the file keeps
/// every offset true, and the reader keeps finding every object where it was.
///
/// What goes: every "/Metadata n 0 R" (the document's XMP and the pictures'), every object
/// nothing refers to any more (the old properties' leftovers, the XMP itself), and inside each
/// JPEG picture the segments with notes — turned into comments of spaces.
enum PDFSweep {

    private struct Object {
        let number: Int
        let start: Int
        /// Between "obj" and "endobj".
        let body: Range<Int>
        /// The dictionary and everything else outside a stream's data.
        let text: Range<Int>
        let stream: Range<Int>?
    }

    /// False when the file is not shaped the way PDFKit writes one — a single classic
    /// cross-reference table, no encryption — and is left untouched.
    static func sweep(_ b: inout [UInt8]) -> Bool {
        guard let trailer = trailer(b), let offsets = xref(b) else { return false }
        if contains(b, trailer, "/Encrypt") || contains(b, trailer, "/Prev") { return false }
        var objects: [Int: Object] = [:]
        for (number, offset) in offsets {
            guard let object = object(b, number: number, at: offset, offsets: offsets) else {
                return false
            }
            objects[number] = object
        }

        // The XMP is referred to only from these keys: once they are spaces, it is unreferenced.
        for object in objects.values { blankMetadataKeys(&b, in: object.text) }
        blankMetadataKeys(&b, in: trailer)

        // Everything still reachable from the trailer stays.
        var reachable = Set<Int>()
        var queue = references(b, in: trailer)
        while let number = queue.popLast() {
            guard reachable.insert(number).inserted, let object = objects[number] else { continue }
            queue += references(b, in: object.text)
        }
        for object in objects.values where !reachable.contains(object.number) {
            // "n 0 obj null … endobj": a valid object that says nothing.
            let body = object.body
            let replacement = Array(" null".utf8)
            for k in body { b[k] = 0x20 }
            if body.count >= replacement.count {
                b.replaceSubrange(body.lowerBound..<(body.lowerBound + replacement.count), with: replacement)
            }
        }
        for object in objects.values where reachable.contains(object.number) {
            guard let stream = object.stream, isJPEGImage(b, object.text) else { continue }
            quietJPEG(&b, in: stream)
        }
        return true
    }

    // MARK: - Reading the file's frame

    private static func trailer(_ b: [UInt8]) -> Range<Int>? {
        guard let at = lastIndex(of: "trailer", in: b),
              let open = index(of: "<<", in: b, from: at),
              let close = dictionaryEnd(b, from: open) else { return nil }
        return open..<close
    }

    /// The in-use objects of the one classic table: number → offset. Nil for anything else —
    /// a cross-reference stream, several tables.
    private static func xref(_ b: [UInt8]) -> [Int: Int]? {
        guard let startxref = lastIndex(of: "startxref", in: b) else { return nil }
        var i = startxref + 9
        skipSpace(b, &i)
        guard let at = integer(b, &i), Binary.matches(b, at, "xref") else { return nil }
        i = at + 4
        var map: [Int: Int] = [:]
        while true {
            skipSpace(b, &i)
            if Binary.matches(b, i, "trailer") { return map }
            guard let first = integer(b, &i) else { return nil }
            skipSpace(b, &i)
            guard let count = integer(b, &i) else { return nil }
            skipSpace(b, &i)
            for n in 0..<count {
                let line = i + n * 20
                guard line + 18 <= b.count, let offset = Int(Binary.ascii(b, line, 10) ?? "") else {
                    return nil
                }
                if b[line + 17] == UInt8(ascii: "n") { map[first + n] = offset }
            }
            i += count * 20
        }
    }

    private static func object(_ b: [UInt8], number: Int, at offset: Int,
                               offsets: [Int: Int]) -> Object? {
        var i = offset
        guard integer(b, &i) == number else { return nil }
        skipSpace(b, &i)
        guard integer(b, &i) != nil else { return nil }
        skipSpace(b, &i)
        guard Binary.matches(b, i, "obj") else { return nil }
        let bodyStart = i + 3
        var j = bodyStart
        skipSpace(b, &j)
        var searchFrom = bodyStart
        if Binary.matches(b, j, "<<"), let close = dictionaryEnd(b, from: j) {
            var k = close
            skipSpace(b, &k)
            if Binary.matches(b, k, "stream") {
                k += 6
                if k < b.count, b[k] == 0x0D { k += 1 }
                if k < b.count, b[k] == 0x0A { k += 1 }
                guard let length = streamLength(b, dictionary: j..<close, offsets: offsets),
                      k + length <= b.count else { return nil }
                let dataEnd = k + length
                guard let end = index(of: "endobj", in: b, from: dataEnd) else { return nil }
                return Object(number: number, start: offset, body: bodyStart..<end,
                              text: bodyStart..<close, stream: k..<dataEnd)
            }
            searchFrom = close   // an "endobj" inside one of its strings ends nothing
        }
        guard let end = index(of: "endobj", in: b, from: searchFrom) else { return nil }
        return Object(number: number, start: offset, body: bodyStart..<end,
                      text: bodyStart..<end, stream: nil)
    }

    /// /Length, direct or through a reference to an object holding the number. Not /Length1:
    /// a font file has both.
    private static func streamLength(_ b: [UInt8], dictionary: Range<Int>,
                                     offsets: [Int: Int]) -> Int? {
        var from = dictionary.lowerBound
        var found: Int?
        while let at = index(of: "/Length", in: b, from: from, to: dictionary.upperBound) {
            if at + 7 < b.count, !isRegular(b[at + 7]) { found = at; break }
            from = at + 7
        }
        guard let key = found else { return nil }
        var i = key + 7
        skipSpace(b, &i)
        guard let value = integer(b, &i) else { return nil }
        var j = i
        skipSpace(b, &j)
        if let generation = integerAt(b, j), generation.end < b.count,
           b[skippingSpace(b, generation.end)] == UInt8(ascii: "R") {
            guard let offset = offsets[value] else { return nil }
            var k = offset
            _ = integer(b, &k); skipSpace(b, &k)
            _ = integer(b, &k); skipSpace(b, &k)
            guard Binary.matches(b, k, "obj") else { return nil }
            k += 3
            skipSpace(b, &k)
            return integer(b, &k)
        }
        return value
    }

    // MARK: - What refers to what

    /// Every "n g R" in the range. Strings are not told apart from the rest: a reference seen
    /// inside one keeps an object alive that need not be — the safe way to be wrong.
    private static func references(_ b: [UInt8], in range: Range<Int>) -> [Int] {
        var found: [Int] = []
        var i = range.lowerBound
        while i < range.upperBound {
            // A number stands on its own: "/F1" is a name, not the object 1.
            guard isDigit(b[i]), i == 0 || !isRegular(b[i - 1]) else { i += 1; continue }
            var j = i
            guard let number = integer(b, &j), j < range.upperBound else { i += 1; continue }
            var k = j
            skipSpace(b, &k)
            guard k > j, let generation = integerAt(b, k) else { i = j; continue }
            var r = generation.end
            skipSpace(b, &r)
            if r > generation.end, r < range.upperBound, b[r] == UInt8(ascii: "R"),
               r + 1 >= b.count || !isRegular(b[r + 1]) {
                found.append(number)
                i = r + 1
            } else {
                i = j
            }
        }
        return found
    }

    /// "/Metadata 12 0 R" → spaces.
    private static func blankMetadataKeys(_ b: inout [UInt8], in range: Range<Int>) {
        var from = range.lowerBound
        while let key = index(of: "/Metadata", in: b, from: from, to: range.upperBound) {
            var i = key + 9
            from = i
            guard i < b.count, !isRegular(b[i]) else { continue }
            skipSpace(b, &i)
            guard integer(b, &i) != nil else { continue }
            skipSpace(b, &i)
            guard integer(b, &i) != nil else { continue }
            skipSpace(b, &i)
            guard i < range.upperBound, b[i] == UInt8(ascii: "R") else { continue }
            for k in key...i { b[k] = 0x20 }
            from = i + 1
        }
    }

    // MARK: - JPEG pictures

    private static func isJPEGImage(_ b: [UInt8], _ text: Range<Int>) -> Bool {
        let compact = String(decoding: b[text].filter { !isSpace($0) }, as: UTF8.self)
        return compact.contains("/Subtype/Image")
            && (compact.contains("/Filter/DCTDecode") || compact.contains("/Filter[/DCTDecode]"))
    }

    /// The JPEG's notes become comments of spaces: the marker turns into COM, the content into
    /// blanks, the length stays — and the picture data after them does not move.
    private static func quietJPEG(_ b: inout [UInt8], in stream: Range<Int>) {
        guard stream.count > 4, b[stream.lowerBound] == 0xFF, b[stream.lowerBound + 1] == 0xD8
        else { return }
        var i = stream.lowerBound + 2
        while i + 4 <= stream.upperBound, b[i] == 0xFF {
            let marker = b[i + 1]
            if marker == 0xDA || marker == 0xD9 { return }
            guard let length = Binary.u16(b, i + 2), length >= 2,
                  i + 2 + length <= stream.upperBound else { return }
            let payload = (i + 4)..<(i + 2 + length)
            let isNote: Bool
            switch marker {
            case 0xE0: isNote = !Binary.matches(b, payload.lowerBound, "JFIF\u{0}")
            case 0xE2: isNote = !Binary.matches(b, payload.lowerBound, "ICC_PROFILE\u{0}")
                && !Binary.matches(b, payload.lowerBound, "MPF\u{0}")
            case 0xE1, 0xE3...0xED, 0xEF: isNote = true
            default: isNote = false
            }
            if isNote {
                b[i + 1] = 0xFE
                for k in payload { b[k] = 0x20 }
            }
            i += 2 + length
        }
    }

    // MARK: - Tokens

    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00
    }

    /// Neither white space nor a delimiter: part of a name or a number.
    private static func isRegular(_ c: UInt8) -> Bool {
        !isSpace(c) && !"()<>[]{}/%".utf8.contains(c)
    }

    private static func skipSpace(_ b: [UInt8], _ i: inout Int) {
        while i < b.count, isSpace(b[i]) { i += 1 }
    }

    private static func skippingSpace(_ b: [UInt8], _ from: Int) -> Int {
        var i = from
        skipSpace(b, &i)
        return min(i, b.count - 1)
    }

    private static func integer(_ b: [UInt8], _ i: inout Int) -> Int? {
        let start = i
        var value = 0
        while i < b.count, isDigit(b[i]), i - start < 18 {
            value = value * 10 + Int(b[i] - 0x30)
            i += 1
        }
        return i > start ? value : nil
    }

    private static func integerAt(_ b: [UInt8], _ at: Int) -> (value: Int, end: Int)? {
        var i = at
        guard let value = integer(b, &i) else { return nil }
        return (value, i)
    }

    /// Where the dictionary opening at `open` ("<<") closes, past its ">>". String literals and
    /// hex strings are stepped over: a ">>" inside one closes nothing.
    private static func dictionaryEnd(_ b: [UInt8], from open: Int) -> Int? {
        var depth = 0
        var i = open
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "("), let end = literalEnd(b, from: i) {
                i = end
                continue
            }
            if c == UInt8(ascii: "<") {
                if i + 1 < b.count, b[i + 1] == UInt8(ascii: "<") {
                    depth += 1
                    i += 2
                    continue
                }
                while i < b.count, b[i] != UInt8(ascii: ">") { i += 1 }   // a hex string
                i += 1
                continue
            }
            if c == UInt8(ascii: ">"), i + 1 < b.count, b[i + 1] == UInt8(ascii: ">") {
                depth -= 1
                i += 2
                if depth == 0 { return i }
                continue
            }
            if c == UInt8(ascii: "%") {   // a comment, to the end of the line
                while i < b.count, b[i] != 0x0A, b[i] != 0x0D { i += 1 }
                continue
            }
            i += 1
        }
        return nil
    }

    private static func literalEnd(_ b: [UInt8], from open: Int) -> Int? {
        var depth = 0
        var i = open
        while i < b.count {
            switch b[i] {
            case UInt8(ascii: "\\"): i += 2; continue
            case UInt8(ascii: "("): depth += 1
            case UInt8(ascii: ")"):
                depth -= 1
                if depth == 0 { return i + 1 }
            default: break
            }
            i += 1
        }
        return nil
    }

    private static func contains(_ b: [UInt8], _ range: Range<Int>, _ text: String) -> Bool {
        index(of: text, in: b, from: range.lowerBound, to: range.upperBound) != nil
    }

    /// The first `text` starting in `start..<end` (the whole rest of the file by default) and
    /// lying wholly inside it.
    private static func index(of text: String, in b: [UInt8], from start: Int,
                              to end: Int? = nil) -> Int? {
        let pattern = Array(text.utf8)
        let limit = min(end ?? b.count, b.count)
        guard let first = pattern.first, start >= 0 else { return nil }
        var i = start
        while i + pattern.count <= limit {
            if b[i] == first, b[i..<(i + pattern.count)].elementsEqual(pattern) { return i }
            i += 1
        }
        return nil
    }

    private static func lastIndex(of text: String, in b: [UInt8]) -> Int? {
        let pattern = Array(text.utf8)
        var i = b.count - pattern.count
        while i >= 0 {
            if b[i..<(i + pattern.count)].elementsEqual(pattern) { return i }
            i -= 1
        }
        return nil
    }
}

/// A zip read the way an office package needs it: its parts by name, and a copy written with
/// some parts replaced. Every other part is carried across as it was compressed, byte for byte.
///
/// Written the way Word writes its own: every date 1980-01-01, no extra fields, no comment —
/// a zip's entries otherwise remember when and on what machine the document was saved.
final class ZipPackage {

    private struct Entry {
        let name: String
        let nameBytes: [UInt8]
        let versionMadeBy: Int
        let versionNeeded: Int
        let flags: Int
        let method: Int
        let crc: Int
        let compressedSize: Int
        let size: Int
        let internalAttributes: Int
        let externalAttributes: Int
        let localOffset: Int
    }

    private let data: Data
    private let bytes: [UInt8]
    private let entries: [Entry]

    init?(path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        else { return nil }
        let b = [UInt8](data)
        guard let entries = Self.centralDirectory(b) else { return nil }
        self.data = data
        self.bytes = b
        self.entries = entries
    }

    private static func centralDirectory(_ b: [UInt8]) -> [Entry]? {
        // The end record: the last "PK\5\6" within the comment's reach of the end.
        let lowest = max(0, b.count - 22 - 65_535)
        var end = b.count - 22
        while end >= lowest, Binary.u32(b, end, bigEndian: false) != 0x0605_4B50 { end -= 1 }
        guard end >= lowest, let count = Binary.u16(b, end + 10, bigEndian: false),
              let start = Binary.u32(b, end + 16, bigEndian: false),
              count != 0xFFFF, start != 0xFFFF_FFFF else { return nil }   // no ZIP64 here
        var list: [Entry] = []
        var i = start
        for _ in 0..<count {
            guard Binary.u32(b, i, bigEndian: false) == 0x0201_4B50,
                  let madeBy = Binary.u16(b, i + 4, bigEndian: false),
                  let needed = Binary.u16(b, i + 6, bigEndian: false),
                  let flags = Binary.u16(b, i + 8, bigEndian: false),
                  let method = Binary.u16(b, i + 10, bigEndian: false),
                  let crc = Binary.u32(b, i + 16, bigEndian: false),
                  let compressed = Binary.u32(b, i + 20, bigEndian: false),
                  let size = Binary.u32(b, i + 24, bigEndian: false),
                  let nameLength = Binary.u16(b, i + 28, bigEndian: false),
                  let extraLength = Binary.u16(b, i + 30, bigEndian: false),
                  let commentLength = Binary.u16(b, i + 32, bigEndian: false),
                  let internalAttributes = Binary.u16(b, i + 36, bigEndian: false),
                  let externalAttributes = Binary.u32(b, i + 38, bigEndian: false),
                  let offset = Binary.u32(b, i + 42, bigEndian: false),
                  i + 46 + nameLength <= b.count,
                  compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF,
                  flags & 1 == 0 else { return nil }   // encrypted entries: not a document's
            let nameBytes = Array(b[(i + 46)..<(i + 46 + nameLength)])
            list.append(Entry(name: String(decoding: nameBytes, as: UTF8.self), nameBytes: nameBytes,
                              versionMadeBy: madeBy, versionNeeded: needed, flags: flags,
                              method: method, crc: crc, compressedSize: compressed, size: size,
                              internalAttributes: internalAttributes, externalAttributes: externalAttributes,
                              localOffset: offset))
            i += 46 + nameLength + extraLength + commentLength
        }
        return list
    }

    /// The parts, in the order they lie in the file.
    var names: [String] {
        entries.sorted { $0.localOffset < $1.localOffset }.map(\.name)
    }

    /// Where an entry's compressed data starts — past its local header, whose name and extra
    /// field need not be the lengths the central directory says.
    private func dataStart(_ entry: Entry) -> Int? {
        guard Binary.u32(bytes, entry.localOffset, bigEndian: false) == 0x0403_4B50,
              let nameLength = Binary.u16(bytes, entry.localOffset + 26, bigEndian: false),
              let extraLength = Binary.u16(bytes, entry.localOffset + 28, bigEndian: false) else {
            return nil
        }
        let start = entry.localOffset + 30 + nameLength + extraLength
        return start + entry.compressedSize <= bytes.count ? start : nil
    }

    /// A part, unpacked. Nil when there is no such part or it cannot be unpacked.
    func contents(of name: String) -> Data? {
        guard let entry = entries.first(where: { $0.name == name }),
              let start = dataStart(entry) else { return nil }
        let packed = bytes[start..<(start + entry.compressedSize)]
        switch entry.method {
        case 0:
            return Data(packed)
        case 8:
            guard entry.size > 0 else { return Data() }
            var out = [UInt8](repeating: 0, count: entry.size)
            let written = packed.withUnsafeBufferPointer { source in
                compression_decode_buffer(&out, entry.size, source.baseAddress!, source.count,
                                          nil, COMPRESSION_ZLIB)
            }
            return written == entry.size ? Data(out) : nil
        default:
            return nil
        }
    }

    /// A copy at `path`, with `replacements` (part name → new contents) stored in place of the
    /// parts of those names, in the same order.
    func write(to path: String, replacing replacements: [String: Data]) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? handle.close() }
        var central: [UInt8] = []
        var offset = 0
        for entry in entries.sorted(by: { $0.localOffset < $1.localOffset }) {
            var method = entry.method, crc = entry.crc
            var compressed = entry.compressedSize, size = entry.size
            let body: Data
            var flags = entry.flags & ~0x0008   // sizes go in front, not after the data
            if let replacement = replacements[entry.name] {
                body = replacement
                method = 0
                flags &= ~0x0006                // deflate's speed bits mean nothing stored
                crc = Int(Binary.crc32(replacement))
                compressed = replacement.count
                size = replacement.count
            } else {
                guard let start = dataStart(entry) else { throw CocoaError(.fileReadCorruptFile) }
                body = data.subdata(in: start..<(start + entry.compressedSize))
            }
            var local: [UInt8] = Binary.le32(0x0403_4B50) + Binary.le16(entry.versionNeeded)
            local += Binary.le16(flags) + Binary.le16(method) + Binary.le16(0) + Binary.le16(0x21)
            local += Binary.le32(crc) + Binary.le32(compressed) + Binary.le32(size)
            local += Binary.le16(entry.nameBytes.count) + Binary.le16(0) + entry.nameBytes
            try handle.write(contentsOf: Data(local))
            try handle.write(contentsOf: body)

            central += Binary.le32(0x0201_4B50) + Binary.le16(entry.versionMadeBy)
            central += Binary.le16(entry.versionNeeded) + Binary.le16(flags) + Binary.le16(method)
            central += Binary.le16(0) + Binary.le16(0x21)
            central += Binary.le32(crc) + Binary.le32(compressed) + Binary.le32(size)
            central += Binary.le16(entry.nameBytes.count) + Binary.le16(0) + Binary.le16(0)
            central += Binary.le16(0) + Binary.le16(entry.internalAttributes)
            central += Binary.le32(entry.externalAttributes) + Binary.le32(offset)
            central += entry.nameBytes
            offset += local.count + body.count
        }
        var end: [UInt8] = Binary.le32(0x0605_4B50) + Binary.le16(0) + Binary.le16(0)
        end += Binary.le16(entries.count) + Binary.le16(entries.count)
        end += Binary.le32(central.count) + Binary.le32(offset) + Binary.le16(0)
        try handle.write(contentsOf: Data(central + end))
    }
}
