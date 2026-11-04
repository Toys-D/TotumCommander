import Foundation

/// Taking out of a file everything it says about itself besides what it is: who made it and
/// with what, when, where — and the notes macOS pins beside it.
///
/// Every kind of file keeps its notes in its own place, so every kind has its own surgeon:
/// pictures (`PictureScrubber`), film and sound (`MediaScrubber`, `TagScrubber`), documents
/// (`DocumentScrubber`). This is the one door to all of them, and it holds the rule they all
/// follow: the clean file is written BESIDE the original and only then put in its place, in one
/// atomic step — a failure halfway leaves the original exactly as it was.
enum MetadataScrubber {

    /// How much to take out.
    enum Scope: String, CaseIterable {
        /// Everything a file says besides what it is.
        case everything
        /// Only where a photograph or a film was taken: the camera, the settings and the dates
        /// stay. Means nothing to a document or a song — those are left alone.
        case place

        var localizedName: String { L("metadata.clean.\(rawValue)") }
    }

    /// What a file is, as far as its notes go.
    enum Kind: Equatable {
        case jpeg, png, gif, webp, tiff, heif
        /// QuickTime and MPEG-4 film: rebuilt from its own tracks, never re-encoded.
        case film
        /// Sound AVFoundation writes back as it was: M4A, WAV, AIFF, CAF.
        case sound
        /// MP3 and raw AAC: the tags are glued to the ends of the stream, not woven into it.
        case taggedStream
        case flac
        case pdf
        /// Word, Excel, PowerPoint — a zip with the properties in parts of their own.
        case office
        /// OpenDocument — a zip with meta.xml.
        case openDocument
        /// Nothing inside to take out: only the notes beside it.
        case other

        init(pathExtension ext: String) {
            switch ext.lowercased() {
            case "jpg", "jpeg", "jpe", "jfif": self = .jpeg
            case "png", "apng": self = .png
            case "gif": self = .gif
            case "webp": self = .webp
            case "tif", "tiff": self = .tiff
            case "heic", "heif", "hif", "avif": self = .heif
            case "mov", "qt", "mp4", "m4v", "3gp", "3g2": self = .film
            case "m4a", "m4r", "wav", "wave", "aif", "aiff", "aifc", "caf": self = .sound
            case "mp3", "aac": self = .taggedStream
            case "flac": self = .flac
            case "pdf": self = .pdf
            case "docx", "docm", "dotx", "dotm", "xlsx", "xlsm", "xltx", "xltm",
                 "pptx", "pptm", "potx", "potm", "ppsx", "ppsm": self = .office
            case "odt", "ods", "odp", "odg", "ott", "ots", "otp", "otg": self = .openDocument
            default: self = .other
            }
        }

        var isPicture: Bool {
            switch self {
            case .jpeg, .png, .gif, .webp, .tiff, .heif: return true
            default: return false
            }
        }

        /// Where "only the place" means something: a photograph or a film can say where it was
        /// taken. A GIF never does in practice, so it is not asked to.
        var knowsPlace: Bool {
            switch self {
            case .jpeg, .png, .webp, .tiff, .heif, .film: return true
            default: return false
            }
        }

        /// What goes from such a file, in the words the dialog uses.
        func localizedLoss(_ scope: Scope) -> String {
            if scope == .place {
                return L(knowsPlace ? "metadata.clean.loss.place" : "metadata.clean.loss.none")
            }
            switch self {
            case .jpeg, .png, .gif, .webp, .tiff, .heif, .film:
                return L("metadata.clean.loss.shooting")
            case .sound, .taggedStream, .flac:
                return L("metadata.clean.loss.tags")
            case .pdf, .office, .openDocument:
                return L("metadata.clean.loss.document")
            case .other:
                return L("metadata.clean.loss.notesOnly")
            }
        }
    }

    enum Failure: LocalizedError, Equatable {
        /// Not what its name promises, or broken.
        case unreadable(String)
        case unwritable(String)
        /// A password stands in the way — a protected PDF.
        case locked(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return String(format: L("metadata.clean.unreadable"), name)
            case .unwritable(let name): return String(format: L("metadata.clean.unwritable"), name)
            case .locked(let name): return String(format: L("metadata.clean.locked"), name)
            }
        }
    }

    // MARK: - What to offer

    /// The kind by the name — and for a picture, by its own first bytes: a PNG saved as ".jpg"
    /// is cleaned as the PNG it is.
    static func kind(of path: String) -> Kind {
        let byName = Kind(pathExtension: (path as NSString).pathExtension)
        guard byName.isPicture,
              let handle = FileHandle(forReadingAtPath: path) else { return byName }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 32)) ?? Data()
        return PictureScrubber.sniff([UInt8](head)) ?? byName
    }

    /// Is there anything to take out of this file? Asked while a menu opens, so it never opens
    /// a document or a film: their kind is promise enough. A picture is looked into (the header
    /// only), so the offer stays off a picture that says nothing.
    static func canClean(path: String) -> Bool {
        let kind = Kind(pathExtension: (path as NSString).pathExtension)
        if !removableAttributes(of: path).isEmpty { return true }
        if kind.isPicture { return PictureScrubber.carriesNotes(path: path) }
        return kind != .other
    }

    /// The same question about a row of a panel: a plain local file, not a folder, not a link —
    /// a link would be replaced by the clean copy of what it points at.
    static func canClean(_ item: FileItem) -> Bool {
        isPlainFile(item) && canClean(path: item.path)
    }

    /// The quick answer for a whole selection, asked by the menu bar and the command palette
    /// every time they open: the kind and the list of notes only, no picture opened. A picture
    /// that turns out to say nothing is dropped later, by `canClean`.
    static func mayClean(_ item: FileItem) -> Bool {
        // By the name: a row's own `fileExtension` comes from the core with its dot, ".jpg" —
        // read as a kind it was nothing at all, and the menu item stayed grey.
        isPlainFile(item)
            && (Kind(pathExtension: (item.name as NSString).pathExtension) != .other
                || !removableAttributes(of: item.path).isEmpty)
    }

    private static func isPlainFile(_ item: FileItem) -> Bool {
        item.name != ".." && !item.isDirectory && !item.isSymlink
    }

    // MARK: - Cleaning

    /// Clean one file. Returns the path of the clean file: the same path when the file was
    /// cleaned in place, the copy's path when `keepingOriginal` asked for a copy.
    @discardableResult
    static func clean(path: String, scope: Scope = .everything,
                      keepingOriginal: Bool = false) async throws -> String {
        let kind = kind(of: path)
        guard scope == .everything || kind.knowsPlace else { return path }
        guard kind != .other else {
            return try cleanNotesOnly(path, keepingOriginal: keepingOriginal)
        }

        let target = keepingOriginal ? copyPath(for: path) : temporaryPath(for: path)
        do {
            try await write(kind, from: path, to: target, scope: scope)
            if scope == .place {
                // Only the place goes: the notes beside the file are not the place.
                copyAllAttributes(from: path, to: target)
            } else {
                try removeAttributes(at: target)
                copyKeptAttributes(from: path, to: target)
            }
            if !keepingOriginal { try settle(target, inPlaceOf: path) }
        } catch {
            try? FileManager.default.removeItem(atPath: target)
            if error is Failure { throw error }
            throw Failure.unwritable(fileName(path))
        }
        return keepingOriginal ? target : path
    }

    private static func write(_ kind: Kind, from path: String, to target: String,
                              scope: Scope) async throws {
        switch kind {
        case .jpeg, .png, .gif, .webp, .tiff, .heif:
            try PictureScrubber.write(kind, from: path, to: target, scope: scope)
        case .film, .sound:
            try await MediaScrubber.remux(from: path, to: target, scope: scope)
        case .taggedStream:
            try TagScrubber.writeWithoutID3(from: path, to: target)
        case .flac:
            try TagScrubber.writeWithoutFLACTags(from: path, to: target)
        case .pdf:
            try DocumentScrubber.writePDF(from: path, to: target)
        case .office:
            try DocumentScrubber.writeOffice(from: path, to: target)
        case .openDocument:
            try DocumentScrubber.writeOpenDocument(from: path, to: target)
        case .other:
            break
        }
    }

    /// A file with nothing inside to take out: only the notes beside it go.
    private static func cleanNotesOnly(_ path: String, keepingOriginal: Bool) throws -> String {
        guard keepingOriginal else {
            try removeAttributes(at: path)
            return path
        }
        let copy = copyPath(for: path)
        do {
            try FileManager.default.copyItem(atPath: path, toPath: copy)
            try removeAttributes(at: copy)
        } catch {
            try? FileManager.default.removeItem(atPath: copy)
            throw Failure.unwritable(fileName(path))
        }
        return copy
    }

    /// Put the clean file where the original was. What belongs to the FILE rather than to the
    /// person — who may read it, when it came to be — stays as it was; the notes beside it come
    /// from the clean file alone.
    private static func settle(_ clean: String, inPlaceOf original: String) throws {
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: original)
        var keep: [FileAttributeKey: Any] = [:]
        keep[.posixPermissions] = attributes[.posixPermissions]
        keep[.creationDate] = attributes[.creationDate]
        try manager.setAttributes(keep, ofItemAtPath: clean)
        // `.usingNewMetadataOnly`: by default the swap carries the original's Finder label and
        // Spotlight comment over to the new file — the very notes this is taking out.
        _ = try manager.replaceItemAt(URL(fileURLWithPath: original),
                                      withItemAt: URL(fileURLWithPath: clean),
                                      backupItemName: nil, options: .usingNewMetadataOnly)
    }

    // MARK: - The notes beside a file

    /// Notes that stay: they are not about the person but about how the file works.
    ///
    /// The quarantine is the "came from the internet" mark macOS checks a file by before its
    /// first opening — taking it out would switch that check off, and it has its own switch in
    /// this program. A resource fork is the CONTENT of an old-style file; the encoding is how to
    /// read a text; a signature is a signature. The system's own marks cannot be removed anyway.
    static func keeps(attribute name: String) -> Bool {
        name == "com.apple.quarantine"
            || name == "com.apple.ResourceFork"
            || name == "com.apple.TextEncoding"
            || name.hasPrefix("com.apple.cs.")
            || systemOwned(name)
    }

    private static func systemOwned(_ name: String) -> Bool {
        name == "com.apple.macl" || name == "com.apple.provenance" || name == "com.apple.rootless"
    }

    /// The notes that would go: where it was downloaded from, tags, comments, Finder flags,
    /// when it was last opened — and whatever other programs pinned there.
    static func removableAttributes(of path: String) -> [String] {
        XattrInspector.names(path: path).filter { !keeps(attribute: $0) }
    }

    /// Take the removable notes off. Throws when one of them would not go — a file that only
    /// looks clean is worse than one that says it is not.
    static func removeAttributes(at path: String) throws {
        for name in removableAttributes(of: path) where !XattrInspector.remove(path: path, name: name) {
            throw Failure.unwritable(fileName(path))
        }
    }

    private static func copyKeptAttributes(from source: String, to target: String) {
        for name in XattrInspector.names(path: source)
        where keeps(attribute: name) && !systemOwned(name) {
            guard let value = XattrInspector.read(path: source, name: name) else { continue }
            _ = value.withUnsafeBytes {
                setxattr(target, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW)
            }
        }
    }

    private static func copyAllAttributes(from source: String, to target: String) {
        for name in XattrInspector.names(path: source) where !systemOwned(name) {
            guard let value = XattrInspector.read(path: source, name: name) else { continue }
            _ = value.withUnsafeBytes {
                setxattr(target, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW)
            }
        }
    }

    // MARK: - Names

    /// "снимок.jpg" → "снимок (без сведений).jpg", and never over something already there.
    static func copyPath(for path: String) -> String {
        let base = (path as NSString).deletingPathExtension
        let ext = (path as NSString).pathExtension
        let suffix = L("metadata.clean.copySuffix")
        var candidate = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
        var index = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = ext.isEmpty ? "\(base) \(suffix) \(index)"
                                    : "\(base) \(suffix) \(index).\(ext)"
            index += 1
        }
        return candidate
    }

    /// Beside the original, hidden, with the original's name at the end — the extension is
    /// what tells AVFoundation which container to write.
    private static func temporaryPath(for path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return (folder as NSString).appendingPathComponent(".fcxl-clean-\(UUID().uuidString)-\(name)")
    }

    static func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }
}

// MARK: - Bytes

/// Reading and writing numbers inside a file's bytes, every read bounds-checked: the files
/// cleaned here come from anywhere, and a malformed one must fail politely, not crash.
enum Binary {
    static func u16(_ b: [UInt8], _ i: Int, bigEndian: Bool = true) -> Int? {
        guard i >= 0, i + 2 <= b.count else { return nil }
        return bigEndian ? Int(b[i]) << 8 | Int(b[i + 1]) : Int(b[i + 1]) << 8 | Int(b[i])
    }

    static func u24(_ b: [UInt8], _ i: Int) -> Int? {
        guard i >= 0, i + 3 <= b.count else { return nil }
        return Int(b[i]) << 16 | Int(b[i + 1]) << 8 | Int(b[i + 2])
    }

    static func u32(_ b: [UInt8], _ i: Int, bigEndian: Bool = true) -> Int? {
        guard i >= 0, i + 4 <= b.count else { return nil }
        let bytes = bigEndian ? [b[i], b[i + 1], b[i + 2], b[i + 3]]
                              : [b[i + 3], b[i + 2], b[i + 1], b[i]]
        return bytes.reduce(0) { $0 << 8 | Int($1) }
    }

    static func u64(_ b: [UInt8], _ i: Int) -> Int? {
        guard i >= 0, i + 8 <= b.count else { return nil }
        let value = b[i..<(i + 8)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return value > UInt64(Int.max) ? nil : Int(value)
    }

    static func put16(_ b: inout [UInt8], _ i: Int, _ value: Int, bigEndian: Bool = true) {
        let hi = UInt8(truncatingIfNeeded: value >> 8), lo = UInt8(truncatingIfNeeded: value)
        b[i] = bigEndian ? hi : lo
        b[i + 1] = bigEndian ? lo : hi
    }

    static func put32(_ b: inout [UInt8], _ i: Int, _ value: Int, bigEndian: Bool = true) {
        for k in 0..<4 {
            let byte = UInt8(truncatingIfNeeded: value >> (8 * (3 - k)))
            b[bigEndian ? i + k : i + 3 - k] = byte
        }
    }

    static func be32(_ value: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4)
        put32(&out, 0, value)
        return out
    }

    static func le32(_ value: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4)
        put32(&out, 0, value, bigEndian: false)
        return out
    }

    static func le16(_ value: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 2)
        put16(&out, 0, value, bigEndian: false)
        return out
    }

    /// Do the bytes at `i` spell `text`?
    static func matches(_ b: [UInt8], _ i: Int, _ text: String) -> Bool {
        let pattern = Array(text.utf8)
        guard i >= 0, i + pattern.count <= b.count else { return false }
        return b[i..<(i + pattern.count)].elementsEqual(pattern)
    }

    static func ascii(_ b: [UInt8], _ i: Int, _ count: Int) -> String? {
        guard i >= 0, count >= 0, i + count <= b.count else { return nil }
        return String(bytes: b[i..<(i + count)], encoding: .isoLatin1)
    }

    /// The C string at `i` and where the next thing starts — nil when it never ends.
    static func cString(_ b: [UInt8], _ i: Int, limit: Int) -> (String, Int)? {
        var end = i
        while end < min(limit, b.count), b[end] != 0 { end += 1 }
        guard end < min(limit, b.count) else { return nil }
        return (String(decoding: b[i..<end], as: UTF8.self), end + 1)
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// The CRC-32 PNG and zip both use.
    static func crc32<C: Collection>(_ bytes: C, seed: UInt32 = 0) -> UInt32 where C.Element == UInt8 {
        var c = ~seed
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }
}
