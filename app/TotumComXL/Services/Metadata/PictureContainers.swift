import Foundation

/// PNG: chunks, each named, sized and checksummed. The notes are chunks of their own — text,
/// the time, EXIF — so cleaning is leaving them out.
enum PNGChunks {

    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// Text (where Stable Diffusion and ComfyUI write the prompt), the time, EXIF (and the old
    /// spelling of its name), a signature, and caBX — C2PA content credentials.
    private static let notes: Set<String> = ["tEXt", "zTXt", "iTXt", "tIME", "eXIf", "exIf", "dSIG", "caBX"]

    /// The cleaned PNG, or nil when the bytes are not one.
    static func clean(_ b: [UInt8], scope: MetadataScrubber.Scope) -> [UInt8]? {
        guard b.starts(with: signature) else { return nil }
        var out = signature
        var i = 8
        while i + 12 <= b.count {
            guard let length = Binary.u32(b, i), let type = Binary.ascii(b, i + 4, 4),
                  i + 12 + length <= b.count else { return nil }
            let data = Array(b[(i + 8)..<(i + 8 + length)])
            let whole = b[i..<(i + 12 + length)]
            switch (scope, type) {
            case (.everything, "eXIf"):
                // All of it goes but which way is up.
                if let orientation = ExifBlob.orientation(in: data, base: 0), orientation != 1 {
                    out += chunk("eXIf", ExifBlob.orientationOnly(orientation))
                }
            case (.everything, _) where notes.contains(type):
                break
            case (.place, "eXIf"):
                var exif = data
                ExifBlob.blankGPS(&exif, base: 0)
                out += chunk("eXIf", exif)
            case (.place, "iTXt"):
                out += placelessXMP(data).map { chunk("iTXt", $0) } ?? Array(whole)
            default:
                out += whole
            }
            i += 12 + length
            if type == "IEND" {
                out += b[i...]
                return out
            }
        }
        return nil
    }

    static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + data
        return Binary.be32(data.count) + body + Binary.be32(Int(Binary.crc32(body)))
    }

    /// An iTXt chunk holding XMP, minus the coordinates; nil when it is some other text, a
    /// compressed one, or has no coordinates to lose.
    private static func placelessXMP(_ data: [UInt8]) -> [UInt8]? {
        guard let (keyword, flags) = Binary.cString(data, 0, limit: data.count),
              keyword == "XML:com.adobe.xmp", flags + 2 <= data.count, data[flags] == 0,
              let (_, translated) = Binary.cString(data, flags + 2, limit: data.count),
              let (_, text) = Binary.cString(data, translated, limit: data.count),
              let cleaned = XMPPacket.removingGPS(Array(data[text...])) else { return nil }
        return Array(data[0..<text]) + cleaned
    }
}

/// GIF: blocks one after another. The notes are comment blocks and application blocks other
/// than the ones that make the picture what it is — XMP among them.
enum GIFBlocks {

    /// The application blocks that are part of the picture: looping, and the colour profile.
    private static let kept: Set<String> = ["NETSCAPE2.0", "ANIMEXTS1.0", "ICCRGBG1012"]

    /// The cleaned GIF, or nil when the bytes are not one.
    static func clean(_ b: [UInt8]) -> [UInt8]? {
        guard Binary.matches(b, 0, "GIF87a") || Binary.matches(b, 0, "GIF89a"), b.count >= 13
        else { return nil }
        var i = 13
        if b[10] & 0x80 != 0 { i += 3 << (Int(b[10] & 7) + 1) }   // the global palette
        guard i <= b.count else { return nil }
        var out = Array(b[0..<i])
        while i < b.count {
            switch b[i] {
            case 0x21:   // an extension
                guard i + 2 <= b.count, let end = subBlocksEnd(b, from: i + 2) else { return nil }
                let keep: Bool
                switch b[i + 1] {
                case 0xFE:
                    keep = false
                case 0xFF:
                    keep = b[i + 2] == 11 && kept.contains(Binary.ascii(b, i + 3, 11) ?? "")
                default:
                    keep = true   // timing, plain text
                }
                if keep { out += b[i..<end] }
                i = end
            case 0x2C:   // a frame
                guard i + 10 <= b.count else { return nil }
                var j = i + 10
                if b[i + 9] & 0x80 != 0 { j += 3 << (Int(b[i + 9] & 7) + 1) }   // its own palette
                guard j + 1 <= b.count, let end = subBlocksEnd(b, from: j + 1) else { return nil }
                out += b[i..<end]
                i = end
            case 0x3B:   // the end
                out += b[i...]
                return out
            default:
                return nil
            }
        }
        return out   // many GIFs never write the end mark; everything before it is whole
    }

    /// Past a chain of sub-blocks: a length byte and that many bytes, until a zero length.
    private static func subBlocksEnd(_ b: [UInt8], from start: Int) -> Int? {
        var i = start
        while i < b.count {
            let length = Int(b[i])
            if length == 0 { return i + 1 }
            i += 1 + length
        }
        return nil
    }
}

/// WebP: RIFF chunks. EXIF and XMP are chunks of their own, announced by flags in the extended
/// header, which have to keep telling the truth.
enum WebPChunks {

    /// The cleaned WebP, or nil when the bytes are not one.
    static func clean(_ b: [UInt8], scope: MetadataScrubber.Scope) -> [UInt8]? {
        guard Binary.matches(b, 0, "RIFF"), Binary.matches(b, 8, "WEBP"),
              let riffSize = Binary.u32(b, 4, bigEndian: false) else { return nil }
        let end = min(b.count, 8 + riffSize)
        var chunks: [(String, [UInt8])] = []
        var i = 12
        while i + 8 <= end {
            guard let type = Binary.ascii(b, i, 4), let size = Binary.u32(b, i + 4, bigEndian: false),
                  i + 8 + size <= end else { return nil }
            chunks.append((type, Array(b[(i + 8)..<(i + 8 + size)])))
            i += 8 + size + (size & 1)
        }

        var hasExif = false, hasXMP = false
        var out: [(String, [UInt8])] = []
        for (type, data) in chunks {
            let exifBase = Binary.matches(data, 0, "Exif\u{0}\u{0}") ? 6 : 0
            switch (scope, type) {
            case (.everything, "EXIF"):
                if let orientation = ExifBlob.orientation(in: data, base: exifBase), orientation != 1 {
                    out.append(("EXIF", ExifBlob.orientationOnly(orientation)))
                    hasExif = true
                }
            case (.everything, "XMP "), (.everything, "C2PA"):
                break
            case (.place, "EXIF"):
                var exif = data
                ExifBlob.blankGPS(&exif, base: exifBase)
                out.append(("EXIF", exif))
                hasExif = true
            case (.place, "XMP "):
                out.append(("XMP ", XMPPacket.removingGPS(data) ?? data))
                hasXMP = true
            default:
                out.append((type, data))
            }
        }
        if let index = out.firstIndex(where: { $0.0 == "VP8X" }), !out[index].1.isEmpty {
            var flags = out[index].1[0]
            flags = hasExif ? flags | 0x08 : flags & ~0x08
            flags = hasXMP ? flags | 0x04 : flags & ~0x04
            out[index].1[0] = flags
        }

        var body = Array("WEBP".utf8)
        for (type, data) in out {
            body += Array(type.utf8) + Binary.le32(data.count) + data
            if data.count & 1 == 1 { body.append(0) }
        }
        return Array("RIFF".utf8) + Binary.le32(body.count) + body + b[end...]
    }
}

/// HEIF and AVIF — boxes inside boxes, the notes stored as items of their own (an "Exif" item,
/// an XMP one) and found through an index of where every item lies. The index is left as it
/// is: the notes are overwritten where they lie with a version that says nothing, of exactly the
/// same length, so not one offset in the file changes and the picture is not touched.
enum HEIFItems {

    private struct Box {
        let type: String
        let start: Int
        let content: Int
        let end: Int
    }

    private struct Extent {
        let method: Int
        let offset: Int
        let length: Int
    }

    /// Overwrite the notes in place. False when the bytes are not HEIF as this understands it.
    static func clean(_ b: inout [UInt8], scope: MetadataScrubber.Scope) -> Bool {
        guard let top = boxes(b, from: 0, to: b.count),
              top.contains(where: { $0.type == "ftyp" }),
              let meta = top.first(where: { $0.type == "meta" }),
              let children = boxes(b, from: meta.content + 4, to: meta.end) else { return false }
        guard let iinf = children.first(where: { $0.type == "iinf" }),
              let iloc = children.first(where: { $0.type == "iloc" }) else { return true }
        let idat = children.first(where: { $0.type == "idat" })
        guard let notes = noteItems(b, iinf), let locations = itemLocations(b, iloc) else {
            return false
        }

        for (id, isExif) in notes {
            guard let extents = locations[id] else { continue }
            var ranges: [Range<Int>] = []
            for extent in extents {
                let area: Range<Int>
                switch extent.method {
                case 0: area = 0..<b.count
                case 1:
                    guard let idat else { return false }
                    area = idat.content..<idat.end
                default: continue
                }
                let start = area.lowerBound + extent.offset
                let end = extent.length == 0 ? area.upperBound : start + extent.length
                guard start >= area.lowerBound, end <= area.upperBound, start <= end else { return false }
                ranges.append(start..<end)
            }
            var payload = ranges.flatMap { b[$0] }
            let length = payload.count
            if isExif {
                let tiff = 4 + (Binary.u32(payload, 0) ?? 0)
                switch scope {
                case .everything:
                    // Which way is up stays: a reader that looks at it must find what it found.
                    let fresh = [0, 0, 0, 0] + ExifBlob.orientationOnly(
                        ExifBlob.orientation(in: payload, base: tiff) ?? 1)
                    payload = fresh.count <= length
                        ? fresh + [UInt8](repeating: 0, count: length - fresh.count)
                        : [UInt8](repeating: 0, count: length)
                case .place:
                    ExifBlob.blankGPS(&payload, base: tiff)
                }
            } else {
                switch scope {
                case .everything:
                    payload = XMPPacket.padded(XMPPacket.empty, to: length)
                        ?? [UInt8](repeating: 0x20, count: length)
                case .place:
                    if let cleaned = XMPPacket.removingGPS(payload),
                       let fitted = XMPPacket.padded(cleaned, to: length) {
                        payload = fitted
                    }
                }
            }
            var cursor = 0
            for range in ranges {
                b.replaceSubrange(range, with: payload[cursor..<(cursor + range.count)])
                cursor += range.count
            }
        }
        if scope == .everything {
            // C2PA content credentials live in a box of their own beside the index. Renamed to
            // "free" and emptied, the box is padding every reader steps over.
            for box in top where box.type == "uuid"
            && Array(b[min(box.content, box.end)..<min(box.content + 16, box.end)]) == PictureNoteScan.c2paUUID {
                b.replaceSubrange((box.start + 4)..<(box.start + 8), with: Array("free".utf8))
                for k in box.content..<box.end { b[k] = 0 }
            }
        }
        return true
    }

    private static func boxes(_ b: [UInt8], from start: Int, to end: Int) -> [Box]? {
        var list: [Box] = []
        var i = start
        while i + 8 <= end {
            guard let size32 = Binary.u32(b, i), let type = Binary.ascii(b, i + 4, 4) else { return nil }
            var header = 8, size = size32
            if size32 == 1 {
                guard let large = Binary.u64(b, i + 8) else { return nil }
                size = large
                header = 16
            } else if size32 == 0 {
                size = end - i
            }
            guard size >= header, i + size <= end else { return nil }
            list.append(Box(type: type, start: i, content: i + header, end: i + size))
            i += size
        }
        return list
    }

    /// The items holding notes: their ids, true for EXIF, false for XMP.
    private static func noteItems(_ b: [UInt8], _ iinf: Box) -> [(Int, Bool)]? {
        guard iinf.content + 4 <= iinf.end else { return nil }
        let first = iinf.content + 4 + (b[iinf.content] == 0 ? 2 : 4)
        guard let entries = boxes(b, from: first, to: iinf.end) else { return nil }
        var found: [(Int, Bool)] = []
        for infe in entries where infe.type == "infe" && infe.content + 4 <= infe.end {
            let version = b[infe.content]
            guard version >= 2 else { continue }   // the old versions name no item type
            var p = infe.content + 4
            guard let id = version == 2 ? Binary.u16(b, p) : Binary.u32(b, p) else { return nil }
            p += (version == 2 ? 2 : 4) + 2        // the id, then the protection index
            guard p + 4 <= infe.end, let type = Binary.ascii(b, p, 4) else { return nil }
            p += 4
            if type == "Exif" {
                found.append((id, true))
            } else if type == "mime",
                      let (_, afterName) = Binary.cString(b, p, limit: infe.end),
                      let (contentType, _) = Binary.cString(b, afterName, limit: infe.end),
                      contentType.hasPrefix("application/rdf+xml") {
                found.append((id, false))
            }
        }
        return found
    }

    /// Where every item lies: its id → the pieces it is made of.
    private static func itemLocations(_ b: [UInt8], _ iloc: Box) -> [Int: [Extent]]? {
        var p = iloc.content
        guard p + 6 <= iloc.end else { return nil }
        let version = Int(b[p])
        p += 4
        let offsetSize = Int(b[p] >> 4), lengthSize = Int(b[p] & 0x0F)
        let baseOffsetSize = Int(b[p + 1] >> 4)
        let indexSize = version == 1 || version == 2 ? Int(b[p + 1] & 0x0F) : 0
        p += 2

        func read(_ size: Int) -> Int? {
            guard p + size <= iloc.end else { return nil }
            defer { p += size }
            switch size {
            case 0: return 0
            case 2: return Binary.u16(b, p)
            case 4: return Binary.u32(b, p)
            case 8: return Binary.u64(b, p)
            default: return nil
            }
        }

        guard let count = read(version < 2 ? 2 : 4) else { return nil }
        var map: [Int: [Extent]] = [:]
        for _ in 0..<count {
            guard let id = read(version < 2 ? 2 : 4) else { return nil }
            var method = 0
            if version == 1 || version == 2 {
                guard let field = read(2) else { return nil }
                method = field & 0x0F
            }
            guard read(2) != nil,   // the data reference
                  let base = read(baseOffsetSize), let extentCount = read(2) else { return nil }
            var extents: [Extent] = []
            for _ in 0..<extentCount {
                if indexSize > 0, read(indexSize) == nil { return nil }
                guard let offset = read(offsetSize), let length = read(lengthSize) else { return nil }
                extents.append(Extent(method: method, offset: base + offset, length: length))
            }
            map[id] = extents
        }
        return map
    }
}
