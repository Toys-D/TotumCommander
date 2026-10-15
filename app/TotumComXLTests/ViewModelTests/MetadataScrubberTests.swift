import AVFoundation
import Compression
import ImageIO
import PDFKit
import XCTest
@testable import TotumComXLApp

/// Taking everything a file says about itself out of it — and nothing else.
///
/// Every test plants words ("MARKER…") in the places a kind of file keeps its notes, cleans the
/// file, and looks for the words in its bytes: a note that only LOOKS gone to the reading API is
/// still in the file someone is sent.
final class MetadataScrubberTests: XCTestCase {

    private var folder: String!

    override func setUpWithError() throws {
        folder = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-scrub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func path(_ name: String) -> String {
        (folder as NSString).appendingPathComponent(name)
    }

    private static let markers = [
        "MARKERMAKE", "MARKERMODEL", "MARKERSOFT", "MARKERARTIST", "MARKERCOMMENT", "MARKERLENS",
        "MARKERBYLINE", "MARKERKEY", "MARKERPNG", "MARKERCOM", "MARKERIRB", "MARKERTITLE",
    ]

    private func found(in data: Data) -> [String] {
        Self.markers.filter { data.range(of: Data($0.utf8)) != nil }
    }

    private func found(_ path: String) -> [String] {
        found(in: FileManager.default.contents(atPath: path) ?? Data())
    }

    private func contains(_ path: String, _ text: String) -> Bool {
        (FileManager.default.contents(atPath: path) ?? Data()).range(of: Data(text.utf8)) != nil
    }

    private func bytes(_ path: String) -> [UInt8] {
        [UInt8](FileManager.default.contents(atPath: path) ?? Data())
    }

    // MARK: - Pictures

    /// A picture with something in every place a picture keeps notes: camera, program, author,
    /// comment, lens, IPTC, GPS, PNG text — and turned on its side, like a portrait from a phone.
    private func makePicture(_ name: String, type: String, orientation: Int = 6) throws -> String {
        let target = path(name)
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw XCTSkip("холст не создался") }
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: target) as CFURL, type as CFString, 1, nil)
        else { throw XCTSkip("\(type) не пишется") }
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "MARKERMAKE", kCGImagePropertyTIFFModel: "MARKERMODEL",
                kCGImagePropertyTIFFSoftware: "MARKERSOFT", kCGImagePropertyTIFFArtist: "MARKERARTIST",
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:08:19 14:30:05",
                kCGImagePropertyExifUserComment: "MARKERCOMMENT",
                kCGImagePropertyExifLensModel: "MARKERLENS",
                kCGImagePropertyExifISOSpeedRatings: [400],
            ] as [CFString: Any],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCByline: ["MARKERBYLINE"],
                kCGImagePropertyIPTCKeywords: ["MARKERKEY"],
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 50.4501, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 30.5234, kCGImagePropertyGPSLongitudeRef: "E",
            ] as [CFString: Any],
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGAuthor: "MARKERPNG", kCGImagePropertyPNGComment: "MARKERPNG",
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("\(type) не записался") }
        return target
    }

    private func properties(_ path: String) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
        else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    /// The picture as pixels — to tell "the same picture" from "a picture that looks alike".
    private func pixels(_ path: String) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width,
                                          height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? buffer : nil
    }

    /// The compressed picture of a JPEG — everything from the start of the scan on.
    private func scan(_ path: String) -> [UInt8] {
        let b = bytes(path)
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF, b[i + 1] != 0xDA {
            i += 2 + (Int(b[i + 2]) << 8 | Int(b[i + 3]))
        }
        return Array(b[min(i, b.count)...])
    }

    /// A comment and a second Photoshop block right after the start — the kind ImageIO's own
    /// cleaning lets through.
    private func addLooseSegments(to path: String) throws {
        var b = bytes(path)
        func segment(_ marker: UInt8, _ text: String) -> [UInt8] {
            let payload = Array(text.utf8)
            return [0xFF, marker, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 0xFF)]
                + payload
        }
        b.insert(contentsOf: segment(0xFE, "MARKERCOM") + segment(0xED, "Photoshop 3.0\u{0}MARKERIRB"),
                 at: 2)
        try Data(b).write(to: URL(fileURLWithPath: path))
    }

    func testAJPEGLosesEveryNoteButKeepsWhichWayIsUp() async throws {
        let jpeg = try makePicture("снимок.jpg", type: "public.jpeg")
        try addLooseSegments(to: jpeg)
        XCTAssertFalse(found(jpeg).isEmpty)
        let picture = pixels(jpeg)
        let compressed = scan(jpeg)

        try await MetadataScrubber.clean(path: jpeg)

        XCTAssertEqual(found(jpeg), [], "ни одной записи не осталось")
        let after = properties(jpeg)
        XCTAssertEqual(after[kCGImagePropertyOrientation] as? Int, 6, "портрет не лёг набок")
        XCTAssertNil(after[kCGImagePropertyGPSDictionary])
        XCTAssertNil(after[kCGImagePropertyIPTCDictionary])
        XCTAssertNotNil(after[kCGImagePropertyProfileName], "цветовой профиль — часть картинки")
        XCTAssertEqual(pixels(jpeg), picture, "картинка та же")
        XCTAssertEqual(scan(jpeg), compressed, "сжатые данные не тронуты — без пережатия")
    }

    func testOnlyThePlaceLeavesAJPEGCameraAndDate() async throws {
        let jpeg = try makePicture("место.jpg", type: "public.jpeg")
        try await MetadataScrubber.clean(path: jpeg, scope: .place)

        let after = PhotoMetadataService.read(path: jpeg)
        XCTAssertNil(after.coordinate, "место ушло")
        XCTAssertFalse(after.entries(in: .camera).isEmpty, "камера осталась")
        XCTAssertFalse(after.entries(in: .exposure).isEmpty, "дата съёмки осталась")
    }

    /// iPhone's own format — the one ImageIO's cleaning leaves exactly as it was.
    func testAHEICIsCleanedWhereItLies() async throws {
        let heic = try makePicture("снимок.heic", type: "public.heic")
        XCTAssertFalse(found(heic).isEmpty)
        let size = bytes(heic).count
        let picture = pixels(heic)

        try await MetadataScrubber.clean(path: heic)

        XCTAssertEqual(found(heic), [])
        XCTAssertEqual(bytes(heic).count, size, "та же длина: ни одно смещение не сдвинулось")
        let after = properties(heic)
        XCTAssertEqual(after[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertNil(PhotoMetadataService.read(path: heic).coordinate)
        XCTAssertEqual(pixels(heic), picture, "HEIC не пережат")
    }

    func testOnlyThePlaceLeavesAHEICCameraAlone() async throws {
        let heic = try makePicture("место.heic", type: "public.heic")
        try await MetadataScrubber.clean(path: heic, scope: .place)

        let after = PhotoMetadataService.read(path: heic)
        XCTAssertNil(after.coordinate, "место ушло")
        XCTAssertFalse(after.entries(in: .camera).isEmpty, "камера осталась")
    }

    /// The compressed picture of a PNG: all its IDAT chunks, end to end.
    private func idat(_ path: String) -> [UInt8] {
        let b = bytes(path)
        var out: [UInt8] = []
        var i = 8
        while i + 12 <= b.count, let length = Binary.u32(b, i) {
            if Binary.matches(b, i + 4, "IDAT") { out += b[(i + 8)..<(i + 8 + length)] }
            i += 12 + length
        }
        return out
    }

    func testAPNGLosesItsTextButNotOneByteOfPicture() async throws {
        let png = try makePicture("экран.png", type: "public.png")
        XCTAssertFalse(found(png).isEmpty)
        let compressed = idat(png)

        try await MetadataScrubber.clean(path: png)

        XCTAssertEqual(found(png), [])
        XCTAssertEqual(idat(png), compressed)
        XCTAssertEqual(properties(png)[kCGImagePropertyOrientation] as? Int, 6)
    }

    func testAGIFLosesCommentsAndXMP() async throws {
        let gif = try makePicture("анимация.gif", type: "com.compuserve.gif")
        var b = bytes(gif)
        XCTAssertEqual(b.last, 0x3B)
        b.insert(contentsOf: [0x21, 0xFE, 9] + Array("MARKERCOM".utf8) + [0], at: b.count - 1)
        try Data(b).write(to: URL(fileURLWithPath: gif))
        let picture = pixels(gif)

        try await MetadataScrubber.clean(path: gif)

        XCTAssertEqual(found(gif), [])
        XCTAssertEqual(pixels(gif), picture)
    }

    /// ImageIO cannot write WebP, so the file is put together by hand: the chunks are what
    /// matters here, and the flags that announce them.
    func testAWebPLosesItsExifAndXMPChunks() throws {
        func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
            Array(type.utf8) + Binary.le32(data.count) + data + (data.count % 2 == 1 ? [0] : [])
        }
        let header: [UInt8] = [0x08 | 0x04 | 0x10] + [UInt8](repeating: 0, count: 9)   // EXIF, XMP, alpha
        let picture = [UInt8](repeating: 0x2F, count: 11)
        let exif = Array("Exif\u{0}\u{0}".utf8) + ExifBlob.orientationOnly(1) + Array("MARKERMAKE".utf8)
        let body = Array("WEBP".utf8) + chunk("VP8X", header) + chunk("VP8L", picture)
            + chunk("EXIF", exif) + chunk("XMP ", Array("<x>MARKERKEY</x>".utf8))
        let file = Array("RIFF".utf8) + Binary.le32(body.count) + body

        let clean = try XCTUnwrap(WebPChunks.clean(file, scope: .everything))

        let expected = Array("WEBP".utf8) + chunk("VP8X", [0x10] + header.dropFirst())
            + chunk("VP8L", picture)
        XCTAssertEqual(clean, Array("RIFF".utf8) + Binary.le32(expected.count) + expected,
                       "остались только картинка и её заголовок, и флаги говорят правду")
    }

    func testATIFFIsWrittenAnewFromItsPixels() async throws {
        let tiff = try makePicture("скан.tiff", type: "public.tiff")
        XCTAssertFalse(found(tiff).isEmpty)
        let picture = pixels(tiff)

        try await MetadataScrubber.clean(path: tiff)

        XCTAssertEqual(found(tiff), [])
        XCTAssertEqual(properties(tiff)[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertEqual(pixels(tiff), picture)
    }

    func testAPictureIsTakenForWhatItIsNotForWhatItIsCalled() async throws {
        let png = try makePicture("на-самом-деле.png", type: "public.png")
        let disguised = path("на-самом-деле.jpg")
        try FileManager.default.moveItem(atPath: png, toPath: disguised)
        XCTAssertEqual(MetadataScrubber.kind(of: disguised), .png)

        try await MetadataScrubber.clean(path: disguised)

        XCTAssertEqual(found(disguised), [])
    }

    func testWhatIsNotWhatItsNameSaysComplainsInsteadOfBreaking() async throws {
        let fake = path("не-картинка.jpg")
        try Data("никакая это не картинка".utf8).write(to: URL(fileURLWithPath: fake))
        do {
            try await MetadataScrubber.clean(path: fake)
            XCTFail("должна быть жалоба")
        } catch let failure as MetadataScrubber.Failure {
            XCTAssertEqual(failure, .unreadable("не-картинка.jpg"))
        }
        XCTAssertEqual(try String(contentsOfFile: fake, encoding: .utf8), "никакая это не картинка")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder), ["не-картинка.jpg"],
                       "ни копий, ни временных файлов")
    }

    func testACleanedCopyLeavesTheOriginalAlone() async throws {
        let jpeg = try makePicture("оригинал.jpg", type: "public.jpeg")
        let copy = try await MetadataScrubber.clean(path: jpeg, keepingOriginal: true)

        XCTAssertNotEqual(copy, jpeg)
        XCTAssertTrue(copy.contains(L("metadata.clean.copySuffix")))
        XCTAssertNotNil(PhotoMetadataService.read(path: jpeg).coordinate, "оригинал не тронут")
        XCTAssertEqual(found(copy), [], "копия чистая")

        let again = try await MetadataScrubber.clean(path: jpeg, keepingOriginal: true)
        XCTAssertNotEqual(again, copy, "вторая копия не ложится поверх первой")
    }

    // MARK: - Film and sound

    private func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = id
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    /// A second of film shot on its side, saying where, on what and with what program.
    private func makeMovie(_ name: String) async throws -> String {
        let target = path(name)
        let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: target), fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
        ])
        writer.add(input)
        writer.metadata = [
            item(.quickTimeMetadataLocationISO6709, "+50.4501+030.5234/"),
            item(.quickTimeMetadataMake, "MARKERMAKE"),
            item(.quickTimeMetadataModel, "MARKERMODEL"),
            item(.quickTimeMetadataSoftware, "MARKERSOFT"),
            item(.quickTimeUserDataAuthor, "MARKERARTIST"),
        ]
        guard writer.startWriting(), let pool = adaptor.pixelBufferPool else {
            throw XCTSkip("видео не пишется")
        }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw XCTSkip("кадр не создался") }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 20), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw XCTSkip("видео не записалось") }
        return target
    }

    func testAFilmLosesPlaceAndCameraButKeepsWhichWayIsUp() async throws {
        let movie = try await makeMovie("видео.mov")
        XCTAssertTrue(contains(movie, "+50.4501"))
        XCTAssertFalse(found(movie).isEmpty)

        try await MetadataScrubber.clean(path: movie)

        XCTAssertFalse(contains(movie, "+50.4501"), "место ушло")
        XCTAssertEqual(found(movie), [])
        let asset = AVURLAsset(url: URL(fileURLWithPath: movie))
        let notes = try await asset.load(.metadata)
        XCTAssertTrue(notes.isEmpty)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let turn = try await XCTUnwrap(track).load(.preferredTransform)
        XCTAssertEqual(atan2(turn.b, turn.a) * 180 / .pi, 90, accuracy: 0.01, "снято боком — боком и осталось")
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1.0, accuracy: 0.11)
    }

    func testOnlyThePlaceLeavesAFilmCameraAlone() async throws {
        let movie = try await makeMovie("место.mov")
        try await MetadataScrubber.clean(path: movie, scope: .place)

        XCTAssertFalse(contains(movie, "+50.4501"), "место ушло")
        XCTAssertTrue(contains(movie, "MARKERMODEL"), "камера осталась")
    }

    /// A WAV put together by hand, with the INFO list and the broadcast block programs add.
    func testAWAVLosesItsInfoList() async throws {
        func sub(_ id: String, _ text: String) -> [UInt8] {
            var value = Array(text.utf8) + [0]
            if value.count % 2 == 1 { value.append(0) }
            return Array(id.utf8) + Binary.le32(value.count) + value
        }
        let samples = (0..<16_000).map { UInt8(truncatingIfNeeded: $0 * 7) }
        let format = Array("fmt ".utf8) + Binary.le32(16) + Binary.le16(1) + Binary.le16(1)
            + Binary.le32(8000) + Binary.le32(16_000) + Binary.le16(2) + Binary.le16(16)
        let info = Array("INFO".utf8) + sub("INAM", "MARKERTITLE") + sub("IART", "MARKERARTIST")
        let list = Array("LIST".utf8) + Binary.le32(info.count) + info
        let broadcast = Array(("MARKERSOFT" + String(repeating: " ", count: 246)).utf8)
        let body = Array("WAVE".utf8) + format + list + Array("bext".utf8) + Binary.le32(broadcast.count)
            + broadcast + Array("data".utf8) + Binary.le32(samples.count) + samples
        let wav = path("запись.wav")
        try Data(Array("RIFF".utf8) + Binary.le32(body.count) + body).write(to: URL(fileURLWithPath: wav))

        try await MetadataScrubber.clean(path: wav)

        XCTAssertEqual(found(wav), [])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wav))
        XCTAssertEqual(file.length, 8000, "звук весь на месте")
    }

    private func syncsafe(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F),
         UInt8(value & 0x7F)]
    }

    func testAnMP3LosesTheTagsAtBothEnds() async throws {
        let frames: [UInt8] = [0xFF, 0xFB, 0x90, 0x64] + (0..<600).map { UInt8(truncatingIfNeeded: $0 * 31 + 5) }
        let title: [UInt8] = Array("TIT2".utf8) + [0, 0, 0, 11, 0, 0, 3] + Array("MARKERKEY!".utf8)
        let id3v2 = Array("ID3".utf8) + [4, 0, 0] + syncsafe(title.count) + title
        let apeItem = Binary.le32(12) + Binary.le32(0) + Array("Artist\u{0}".utf8) + Array("MARKERARTIST".utf8)
        let apeFooter = Array("APETAGEX".utf8) + Binary.le32(2000) + Binary.le32(apeItem.count + 32)
            + Binary.le32(1) + Binary.le32(0) + [UInt8](repeating: 0, count: 8)
        let comment = Array("MARKERCOMMENT".utf8)
        let id3v1 = Array("TAG".utf8) + comment + [UInt8](repeating: 0, count: 125 - comment.count)
        let mp3 = path("песня.mp3")
        try Data(id3v2 + frames + apeItem + apeFooter + id3v1).write(to: URL(fileURLWithPath: mp3))

        try await MetadataScrubber.clean(path: mp3)

        XCTAssertEqual(bytes(mp3), frames, "остался только звук, байт в байт")
    }

    func testAFLACKeepsItsStreamAndLosesItsTags() async throws {
        let streamInfo: [UInt8] = [0x00, 0, 0, 34] + [UInt8](repeating: 7, count: 34)
        let comments: [UInt8] = [0x04, 0, 0, 13] + Array("MARKERARTIST!".utf8)
        let cover: [UInt8] = [0x86, 0, 0, 10] + Array("MARKERKEY!".utf8)
        let frames: [UInt8] = [0xFF, 0xF8] + [UInt8](repeating: 0x42, count: 300)
        let flac = path("альбом.flac")
        try Data(Array("fLaC".utf8) + streamInfo + comments + cover + frames)
            .write(to: URL(fileURLWithPath: flac))

        try await MetadataScrubber.clean(path: flac)

        XCTAssertEqual(bytes(flac), Array("fLaC".utf8) + [0x80, 0, 0, 34]
                       + [UInt8](repeating: 7, count: 34) + frames,
                       "STREAMINFO стал последним блоком, звук тот же")
    }

    // MARK: - Documents

    /// A PDF the way people have them: properties, XMP, a photograph on the page, a note by
    /// somebody and a link.
    private func makePDF(_ name: String) throws -> String {
        let target = path(name)
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: "MARKERTITLE", kCGPDFContextAuthor: "MARKERARTIST",
            kCGPDFContextSubject: "MARKERCOMMENT", kCGPDFContextKeywords: "MARKERKEY",
            kCGPDFContextCreator: "MARKERSOFT",
        ]
        guard let context = CGContext(URL(fileURLWithPath: target) as CFURL, mediaBox: &box,
                                      info as CFDictionary) else { throw XCTSkip("PDF не пишется") }
        let xmp = #"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator><rdf:Seq><rdf:li>MARKERBYLINE</rdf:li></rdf:Seq></dc:creator></rdf:Description></rdf:RDF></x:xmpmeta>"#
        context.addDocumentMetadata(Data(xmp.utf8) as CFData)
        context.beginPDFPage(nil)
        let photo = try makePicture("вклейка.jpg", type: "public.jpeg", orientation: 1)
        if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: photo) as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            context.draw(image, in: CGRect(x: 20, y: 20, width: 96, height: 64))
        }
        context.endPDFPage()
        context.closePDF()
        try FileManager.default.removeItem(atPath: photo)

        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: target)))
        let note = PDFAnnotation(bounds: CGRect(x: 120, y: 120, width: 20, height: 20),
                                 forType: .text, withProperties: nil)
        note.userName = "MARKERMODEL"
        note.contents = "заметка"
        document.page(at: 0)?.addAnnotation(note)
        let link = PDFAnnotation(bounds: CGRect(x: 10, y: 150, width: 50, height: 20),
                                 forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")
        document.page(at: 0)?.addAnnotation(link)
        guard document.write(to: URL(fileURLWithPath: target)) else { throw XCTSkip("PDF не записался") }
        return target
    }

    /// The words in a PDF: in its bytes and in every packed stream, unpacked.
    private func found(inPDF path: String) -> [String] {
        let data = FileManager.default.contents(atPath: path) ?? Data()
        var all = data
        var from = data.startIndex
        while let start = data.range(of: Data("stream".utf8), in: from..<data.endIndex) {
            var body = start.upperBound
            if body < data.endIndex, data[body] == 0x0D { body += 1 }
            if body < data.endIndex, data[body] == 0x0A { body += 1 }
            guard let end = data.range(of: Data("endstream".utf8), in: body..<data.endIndex) else { break }
            let packed = [UInt8](data[body..<end.lowerBound])
            if packed.count > 2 {
                var out = [UInt8](repeating: 0, count: 1 << 20)
                let count = packed.withUnsafeBufferPointer { source in
                    compression_decode_buffer(&out, out.count, source.baseAddress! + 2, source.count - 2,
                                              nil, COMPRESSION_ZLIB)
                }
                all.append(contentsOf: out.prefix(count))
            }
            from = end.upperBound
        }
        return found(in: all)
    }

    func testAPDFLosesItsPropertiesItsXMPAndTheNotesOfItsPictures() async throws {
        let pdf = try makePDF("договор.pdf")
        XCTAssertTrue(found(inPDF: pdf).contains("MARKERBYLINE"), "XMP на месте до очистки")
        XCTAssertTrue(found(inPDF: pdf).contains("MARKERMODEL"), "автор заметки на месте")

        try await MetadataScrubber.clean(path: pdf)

        XCTAssertEqual(found(inPDF: pdf), [], "ни в свойствах, ни в XMP, ни в снимке, ни в остатках")
        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: pdf)), "PDF открывается")
        XCTAssertEqual(document.pageCount, 1)
        let annotations = document.page(at: 0)?.annotations ?? []
        XCTAssertEqual(annotations.first { $0.type == "Link" }?.url?.absoluteString, "https://example.com",
                       "ссылка работает")
        XCTAssertEqual(annotations.first { $0.type == "Text" }?.contents, "заметка", "заметка на месте")
        XCTAssertNil(document.documentAttributes?[PDFDocumentAttribute.authorAttribute])
        XCTAssertNotNil(document.page(at: 0)?.thumbnail(of: CGSize(width: 50, height: 50), for: .mediaBox))
    }

    func testAProtectedPDFIsRefusedNotUnlocked() async throws {
        let plain = try makePDF("открытый.pdf")
        let locked = path("закрытый.pdf")
        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: plain)))
        // Latin passwords: PDFKit quietly writes a Cyrillic one as no protection at all.
        XCTAssertTrue(document.write(to: URL(fileURLWithPath: locked), withOptions: [
            .ownerPasswordOption: "owner", .userPasswordOption: "reader",
        ]))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: locked))).isEncrypted)
        let before = bytes(locked)

        do {
            try await MetadataScrubber.clean(path: locked)
            XCTFail("защищённый PDF не переписывается без защиты")
        } catch let failure as MetadataScrubber.Failure {
            XCTAssertEqual(failure, .locked("закрытый.pdf"))
        }
        XCTAssertEqual(bytes(locked), before)
    }

    /// A zip the way office programs write one: some parts packed, some stored, one with its
    /// sizes after the data, a timestamp field and a date on every part.
    private func makeZip(_ name: String, _ parts: [(String, String, Bool)]) throws -> String {
        var out: [UInt8] = [], central: [UInt8] = []
        for (index, (entry, text, pack)) in parts.enumerated() {
            let raw = Array(text.utf8)
            var body = raw
            if pack {
                var packed = [UInt8](repeating: 0, count: raw.count + 512)
                let count = compression_encode_buffer(&packed, packed.count, raw, raw.count, nil,
                                                      COMPRESSION_ZLIB)
                body = Array(packed.prefix(count))
            }
            let crc = Int(Binary.crc32(raw))
            let trailing = index == 1
            let name = Array(entry.utf8)
            let extra: [UInt8] = [0x55, 0x54, 5, 0, 1, 1, 2, 3, 4]
            let offset = out.count
            out += Binary.le32(0x0403_4B50) + Binary.le16(20) + Binary.le16(trailing ? 8 : 0)
            out += Binary.le16(pack ? 8 : 0) + Binary.le16(0x6000) + Binary.le16(0x5A6D)
            out += trailing ? [UInt8](repeating: 0, count: 12)
                            : Binary.le32(crc) + Binary.le32(body.count) + Binary.le32(raw.count)
            out += Binary.le16(name.count) + Binary.le16(extra.count) + name + extra + body
            if trailing {
                out += Binary.le32(0x0807_4B50) + Binary.le32(crc) + Binary.le32(body.count)
                    + Binary.le32(raw.count)
            }
            central += Binary.le32(0x0201_4B50) + Binary.le16(0x031E) + Binary.le16(20)
            central += Binary.le16(trailing ? 8 : 0) + Binary.le16(pack ? 8 : 0)
            central += Binary.le16(0x6000) + Binary.le16(0x5A6D)
            central += Binary.le32(crc) + Binary.le32(body.count) + Binary.le32(raw.count)
            central += Binary.le16(name.count) + Binary.le16(extra.count) + Binary.le16(0)
            central += Binary.le16(0) + Binary.le16(0) + Binary.le32(0) + Binary.le32(offset) + name + extra
        }
        let end = Binary.le32(0x0605_4B50) + Binary.le16(0) + Binary.le16(0) + Binary.le16(parts.count)
            + Binary.le16(parts.count) + Binary.le32(central.count) + Binary.le32(out.count) + Binary.le16(0)
        let target = path(name)
        try Data(out + central + end).write(to: URL(fileURLWithPath: target))
        return target
    }

    /// The system's own unzip, as a second opinion: every checksum and size must add up.
    private func unzipAgrees(_ path: String) throws -> Bool {
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-tqq", path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        return unzip.terminationStatus == 0
    }

    func testAWordDocumentLosesItsPropertiesAndNothingElse() async throws {
        let relations = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties" Target="/docProps/custom.xml"/></Relationships>"#
        let core = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:creator>MARKERARTIST</dc:creator><cp:lastModifiedBy>MARKERMODEL</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">2026-01-01T10:00:00Z</dcterms:created></cp:coreProperties>"#
        let app = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Template>MARKERSOFT.dotm</Template><Company>MARKERMAKE</Company></Properties>"#
        let custom = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="2" name="Client"><vt:lpwstr>MARKERKEY</vt:lpwstr></property></Properties>"#
        let text = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Текст договора</w:t></w:r></w:p></w:body></w:document>"#
        // What macOS's own writer adds, mentioned by no relationship.
        let cocoa = #"<meta xmlns="http://schemas.apple.com/cocoa/2006/metadata"><generator>MARKERLENS</generator></meta>"#
        let names = ["[Content_Types].xml", "_rels/.rels", "docProps/core.xml", "docProps/app.xml",
                     "docProps/custom.xml", "word/document.xml", "docProps/meta.xml"]
        let docx = try makeZip("договор.docx", Array(zip(names, ["<Types/>", relations, core, app, custom, text, cocoa]))
            .enumerated().map { ($0.element.0, $0.element.1, $0.offset % 2 == 1) })
        let textBefore = ZipPackage(path: docx)?.contents(of: "word/document.xml")

        try await MetadataScrubber.clean(path: docx)

        let package = try XCTUnwrap(ZipPackage(path: docx))
        XCTAssertEqual(package.names, names, "части в том же порядке")
        for part in ["docProps/core.xml", "docProps/app.xml", "docProps/custom.xml", "docProps/meta.xml"] {
            let root = try XCTUnwrap(XMLDocument(data: XCTUnwrap(package.contents(of: part))).rootElement())
            XCTAssertEqual(root.childCount, 0, part)
        }
        let coreRoot = try XCTUnwrap(XMLDocument(data: XCTUnwrap(package.contents(of: "docProps/core.xml"))).rootElement())
        XCTAssertEqual(coreRoot.name, "cp:coreProperties", "корень и его пространства имён на месте")
        XCTAssertEqual(package.contents(of: "word/document.xml"), textBefore, "текст документа не тронут")
        let everything = names.compactMap { package.contents(of: $0) }.reduce(Data(), +)
        XCTAssertEqual(found(in: everything), [])
        XCTAssertTrue(try unzipAgrees(docx), "zip цел")
        let b = bytes(docx)
        XCTAssertEqual(Binary.u16(b, 12, bigEndian: false), 0x21, "даты частей — 1980-01-01, как пишет Word")
    }

    func testAnOpenDocumentLosesItsMetaAndKeepsItsMimetypeFirst() async throws {
        let meta = #"<?xml version="1.0" encoding="UTF-8"?><office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" xmlns:dc="http://purl.org/dc/elements/1.1/" office:version="1.3"><office:meta><meta:initial-creator>MARKERARTIST</meta:initial-creator><dc:creator>MARKERMODEL</dc:creator><meta:generator>MARKERSOFT</meta:generator></office:meta></office:document-meta>"#
        let odt = try makeZip("письмо.odt", [
            ("mimetype", "application/vnd.oasis.opendocument.text", false),
            ("meta.xml", meta, true),
            ("content.xml", "<office:document-content/>", true),
        ])

        try await MetadataScrubber.clean(path: odt)

        let package = try XCTUnwrap(ZipPackage(path: odt))
        let b = bytes(odt)
        XCTAssertEqual(package.names.first, "mimetype")
        XCTAssertEqual(Binary.u16(b, 8, bigEndian: false), 0, "mimetype не сжат")
        XCTAssertTrue(Binary.matches(b, 38, "application/vnd.oasis.opendocument.text"),
                      "и лежит первым, сразу за заголовком без лишних полей")
        let root = try XCTUnwrap(XMLDocument(data: XCTUnwrap(package.contents(of: "meta.xml"))).rootElement())
        XCTAssertEqual(root.attribute(forName: "office:version")?.stringValue, "1.3")
        XCTAssertEqual(root.childCount, 1)
        XCTAssertEqual((root.child(at: 0) as? XMLElement)?.childCount, 0)
        XCTAssertTrue(try unzipAgrees(odt))
    }

    func testOnlyThePlaceLeavesADocumentAlone() async throws {
        let pdf = try makePDF("без-места.pdf")
        let before = bytes(pdf)
        let result = try await MetadataScrubber.clean(path: pdf, scope: .place)
        XCTAssertEqual(result, pdf)
        XCTAssertEqual(bytes(pdf), before)
    }

    // MARK: - The notes beside a file

    private func pin(_ name: String, _ value: Data, on path: String) {
        _ = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, 0) }
    }

    private func plist(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    func testTheNotesBesideAFileGoButTheQuarantineStays() async throws {
        let text = path("заметки.txt")
        try Data("просто текст".utf8).write(to: URL(fileURLWithPath: text))
        XCTAssertFalse(MetadataScrubber.canClean(path: text), "сказать нечего — и предлагать нечего")
        pin("com.apple.metadata:kMDItemWhereFroms", try plist(["https://example.com/secret"]), on: text)
        pin("com.apple.metadata:_kMDItemUserTags", try plist(["Работа\n4"]), on: text)
        pin("com.apple.metadata:kMDItemFinderComment", try plist("MARKERCOMMENT"), on: text)
        pin("com.apple.quarantine", Data("0083;66f1a2b3;Safari;".utf8), on: text)
        pin("com.example.private", Data("MARKERKEY".utf8), on: text)
        XCTAssertTrue(MetadataScrubber.canClean(path: text))
        let modified = try FileManager.default.attributesOfItem(atPath: text)[.modificationDate] as? Date

        try await MetadataScrubber.clean(path: text)

        XCTAssertEqual(MetadataScrubber.removableAttributes(of: text), [])
        XCTAssertTrue(XattrInspector.names(path: text).contains("com.apple.quarantine"),
                      "по отметке о загрузке macOS проверяет файл — она остаётся")
        XCTAssertEqual(try String(contentsOfFile: text, encoding: .utf8), "просто текст")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: text)[.modificationDate] as? Date,
                       modified, "сам файл не переписывался")
        XCTAssertFalse(MetadataScrubber.canClean(path: text))
    }

    func testCleaningInPlaceKeepsWhatBelongsToTheFile() async throws {
        let jpeg = try makePicture("права.jpg", type: "public.jpeg")
        pin("com.apple.metadata:kMDItemWhereFroms", try plist(["https://example.com"]), on: jpeg)
        pin("com.apple.metadata:kMDItemFinderComment", try plist("MARKERCOMMENT"), on: jpeg)
        pin("com.apple.quarantine", Data("0083;66f1a2b3;Safari;".utf8), on: jpeg)
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o640, .creationDate: created],
                                              ofItemAtPath: jpeg)

        try await MetadataScrubber.clean(path: jpeg)

        let attributes = try FileManager.default.attributesOfItem(atPath: jpeg)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual((attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                       created.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(MetadataScrubber.removableAttributes(of: jpeg), [],
                       "ни откуда скачан, ни комментария Finder")
        XCTAssertTrue(XattrInspector.names(path: jpeg).contains("com.apple.quarantine"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder)
            .contains { $0.hasPrefix(".fcxl-clean-") }, "временных файлов не осталось")
    }

    func testAPictureThatSaysNothingIsNotOffered() throws {
        let png = path("пусто.png")
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: png))
        XCTAssertFalse(MetadataScrubber.canClean(path: png))
        XCTAssertTrue(MetadataScrubber.canClean(path: try makePicture("полный.png", type: "public.png")))
    }
}
