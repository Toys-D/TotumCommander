import Compression
import Foundation

/// The notes a picture keeps where ImageIO does not look: PNG text chunks (where Stable
/// Diffusion, ComfyUI and NovelAI write the prompt), JPEG comments, and C2PA content
/// credentials (the signed record ChatGPT, Firefly and Bing put in their pictures).
///
/// Found by walking the file's own structure and reading only those parts — the picture data is
/// stepped over, so a 50-megabyte PNG costs a few small reads.
struct PictureNoteScan {

    /// Text notes by keyword: PNG's tEXt, zTXt and iTXt; a JPEG comment comes as "comment".
    var texts: [String: String] = [:]
    /// The C2PA manifest store (JUMBF), when the picture carries one.
    var credentials: [UInt8]?
    /// A note ImageIO does not report and cleaning would take out.
    var hasLooseNotes = false

    /// No note is read past this size: a prompt or a workflow is kilobytes, not megabytes.
    static let limit = 8 << 20

    /// The box C2PA lives in inside HEIF, AVIF and MP4: a "uuid" box with this id.
    static let c2paUUID: [UInt8] = [0xD8, 0xFE, 0xC3, 0xD6, 0x1B, 0x0E, 0x48, 0x3C,
                                    0x92, 0x97, 0x58, 0x28, 0x87, 0x7E, 0xC4, 0x81]

    static func scan(path: String) -> PictureNoteScan {
        var found = PictureNoteScan()
        guard let reader = Reader(path: path), let head = reader.read(0, min(32, reader.size)),
              let kind = PictureScrubber.sniff(head) else { return found }
        switch kind {
        case .jpeg: found.scanJPEG(reader)
        case .png: found.scanPNG(reader)
        case .webp: found.scanWebP(reader)
        case .heif: found.scanHEIF(reader)
        default: break
        }
        return found
    }

    // MARK: - The formats

    private mutating func scanJPEG(_ r: Reader) {
        var i = 2
        while let head = r.read(i, 4), head[0] == 0xFF {
            let marker = head[1]
            if marker == 0xFF { i += 1; continue }                       // a fill byte
            if marker == 0xDA || marker == 0xD9 { return }               // the picture data
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            guard let length = Binary.u16(head, 2), length >= 2 else { return }
            let payload = { r.read(i + 4, min(length - 2, Self.limit)) ?? [] }
            switch marker {
            case 0xFE:
                hasLooseNotes = true
                let text = Self.text(payload())
                texts["comment"] = texts["comment"].map { $0 + "\n" + text } ?? text
            case 0xEB:
                hasLooseNotes = true
                let bytes = payload()
                // "JP", the box instance and the sequence number come before each piece.
                if Binary.matches(bytes, 0, "JP"), bytes.count > 8 {
                    credentials = (credentials ?? []) + bytes[8...]
                }
            case 0xE0:
                if !Binary.matches(payload(), 0, "JFIF\u{0}") { hasLooseNotes = true }
            case 0xE1:
                let bytes = r.read(i + 4, min(length - 2, 64)) ?? []
                if !Binary.matches(bytes, 0, "Exif\u{0}\u{0}"),
                   !Binary.matches(bytes, 0, "http://ns.adobe.com/xap/1.0/\u{0}") {
                    hasLooseNotes = true
                }
            case 0xE2:
                let bytes = r.read(i + 4, min(length - 2, 16)) ?? []
                if !Binary.matches(bytes, 0, "ICC_PROFILE\u{0}"), !Binary.matches(bytes, 0, "MPF\u{0}") {
                    hasLooseNotes = true
                }
            case 0xE3...0xEA, 0xEC, 0xED, 0xEF:
                hasLooseNotes = true
            default:
                break
            }
            i += 2 + length
        }
    }

    private mutating func scanPNG(_ r: Reader) {
        var i = 8
        while let head = r.read(i, 8), let length = Binary.u32(head, 0),
              let type = Binary.ascii(head, 4, 4) {
            switch type {
            case "tEXt", "zTXt", "iTXt":
                hasLooseNotes = true
                if length <= Self.limit, let data = r.read(i + 8, length),
                   let (keyword, text) = Self.pngText(type, data) {
                    texts[keyword] = text
                }
            case "tIME", "exIf", "dSIG":
                // Not "eXIf": macOS writes one into every PNG it saves, with nothing but the
                // picture's own size in it — whether it says more, ImageIO tells.
                hasLooseNotes = true
            case "caBX":
                hasLooseNotes = true
                credentials = r.read(i + 8, min(length, Self.limit))
            case "IEND":
                return
            default:
                break
            }
            i += 12 + length
        }
    }

    private mutating func scanWebP(_ r: Reader) {
        var i = 12
        while let head = r.read(i, 8), let type = Binary.ascii(head, 0, 4),
              let size = Binary.u32(head, 4, bigEndian: false) {
            switch type {
            case "EXIF", "XMP ":
                hasLooseNotes = true
            case "C2PA":
                hasLooseNotes = true
                credentials = r.read(i + 8, min(size, Self.limit))
            default:
                break
            }
            i += 8 + size + (size & 1)
        }
    }

    private mutating func scanHEIF(_ r: Reader) {
        var i = 0
        while let head = r.read(i, 8), let size32 = Binary.u32(head, 0),
              let type = Binary.ascii(head, 4, 4) {
            var header = 8, size = size32
            if size32 == 1 {
                guard let large = r.read(i + 8, 8).flatMap({ Binary.u64($0, 0) }) else { return }
                size = large
                header = 16
            } else if size32 == 0 {
                size = r.size - i
            }
            guard size >= header else { return }
            if type == "uuid", r.read(i + header, 16) == Self.c2paUUID {
                hasLooseNotes = true
                credentials = r.read(i + header + 16, min(size - header - 16, Self.limit))
            }
            i += size
        }
    }

    // MARK: - Text

    /// A PNG text chunk: its keyword and its text, unpacked. tEXt is Latin-1 by the book, but
    /// programs write UTF-8 into it just as often — UTF-8 is tried first.
    static func pngText(_ type: String, _ data: [UInt8]) -> (String, String)? {
        guard let (keyword, next) = Binary.cString(data, 0, limit: data.count) else { return nil }
        switch type {
        case "tEXt":
            return (keyword, text(Array(data[next...])))
        case "zTXt":
            guard next + 1 <= data.count, let unpacked = inflate(Array(data[(next + 1)...]))
            else { return nil }
            return (keyword, text(unpacked))
        default:   // iTXt
            guard next + 2 <= data.count,
                  let (_, translated) = Binary.cString(data, next + 2, limit: data.count),
                  let (_, start) = Binary.cString(data, translated, limit: data.count) else { return nil }
            var body = Array(data[start...])
            if data[next] == 1 {
                guard let unpacked = inflate(body) else { return nil }
                body = unpacked
            }
            return (keyword, String(decoding: body, as: UTF8.self))
        }
    }

    static func text(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    /// zlib, as PNG packs its text: a two-byte header, then plain deflate.
    static func inflate(_ zlib: [UInt8]) -> [UInt8]? {
        guard zlib.count > 2 else { return nil }
        let packed = Array(zlib.dropFirst(2))
        var capacity = max(packed.count * 4, 4096)
        while capacity <= limit {
            var out = [UInt8](repeating: 0, count: capacity)
            let written = packed.withUnsafeBufferPointer { source in
                compression_decode_buffer(&out, capacity, source.baseAddress!, source.count,
                                          nil, COMPRESSION_ZLIB)
            }
            if written == 0 { return nil }
            if written < capacity { return Array(out.prefix(written)) }
            capacity *= 2   // filled to the brim: it may not all have fitted
        }
        return nil
    }

    // MARK: - Reading pieces of a file

    private final class Reader {
        let handle: FileHandle
        let size: Int

        init?(path: String) {
            guard let handle = FileHandle(forReadingAtPath: path),
                  let end = try? handle.seekToEnd() else { return nil }
            self.handle = handle
            self.size = Int(end)
        }

        deinit { try? handle.close() }

        func read(_ offset: Int, _ count: Int) -> [UInt8]? {
            guard offset >= 0, count >= 0, offset + count <= size else { return nil }
            guard count > 0 else { return [] }
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return [UInt8](data)
        }
    }
}
