import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// What has been done to the picture on screen, and nothing else: rotation in quarter turns,
/// two mirrors, inversion, a new size. A value, not a picture — the viewer keeps one of these
/// while the person presses buttons, shows the result on the PREVIEW, and only on "Save"
/// applies the very same value to the file at full size.
///
/// Every button speaks in what the person SEES. On a picture already turned a quarter, a
/// horizontal mirror is a vertical one in the file's own coordinates, and after a single mirror
/// a "turn right" runs left. Both rules live here (see `flipOnScreen`, `rotateOnScreen`) rather
/// than in the buttons, because getting them wrong is invisible until someone rotates a
/// mirrored photograph and it walks the wrong way.
struct ImageEdits: Equatable {
    /// Quarter turns clockwise, 0…3, in the FILE's coordinates.
    var quarterTurns = 0
    var flipHorizontal = false
    var flipVertical = false
    var invert = false
    /// Target size in pixels, before turning and mirroring. nil — the original size.
    var resize: CGSize?

    // Colour, the way the sliders show it: every one of these sits at its neutral value while
    // the picture is untouched, so "nothing was changed" is a plain comparison.
    /// −1 … 1, 0 — as it was.
    var brightness: Double = 0
    /// 0.25 … 4, 1 — as it was.
    var contrast: Double = 1
    /// 0 … 2, 1 — as it was; 0 is grey.
    var saturation: Double = 1
    /// −100 … 100, 0 — as it was; above zero the picture warms.
    var warmth: Double = 0
    /// 0 … 2, 0 — as it was.
    var sharpness: Double = 0

    /// Levelling the horizon: degrees, −15 … 15, 0 — as it was. The picture turns by this
    /// much and is cut back to a rectangle with no empty corners (see `insideTurned`).
    var straighten: Double = 0

    /// The piece to keep, in shares of the FINAL picture — the one on screen, after turning
    /// and mirroring. nil — the whole of it. Kept in the final space on purpose: the frame is
    /// drawn on what the person sees, and a rectangle in the file's own coordinates would have
    /// to be carried through every transform to get back there.
    var crop: CGRect?

    static let neutralTemperature: Double = 6500

    var hasGeometryChanges: Bool { straighten != 0 || crop != nil }

    var hasColourChanges: Bool {
        brightness != 0 || contrast != 1 || saturation != 1 || warmth != 0 || sharpness != 0
    }

    mutating func resetColours() {
        brightness = 0; contrast = 1; saturation = 1; warmth = 0; sharpness = 0
    }

    var isIdentity: Bool {
        quarterTurns == 0 && !flipHorizontal && !flipVertical && !invert && resize == nil
            && !hasColourChanges && !hasGeometryChanges
    }

    /// The biggest upright rectangle of the ORIGINAL proportion that fits inside a picture
    /// turned by `degrees` — what levelling the horizon has to cut back to, or the corners
    /// come out empty. Answers its SIZE in points; the caller centres it in the turned
    /// picture. Sizes, not shares: the turned frame is rounded out to whole pixels (200×200
    /// at 8° becomes 226×227 — measured), and shares of an assumed frame drifted a pixel off,
    /// which is exactly enough to catch the blended edge.
    static func insideTurned(size: CGSize, degrees: Double) -> CGSize {
        let angle = abs(degrees) * .pi / 180
        guard angle > 0.0001, size.width > 0, size.height > 0 else { return size }
        // The rectangle W×H turned by `a` holds a point (x, y) when
        //   |x·cos a + y·sin a| ≤ W/2  and  |−x·sin a + y·cos a| ≤ H/2.
        // Our piece keeps the ORIGINAL proportion r = W/H and stands upright at the same
        // centre, so its corners are (±r·h/2, ±h/2); putting the worst corner into each
        // condition gives two limits on h, and the smaller one is the answer.
        let ratio = size.width / size.height
        let sinA = sin(angle), cosA = cos(angle)
        let byWidth = size.width / (ratio * cosA + sinA)
        let byHeight = size.height / (ratio * sinA + cosA)
        let height = min(byWidth, byHeight)
        return CGSize(width: max(1, ratio * height), height: max(1, height))
    }

    /// A crop of the given proportion, as big as fits, centred — what the 1:1 / 4:3 / 16:9
    /// buttons hand over.
    static func centredCrop(ratio: CGFloat, in size: CGSize) -> CGRect {
        guard ratio > 0, size.width > 0, size.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let current = size.width / size.height
        if current > ratio {
            let width = ratio / current
            return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
        }
        let height = current / ratio
        return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
    }

    /// A turn as the person sees it. One mirror reverses which way "clockwise" runs; two
    /// mirrors cancel out.
    mutating func rotateOnScreen(clockwise: Bool) {
        let mirrored = flipHorizontal != flipVertical
        let toRight = mirrored ? !clockwise : clockwise
        quarterTurns = (quarterTurns + (toRight ? 1 : 3)) % 4
    }

    /// A mirror as the person sees it: on a picture standing on its side the axes swap.
    mutating func flipOnScreen(horizontal: Bool) {
        let swapped = quarterTurns % 2 == 1
        if horizontal == !swapped { flipHorizontal.toggle() } else { flipVertical.toggle() }
    }

    /// The size the result will have, from the source's size in pixels.
    func resultSize(source: CGSize) -> CGSize {
        let base = resize ?? source
        return quarterTurns % 2 == 1 ? CGSize(width: base.height, height: base.width) : base
    }

    /// A size that keeps the source's proportion and fits the wanted width (or height).
    static func proportional(source: CGSize, width: CGFloat?, height: CGFloat?) -> CGSize? {
        guard source.width > 0, source.height > 0 else { return nil }
        if let width, width > 0 {
            return CGSize(width: width.rounded(), height: (width * source.height / source.width).rounded())
        }
        if let height, height > 0 {
            return CGSize(width: (height * source.width / source.height).rounded(), height: height.rounded())
        }
        return nil
    }
}

/// The formats the picture can be saved as. Only what ImageIO can actually WRITE on this
/// system — measured, not assumed: WebP reads but does not write, so it is not offered.
enum ImageSaveFormat: String, CaseIterable {
    case png, jpeg, heic, tiff

    var utType: UTType {
        switch self {
        case .png:  return .png
        case .jpeg: return .jpeg
        case .heic: return UTType("public.heic") ?? .jpeg
        case .tiff: return .tiff
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .tiff: return "tiff"
        }
    }

    /// Quality means nothing to PNG and TIFF — they are lossless, and the slider is hidden.
    var usesQuality: Bool { self == .jpeg || self == .heic }

    var titleKey: String { "viewer.image.format.\(rawValue)" }

    /// The format a file already is, by its name — what "Save" writes back into.
    ///
    /// The leading dot is dropped on purpose: a FileItem carries its extension WITH one
    /// (".jpg"), and a comparison against "jpg" quietly matched nothing — the editing bar
    /// simply never appeared.
    static func matching(extension ext: String) -> ImageSaveFormat? {
        var name = ext.trimmingCharacters(in: .whitespaces).lowercased()
        while name.hasPrefix(".") { name.removeFirst() }
        switch name {
        case "png": return .png
        case "jpg", "jpeg", "jpe": return .jpeg
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        default: return nil
        }
    }
}

/// Applying the edits and writing the result. Nothing here touches the interface, so every
/// rule can be measured on a real picture in a test.
enum ImageEditor {
    /// One shared context: building a CIContext per picture is the slow way to do this.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The edits applied to `source`. nil only when the render itself fails.
    static func apply(_ edits: ImageEdits, to source: CGImage) -> CGImage? {
        guard !edits.isIdentity else { return source }
        var picture = CIImage(cgImage: source)

        if let size = edits.resize, size.width > 0, size.height > 0 {
            let scale = CGAffineTransform(scaleX: size.width / CGFloat(source.width),
                                          y: size.height / CGFloat(source.height))
            picture = picture.transformed(by: scale)
        }
        if edits.brightness != 0 || edits.contrast != 1 || edits.saturation != 1 {
            picture = picture.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: edits.brightness,
                kCIInputContrastKey: edits.contrast,
                kCIInputSaturationKey: edits.saturation,
            ])
        }
        if edits.warmth != 0 {
            // The filter maps what it is told is the scene's neutral onto a target neutral.
            // Lowering the TARGET warms the picture: measured on grey pixels, where +60 with
            // the target raised came out COLDER (red minus blue went to −21). Hence the minus.
            picture = picture.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: ImageEdits.neutralTemperature, y: 0),
                "inputTargetNeutral": CIVector(x: ImageEdits.neutralTemperature - edits.warmth * 30, y: 0),
            ])
        }
        if edits.sharpness > 0 {
            picture = picture.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: edits.sharpness,
            ])
            // Sharpening reaches past the frame; keep the picture its own size.
            picture = picture.cropped(to: picture.extent.intersection(
                CIImage(cgImage: source).extent.applying(
                    edits.resize.map { CGAffineTransform(scaleX: $0.width / CGFloat(source.width),
                                                         y: $0.height / CGFloat(source.height)) } ?? .identity)))
        }
        if edits.straighten != 0 {
            let before = picture.extent.size
            let angle = -edits.straighten * .pi / 180
            picture = picture.transformed(by: CGAffineTransform(rotationAngle: angle))
            picture = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX,
                                                                y: -picture.extent.minY))
            let keep = ImageEdits.insideTurned(size: before, degrees: edits.straighten)
            let frame = picture.extent
            var box = CGRect(x: frame.midX - keep.width / 2, y: frame.midY - keep.height / 2,
                             width: keep.width, height: keep.height)
            // A pixel in from the exact maximum: the turned edge is blended with the empty
            // corner, and cutting flush leaves a thin dark fringe along the sides. Rounded
            // INWARD as well — `cropped(to:)` rounds a fractional rectangle outward, which
            // handed the fringe straight back (measured: the inset changed nothing).
            box = box.insetBy(dx: 1, dy: 1)
            box = CGRect(x: box.minX.rounded(.up), y: box.minY.rounded(.up),
                         width: (box.maxX.rounded(.down) - box.minX.rounded(.up)),
                         height: (box.maxY.rounded(.down) - box.minY.rounded(.up)))
            picture = picture.cropped(to: box)
            picture = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX,
                                                                y: -picture.extent.minY))
        }
        if edits.invert {
            picture = picture.applyingFilter("CIColorInvert")
        }

        var transform = CGAffineTransform.identity
        if edits.flipHorizontal { transform = transform.scaledBy(x: -1, y: 1) }
        if edits.flipVertical { transform = transform.scaledBy(x: 1, y: -1) }
        if edits.quarterTurns != 0 {
            // Clockwise on screen: CoreImage's Y grows upwards, so the angle is negative.
            transform = transform.rotated(by: -CGFloat(edits.quarterTurns) * .pi / 2)
        }
        picture = picture.transformed(by: transform)
        // Back to an origin of zero, or the render would come out empty.
        picture = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX,
                                                            y: -picture.extent.minY))
        if let crop = edits.crop {
            // Shares of the picture as it now stands; y is measured from the TOP, the way the
            // frame is drawn on screen, and flipped here into CoreImage's upward y.
            let extent = picture.extent
            let box = CGRect(x: extent.minX + crop.minX * extent.width,
                             y: extent.minY + (1 - crop.maxY) * extent.height,
                             width: crop.width * extent.width,
                             height: crop.height * extent.height)
            picture = picture.cropped(to: box.intersection(extent))
            picture = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX,
                                                                y: -picture.extent.minY))
        }
        return context.createCGImage(picture, from: picture.extent)
    }

    /// The first frame of a file, at full size — what "Save" edits, never the screen's preview.
    static func loadOriginal(path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        // Orientation baked in, so a photograph taken sideways edits the way it looks.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: false]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else { return nil }
        guard let orientation = orientation(of: source), orientation != .up else { return image }
        var upright = ImageEdits()
        switch orientation {
        case .down: upright.quarterTurns = 2
        case .left: upright.quarterTurns = 3
        case .right: upright.quarterTurns = 1
        case .upMirrored: upright.flipHorizontal = true
        case .downMirrored: upright.flipVertical = true
        case .leftMirrored: upright.quarterTurns = 3; upright.flipHorizontal = true
        case .rightMirrored: upright.quarterTurns = 1; upright.flipHorizontal = true
        default: return image
        }
        return apply(upright, to: image) ?? image
    }

    static func orientation(of source: CGImageSource) -> CGImagePropertyOrientation? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32 else { return nil }
        return CGImagePropertyOrientation(rawValue: raw)
    }

    enum SaveError: LocalizedError {
        case cannotWrite(String)
        var errorDescription: String? {
            switch self {
            case .cannotWrite(let format): return String(format: L("viewer.image.saveFailed"), format)
            }
        }
    }

    /// Write the picture as `format`. Quality is for JPEG and HEIC; the rest ignore it.
    /// Metadata is deliberately NOT copied: a rotated picture with the original's orientation
    /// tag would be turned twice, and the file's own tags say things about a picture that no
    /// longer exists.
    /// Write the picture as `format`. Quality is for JPEG and HEIC; the rest ignore it.
    ///
    /// `metadata` is what the source file carried — camera, lens, date, place. It is copied
    /// over so an edited photograph does not lose its history, MINUS the orientation tag: the
    /// turn is already in the pixels, and leaving the tag would turn the picture twice.
    /// Pass nil to write the picture bare — that is "remove EXIF".
    static func write(_ image: CGImage, to path: String, format: ImageSaveFormat,
                      quality: Double = 0.9, metadata: [CFString: Any]? = nil) throws {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let destination = CGImageDestinationCreateWithURL(url, format.utType.identifier as CFString, 1, nil)
        else { throw SaveError.cannotWrite(format.rawValue) }
        var options: [CFString: Any] = metadata.map { cleaned($0) } ?? [:]
        if format.usesQuality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SaveError.cannotWrite(format.rawValue) }
    }

    /// The source's properties without what no longer describes the picture: the orientation
    /// (baked into the pixels) and the old pixel dimensions.
    static func cleaned(_ properties: [CFString: Any]) -> [CFString: Any] {
        var result = properties
        result.removeValue(forKey: kCGImagePropertyOrientation)
        result.removeValue(forKey: kCGImagePropertyPixelWidth)
        result.removeValue(forKey: kCGImagePropertyPixelHeight)
        if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        return result
    }

    /// Everything the file says about itself — for showing, and for carrying over on save.
    static func metadata(ofFile path: String) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties
    }

    /// One line per thing worth reading: camera, lens, when, how, and where. Values the file
    /// does not carry are simply absent — no empty rows.
    static func readableMetadata(_ properties: [CFString: Any]) -> [(String, String)] {
        var rows: [(String, String)] = []
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        func add(_ key: String, _ value: Any?) {
            guard let value else { return }
            let text = "\(value)".trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            rows.append((L(key), text))
        }
        if let w = properties[kCGImagePropertyPixelWidth], let h = properties[kCGImagePropertyPixelHeight] {
            add("viewer.exif.size", "\(w) × \(h)")
        }
        add("viewer.exif.camera", [tiff[kCGImagePropertyTIFFMake], tiff[kCGImagePropertyTIFFModel]]
            .compactMap { $0 as? String }.joined(separator: " ").nilIfEmpty)
        add("viewer.exif.lens", exif[kCGImagePropertyExifLensModel] as? String)
        add("viewer.exif.date", exif[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? tiff[kCGImagePropertyTIFFDateTime] as? String)
        if let value = exif[kCGImagePropertyExifExposureTime] as? Double, value > 0 {
            add("viewer.exif.exposure", value >= 1 ? String(format: "%.1f с", value)
                                                   : "1/\(Int((1 / value).rounded()))")
        }
        if let value = exif[kCGImagePropertyExifFNumber] as? Double { add("viewer.exif.aperture", "f/\(value)") }
        if let list = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = list.first {
            add("viewer.exif.iso", iso)
        }
        if let value = exif[kCGImagePropertyExifFocalLength] as? Double {
            add("viewer.exif.focal", "\(Int(value.rounded())) мм")
        }
        add("viewer.exif.software", tiff[kCGImagePropertyTIFFSoftware] as? String)
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let ns = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? ""
            let ew = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? ""
            add("viewer.exif.place", String(format: "%.5f%@ %.5f%@", lat, ns, lon, ew))
        }
        return rows
    }

    /// The path "Save as this format" writes to: the same name with the format's extension.
    static func path(_ path: String, forFormat format: ImageSaveFormat) -> String {
        let base = (path as NSString).deletingPathExtension
        return base + "." + format.fileExtension
    }

    /// A free name for a copy beside the original: "снимок копия.jpg", then "…копия 2.jpg".
    /// Never returns a name that is taken, so saving a copy can never eat a neighbour.
    static func copyPath(for path: String, format: ImageSaveFormat, suffix: String,
                         exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let base = (path as NSString).deletingPathExtension
        let ext = "." + format.fileExtension
        let first = "\(base) \(suffix)\(ext)"
        guard exists(first) else { return first }
        for number in 2...9999 {
            let candidate = "\(base) \(suffix) \(number)\(ext)"
            if !exists(candidate) { return candidate }
        }
        return "\(base) \(suffix) \(UUID().uuidString)\(ext)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
