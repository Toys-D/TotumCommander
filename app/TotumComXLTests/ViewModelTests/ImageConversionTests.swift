import AppKit
import ImageIO
import XCTest

@testable import TotumComXLApp

/// Converting a pile of pictures. The two things that go wrong quietly — what size a picture
/// becomes and what it is called — are decided by pure functions, so they are checked here in
/// full; the writing itself is checked once, end to end, on real files.
final class ImageConversionTests: XCTestCase {

    private typealias Service = ImageConversionService

    // MARK: - The arithmetic

    func testFittingWithinASideKeepsTheProportions() {
        var options = Service.Options()
        options.resize = .fit
        options.side = 1000
        let landscape = Service.newSize(for: CGSize(width: 4000, height: 3000), options: options)
        XCTAssertEqual(landscape, CGSize(width: 1000, height: 750))
        let portrait = Service.newSize(for: CGSize(width: 3000, height: 4000), options: options)
        XCTAssertEqual(portrait, CGSize(width: 750, height: 1000), "длинная сторона — та, что длиннее")
    }

    /// Blowing a photograph up adds nothing that was not there and costs a great deal of disk.
    func testAPictureIsNeverMadeBiggerUnlessAsked() {
        var options = Service.Options()
        options.resize = .fit
        options.side = 4000
        XCTAssertNil(Service.newSize(for: CGSize(width: 800, height: 600), options: options),
                     "меньше требуемого — оставляем как есть")
        options.allowsUpscale = true
        XCTAssertEqual(Service.newSize(for: CGSize(width: 800, height: 600), options: options),
                       CGSize(width: 4000, height: 3000), "но если попросили — растянем")
    }

    func testAShareOfTheOriginal() {
        var options = Service.Options()
        options.resize = .percent
        options.percent = 25
        XCTAssertEqual(Service.newSize(for: CGSize(width: 4000, height: 3000), options: options),
                       CGSize(width: 1000, height: 750))
        options.percent = 100
        XCTAssertNil(Service.newSize(for: CGSize(width: 4000, height: 3000), options: options),
                     "сто процентов — это ничего не менять")
    }

    /// A picture that rounds to nothing is not a picture.
    func testATinyShareStillLeavesAPicture() {
        var options = Service.Options()
        options.resize = .percent
        options.percent = 1
        let size = Service.newSize(for: CGSize(width: 20, height: 8), options: options)
        XCTAssertEqual(size, CGSize(width: 1, height: 1))
        XCTAssertNil(Service.newSize(for: .zero, options: options), "у пустого размера нет доли")
    }

    // MARK: - The naming

    func testBesideTheOriginalGetsASuffix() {
        var options = Service.Options()
        options.format = .jpeg
        options.destination = .beside
        options.suffix = "-web"
        let target = Service.target(for: "/дом/Снимки/причал.png", options: options,
                                    fileExists: { _ in false })
        XCTAssertEqual(target, "/дом/Снимки/причал-web.jpg")
    }

    func testASubfolderIsUsedWhenAskedFor() {
        var options = Service.Options()
        options.format = .jpeg
        options.destination = .subfolder
        options.subfolderName = "Для сайта"
        XCTAssertEqual(Service.target(for: "/дом/причал.png", options: options,
                                      fileExists: { _ in false }),
                       "/дом/Для сайта/причал.jpg")
    }

    /// Replacing keeps the very same path when the format does not change, and only then.
    func testReplacingTheOriginal() {
        var options = Service.Options()
        options.destination = .replace
        options.format = .same
        XCTAssertEqual(Service.target(for: "/дом/причал.jpg", options: options,
                                      fileExists: { _ in true }),
                       "/дом/причал.jpg")
        options.format = .jpeg
        XCTAssertEqual(Service.target(for: "/дом/причал.png", options: options,
                                      fileExists: { _ in false }),
                       "/дом/причал.jpg", "другой формат — другое имя, рядом")
    }

    /// Two sources easily want one name — photo.png and photo.jpg both becoming photo.jpg — and
    /// the second must not silently eat the first.
    func testTwoSourcesNeverGetTheSameName() {
        var options = Service.Options()
        options.format = .jpeg
        options.destination = .subfolder
        options.subfolderName = "Готовые"
        let steps = Service.plan(paths: ["/дом/причал.png", "/дом/причал.tiff"],
                                 options: options,
                                 sizeOf: { _ in CGSize(width: 100, height: 100) },
                                 fileExists: { _ in false })
        XCTAssertEqual(steps.map(\.target),
                       ["/дом/Готовые/причал.jpg", "/дом/Готовые/причал 2.jpg"])
    }

    func testAnExistingFileIsNotOverwritten() {
        var options = Service.Options()
        options.format = .png
        options.destination = .beside
        options.suffix = "-копия"
        let taken = "/дом/причал-копия.png"
        let target = Service.target(for: "/дом/причал.jpg", options: options,
                                    fileExists: { $0 == taken })
        XCTAssertEqual(target, "/дом/причал-копия 2.png")
    }

    /// A batch that rewrites JPEGs as the same JPEGs is work for nothing, and the dialog must
    /// be able to say so.
    func testAPlanThatChangesNothingIsRecognised() {
        var options = Service.Options()
        options.format = .same
        options.resize = .none
        options.keepsMetadata = true
        let steps = [Service.Step(source: "/a.jpg", target: "/a.jpg", newSize: nil,
                                  originalSize: CGSize(width: 10, height: 10))]
        XCTAssertFalse(Service.changesAnything(options, steps: steps))
        options.keepsMetadata = false
        XCTAssertTrue(Service.changesAnything(options, steps: steps), "вычистка сведений — тоже дело")
    }

    func testQualityOnlyMeansSomethingForTheLossyFormats() {
        XCTAssertTrue(Service.Format.jpeg.usesQuality)
        XCTAssertTrue(Service.Format.heic.usesQuality)
        XCTAssertFalse(Service.Format.png.usesQuality, "PNG без потерь — ползунок там лжёт")
        XCTAssertFalse(Service.Format.tiff.usesQuality)
    }

    // MARK: - Real files

    /// A PNG of EXACTLY the given pixels.
    ///
    /// Built from a bitmap rather than by drawing into an NSImage: on a Retina machine an
    /// NSImage hands back twice the pixels it was asked for, and a test whose fixture is not
    /// the size it claims proves nothing about the resizing.
    private func makePNG(_ path: String, width: Int, height: Int) throws {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw XCTSkip("не создался растр")
        }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        // Something to see besides one flat colour, so the file has a size worth comparing.
        NSColor.black.setFill()
        for x in stride(from: 0, to: width, by: 7) {
            NSRect(x: CGFloat(x), y: 0, width: 3, height: CGFloat(height)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("не вышел PNG")
        }
        try data.write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(Service.pixelSize(of: path), CGSize(width: width, height: height),
                       "подопытный файл ровно того размера, о котором говорит тест")
    }

    func testAWholeBatchIsConvertedAndResized() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let first = (root as NSString).appendingPathComponent("первый.png")
        let second = (root as NSString).appendingPathComponent("второй.png")
        try makePNG(first, width: 1200, height: 600)
        try makePNG(second, width: 400, height: 400)

        var options = Service.Options()
        options.format = .jpeg
        options.quality = 0.7
        options.resize = .fit
        options.side = 600
        options.destination = .subfolder
        options.subfolderName = "Готовые"

        let steps = Service.plan(paths: [first, second], options: options)
        XCTAssertEqual(steps.first?.newSize, CGSize(width: 600, height: 300))
        XCTAssertNil(steps.last?.newSize, "четыреста меньше шестисот — размер не трогаем")

        for step in steps { _ = try Service.convert(step, options: options) }

        let madeFirst = (root as NSString).appendingPathComponent("Готовые/первый.jpg")
        let madeSecond = (root as NSString).appendingPathComponent("Готовые/второй.jpg")
        XCTAssertEqual(Service.pixelSize(of: madeFirst), CGSize(width: 600, height: 300))
        XCTAssertEqual(Service.pixelSize(of: madeSecond), CGSize(width: 400, height: 400))
        // Smaller in bytes as well as in pixels — compared LIKE FOR LIKE, against the same
        // picture in the same format at full size. Against the source PNG it would prove
        // nothing: a synthetic picture of flat stripes compresses better as PNG than as JPEG,
        // whatever the size.
        var fullSize = options
        fullSize.resize = .none
        fullSize.suffix = "-полный"
        fullSize.destination = .beside
        let untouched = Service.plan(paths: [first], options: fullSize)[0]
        _ = try Service.convert(untouched, options: fullSize)
        let big = try FileManager.default
            .attributesOfItem(atPath: untouched.target)[.size] as? Int ?? 0
        let small = try FileManager.default
            .attributesOfItem(atPath: madeFirst)[.size] as? Int ?? 0
        XCTAssertLessThan(small, big, "уменьшённый снимок весит меньше того же снимка целиком")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first), "оригинал на месте")
    }

    /// Replacing writes over the original — and leaves a whole picture there, not half of one.
    func testReplacingLeavesAWholePicture() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = (root as NSString).appendingPathComponent("снимок.png")
        try makePNG(path, width: 800, height: 400)

        var options = Service.Options()
        options.format = .same
        options.resize = .percent
        options.percent = 50
        options.destination = .replace

        let steps = Service.plan(paths: [path], options: options)
        XCTAssertEqual(steps.first?.target, path)
        _ = try Service.convert(steps[0], options: options)
        XCTAssertEqual(Service.pixelSize(of: path), CGSize(width: 400, height: 200))
        XCTAssertNotNil(NSImage(contentsOfFile: path), "файл читается как картинка")
    }

    func testConvertingSomethingThatIsNotAPictureComplains() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-nope-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("вовсе не картинка".utf8).write(to: URL(fileURLWithPath: path))
        let step = Service.Step(source: path, target: path + ".jpg", newSize: nil,
                                originalSize: nil)
        XCTAssertThrowsError(try Service.convert(step, options: Service.Options()))
    }
}
