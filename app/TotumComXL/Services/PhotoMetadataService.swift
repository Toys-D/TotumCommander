import AppKit
import CoreLocation
import ImageIO

/// What a photograph carries besides the picture: the camera, the settings, the words a picture
/// desk put in it, and the place it was taken.
///
/// Read through ImageIO, which reads the file's header and not the picture — a 60-megapixel RAW
/// answers as fast as a thumbnail, because none of it is decoded.
enum PhotoMetadataService {

    /// One line of the panel.
    struct Entry: Identifiable, Equatable {
        var id: String { "\(section)|\(label)" }
        let section: Section
        let label: String
        let value: String
    }

    /// The groups the lines fall into, in the order a person reads them.
    enum Section: String, CaseIterable, Equatable {
        /// `origin`: made by a neural network, and how — right after the picture itself, where
        /// a person checking a picture looks first.
        case picture, origin, camera, exposure, description, place

        var localizedName: String { L("exif.section.\(rawValue)") }
    }

    /// Everything found, grouped and ready to show.
    struct Info: Equatable {
        var entries: [Entry] = []
        /// Where the picture was taken, when it says so.
        var coordinate: CLLocationCoordinate2D?
        /// Metres above sea level, when it says so.
        var altitude: Double?

        var isEmpty: Bool { entries.isEmpty && coordinate == nil }

        func entries(in section: Section) -> [Entry] {
            entries.filter { $0.section == section }
        }

        static func == (lhs: Info, rhs: Info) -> Bool {
            lhs.entries == rhs.entries
                && lhs.altitude == rhs.altitude
                && lhs.coordinate?.latitude == rhs.coordinate?.latitude
                && lhs.coordinate?.longitude == rhs.coordinate?.longitude
        }
    }

    // MARK: - Reading

    static func read(path: String) -> Info {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return Info() }
        var info = info(from: raw)
        info.entries += AIOrigin.read(path: path).entries
        return info
    }

    /// The whole reading, from the dictionary ImageIO hands back — pure, so every rule below is
    /// testable without a camera.
    static func info(from raw: [CFString: Any]) -> Info {
        var info = Info()
        let exif = raw[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = raw[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let iptc = raw[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let gps = raw[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        func add(_ section: Section, _ key: String, _ value: String?) {
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            info.entries.append(Entry(section: section, label: L(key), value: value))
        }

        // The picture itself
        if let width = raw[kCGImagePropertyPixelWidth] as? Int,
           let height = raw[kCGImagePropertyPixelHeight] as? Int {
            add(.picture, "exif.size", "\(width) × \(height)")
            let megapixels = Double(width * height) / 1_000_000
            if megapixels >= 0.1 {
                add(.picture, "exif.megapixels", String(format: "%.1f", megapixels))
            }
        }
        add(.picture, "exif.colorModel", raw[kCGImagePropertyColorModel] as? String)
        add(.picture, "exif.profile", raw[kCGImagePropertyProfileName] as? String)
        if let depth = raw[kCGImagePropertyDepth] as? Int {
            add(.picture, "exif.depth", String(format: L("exif.depth.value"), depth))
        }
        if let dpi = raw[kCGImagePropertyDPIWidth] as? Double, dpi > 0 {
            add(.picture, "exif.dpi", String(format: "%.0f", dpi))
        }
        if let orientation = raw[kCGImagePropertyOrientation] as? Int, orientation != 1 {
            add(.picture, "exif.orientation", orientationName(orientation))
        }

        // The camera
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?
            .trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?
            .trimmingCharacters(in: .whitespaces)
        add(.camera, "exif.camera", cameraName(make: make, model: model))
        add(.camera, "exif.lens", exif[kCGImagePropertyExifLensModel] as? String)
        add(.camera, "exif.software", tiff[kCGImagePropertyTIFFSoftware] as? String)

        // How it was taken
        if let seconds = exif[kCGImagePropertyExifExposureTime] as? Double {
            add(.exposure, "exif.shutter", shutter(seconds))
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? Double, aperture > 0 {
            add(.exposure, "exif.aperture", "f/" + trimmed(aperture))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
            add(.exposure, "exif.iso", String(iso))
        }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double, focal > 0 {
            var text = trimmed(focal) + " " + L("exif.mm")
            if let equivalent = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int,
               equivalent > 0, abs(Double(equivalent) - focal) > 1 {
                text += String(format: L("exif.equivalent"), equivalent)
            }
            add(.exposure, "exif.focal", text)
        }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double, bias != 0 {
            add(.exposure, "exif.bias", (bias > 0 ? "+" : "") + trimmed(bias) + " EV")
        }
        if let flash = exif[kCGImagePropertyExifFlash] as? Int {
            // Bit 0 says whether the flash actually fired; the rest is the mode it was in.
            add(.exposure, "exif.flash",
                L(flash & 1 == 1 ? "exif.flash.fired" : "exif.flash.off"))
        }
        add(.exposure, "exif.taken",
            humanDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String))

        // The words in it
        add(.description, "exif.title", iptc[kCGImagePropertyIPTCObjectName] as? String)
        add(.description, "exif.caption", iptc[kCGImagePropertyIPTCCaptionAbstract] as? String)
        if let keywords = iptc[kCGImagePropertyIPTCKeywords] as? [String], !keywords.isEmpty {
            add(.description, "exif.keywords", keywords.joined(separator: ", "))
        }
        add(.description, "exif.author",
            (iptc[kCGImagePropertyIPTCByline] as? [String])?.joined(separator: ", ")
                ?? iptc[kCGImagePropertyIPTCByline] as? String
                ?? tiff[kCGImagePropertyTIFFArtist] as? String)
        add(.description, "exif.copyright",
            iptc[kCGImagePropertyIPTCCopyrightNotice] as? String
                ?? tiff[kCGImagePropertyTIFFCopyright] as? String)
        let where_ = [iptc[kCGImagePropertyIPTCCity] as? String,
                      iptc[kCGImagePropertyIPTCProvinceState] as? String,
                      iptc[kCGImagePropertyIPTCCountryPrimaryLocationName] as? String]
            .compactMap { $0 }.filter { !$0.isEmpty }
        if !where_.isEmpty { add(.description, "exif.location", where_.joined(separator: ", ")) }

        // Where it was taken
        if let coordinate = coordinate(from: gps) {
            info.coordinate = coordinate
            add(.place, "exif.coordinates", format(coordinate))
        }
        if let altitude = gps[kCGImagePropertyGPSAltitude] as? Double {
            // Reference 1 means below sea level — a valley, or a dive.
            let below = (gps[kCGImagePropertyGPSAltitudeRef] as? Int) == 1
            info.altitude = below ? -altitude : altitude
            add(.place, "exif.altitude",
                String(format: L("exif.altitude.value"), (below ? -altitude : altitude)))
        }
        return info
    }

    // MARK: - Pieces

    /// "Canon" + "Canon EOS R5" → "Canon EOS R5": the maker's name is usually already in the
    /// model, and printing it twice is how a photo panel starts looking careless.
    static func cameraName(make: String?, model: String?) -> String? {
        let make = make?.isEmpty == false ? make : nil
        let model = model?.isEmpty == false ? model : nil
        guard let model else { return make }
        guard let make else { return model }
        if model.range(of: make, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return model
        }
        return "\(make) \(model)"
    }

    /// 0.004 s → "1/250"; 2 s → "2 с". A shutter is written as a fraction because that is how
    /// it is read off a camera.
    static func shutter(_ seconds: Double) -> String? {
        guard seconds > 0 else { return nil }
        if seconds >= 1 { return trimmed(seconds) + " " + L("exif.seconds") }
        return "1/" + String(Int((1 / seconds).rounded()))
    }

    /// Latitude and longitude, already signed by their hemisphere. South and West are NEGATIVE —
    /// the file stores them as positive numbers with a letter beside them, and a reader that
    /// forgets the letter puts Rio de Janeiro in the Atlantic north of the equator.
    static func coordinate(from gps: [CFString: Any]) -> CLLocationCoordinate2D? {
        guard let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
        let point = CLLocationCoordinate2D(latitude: south ? -latitude : latitude,
                                           longitude: west ? -longitude : longitude)
        // 0,0 is in the Atlantic off Africa and is what a camera writes when it has no fix.
        guard CLLocationCoordinate2DIsValid(point),
              abs(point.latitude) > 0.0001 || abs(point.longitude) > 0.0001 else { return nil }
        return point
    }

    static func format(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }

    /// EXIF writes its dates as "2026:08:19 14:30:05" — not a format anyone else reads.
    static func humanDate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = reader.date(from: raw) else { return raw }
        let writer = DateFormatter()
        writer.dateStyle = .medium
        writer.timeStyle = .medium
        return writer.string(from: date)
    }

    static func orientationName(_ value: Int) -> String {
        switch value {
        case 3: return L("exif.orientation.180")
        case 6: return L("exif.orientation.right")
        case 8: return L("exif.orientation.left")
        default: return L("exif.orientation.mirrored")
        }
    }

    /// 2.0 → "2", 2.8 → "2.8": trailing zeroes make a lens sound like a measurement.
    static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
