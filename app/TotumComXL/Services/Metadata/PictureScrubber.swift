import Foundation
import ImageIO

/// Pictures. Every format keeps its notes in its own place, and each is cut along its own seams:
/// where the format lets the notes be cut out, the picture data is never decoded and encoded
/// again — a cleaned photograph is the same photograph, byte for byte, minus what it said.
///
/// Only TIFF goes through ImageIO: its notes are tangled into the picture's own directory, and
/// a TIFF written anew from its pixels loses nothing — TIFF compression is lossless.
///
/// Not ImageIO's own "copy without metadata" either, though it exists: it leaves HEIC and PNG
/// exactly as they were while reporting success, drops the orientation of a JPEG (a portrait
/// photograph would lie on its side), and lets a second Photoshop block through untouched.
enum PictureScrubber {

    static func write(_ kind: MetadataScrubber.Kind, from path: String, to target: String,
                      scope: MetadataScrubber.Scope) throws {
        let name = MetadataScrubber.fileName(path)
        if kind == .tiff {
            return try writeTIFF(from: path, to: target, scope: scope)
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MetadataScrubber.Failure.unreadable(name)
        }
        var bytes = [UInt8](data)
        let clean: [UInt8]?
        switch kind {
        case .jpeg: clean = JPEGSegments.clean(bytes, scope: scope)
        case .png: clean = PNGChunks.clean(bytes, scope: scope)
        case .gif: clean = GIFBlocks.clean(bytes)
        case .webp: clean = WebPChunks.clean(bytes, scope: scope)
        case .heif: clean = HEIFItems.clean(&bytes, scope: scope) ? bytes : nil
        default: clean = nil
        }
        guard let clean else { throw MetadataScrubber.Failure.unreadable(name) }
        do {
            try Data(clean).write(to: URL(fileURLWithPath: target), options: .withoutOverwriting)
        } catch {
            throw MetadataScrubber.Failure.unwritable(name)
        }
    }

    /// What the first bytes say the picture is.
    static func sniff(_ head: [UInt8]) -> MetadataScrubber.Kind? {
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return .jpeg }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if Binary.matches(head, 0, "GIF8") { return .gif }
        if Binary.matches(head, 0, "RIFF"), Binary.matches(head, 8, "WEBP") { return .webp }
        if Binary.matches(head, 0, "II*\u{0}") || Binary.matches(head, 0, "MM\u{0}*") { return .tiff }
        if Binary.matches(head, 4, "ftyp"), let brand = Binary.ascii(head, 8, 4),
           ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1", "mif2",
            "avif", "avis"].contains(brand) { return .heif }
        return nil
    }

    /// Does the picture say anything besides what it is? The notes ImageIO does not report
    /// (a PNG's text, where Stable Diffusion keeps the prompt; C2PA credentials) by walking the
    /// file, the rest through ImageIO — the header only either way.
    static func carriesNotes(path: String) -> Bool {
        if PictureNoteScan.scan(path: path).hasLooseNotes { return true }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
        else { return false }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag],
           tags.contains(where: { !technical.contains(CGImageMetadataTagCopyName($0) as String? ?? "") }) {
            return true
        }
        // PNG text does not always reach the XMP view of the notes.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        return png.keys.contains { textKeys.contains($0) }
    }

    /// What every picture says about its own pixels — not a note about anyone.
    private static let technical: Set<String> = [
        "Orientation", "XResolution", "YResolution", "ResolutionUnit", "PixelXDimension",
        "PixelYDimension", "ColorSpace", "Compression", "PhotometricInterpretation", "TileWidth",
        "TileLength", "SamplesPerPixel", "BitsPerSample", "PlanarConfiguration",
        "YCbCrPositioning", "YCbCrSubSampling", "ExifVersion", "FlashPixVersion",
        "ComponentsConfiguration", "ImageWidth", "ImageLength",
    ]

    private static let textKeys: Set<CFString> = [
        kCGImagePropertyPNGAuthor, kCGImagePropertyPNGComment, kCGImagePropertyPNGCopyright,
        kCGImagePropertyPNGCreationTime, kCGImagePropertyPNGDescription,
        kCGImagePropertyPNGModificationTime, kCGImagePropertyPNGSoftware, kCGImagePropertyPNGTitle,
    ]

    /// TIFF, written anew. "Everything": every page from its pixels, with only which way is up,
    /// the resolution and the compression it had. "Place": every page as it was, minus GPS.
    private static func writeTIFF(from path: String, to target: String,
                                  scope: MetadataScrubber.Scope) throws {
        let name = MetadataScrubber.fileName(path)
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let type = CGImageSourceGetType(source), CGImageSourceGetCount(source) > 0 else {
            throw MetadataScrubber.Failure.unreadable(name)
        }
        let count = CGImageSourceGetCount(source)
        guard let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: target) as CFURL, type, count, nil) else {
            throw MetadataScrubber.Failure.unwritable(name)
        }
        for index in 0..<count {
            switch scope {
            case .everything:
                guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                    throw MetadataScrubber.Failure.unreadable(name)
                }
                let original = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                    as? [CFString: Any] ?? [:]
                var kept: [CFString: Any] = [:]
                for key in [kCGImagePropertyOrientation, kCGImagePropertyDPIWidth,
                            kCGImagePropertyDPIHeight] {
                    kept[key] = original[key]
                }
                if let tiff = original[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
                   let compression = tiff[kCGImagePropertyTIFFCompression] {
                    kept[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: compression]
                }
                CGImageDestinationAddImage(destination, image, kept as CFDictionary)
            case .place:
                CGImageDestinationAddImageFromSource(
                    destination, source, index,
                    [kCGImagePropertyGPSDictionary: kCFNull as Any] as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else {
            throw MetadataScrubber.Failure.unwritable(name)
        }
    }
}

/// JPEG: a row of segments before the picture data, the notes in segments of their own.
enum JPEGSegments {

    private struct Segment {
        let marker: UInt8
        let start: Int
        let end: Int
        var payload: Int { start + 4 }
    }

    private static let xmpHeader = "http://ns.adobe.com/xap/1.0/\u{0}"

    /// The cleaned JPEG, or nil when the bytes are not one.
    static func clean(_ b: [UInt8], scope: MetadataScrubber.Scope) -> [UInt8]? {
        guard let (segments, dataStart) = segments(b) else { return nil }

        // Which way is up — read before the EXIF holding it goes.
        var orientation: Int?
        if scope == .everything,
           let exif = segments.first(where: { isExif($0, b) }) {
            orientation = ExifBlob.orientation(in: b, base: exif.payload + 6)
        }

        var out: [UInt8] = [0xFF, 0xD8]
        var placedOrientation = orientation == nil || orientation == 1
        var mpfOld: Int?, mpfNew: Int?
        for segment in segments {
            if !placedOrientation, !(segment.marker == 0xE0 && Binary.matches(b, segment.payload, "JFIF\u{0}")) {
                // Right after the JFIF header, where an EXIF belongs.
                out += self.segment(0xE1, Array("Exif\u{0}\u{0}".utf8) + ExifBlob.orientationOnly(orientation ?? 1))
                placedOrientation = true
            }
            var bytes = Array(b[segment.start..<segment.end])
            switch scope {
            case .everything:
                guard staysInEverything(segment, b) else { continue }
            case .place:
                if isExif(segment, b) {
                    ExifBlob.blankGPS(&bytes, base: 10)
                } else if segment.marker == 0xE1, Binary.matches(b, segment.payload, xmpHeader),
                          let cleaned = XMPPacket.removingGPS(Array(bytes[(4 + xmpHeader.utf8.count)...])) {
                    bytes = self.segment(0xE1, Array(xmpHeader.utf8) + cleaned)
                }
            }
            if segment.marker == 0xE2, Binary.matches(b, segment.payload, "MPF\u{0}") {
                mpfOld = segment.payload + 4
                mpfNew = out.count + 8
            }
            out += bytes
        }
        if !placedOrientation {
            out += segment(0xE1, Array("Exif\u{0}\u{0}".utf8) + ExifBlob.orientationOnly(orientation ?? 1))
        }

        // The pictures after this one (a multi-picture file: the HDR gain map, the depth) are
        // found by their distance from the MPF header. Whatever left or changed between that
        // header and them, the distance changes by the same.
        let tailNew = out.count
        out += b[dataStart...]
        if let mpfOld, let mpfNew {
            let shift = (tailNew - dataStart) - (mpfNew - mpfOld)
            if shift != 0 { shiftMPFOffsets(&out, header: mpfNew, by: shift) }
        }
        return out
    }

    /// The segments before the picture data, and where the data starts. Nil when the bytes are
    /// not a JPEG.
    private static func segments(_ b: [UInt8]) -> ([Segment], Int)? {
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var list: [Segment] = []
        var i = 2
        while i + 1 < b.count {
            guard b[i] == 0xFF else { return nil }
            var m = i + 1
            while m < b.count, b[m] == 0xFF { m += 1 }   // fill bytes
            guard m < b.count else { return nil }
            let marker = b[m]
            if marker == 0xDA || marker == 0xD9 { return (list, m - 1) }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                list.append(Segment(marker: marker, start: m - 1, end: m + 1))
                i = m + 1
                continue
            }
            guard let length = Binary.u16(b, m + 1), length >= 2, m + 1 + length <= b.count
            else { return nil }
            list.append(Segment(marker: marker, start: m - 1, end: m + 1 + length))
            i = m + 1 + length
        }
        return nil
    }

    private static func isExif(_ segment: Segment, _ b: [UInt8]) -> Bool {
        segment.marker == 0xE1 && Binary.matches(b, segment.payload, "Exif\u{0}\u{0}")
    }

    /// With "everything": does this segment stay? The picture's own description does — the
    /// JFIF header, the colour profile, the multi-picture index, Adobe's colour transform, the
    /// tables. Every note goes: EXIF, XMP, IPTC, comments, the cameras' and programs' own.
    private static func staysInEverything(_ segment: Segment, _ b: [UInt8]) -> Bool {
        switch segment.marker {
        case 0xE0: return Binary.matches(b, segment.payload, "JFIF\u{0}")
        case 0xE2: return Binary.matches(b, segment.payload, "ICC_PROFILE\u{0}")
                       || Binary.matches(b, segment.payload, "MPF\u{0}")
        case 0xEE: return true
        case 0xE1, 0xE3...0xED, 0xEF, 0xFE: return false
        default: return true
        }
    }

    private static func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0xFF, marker, 0, 0]
        Binary.put16(&out, 2, payload.count + 2)
        return out + payload
    }

    /// Move every picture the MPF index points at by `shift` bytes. The first picture is this
    /// one, at offset zero, and stays.
    private static func shiftMPFOffsets(_ b: inout [UInt8], header: Int, by shift: Int) {
        let bigEndian: Bool
        if Binary.matches(b, header, "MM") { bigEndian = true }
        else if Binary.matches(b, header, "II") { bigEndian = false }
        else { return }
        guard let first = Binary.u32(b, header + 4, bigEndian: bigEndian),
              let count = Binary.u16(b, header + first, bigEndian: bigEndian) else { return }
        for n in 0..<count {
            let entry = header + first + 2 + n * 12
            guard let tag = Binary.u16(b, entry, bigEndian: bigEndian), tag == 0xB002,
                  let size = Binary.u32(b, entry + 4, bigEndian: bigEndian),
                  let at = Binary.u32(b, entry + 8, bigEndian: bigEndian) else { continue }
            for k in stride(from: 0, to: size - 15, by: 16) {
                let field = header + at + k + 8
                guard let offset = Binary.u32(b, field, bigEndian: bigEndian), offset != 0
                else { continue }
                Binary.put32(&b, field, offset + shift, bigEndian: bigEndian)
            }
        }
    }
}
