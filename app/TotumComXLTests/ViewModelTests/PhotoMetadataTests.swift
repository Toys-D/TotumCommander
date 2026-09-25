import AppKit
import CoreLocation
import ImageIO
import XCTest

@testable import TotumComXLApp

/// Reading what a photograph carries besides the picture. The rules are checked against the
/// dictionaries ImageIO actually hands back — and once end to end, against a real file with the
/// tags written into it.
final class PhotoMetadataTests: XCTestCase {

    // MARK: - The place

    /// South and West are NEGATIVE. The file stores them as positive numbers with a letter
    /// beside them, and a reader that forgets the letter puts Rio de Janeiro in the Atlantic
    /// north of the equator.
    func testTheHemisphereLetterDecidesTheSign() {
        let rio: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 22.9068, kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 43.1729, kCGImagePropertyGPSLongitudeRef: "W",
        ]
        let point = PhotoMetadataService.coordinate(from: rio)
        XCTAssertEqual(point?.latitude ?? 0, -22.9068, accuracy: 0.0001)
        XCTAssertEqual(point?.longitude ?? 0, -43.1729, accuracy: 0.0001)

        let kyiv: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 50.4501, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 30.5234, kCGImagePropertyGPSLongitudeRef: "E",
        ]
        XCTAssertEqual(PhotoMetadataService.coordinate(from: kyiv)?.latitude ?? 0, 50.4501,
                       accuracy: 0.0001)
    }

    /// A camera with no fix writes zeroes, and zero-zero is a spot in the Atlantic — not a place
    /// anyone photographed.
    func testAZeroFixIsNotAPlace() {
        let none: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 0.0, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0.0, kCGImagePropertyGPSLongitudeRef: "E",
        ]
        XCTAssertNil(PhotoMetadataService.coordinate(from: none))
        XCTAssertNil(PhotoMetadataService.coordinate(from: [:]))
    }

    func testAltitudeBelowSeaLevelIsNegative() {
        let raw: [CFString: Any] = [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSAltitude: 12.0, kCGImagePropertyGPSAltitudeRef: 1,
        ] as [CFString: Any]]
        XCTAssertEqual(PhotoMetadataService.info(from: raw).altitude, -12)
    }

    // MARK: - The pieces

    func testTheMakersNameIsNotPrintedTwice() {
        XCTAssertEqual(PhotoMetadataService.cameraName(make: "Canon", model: "Canon EOS R5"),
                       "Canon EOS R5")
        XCTAssertEqual(PhotoMetadataService.cameraName(make: "NIKON CORPORATION",
                                                        model: "NIKON D850"),
                       "NIKON CORPORATION NIKON D850", "разные слова — обе части нужны")
        XCTAssertEqual(PhotoMetadataService.cameraName(make: "Apple", model: "iPhone 15 Pro"),
                       "Apple iPhone 15 Pro")
        XCTAssertEqual(PhotoMetadataService.cameraName(make: nil, model: "X100V"), "X100V")
        XCTAssertNil(PhotoMetadataService.cameraName(make: nil, model: nil))
    }

    /// A shutter is written as a fraction, the way it is read off a camera.
    func testShutterIsAFraction() {
        XCTAssertEqual(PhotoMetadataService.shutter(0.004), "1/250")
        XCTAssertEqual(PhotoMetadataService.shutter(1.0 / 60), "1/60")
        XCTAssertEqual(PhotoMetadataService.shutter(2), "2 \(L("exif.seconds"))")
        XCTAssertNil(PhotoMetadataService.shutter(0))
    }

    func testEXIFDatesAreTurnedIntoHumanOnes() {
        let human = PhotoMetadataService.humanDate("2026:08:19 14:30:05")
        XCTAssertNotNil(human)
        XCTAssertFalse(human?.contains("2026:08") ?? true, "двоеточия в дате остались: \(human ?? "")")
        XCTAssertEqual(PhotoMetadataService.humanDate("совсем не дата"), "совсем не дата",
                       "непонятное показывается как есть, а не пропадает")
        XCTAssertNil(PhotoMetadataService.humanDate(nil))
    }

    // MARK: - A real file

    /// End to end: tags written into a JPEG, then read back out of it.
    func testTagsWrittenIntoAFileAreReadBack() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-exif-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let picture = NSImage(size: NSSize(width: 120, height: 80))
        picture.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 120, height: 80).fill()
        picture.unlockFocus()
        guard let cgImage = picture.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.jpeg" as CFString, 1, nil)
        else { return XCTFail("файл не создался") }

        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFModel: "iPhone 15 Pro",
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [400],
                kCGImagePropertyExifFocalLength: 24.0,
                kCGImagePropertyExifDateTimeOriginal: "2026:08:19 14:30:05",
                kCGImagePropertyExifFlash: 1,
            ] as [CFString: Any],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCObjectName: "Причал",
                kCGImagePropertyIPTCKeywords: ["море", "вечер"],
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 22.9068, kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 43.1729, kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let info = PhotoMetadataService.read(path: path)
        func value(_ label: String) -> String? {
            info.entries.first { $0.label == L(label) }?.value
        }
        XCTAssertEqual(value("exif.camera"), "Apple iPhone 15 Pro")
        XCTAssertEqual(value("exif.shutter"), "1/250")
        XCTAssertEqual(value("exif.aperture"), "f/2.8")
        XCTAssertEqual(value("exif.iso"), "400")
        XCTAssertEqual(value("exif.focal"), "24 \(L("exif.mm"))")
        XCTAssertEqual(value("exif.flash"), L("exif.flash.fired"))
        XCTAssertEqual(value("exif.title"), "Причал")
        XCTAssertEqual(value("exif.keywords"), "море, вечер")
        // Against the PIXELS of the file, not the points it was drawn at: a picture made on a
        // Retina machine is twice the size it was asked for, and the panel must say what is in
        // the file.
        XCTAssertEqual(value("exif.size"), "\(cgImage.width) × \(cgImage.height)")
        XCTAssertEqual(info.coordinate?.latitude ?? 0, -22.9068, accuracy: 0.0001,
                       "южное полушарие осталось южным")
        XCTAssertFalse(info.isEmpty)
        XCTAssertEqual(info.entries(in: .camera).count, 1)
    }

    // MARK: - Taking it out again

    /// A picture with everything in it, for the cleaning tests.
    private func makePhotograph() throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-clean-\(UUID().uuidString).jpg")
        let picture = NSImage(size: NSSize(width: 200, height: 140))
        picture.lockFocus()
        NSColor.systemIndigo.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 140).fill()
        picture.unlockFocus()
        guard let cgImage = picture.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.jpeg" as CFString, 1, nil)
        else { throw XCTSkip("файл не создался") }
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 15 Pro",
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifISOSpeedRatings: [400],
                kCGImagePropertyExifDateTimeOriginal: "2026:08:19 14:30:05",
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 50.4501, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 30.5234, kCGImagePropertyGPSLongitudeRef: "E",
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return path
    }

    /// Everything out: no camera, no dates, no place — and the picture itself untouched.
    func testCleaningEverythingLeavesThePictureAndNothingElse() throws {
        let path = try makePhotograph()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let before = PhotoMetadataService.read(path: path)
        XCTAssertNotNil(before.coordinate)
        XCTAssertFalse(before.entries(in: .camera).isEmpty)
        let pixelsBefore = NSImage(contentsOfFile: path)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)

        try PhotoMetadataService.clean(path: path, what: .everything)

        let after = PhotoMetadataService.read(path: path)
        XCTAssertNil(after.coordinate, "координаты ушли")
        XCTAssertTrue(after.entries(in: .camera).isEmpty, "камера ушла")
        XCTAssertTrue(after.entries(in: .exposure).isEmpty, "настройки съёмки ушли")
        XCTAssertFalse(after.entries(in: .picture).isEmpty, "размер остался — это про сам файл")
        let pixelsAfter = NSImage(contentsOfFile: path)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        XCTAssertEqual(pixelsAfter?.width, pixelsBefore?.width, "картинка та же")
        XCTAssertEqual(pixelsAfter?.height, pixelsBefore?.height)
        XCTAssertFalse(PhotoMetadataService.hasMetadata(path: path))
    }

    /// Only the place: what a person usually wants before sending a photograph on — the camera
    /// and the date are not what gives away where they live.
    func testCleaningOnlyThePlaceKeepsTheRest() throws {
        let path = try makePhotograph()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try PhotoMetadataService.clean(path: path, what: .place)

        let after = PhotoMetadataService.read(path: path)
        XCTAssertNil(after.coordinate, "место ушло")
        XCTAssertFalse(after.entries(in: .camera).isEmpty, "камера осталась")
        XCTAssertFalse(after.entries(in: .exposure).isEmpty, "ISO и дата остались")
    }

    /// Asked for a copy, the original is left exactly as it was — and the copy never lands on
    /// top of a file that is already there.
    func testACleanedCopyLeavesTheOriginalAlone() throws {
        let path = try makePhotograph()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let copy = try PhotoMetadataService.clean(path: path, what: .everything,
                                                   keepingOriginal: true)
        defer { try? FileManager.default.removeItem(atPath: copy) }

        XCTAssertNotEqual(copy, path)
        XCTAssertTrue(copy.contains(L("exif.clean.copySuffix")))
        XCTAssertNotNil(PhotoMetadataService.read(path: path).coordinate, "оригинал не тронут")
        XCTAssertNil(PhotoMetadataService.read(path: copy).coordinate, "копия чистая")

        // A second copy does not overwrite the first.
        let again = try PhotoMetadataService.clean(path: path, what: .everything,
                                                    keepingOriginal: true)
        defer { try? FileManager.default.removeItem(atPath: again) }
        XCTAssertNotEqual(again, copy)
    }

    func testCleaningWhatIsNotAPictureComplainsInsteadOfBreakingIt() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-not-a-picture-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("никакая это не картинка".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try PhotoMetadataService.clean(path: path))
        XCTAssertEqual(try? String(contentsOfFile: path, encoding: .utf8),
                       "никакая это не картинка", "файл остался как был")
    }

    /// A picture with nothing in it says nothing — no empty rows, no zeroes pretending to be data.
    func testAPlainPictureCarriesNothing() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-plain-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let picture = NSImage(size: NSSize(width: 40, height: 40))
        picture.lockFocus(); NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 40).fill(); picture.unlockFocus()
        let rep = NSBitmapImageRep(data: picture.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: path))

        let info = PhotoMetadataService.read(path: path)
        XCTAssertNil(info.coordinate)
        XCTAssertTrue(info.entries(in: .camera).isEmpty)
        XCTAssertTrue(info.entries(in: .exposure).isEmpty)
        XCTAssertFalse(info.entries(in: .picture).isEmpty, "размер известен всегда")
        XCTAssertTrue(PhotoMetadataService.read(path: "/нет/такого.jpg").isEmpty)
    }
}
