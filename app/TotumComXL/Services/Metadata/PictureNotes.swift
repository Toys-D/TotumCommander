import Foundation

/// The TIFF structure EXIF is written in — just enough of it to keep which way is up and to
/// take the place out without moving a byte.
enum ExifBlob {

    /// A whole EXIF that says only which way is up: big-endian TIFF, one directory, one entry.
    static func orientationOnly(_ orientation: Int) -> [UInt8] {
        [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08,   // "MM", 42, the directory at 8
         0x00, 0x01,                                         // one entry:
         0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01,     // Orientation, SHORT, one value
         0x00, UInt8(clamping: orientation), 0x00, 0x00,     // the value, left-justified
         0x00, 0x00, 0x00, 0x00]                             // and no next directory
    }

    /// Which way is up, as the first directory says. Nil when it does not say, or when no
    /// readable TIFF starts at `base`.
    static func orientation(in b: [UInt8], base: Int) -> Int? {
        guard let bigEndian = byteOrder(b, base),
              let directory = firstDirectory(b, base, bigEndian) else { return nil }
        guard let entry = entries(b, directory, bigEndian).first(where: { $0.tag == 0x0112 }),
              let value = Binary.u16(b, entry.valueField, bigEndian: bigEndian),
              (1...8).contains(value) else { return nil }
        return value
    }

    /// Blank the GPS directory where it lies: every entry and every value it points at becomes
    /// zero, and the directory says it holds nothing. Same length — nothing around it moves.
    /// False when there is no GPS directory, or no readable TIFF at `base`.
    @discardableResult
    static func blankGPS(_ b: inout [UInt8], base: Int) -> Bool {
        guard let bigEndian = byteOrder(b, base),
              let directory = firstDirectory(b, base, bigEndian),
              let pointer = entries(b, directory, bigEndian).first(where: { $0.tag == 0x8825 }),
              let offset = Binary.u32(b, pointer.valueField, bigEndian: bigEndian), offset > 0,
              Binary.u16(b, base + offset, bigEndian: bigEndian) != nil else { return false }
        let gps = base + offset
        for entry in entries(b, gps, bigEndian) {
            let size = typeSize(entry.type) * entry.count
            if size > 4, let at = Binary.u32(b, entry.valueField, bigEndian: bigEndian),
               base + at >= 0, base + at + size <= b.count {
                for k in (base + at)..<(base + at + size) { b[k] = 0 }
            }
            for k in entry.position..<(entry.position + 12) { b[k] = 0 }
        }
        Binary.put16(&b, gps, 0, bigEndian: bigEndian)
        return true
    }

    // MARK: - TIFF, as little of it as this needs

    private struct Entry {
        let position: Int
        let tag: Int
        let type: Int
        let count: Int
        var valueField: Int { position + 8 }
    }

    /// True for big-endian ("MM"), false for little ("II"), nil when no TIFF starts at `base`.
    private static func byteOrder(_ b: [UInt8], _ base: Int) -> Bool? {
        if Binary.matches(b, base, "MM"), Binary.u16(b, base + 2) == 42 { return true }
        if Binary.matches(b, base, "II"), Binary.u16(b, base + 2, bigEndian: false) == 42 { return false }
        return nil
    }

    private static func firstDirectory(_ b: [UInt8], _ base: Int, _ bigEndian: Bool) -> Int? {
        guard let offset = Binary.u32(b, base + 4, bigEndian: bigEndian), offset >= 8,
              base + offset + 2 <= b.count else { return nil }
        return base + offset
    }

    private static func entries(_ b: [UInt8], _ directory: Int, _ bigEndian: Bool) -> [Entry] {
        guard let count = Binary.u16(b, directory, bigEndian: bigEndian),
              directory + 2 + count * 12 <= b.count else { return [] }
        return (0..<count).compactMap { n in
            let p = directory + 2 + n * 12
            guard let tag = Binary.u16(b, p, bigEndian: bigEndian),
                  let type = Binary.u16(b, p + 2, bigEndian: bigEndian),
                  let count = Binary.u32(b, p + 4, bigEndian: bigEndian) else { return nil }
            return Entry(position: p, tag: tag, type: type, count: count)
        }
    }

    private static func typeSize(_ type: Int) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11, 13: return 4
        case 5, 10, 12, 16, 17, 18: return 8
        default: return 0
        }
    }
}

/// XMP — the XML pictures and documents carry their notes in.
enum XMPPacket {

    /// The smallest XMP that says nothing.
    static let empty = Array(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"/>"#.utf8)

    private static let exifNamespace = "http://ns.adobe.com/exif/1.0/"

    /// The same XMP without the coordinates. Nil when it holds none, or cannot be read.
    static func removingGPS(_ bytes: [UInt8]) -> [UInt8]? {
        guard let document = try? XMLDocument(data: Data(bytes), options: [.nodePreserveAll]),
              let root = document.rootElement() else { return nil }
        var changed = false
        func isGPS(_ node: XMLNode) -> Bool {
            guard let local = node.localName, local.hasPrefix("GPS") else { return false }
            return node.uri == exifNamespace || node.prefix == "exif"
        }
        func visit(_ element: XMLElement) {
            for attribute in element.attributes ?? [] where isGPS(attribute) {
                if let name = attribute.name { element.removeAttribute(forName: name) }
                changed = true
            }
            for case let child as XMLElement in element.children ?? [] {
                if isGPS(child) {
                    child.detach()
                    changed = true
                } else {
                    visit(child)
                }
            }
        }
        visit(root)
        guard changed else { return nil }

        var out = [UInt8](document.xmlData(options: [.nodePreserveAll]))
        // XMLDocument opens with an XML declaration the packet may never have had.
        if !Binary.matches(bytes, 0, "<?xml"), Binary.matches(out, 0, "<?xml"),
           let close = out.firstRange(of: Array("?>".utf8)) {
            out.removeSubrange(0..<close.upperBound)
            while let first = out.first, first == 0x0A || first == 0x0D { out.removeFirst() }
        }
        return out
    }

    /// `bytes` grown to exactly `length` with spaces — an XMP packet is made to be padded, and
    /// XML lets a document end in white space. Nil when it does not fit.
    static func padded(_ bytes: [UInt8], to length: Int) -> [UInt8]? {
        guard bytes.count <= length else { return nil }
        return bytes + [UInt8](repeating: 0x20, count: length - bytes.count)
    }
}
