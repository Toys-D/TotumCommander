import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Turning a pile of pictures into another pile: another format, another size, or both.
///
/// The arithmetic and the naming are separated from the writing on purpose. What size a picture
/// becomes and what it is called are the two things that go wrong quietly — a batch that
/// overwrites an original or stretches a photograph to twice its size is noticed far too late —
/// so both are decided by the pure functions below and checked without touching a disk.
enum ImageConversionService {

    // MARK: - What to make

    enum Format: String, CaseIterable, Equatable {
        case jpeg, png, heic, tiff
        /// Leave the format alone — only the size changes.
        case same

        var utType: UTType? {
            switch self {
            case .jpeg: return .jpeg
            case .png:  return .png
            case .heic: return UTType("public.heic")
            case .tiff: return .tiff
            case .same: return nil
            }
        }

        var fileExtension: String? {
            switch self {
            case .jpeg: return "jpg"
            case .png:  return "png"
            case .heic: return "heic"
            case .tiff: return "tiff"
            case .same: return nil
            }
        }

        /// Does the quality setting mean anything for this format? PNG and TIFF are lossless —
        /// a quality slider over them promises something it cannot do.
        var usesQuality: Bool { self == .jpeg || self == .heic }

        var localizedName: String { L("convert.format.\(rawValue)") }
    }

    /// How the size is decided.
    enum Resize: String, CaseIterable, Equatable {
        case none
        /// Fit inside a box of the given side, keeping the proportions.
        case fit
        /// A share of the original, in per cent.
        case percent

        var localizedName: String { L("convert.resize.\(rawValue)") }
    }

    /// Where the results go.
    enum Destination: String, CaseIterable, Equatable {
        /// Beside the original, with a suffix in the name.
        case beside
        /// Into a subfolder of the original's folder.
        case subfolder
        /// Over the original. Only offered when something actually changes.
        case replace

        var localizedName: String { L("convert.where.\(rawValue)") }
    }

    struct Options: Equatable {
        var format: Format = .jpeg
        /// 0…1 for the lossy formats.
        var quality: Double = 0.85
        var resize: Resize = .none
        /// The longest side, for `.fit`.
        var side: Int = 2000
        /// The share, for `.percent`.
        var percent: Int = 50
        /// Never make a picture bigger than it was: blowing a photograph up adds nothing that
        /// was not there and costs a great deal of disk.
        var allowsUpscale = false
        var destination: Destination = .beside
        var suffix: String = ""
        var subfolderName: String = ""
        /// Keep the camera, the date and the place. Off means the copy carries nothing —
        /// which is what a picture bound for a website usually wants.
        var keepsMetadata = true
    }

    /// One line of the plan: what will be made out of what.
    struct Step: Equatable, Identifiable {
        var id: String { source }
        let source: String
        let target: String
        /// Nil when the size is left alone.
        let newSize: CGSize?
        let originalSize: CGSize?
    }

    // MARK: - The arithmetic

    /// The size a picture becomes. Nil means "leave it as it is" — including the case where the
    /// rule would only make it bigger and upscaling is not allowed.
    static func newSize(for size: CGSize, options: Options) -> CGSize? {
        guard size.width > 0, size.height > 0 else { return nil }
        switch options.resize {
        case .none:
            return nil
        case .fit:
            let side = CGFloat(max(1, options.side))
            let longest = max(size.width, size.height)
            let scale = side / longest
            if scale >= 1, !options.allowsUpscale { return nil }
            return rounded(size, by: scale)
        case .percent:
            let scale = CGFloat(max(1, options.percent)) / 100
            if scale >= 1, !options.allowsUpscale { return nil }
            return rounded(size, by: scale)
        }
    }

    /// At least one pixel each way: a picture that rounds to zero is not a picture.
    private static func rounded(_ size: CGSize, by scale: CGFloat) -> CGSize {
        CGSize(width: max(1, (size.width * scale).rounded()),
               height: max(1, (size.height * scale).rounded()))
    }

    // MARK: - The naming

    /// Where one picture's result goes.
    ///
    /// `taken` holds the targets already claimed by earlier files of the same batch: two source
    /// files can easily want the same name (photo.png and photo.jpg both becoming photo.jpg),
    /// and the second must not silently eat the first.
    static func target(for path: String, options: Options,
                       taken: Set<String> = [], fileExists: (String) -> Bool = {
                           FileManager.default.fileExists(atPath: $0)
                       }) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = options.format.fileExtension ?? (path as NSString).pathExtension

        var directory = folder
        var name = stem
        switch options.destination {
        case .replace:
            return ext.lowercased() == (path as NSString).pathExtension.lowercased()
                ? path
                : (folder as NSString).appendingPathComponent("\(stem).\(ext)")
        case .subfolder:
            let sub = options.subfolderName.trimmingCharacters(in: .whitespaces)
            directory = (folder as NSString)
                .appendingPathComponent(sub.isEmpty ? L("convert.subfolder.default") : sub)
        case .beside:
            let suffix = options.suffix.trimmingCharacters(in: .whitespaces)
            name = stem + (suffix.isEmpty ? L("convert.suffix.default") : suffix)
        }

        var candidate = (directory as NSString).appendingPathComponent("\(name).\(ext)")
        // Never over something that is already there, and never over another result of the same
        // batch.
        var index = 2
        while candidate != path, taken.contains(candidate) || fileExists(candidate) {
            candidate = (directory as NSString).appendingPathComponent("\(name) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    /// The whole plan, in the order the files were given.
    static func plan(paths: [String], options: Options,
                     sizeOf: (String) -> CGSize? = { pixelSize(of: $0) },
                     fileExists: (String) -> Bool = {
                         FileManager.default.fileExists(atPath: $0)
                     }) -> [Step] {
        var taken: Set<String> = []
        var steps: [Step] = []
        for path in paths {
            let target = target(for: path, options: options, taken: taken, fileExists: fileExists)
            taken.insert(target)
            let original = sizeOf(path)
            steps.append(Step(source: path, target: target,
                              newSize: original.flatMap { newSize(for: $0, options: options) },
                              originalSize: original))
        }
        return steps
    }

    /// The picture's size in pixels, read from the file's header without decoding it.
    static func pixelSize(of path: String) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = raw[kCGImagePropertyPixelWidth] as? Int,
              let height = raw[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }
}

// MARK: - The writing

extension ImageConversionService {

    enum ConversionError: LocalizedError {
        case unreadable(String)
        case unwritable(String)
        case nothingToDo

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return String(format: L("convert.error.unreadable"), name)
            case .unwritable(let name): return String(format: L("convert.error.unwritable"), name)
            case .nothingToDo: return L("convert.error.nothing")
            }
        }
    }

    /// Make one picture. Answers the path actually written.
    @discardableResult
    static func convert(_ step: Step, options: Options) throws -> String {
        let name = (step.source as NSString).lastPathComponent
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: step.source) as CFURL, nil) else {
            throw ConversionError.unreadable(name)
        }
        let type = options.format.utType?.identifier as CFString?
            ?? CGImageSourceGetType(source)
            ?? UTType.jpeg.identifier as CFString

        // The picture itself: either the whole thing, or a smaller one made by ImageIO, which
        // scales while decoding rather than decoding a hundred megapixels first.
        let image: CGImage?
        if let wanted = step.newSize {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                // Upright, so a photograph taken sideways comes out the right way up.
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(max(wanted.width, wanted.height)),
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { throw ConversionError.unreadable(name) }

        let folder = (step.target as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: folder) {
            try FileManager.default.createDirectory(atPath: folder,
                                                    withIntermediateDirectories: true)
        }

        // Written beside the target and moved into place, so a picture is never half-written —
        // which matters most when the target IS the original.
        let temporary = (folder as NSString)
            .appendingPathComponent(".fcxl-convert-\(UUID().uuidString)")
        guard let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: temporary) as CFURL, type, 1, nil) else {
            throw ConversionError.unwritable(name)
        }

        var properties: [CFString: Any] = [:]
        if options.keepsMetadata,
           let existing = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            properties = existing
            // The picture was turned upright when it was scaled, so the old orientation tag
            // would turn it again — sideways, and this time for good.
            if step.newSize != nil { properties.removeValue(forKey: kCGImagePropertyOrientation) }
        }
        if options.format.usesQuality {
            properties[kCGImageDestinationLossyCompressionQuality] =
                max(0.1, min(1, options.quality))
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(atPath: temporary)
            throw ConversionError.unwritable(name)
        }

        if FileManager.default.fileExists(atPath: step.target) {
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: step.target),
                                                      withItemAt: URL(fileURLWithPath: temporary))
        } else {
            try FileManager.default.moveItem(atPath: temporary, toPath: step.target)
        }
        return step.target
    }

    /// Does this plan actually change anything? A batch that converts JPEGs to JPEGs at full
    /// size and the same quality only rewrites them for nothing.
    static func changesAnything(_ options: Options, steps: [Step]) -> Bool {
        if options.format != .same { return true }
        if options.resize != .none, steps.contains(where: { $0.newSize != nil }) { return true }
        if !options.keepsMetadata { return true }
        return false
    }
}
