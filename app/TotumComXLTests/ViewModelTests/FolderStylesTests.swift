import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TotumComXLApp

/// Свои стили папок: строгие правила для картинок, библиотека, перекраска.
@MainActor
final class FolderStylesTests: XCTestCase {

    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fcxl-styles-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "fcxl.folder.styles.test.\(UUID().uuidString)"
        FolderStyleLibrary.storageOverride = .init(directory: folder.appendingPathComponent("library"),
                                                   defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        FolderStyleLibrary.storageOverride = nil
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: - SVG

    private func svg(_ body: String, viewBox: String = "0 0 512 512") -> Data {
        Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(viewBox)\">\(body)</svg>".utf8)
    }

    private let folderShape = "<rect x=\"40\" y=\"140\" width=\"432\" height=\"300\" fill=\"#FF00FF\"/>"

    func test_образецПроходитПравила() {
        XCTAssertEqual(FolderStyleValidator.problems(svg: Data(FolderStyleLibrary.sampleSVG.utf8)), [])
    }

    func test_svg_каждоеНарушениеНазываетсяСвоимСловом() {
        let cases: [(String, FolderStyleProblem)] = [
            ("<text x=\"10\" y=\"20\" fill=\"#FF00FF\">Папка</text>", .text),
            ("<style>rect { fill: #FF00FF; }</style>", .styleBlock),
            ("<style>@import url(x.css);</style>", .styleBlock),
            ("<style>.a { fill: #3A7BD5; }</style>", .colors(["#3A7BD5"])),
            ("<style>.h { display: none; }</style>", .hiddenLayers),
            ("<g style=\"display:none;\"><rect width=\"9\" height=\"9\" fill=\"#FFFFFF\"/></g>", .hiddenLayers),
            ("<g display=\"none\"><rect width=\"9\" height=\"9\"/></g>", .hiddenLayers),
            ("<rect width=\"9\" height=\"9\" fill=\"url(#grad)\"/>", .references),
            ("<rect width=\"9\" height=\"9\" onclick=\"alert(1)\"/>", .references),
            ("<image href=\"cat.png\" width=\"9\" height=\"9\"/>", .forbidden(["image"])),
            ("<script>alert(1)</script>", .forbidden(["script"])),
            ("<rect width=\"9\" height=\"9\" style=\"fill:#3A7BD5;\"/>", .colors(["#3A7BD5"])),
            ("<rect width=\"9\" height=\"9\" fill=\"red\"/>", .colors(["red"])),
        ]
        for (extra, problem) in cases {
            XCTAssertTrue(FolderStyleValidator.problems(svg: svg(folderShape + extra)).contains(problem),
                          "\(extra) → должно быть \(problem)")
        }
    }

    func test_svg_холстЦветПапкиИСамФайл() {
        XCTAssertEqual(FolderStyleValidator.problems(svg: svg(folderShape, viewBox: "0 0 500 400")), [.notSquare])
        XCTAssertEqual(FolderStyleValidator.problems(svg: Data(
            "<svg xmlns=\"http://www.w3.org/2000/svg\">\(folderShape)</svg>".utf8)), [.noViewBox])
        XCTAssertEqual(FolderStyleValidator.problems(svg: svg("<rect width=\"9\" height=\"9\" fill=\"#B000B0\"/>")),
                       [.noFolderColor], "без цвета папки перекрашивать нечего")
        XCTAssertEqual(FolderStyleValidator.problems(svg: Data("<svg>не закрыт".utf8)), [.notSVG])
        XCTAssertEqual(FolderStyleValidator.problems(svg: Data("<html><body/></html>".utf8)), [.notSVG])
        let entity = "<?xml version=\"1.0\"?><!DOCTYPE svg [<!ENTITY a \"aaaa\">]>"
        XCTAssertEqual(FolderStyleValidator.problems(svg: Data((entity + String(decoding: svg(folderShape), as: UTF8.self)).utf8)),
                       [.references])
        XCTAssertEqual(FolderStyleValidator.problems(svg: Data(repeating: 32, count: FolderStyleValidator.svgLimit + 1)),
                       [.fileTooBig(limitKB: 200)])
    }

    /// Что Illustrator пишет всегда и что не рисуется — не повод для отказа.
    func test_svg_служебноеИКороткиеЦветаНеМешают() {
        let body = "<metadata><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><foo/></rdf:RDF></metadata>"
            + "<title>Папка</title><g id=\"_Слой_1\"><rect width=\"90\" height=\"90\" style=\"fill:#f0f;stroke:none\"/>"
            + "<path d=\"M0 0h9v9z\" fill=\"#000000\" fill-opacity=\"0.2\"/></g>"
        XCTAssertEqual(FolderStyleValidator.problems(svg: svg(body)), [])
    }

    /// Так Illustrator пишет SVG по умолчанию: цвета — классами в блоке стилей, короткой записью.
    private let illustratorSVG = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg id="_Слой_1" data-name="Слой_1" xmlns="http://www.w3.org/2000/svg" version="1.1" viewBox="0 0 500 500">
      <!-- Generator: Adobe Illustrator 29.4.0, SVG Export Plug-In . SVG Version: 2.1.0 Build 152)  -->
      <defs>
        <style>
          .st0 {
            fill: #f0f;
          }

          .st1 {
            fill: #b000b0;
          }

          .st2 {
            fill: #fff;
            fill-opacity: .92;
          }
        </style>
      </defs>
      <rect class="st1" x="0" y="60" width="300" height="80"/>
      <rect class="st2" x="40" y="120" width="420" height="200"/>
      <rect class="st0" x="0" y="160" width="500" height="280"/>
    </svg>
    """

    func test_svgИзIllustrator_цветаКлассамиПринимаются() throws {
        XCTAssertEqual(FolderStyleValidator.problems(svg: Data(illustratorSVG.utf8)), [])
        let entry = try FolderStyleLibrary.add(contentsOf: file("ai.svg", Data(illustratorSVG.utf8)))
        let image = try XCTUnwrap(FolderStyleArt.image(for: entry, size: 64, tint: NSColor(srgbRed: 0, green: 0.6, blue: 0, alpha: 1), scale: 1))
        let front = try XCTUnwrap(color(image, x: 0.5, y: 0.8), "передняя стенка — класс .st0")
        XCTAssertEqual(front.greenComponent, 0.6, accuracy: 0.05)
        XCTAssertEqual(front.redComponent, 0, accuracy: 0.05)
    }

    // MARK: - PNG

    /// PNG: в середине — папка цвета `color` со светлой полосой-листом; фон прозрачный, если
    /// не сказано иначе. Рисуется прямо в CGContext: растр без прозрачности NSGraphicsContext не берёт.
    private func png(width: Int, height: Int, color: NSColor = .systemYellow, opaqueBackground: Bool = false,
                     alpha: Bool = true, empty: Bool = false) -> Data {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
        if opaqueBackground || !alpha {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        if !empty {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: width / 8, y: height / 4, width: width * 3 / 4, height: height / 2))
            context.setFillColor(NSColor.white.cgColor)   // лист — светлее тела
            context.fill(CGRect(x: width / 4, y: height * 5 / 8, width: width / 2, height: height / 16))
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    func test_png_правила() {
        XCTAssertEqual(FolderStyleValidator.problems(png: png(width: 512, height: 512)), [])
        XCTAssertEqual(FolderStyleValidator.problems(png: png(width: 600, height: 500)),
                       [.pngNotSquare(width: 600, height: 500)])
        XCTAssertEqual(FolderStyleValidator.problems(png: png(width: 256, height: 256)), [.pngTooSmall(side: 256)])
        XCTAssertEqual(FolderStyleValidator.problems(png: png(width: 512, height: 512, opaqueBackground: true)),
                       [.pngOpaqueBackground])
        XCTAssertEqual(FolderStyleValidator.problems(png: png(width: 512, height: 512, alpha: false)), [.pngNoAlpha])
        XCTAssertEqual(FolderStyleValidator.problems(png: png(width: 512, height: 512, empty: true)), [.empty])
        XCTAssertEqual(FolderStyleValidator.problems(png: Data("не картинка".utf8)), [.pngUnreadable])
    }

    // MARK: - Библиотека

    private func file(_ name: String, _ data: Data) -> URL {
        let url = folder.appendingPathComponent(name)
        try? data.write(to: url)
        return url
    }

    func test_добавлениеКопияИмяИПоколение() throws {
        let before = FolderStyleLibrary.generation
        let entry = try FolderStyleLibrary.add(contentsOf: file("Моя папка.svg", Data(FolderStyleLibrary.sampleSVG.utf8)))
        XCTAssertEqual(entry.name, "Моя папка")
        XCTAssertEqual(entry.format, .svg)
        XCTAssertEqual(FolderStyleLibrary.entries, [entry])
        XCTAssertTrue(FileManager.default.fileExists(atPath: FolderStyleLibrary.fileURL(of: entry).path),
                      "копия в папке программы — исходник можно стереть")
        XCTAssertGreaterThan(FolderStyleLibrary.generation, before, "панели узнают и перерисуют")
        XCTAssertEqual(FolderIconStyle.custom(entry.id).title, "Моя папка")
    }

    func test_неПоПравиламНеПопадает() {
        XCTAssertThrowsError(try FolderStyleLibrary.add(contentsOf: file("синяя.svg", svg(
            folderShape + "<rect width=\"9\" height=\"9\" fill=\"#3A7BD5\"/>")))) { error in
            XCTAssertEqual((error as? FolderStyleRejection)?.problems, [.colors(["#3A7BD5"])])
        }
        XCTAssertThrowsError(try FolderStyleLibrary.add(contentsOf: file("папка.jpg", Data([0xFF, 0xD8])))) { error in
            XCTAssertEqual((error as? FolderStyleRejection)?.problems, [.format])
        }
        XCTAssertEqual(FolderStyleLibrary.entries, [])
    }

    func test_удалениеВыбранногоВозвращаетMacOS() throws {
        let entry = try FolderStyleLibrary.add(contentsOf: file("p.png", png(width: 512, height: 512)))
        FolderStyleLibrary.defaults.set(FolderIconStyle.custom(entry.id).rawValue, forKey: FolderIconStyle.storageKey)
        FolderStyleLibrary.remove(entry.id)
        XCTAssertEqual(FolderStyleLibrary.entries, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: FolderStyleLibrary.fileURL(of: entry).path))
        XCTAssertEqual(FolderStyleLibrary.defaults.string(forKey: FolderIconStyle.storageKey), "macos")
    }

    /// Убранный стиль забывается и в той теме, что его помнила; другая тема остаётся со своим.
    func test_удалениеСтиляЗабываетсяИВТеме() throws {
        let entry = try FolderStyleLibrary.add(contentsOf: file("p.png", png(width: 512, height: 512)))
        let d = FolderStyleLibrary.defaults
        d.set(FolderIconStyle.custom(entry.id).rawValue, forKey: FolderIconStyle.lightKey)
        d.set("totum", forKey: FolderIconStyle.darkKey)
        d.set("totum", forKey: FolderIconStyle.storageKey)
        FolderStyleLibrary.remove(entry.id)
        XCTAssertEqual(d.string(forKey: FolderIconStyle.lightKey), "macos")
        XCTAssertEqual(d.string(forKey: FolderIconStyle.darkKey), "totum")
        XCTAssertEqual(d.string(forKey: FolderIconStyle.storageKey), "totum", "на экране был другой — не тронут")
    }

    /// Список не записался (диск полон, папка недоступна) — стиль не добавлен и копии-сироты
    /// не остаётся, а не «добавлен» до первого перезапуска.
    func test_списокНеЗаписался_стильНеДобавленИКопииНет() throws {
        let library = folder.appendingPathComponent("library")
        // На месте списка — папка: записать файл туда нельзя.
        try FileManager.default.createDirectory(at: library.appendingPathComponent("styles.json"),
                                                withIntermediateDirectories: true)
        XCTAssertThrowsError(try FolderStyleLibrary.add(contentsOf: file("p.png", png(width: 512, height: 512))))
        XCTAssertEqual(FolderStyleLibrary.entries, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), ["styles.json"],
                       "копии нет")
    }

    // MARK: - Своя картинка на каждую тему

    private func themeDefaults() -> (UserDefaults, String) {
        let suite = "fcxl.folder.styles.theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (defaults, suite)
    }

    /// Выбор в одной теме другую не трогает: тема, своей ещё не помнившая, остаётся с той
    /// картинкой, что показывала.
    func test_картинкаПапокПомнитсяНаКаждуюТему() {
        let (d, _) = themeDefaults()
        d.set("catalogV4", forKey: FolderIconStyle.storageKey)

        FolderIconStyle.choose(.totum, dark: true, in: d)
        XCTAssertEqual(d.string(forKey: FolderIconStyle.storageKey), "totum", "на экране — выбранная")
        XCTAssertEqual(d.string(forKey: FolderIconStyle.darkKey), "totum")
        XCTAssertEqual(d.string(forKey: FolderIconStyle.lightKey), "catalogV4", "светлая — та, что была")

        FolderIconStyle.mirror(dark: false, in: d)
        XCTAssertEqual(d.string(forKey: FolderIconStyle.storageKey), "catalogV4")
        FolderIconStyle.choose(.catalogV9, dark: false, in: d)
        FolderIconStyle.mirror(dark: true, in: d)
        XCTAssertEqual(d.string(forKey: FolderIconStyle.storageKey), "totum", "тёмная помнит своё")
        FolderIconStyle.mirror(dark: false, in: d)
        XCTAssertEqual(d.string(forKey: FolderIconStyle.storageKey), "catalogV9", "светлая — своё")
    }

    /// Тема, для которой ничего не запомнено, картинку на экране не меняет.
    func test_темаБезСвоейКартинкиПоказываетПрежнюю() {
        let (d, _) = themeDefaults()
        d.set("catalogV6", forKey: FolderIconStyle.storageKey)
        FolderIconStyle.mirror(dark: true, in: d)
        XCTAssertEqual(d.string(forKey: FolderIconStyle.storageKey), "catalogV6")
    }

    /// Выбор, сделанный до того, как картинка стала помниться по темам, остаётся в обеих; уже
    /// помнящие по темам настройки не трогаются.
    func test_прежнийВыборПереходитВОбеТемы() {
        let (d, suite) = themeDefaults()
        d.set("catalogV6", forKey: FolderIconStyle.storageKey)
        FolderIconStyle.migratePerThemeIfNeeded(d, domain: suite)
        XCTAssertEqual(d.string(forKey: FolderIconStyle.lightKey), "catalogV6")
        XCTAssertEqual(d.string(forKey: FolderIconStyle.darkKey), "catalogV6")

        d.set("totum", forKey: FolderIconStyle.darkKey)
        d.set("catalogV3", forKey: FolderIconStyle.storageKey)
        FolderIconStyle.migratePerThemeIfNeeded(d, domain: suite)
        XCTAssertEqual(d.string(forKey: FolderIconStyle.darkKey), "totum")
        XCTAssertEqual(d.string(forKey: FolderIconStyle.lightKey), "catalogV6")
    }

    /// Набор по умолчанию только зарегистрирован — это не выбор человека, и в его файл
    /// настроек переносить нечего.
    func test_наборПоУмолчаниюНеСчитаетсяВыбором() {
        // Домен регистрации у процесса один на все UserDefaults — вернуть после себя.
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.registrationDomain) }
        let (d, suite) = themeDefaults()
        d.register(defaults: [FolderIconStyle.storageKey: "catalogV4"])
        FolderIconStyle.migratePerThemeIfNeeded(d, domain: suite)
        XCTAssertNil(d.persistentDomain(forName: suite)?[FolderIconStyle.lightKey])
        XCTAssertNil(d.persistentDomain(forName: suite)?[FolderIconStyle.darkKey])
    }

    func test_стильВСтрокуИОбратно() {
        XCTAssertEqual(FolderIconStyle.custom("A1").rawValue, "custom:A1")
        XCTAssertEqual(FolderIconStyle(rawValue: "custom:A1"), .custom("A1"))
        XCTAssertNil(FolderIconStyle(rawValue: "custom:"))
        XCTAssertEqual(FolderIconStyle(rawValue: "catalogV6"), .catalogV6)
        XCTAssertNil(FolderIconStyle(rawValue: "нет такого"))
        XCTAssertEqual(FolderIconStyle(rawValue: "totum"), .totum)
        XCTAssertEqual(FolderIconStyle.allCases.count, 9, "в списке встроенных своих нет")
    }

    // MARK: - Перекраска

    func test_svg_ролиЗаменяютсяЦветомПапок() {
        let text = "<rect fill=\"#ff00ff\"/><rect style=\"fill:#F0F\"/><rect fill=\"#B000B0\"/><rect fill=\"#F0F0F0\"/>"
        let painted = FolderStyleArt.recolored(svg: text, tint: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(painted, "<rect fill=\"#FF0000\"/><rect style=\"fill:#FF0000\"/><rect fill=\"#BF0000\"/><rect fill=\"#F0F0F0\"/>")
    }

    /// Пиксель картинки (x, y от левого верхнего угла, доли стороны).
    private func color(_ image: NSImage, x: CGFloat, y: CGFloat) -> NSColor? {
        guard let rep = image.representations.first as? NSBitmapImageRep else { return nil }
        return rep.colorAt(x: Int(x * CGFloat(rep.pixelsWide)), y: Int(y * CGFloat(rep.pixelsHigh)))?
            .usingColorSpace(.sRGB)
    }

    func test_своиКартинкиКрасятсяВЦветПапок() throws {
        let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let svgEntry = try FolderStyleLibrary.add(contentsOf: file("s.svg", Data(FolderStyleLibrary.sampleSVG.utf8)))
        let svgImage = try XCTUnwrap(FolderStyleArt.image(for: svgEntry, size: 64, tint: blue, scale: 1))
        let front = try XCTUnwrap(color(svgImage, x: 0.5, y: 0.8), "передняя стенка")
        XCTAssertEqual(front.blueComponent, 1, accuracy: 0.05)
        XCTAssertEqual(front.redComponent, 0, accuracy: 0.05)

        // PNG: тело папки (основной тон) становится ровно цветом папок, лист остаётся светлее.
        let pngEntry = try FolderStyleLibrary.add(contentsOf: file("p.png", png(width: 512, height: 512)))
        let painted = try XCTUnwrap(FolderStyleArt.image(for: pngEntry, size: 64, tint: blue, scale: 1))
        let body = try XCTUnwrap(color(painted, x: 0.5, y: 0.55))
        XCTAssertEqual(body.blueComponent, 1, accuracy: 0.08)
        XCTAssertEqual(body.redComponent, 0, accuracy: 0.08)
        let paper = try XCTUnwrap(color(painted, x: 0.5, y: 0.34))
        XCTAssertGreaterThan(paper.redComponent, 0.8, "лист светлее тела — почти белый")

        FolderStyleLibrary.setRecolor(false, for: pngEntry.id)
        let asIs = try XCTUnwrap(FolderStyleArt.image(for: try XCTUnwrap(FolderStyleLibrary.entry(pngEntry.id)),
                                                      size: 64, tint: blue, scale: 1))
        let yellow = try XCTUnwrap(color(asIs, x: 0.5, y: 0.55))
        XCTAssertGreaterThan(yellow.redComponent, 0.8, "как есть — своя жёлтая")
    }

    /// «Totum»: тело — в цвет папок, обводка и «TC» — свои при любом цвете.
    func test_totum_телоВЦветПапок_обводкаИБуквыСвои() throws {
        for tint in [NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)] {
            let image = try XCTUnwrap(FolderStyleArt.image(svg: TotumFolderArt.svg, size: 491, tint: tint, scale: 1))
            // Координаты — доли холста 491 со сдвигом холста (4.5, -7.5) от рисунка 500×500.
            func at(_ x: CGFloat, _ y: CGFloat) -> NSColor? { color(image, x: (x - 4.5) / 491, y: (y + 7.5) / 491) }
            let body = try XCTUnwrap(at(60, 200))
            XCTAssertEqual(body.redComponent, tint.redComponent, accuracy: 0.03)
            XCTAssertEqual(body.blueComponent, tint.blueComponent, accuracy: 0.03)
            let letter = try XCTUnwrap(at(133, 260), "ножка «T»")
            XCTAssertEqual(letter.redComponent, 1, accuracy: 0.03)
            XCTAssertEqual(letter.blueComponent, 1, accuracy: 0.03)
            let outline = try XCTUnwrap(at(10, 250), "левая обводка")
            XCTAssertEqual(outline.redComponent, 0x56 / 255.0, accuracy: 0.03)
            XCTAssertEqual(outline.blueComponent, 0x70 / 255.0, accuracy: 0.03)
        }
    }

    func test_стёртыйЗаСпинойСтиль_папкаMacOS() {
        let image = FolderIconRenderer.image(style: .custom("нет-такого"), size: 32, tintColor: nil)
        XCTAssertEqual(image.size, NSSize(width: 32, height: 32))
    }
}
