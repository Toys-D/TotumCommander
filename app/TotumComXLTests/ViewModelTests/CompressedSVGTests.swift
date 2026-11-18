import XCTest
@testable import TotumComXLApp

/// Сжатый SVG (.svgz) — тот же рисунок SVG, упакованный gzip. Так сохраняют Inkscape и
/// Illustrator. Система его не распаковывает: вместо рисунка в просмотре стояла страница
/// «Encoding error». Программа распаковывает файл сама и показывает как обычный SVG.
final class CompressedSVGTests: XCTestCase {

    private let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200" viewBox="0 0 200 200"><rect width="200" height="200" fill="#1e90ff"/><circle cx="100" cy="100" r="60" fill="#ffd700"/></svg>"##
    /// Тот же рисунок после `gzip -n -9`.
    private let packed = Data(base64Encoded: "H4sIAAAAAAACA3WO3QrCMAxGXyXE+zVTUJS2F3uVrn9QnXRlmW9vCgOvvAgkh++ET69bhP1ZXqvB1Nr7oRQzD3wZlhrVmYiUJBA4zy0ZFICQfI6pHceWPU/LbpCAQEgftLp61/5LIZdi8DT6O4WAymqXqysenPwZe8B9jqUavP6EEOabUBF6K/sFcDvEFb0AAAA=")!

    private var folder = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("svgz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Распаковка

    func test_распаковка_возвращаетРисунок() throws {
        XCTAssertEqual(CompressedSVG.unpack(packed).map { String(decoding: $0, as: UTF8.self) }, svg)
    }

    func test_неСжатое_неРаспаковывается() {
        XCTAssertNil(CompressedSVG.unpack(Data(svg.utf8)))
        XCTAssertNil(CompressedSVG.unpack(Data()))
    }

    func test_обрезанныйФайл_неРаспаковывается() {
        XCTAssertNil(CompressedSVG.unpack(packed.prefix(packed.count / 2)))
    }

    /// Маленький файл может разворачиваться в гигабайты — больше предела не распаковываем.
    func test_распакованноеБольшеПредела_отказ() {
        XCTAssertNil(CompressedSVG.unpack(packed, limit: 50))
        XCTAssertNotNil(CompressedSVG.unpack(packed, limit: svg.utf8.count))
    }

    func test_сжатыйПоРасширению_безУчётаРегистра() {
        XCTAssertTrue(CompressedSVG.isCompressed("/a/рисунок.svgz"))
        XCTAssertTrue(CompressedSVG.isCompressed("/a/РИСУНОК.SVGZ"))
        XCTAssertFalse(CompressedSVG.isCompressed("/a/рисунок.svg"))
        XCTAssertFalse(CompressedSVG.isCompressed("/a/svgz"))
    }

    // MARK: - Что отдаётся на показ

    func test_наПоказ_распакованнаяКопияСТемЖеИменем() throws {
        let source = try file("схема участка.svgz", packed)
        let shown = CompressedSVG.previewURL(for: source)
        XCTAssertNotEqual(shown, source)
        XCTAssertEqual(shown.lastPathComponent, "схема участка.svg", "имя то же, расширение обычного SVG")
        XCTAssertEqual(try String(contentsOf: shown, encoding: .utf8), svg)
        XCTAssertEqual(try Data(contentsOf: source), packed, "сам файл не тронут")
    }

    func test_наПоказ_второйРазТаЖеКопия() throws {
        let source = try file("а.svgz", packed)
        XCTAssertEqual(CompressedSVG.previewURL(for: source), CompressedSVG.previewURL(for: source))
    }

    func test_файлИзменился_копияНовая_прежняяУбрана() throws {
        let source = try file("а.svgz", packed)
        let first = CompressedSVG.previewURL(for: source)
        // Другой рисунок и другая дата: без сжатия на диске лежит обычный текст — он отдаётся сам.
        try Data("<svg/>".utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: source.path)
        XCTAssertEqual(CompressedSVG.previewURL(for: source), source, "несжатый под именем .svgz система читает сама")
        try packed.write(to: source)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                                              ofItemAtPath: source.path)
        let second = CompressedSVG.previewURL(for: source)
        XCTAssertNotEqual(second, first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "старая копия не копится")
    }

    func test_обычныеФайлы_отдаютсяСами() throws {
        let plain = try file("а.svg", Data(svg.utf8))
        XCTAssertEqual(CompressedSVG.previewURL(for: plain), plain)
        let photo = folder.appendingPathComponent("снимок.png")
        XCTAssertEqual(CompressedSVG.previewURL(for: photo), photo)
        XCTAssertEqual(CompressedSVG.previewPath(for: photo.path), photo.path)
    }

    func test_битыйИПропавший_отдаютсяСами() throws {
        let broken = try file("битый.svgz", Data([0x1f, 0x8b, 0x08, 0x00, 0x01, 0x02, 0x03]))
        XCTAssertEqual(CompressedSVG.previewURL(for: broken), broken)
        let missing = folder.appendingPathComponent("нет.svgz")
        XCTAssertEqual(CompressedSVG.previewURL(for: missing), missing)
    }

    // MARK: - В просмотрщике

    func test_сжатыйSVG_векторнаяКартинка() {
        XCTAssertEqual(fileCategory(forFileName: "схема.svgz"), .vectorImage)
    }

    /// Насквозь: система рисует .svgz тем же рисунком, что и .svg, а не страницей с ошибкой.
    func test_картинкаИзСжатогоSVG_рисуется() async throws {
        let source = try file("круг.svgz", packed)
        guard let image = await loadPreviewImageAsync(path: source.path, targetSize: CGSize(width: 200, height: 200)),
              let bitmap = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else {
            throw XCTSkip("система не отдала картинку (нет службы эскизов)")
        }
        let centre = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
            .usingColorSpace(.sRGB))
        XCTAssertGreaterThan(centre.redComponent, 0.8, "в середине жёлтый круг")
        XCTAssertGreaterThan(centre.greenComponent, 0.6)
        XCTAssertLessThan(centre.blueComponent, 0.4, "а не белая страница с ошибкой")
    }
}
