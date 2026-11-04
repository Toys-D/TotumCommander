import SwiftUI
import AppKit
import XCTest

@testable import TotumComXLApp

/// Правка картинок: повороты и зеркала считаются от того, что человек ВИДИТ, а сохранение
/// пишет настоящий файл в выбранном формате. Проверяется на настоящих пикселях, не на словах.
final class ImageEditingTests: XCTestCase {

    private var root: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("fcxl-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    private func path(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }

    /// Картинка-указатель: красный пиксель в левом верхнем углу, остальное белое. По тому,
    /// куда он уехал, видно, что именно сделали с изображением.
    private func marker(width: Int = 4, height: Int = 2) throws -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        // Верхний левый угол картинки: в CGContext начало внизу, поэтому y = height - 1.
        context.fill(CGRect(x: 0, y: height - 1, width: 1, height: 1))
        return try XCTUnwrap(context.makeImage())
    }

    /// Цвет пикселя (x, y) в координатах КАРТИНКИ: (0,0) — левый верхний угол.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Строка 0 в памяти — верх картинки; в CGContext рисование идёт снизу вверх, но
        // выкладка байтов сверху вниз (замерено пробой, а не выведено из документации).
        let offset = (y * image.width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func isRed(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r > 200 && c.g < 60 && c.b < 60 }

    // MARK: - Правила поворота и зеркал

    func test_поворотыСкладываютсяПоКругу() {
        var e = ImageEdits()
        e.rotateOnScreen(clockwise: true);  XCTAssertEqual(e.quarterTurns, 1)
        e.rotateOnScreen(clockwise: true);  XCTAssertEqual(e.quarterTurns, 2)
        e.rotateOnScreen(clockwise: false); XCTAssertEqual(e.quarterTurns, 1)
        e.rotateOnScreen(clockwise: false); XCTAssertEqual(e.quarterTurns, 0)
        e.rotateOnScreen(clockwise: false); XCTAssertEqual(e.quarterTurns, 3, "влево из нуля — три четверти")
    }

    func test_наЗеркальнойКартинкеПоворотИдётВТуЖеСторонуЧтоИНаЭкране() {
        var e = ImageEdits()
        e.flipOnScreen(horizontal: true)
        e.rotateOnScreen(clockwise: true)
        XCTAssertEqual(e.quarterTurns, 3, "одно зеркало разворачивает направление")
        var both = ImageEdits()
        both.flipOnScreen(horizontal: true)
        both.flipOnScreen(horizontal: false)
        both.rotateOnScreen(clockwise: true)
        XCTAssertEqual(both.quarterTurns, 1, "два зеркала гасят друг друга")
    }

    func test_наПовёрнутойКартинкеОсиЗеркалаМеняютсяМестами() {
        var e = ImageEdits()
        e.quarterTurns = 1
        e.flipOnScreen(horizontal: true)
        XCTAssertTrue(e.flipVertical, "на боку горизонталь экрана — вертикаль файла")
        XCTAssertFalse(e.flipHorizontal)
    }

    func test_размерРезультатаИПропорции() {
        var e = ImageEdits()
        let source = CGSize(width: 400, height: 100)
        XCTAssertEqual(e.resultSize(source: source), source)
        e.quarterTurns = 1
        XCTAssertEqual(e.resultSize(source: source), CGSize(width: 100, height: 400), "на боку стороны меняются")
        e.resize = CGSize(width: 200, height: 50)
        XCTAssertEqual(e.resultSize(source: source), CGSize(width: 50, height: 200))
        XCTAssertEqual(ImageEdits.proportional(source: source, width: 200, height: nil),
                       CGSize(width: 200, height: 50))
        XCTAssertEqual(ImageEdits.proportional(source: source, width: nil, height: 25),
                       CGSize(width: 100, height: 25))
        XCTAssertNil(ImageEdits.proportional(source: .zero, width: 200, height: nil))
        XCTAssertTrue(ImageEdits().isIdentity)
        XCTAssertFalse(e.isIdentity)
    }

    // MARK: - Настоящие пиксели

    func test_поворотПереноситУголКудаНадо() throws {
        let source = try marker()          // 4×2, красный в левом верхнем
        var e = ImageEdits(); e.quarterTurns = 1
        let turned = try XCTUnwrap(ImageEditor.apply(e, to: source))
        XCTAssertEqual(turned.width, 2); XCTAssertEqual(turned.height, 4)
        XCTAssertTrue(isRed(try pixel(turned, turned.width - 1, 0)), "по часовой левый верхний уходит вправо вверх")
    }

    func test_зеркалоИИнверсияМеняютПиксели() throws {
        let source = try marker()
        var flipped = ImageEdits(); flipped.flipHorizontal = true
        let mirror = try XCTUnwrap(ImageEditor.apply(flipped, to: source))
        XCTAssertTrue(isRed(try pixel(mirror, mirror.width - 1, 0)), "угол переехал направо")
        XCTAssertFalse(isRed(try pixel(mirror, 0, 0)))

        var inverted = ImageEdits(); inverted.invert = true
        let negative = try XCTUnwrap(ImageEditor.apply(inverted, to: source))
        let corner = try pixel(negative, 0, 0)
        XCTAssertTrue(corner.r < 60 && corner.g > 200 && corner.b > 200, "красный стал голубым: \(corner)")
    }

    func test_изменениеРазмера() throws {
        let source = try marker(width: 40, height: 20)
        var e = ImageEdits(); e.resize = CGSize(width: 20, height: 10)
        let smaller = try XCTUnwrap(ImageEditor.apply(e, to: source))
        XCTAssertEqual(smaller.width, 20); XCTAssertEqual(smaller.height, 10)
    }

    func test_безПравокКартинкаТаЖе() throws {
        let source = try marker()
        XCTAssertTrue(ImageEditor.apply(ImageEdits(), to: source) === source, "нечего делать — ничего и не делаем")
    }

    // MARK: - Запись файла

    func test_записьВоВсеПредлагаемыеФорматы() throws {
        let source = try marker(width: 8, height: 8)
        for format in ImageSaveFormat.allCases {
            let out = path("проба." + format.fileExtension)
            try ImageEditor.write(source, to: out, format: format, quality: 0.8)
            XCTAssertTrue(FileManager.default.fileExists(atPath: out), "\(format) не записан")
            let back = try XCTUnwrap(ImageEditor.loadOriginal(path: out), "\(format) не читается обратно")
            XCTAssertEqual(back.width, 8); XCTAssertEqual(back.height, 8)
            XCTAssertNotEqual(L(format.titleKey), format.titleKey, "нет перевода \(format.titleKey)")
        }
        XCTAssertEqual(ImageSaveFormat.matching(extension: "JPG"), .jpeg)
        // FileItem несёт расширение С точкой — сравнение с «jpg» молча не совпадало,
        // и полоса правки не появлялась ни на одной картинке.
        XCTAssertEqual(ImageSaveFormat.matching(extension: ".jpg"), .jpeg)
        XCTAssertEqual(ImageSaveFormat.matching(extension: ".PNG"), .png)
        XCTAssertEqual(ImageSaveFormat.matching(extension: " .tiff "), .tiff)
        XCTAssertEqual(ImageSaveFormat.matching(extension: "heif"), .heic)
        XCTAssertNil(ImageSaveFormat.matching(extension: "psd"))
        XCTAssertTrue(ImageSaveFormat.jpeg.usesQuality)
        XCTAssertFalse(ImageSaveFormat.png.usesQuality)
        XCTAssertEqual(ImageEditor.path("/папка/снимок.png", forFormat: .jpeg), "/папка/снимок.jpg")
    }

    /// Сохранение идёт от ОРИГИНАЛА, а не от превью на экране: правки, применённые к файлу,
    /// дают файл прежнего размера, а не размера картинки в окне.
    func test_сохранениеИдётОтОригинальногоРазмера() throws {
        let big = try marker(width: 120, height: 60)
        let original = path("оригинал.png")
        try ImageEditor.write(big, to: original, format: .png)

        let loaded = try XCTUnwrap(ImageEditor.loadOriginal(path: original))
        XCTAssertEqual(loaded.width, 120, "читается полный размер, не превью")
        var e = ImageEdits(); e.rotateOnScreen(clockwise: true)
        let turned = try XCTUnwrap(ImageEditor.apply(e, to: loaded))
        let out = path("повёрнутый.png")
        try ImageEditor.write(turned, to: out, format: .png)
        let saved = try XCTUnwrap(ImageEditor.loadOriginal(path: out))
        XCTAssertEqual(saved.width, 60); XCTAssertEqual(saved.height, 120)
    }

    // MARK: - Цвет

    /// Серая картинка, чтобы яркость и контраст были видны без примеси цвета.
    private func grey(_ level: CGFloat, side: Int = 4) throws -> CGImage {
        let c = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try XCTUnwrap(c.makeImage())
    }

    func test_нейтральныеПоложенияПолзунковНичегоНеМеняют() {
        var e = ImageEdits()
        XCTAssertFalse(e.hasColourChanges)
        XCTAssertTrue(e.isIdentity)
        e.brightness = 0.2
        XCTAssertTrue(e.hasColourChanges); XCTAssertFalse(e.isIdentity)
        e.resetColours()
        XCTAssertTrue(e.isIdentity, "сброс цвета возвращает картинку в исходное")
    }

    func test_яркостьИКонтрастМеняютПиксели() throws {
        let source = try grey(0.5)
        let before = try pixel(source, 1, 1).r

        var brighter = ImageEdits(); brighter.brightness = 0.3
        let up = try pixel(try XCTUnwrap(ImageEditor.apply(brighter, to: source)), 1, 1).r
        XCTAssertGreaterThan(up, before + 20, "яркость вверх — пиксель светлее")

        var darker = ImageEdits(); darker.brightness = -0.3
        let down = try pixel(try XCTUnwrap(ImageEditor.apply(darker, to: source)), 1, 1).r
        XCTAssertLessThan(down, before - 20, "яркость вниз — темнее")

        // Контраст разводит тона от середины: тёмное темнеет, светлое светлеет.
        var contrast = ImageEdits(); contrast.contrast = 2
        let dark = try pixel(try XCTUnwrap(ImageEditor.apply(contrast, to: try grey(0.25))), 1, 1).r
        let light = try pixel(try XCTUnwrap(ImageEditor.apply(contrast, to: try grey(0.75))), 1, 1).r
        XCTAssertLessThan(dark, try pixel(try grey(0.25), 1, 1).r)
        XCTAssertGreaterThan(light, try pixel(try grey(0.75), 1, 1).r)
    }

    func test_насыщенностьВНольДаётСерое() throws {
        let source = try marker()
        var grey = ImageEdits(); grey.saturation = 0
        let flat = try XCTUnwrap(ImageEditor.apply(grey, to: source))
        let corner = try pixel(flat, 0, 0)
        XCTAssertEqual(corner.r, corner.g, accuracy: 12, "красный обесцветился: \(corner)")
        XCTAssertEqual(corner.g, corner.b, accuracy: 12)
    }

    func test_теплоВышеНуляГрееткартинку() throws {
        let source = try grey(0.5)
        let before = try pixel(source, 1, 1)
        var warm = ImageEdits(); warm.warmth = 60
        let warmed = try pixel(try XCTUnwrap(ImageEditor.apply(warm, to: source)), 1, 1)
        XCTAssertGreaterThan(warmed.r - warmed.b, before.r - before.b, "теплее: красного больше синего")
        var cold = ImageEdits(); cold.warmth = -60
        let cooled = try pixel(try XCTUnwrap(ImageEditor.apply(cold, to: source)), 1, 1)
        XCTAssertLessThan(cooled.r - cooled.b, before.r - before.b, "холоднее: синего больше")
    }

    func test_резкостьНеМеняетРазмер() throws {
        let source = try marker(width: 16, height: 16)
        var sharp = ImageEdits(); sharp.sharpness = 1.5
        let result = try XCTUnwrap(ImageEditor.apply(sharp, to: source))
        XCTAssertEqual(result.width, 16); XCTAssertEqual(result.height, 16)
    }

    /// Копия ложится рядом и никогда не затирает соседа: занятое имя — берём следующее.
    func test_имяКопииНеЗанимаетЧужое() {
        var taken: Set<String> = []
        let first = ImageEditor.copyPath(for: "/п/снимок.jpg", format: .jpeg, suffix: "правка",
                                         exists: { taken.contains($0) })
        XCTAssertEqual(first, "/п/снимок правка.jpg")
        taken.insert(first)
        let second = ImageEditor.copyPath(for: "/п/снимок.jpg", format: .jpeg, suffix: "правка",
                                          exists: { taken.contains($0) })
        XCTAssertEqual(second, "/п/снимок правка 2.jpg")
        taken.insert(second)
        XCTAssertEqual(ImageEditor.copyPath(for: "/п/снимок.jpg", format: .jpeg, suffix: "правка",
                                            exists: { taken.contains($0) }), "/п/снимок правка 3.jpg")
        // В другом формате — своё расширение.
        XCTAssertEqual(ImageEditor.copyPath(for: "/п/снимок.jpg", format: .png, suffix: "правка",
                                            exists: { _ in false }), "/п/снимок правка.png")
        for key in ["viewer.image.replaceOriginal", "viewer.image.saveCopy", "viewer.image.copySuffix",
                    "viewer.image.replaceTitle", "viewer.image.replaceMessage"] {
            XCTAssertNotEqual(L(key), key, "нет перевода \(key)")
        }
    }

    // MARK: - Авто-уровни

    /// Блёклая картинка: полоса от тёмно-серого к светло-серому без чёрного и белого.
    private func dull(side: Int = 64) throws -> CGImage {
        let c = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<side {
            let level = 0.35 + 0.25 * CGFloat(x) / CGFloat(side - 1)
            c.setFillColor(CGColor(red: level, green: level * 0.95, blue: level * 0.9, alpha: 1))
            c.fill(CGRect(x: x, y: 0, width: 1, height: side))
        }
        return try XCTUnwrap(c.makeImage())
    }

    func test_автоУровниВключаютсяИСбрасываются() {
        var e = ImageEdits()
        e.autoEnhance = true
        XCTAssertTrue(e.hasColourChanges, "кнопка «Цвет» подсвечивается и при одной автоправке")
        XCTAssertFalse(e.isIdentity, "есть что сохранять")
        e.resetColours()
        XCTAssertTrue(e.isIdentity)
    }

    func test_автоУровниМеняютБлёклуюКартинкуНоНеРазмер() throws {
        let source = try dull()
        var e = ImageEdits()
        e.autoEnhance = true
        let result = try XCTUnwrap(ImageEditor.apply(e, to: source))
        XCTAssertEqual(result.width, source.width)
        XCTAssertEqual(result.height, source.height)
        let before = try pixel(source, 63, 32).r - pixel(source, 0, 32).r
        let after = try pixel(result, 63, 32).r - pixel(result, 0, 32).r
        XCTAssertNotEqual(after, before, "автоправка что-то сделала с тонами")
    }

    // MARK: - Рисование

    /// Белый лист с чёрной полосой слева: размытие должно смешать её с белым.
    private func sheet(side: Int = 200) throws -> CGImage {
        let c = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: side, height: side))
        c.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: side / 2, height: side))
        return try XCTUnwrap(c.makeImage())
    }

    /// Красный пометок проходит через рабочее пространство Core Image и выходит чуть другим
    /// (замерено: 243·70·53), поэтому порог мягче, чем у `isRed`.
    private func isMarkRed(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r > 200 && c.g < 110 && c.b < 110 }

    func test_пометкиДелаютПравкуНастоящей() {
        var e = ImageEdits()
        e.annotations.append(ImageAnnotation(tool: .arrow, start: .zero, end: CGPoint(x: 1, y: 1)))
        XCTAssertFalse(e.isIdentity, "картинку с пометкой есть что сохранять")
    }

    func test_рамкаРисуетсяПоКраюАСерединаНетронута() throws {
        let source = try sheet()
        var e = ImageEdits()
        e.annotations = [ImageAnnotation(tool: .frame, start: CGPoint(x: 0.6, y: 0.2),
                                         end: CGPoint(x: 0.9, y: 0.8), colour: .red)]
        let result = try XCTUnwrap(ImageEditor.apply(e, to: source))
        XCTAssertTrue(isMarkRed(try pixel(result, 120, 100)), "левая сторона рамки — красная")
        let inside = try pixel(result, 150, 100)
        XCTAssertTrue(inside.r > 240 && inside.g > 240, "внутри рамки белое")
        let outside = try pixel(result, 190, 100)
        XCTAssertTrue(outside.r > 240 && outside.g > 240, "снаружи рамки белое")
    }

    func test_размытиеТолькоВнутриСвоегоУчастка() throws {
        let source = try sheet()
        var e = ImageEdits()
        // Участок поперёк границы чёрного и белого — в верхней половине картинки.
        e.annotations = [ImageAnnotation(tool: .blur, start: CGPoint(x: 0.3, y: 0.1),
                                         end: CGPoint(x: 0.7, y: 0.4))]
        let result = try XCTUnwrap(ImageEditor.apply(e, to: source))
        let edge = try pixel(result, 100, 50)
        XCTAssertTrue(edge.r > 40 && edge.r < 215, "на границе внутри участка — серое: \(edge)")
        let below = try pixel(result, 100, 160)
        XCTAssertTrue(below.r > 240 || below.r < 15, "под участком граница резкая: \(below)")
    }

    func test_подписьОставляетБуквы() throws {
        let source = try sheet()
        var e = ImageEdits()
        e.annotations = [ImageAnnotation(tool: .text, start: CGPoint(x: 0.55, y: 0.3),
                                         end: CGPoint(x: 0.55, y: 0.3), colour: .red, text: "ЖЖЖ")]
        let result = try XCTUnwrap(ImageEditor.apply(e, to: source))
        var red = 0
        for x in stride(from: 110, to: 200, by: 2) {
            for y in stride(from: 60, to: 80, by: 2) where isMarkRed(try pixel(result, x, y)) { red += 1 }
        }
        XCTAssertGreaterThan(red, 5, "красные буквы на белом")
    }

    func test_пометкиПоворачиваютсяИОтражаютсяВместеСКартинкой() {
        var e = ImageEdits()
        e.annotations = [ImageAnnotation(tool: .arrow, start: CGPoint(x: 0.1, y: 0.2),
                                         end: CGPoint(x: 0.3, y: 0.2))]
        e.rotateOnScreen(clockwise: true)
        XCTAssertEqual(e.annotations[0].start.x, 0.8, accuracy: 1e-9)
        XCTAssertEqual(e.annotations[0].start.y, 0.1, accuracy: 1e-9)
        e.rotateOnScreen(clockwise: false)
        XCTAssertEqual(e.annotations[0].start.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(e.annotations[0].start.y, 0.2, accuracy: 1e-9)
        e.flipOnScreen(horizontal: true)
        XCTAssertEqual(e.annotations[0].start.x, 0.9, accuracy: 1e-9)
    }

    func test_обрезкаНеСдвигаетПометкуСЕёМеста() {
        var e = ImageEdits()
        e.annotations = [ImageAnnotation(tool: .frame, start: CGPoint(x: 0.5, y: 0.5),
                                         end: CGPoint(x: 0.75, y: 0.75))]
        e.crop = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        XCTAssertEqual(e.annotations[0].start.x, 0, accuracy: 1e-9)
        XCTAssertEqual(e.annotations[0].end.x, 0.5, accuracy: 1e-9)
        e.crop = nil
        XCTAssertEqual(e.annotations[0].start.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(e.annotations[0].end.y, 0.75, accuracy: 1e-9)
    }

    // MARK: - Обрезка и горизонт

    func test_обрезкаБерётИменноТуЧасть() throws {
        let source = try marker(width: 8, height: 8)   // красный в левом ВЕРХНЕМ углу
        var left = ImageEdits(); left.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let piece = try XCTUnwrap(ImageEditor.apply(left, to: source))
        XCTAssertEqual(piece.width, 4); XCTAssertEqual(piece.height, 4)
        XCTAssertTrue(isRed(try pixel(piece, 0, 0)), "верхняя левая четверть — с красным углом")

        var right = ImageEdits(); right.crop = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        let other = try XCTUnwrap(ImageEditor.apply(right, to: source))
        XCTAssertFalse(isRed(try pixel(other, 0, 0)), "нижняя правая четверть — без него")
    }

    func test_обрезкаПоПропорции() {
        let wide = CGSize(width: 400, height: 100)
        let square = ImageEdits.centredCrop(ratio: 1, in: wide)
        XCTAssertEqual(square.height, 1, accuracy: 0.001, "по высоте берём всё")
        XCTAssertEqual(square.width, 0.25, accuracy: 0.001)
        XCTAssertEqual(square.midX, 0.5, accuracy: 0.001, "по центру")
        let tall = ImageEdits.centredCrop(ratio: 1, in: CGSize(width: 100, height: 400))
        XCTAssertEqual(tall.width, 1, accuracy: 0.001)
        XCTAssertEqual(tall.height, 0.25, accuracy: 0.001)
        let sixteenNine = ImageEdits.centredCrop(ratio: 16.0 / 9, in: CGSize(width: 100, height: 100))
        XCTAssertEqual(sixteenNine.width, 1, accuracy: 0.001)
        XCTAssertEqual(sixteenNine.height, 9.0 / 16, accuracy: 0.001)
    }

    func test_выравниваниеГоризонтаНеОставляетПустыхУглов() throws {
        // Прямоугольник внутри повёрнутого — заметно меньше целого и по центру.
        let source = CGSize(width: 400, height: 300)
        let keep = ImageEdits.insideTurned(size: source, degrees: 10)
        XCTAssertLessThan(keep.width, source.width); XCTAssertLessThan(keep.height, source.height)
        XCTAssertGreaterThan(keep.width, source.width * 0.6)
        XCTAssertEqual(keep.width / keep.height, source.width / source.height, accuracy: 0.02,
                       "пропорция сохраняется")
        XCTAssertEqual(ImageEdits.insideTurned(size: source, degrees: 0), source, "без поворота режем нечего")

        // На настоящих пикселях: белая картинка после выравнивания остаётся белой — то есть
        // в кадр не попали чёрные углы от поворота.
        let white = try grey(1.0, side: 200)
        var level = ImageEdits(); level.straighten = 8
        let result = try XCTUnwrap(ImageEditor.apply(level, to: white))
        for point in [(0, 0), (result.width - 1, 0), (0, result.height - 1),
                      (result.width - 1, result.height - 1)] {
            let corner = try pixel(result, point.0, point.1)
            XCTAssertGreaterThan(corner.r, 200, "угол \(point) пустой: \(corner)")
        }
    }

    // MARK: - Сведения о снимке

    func test_сведенияПереносятсяИСнимаются() throws {
        let source = try marker(width: 8, height: 8)
        let withInfo = path("сописанием.jpg")
        // Записываем с придуманной камерой и «неправильной» ориентацией.
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Проба",
                                             kCGImagePropertyTIFFModel: "Камера X"] as [CFString: Any],
        ]
        try ImageEditor.write(source, to: withInfo, format: .jpeg, quality: 0.9, metadata: props)
        let read = try XCTUnwrap(ImageEditor.metadata(ofFile: withInfo))
        let rows = ImageEditor.readableMetadata(read)
        XCTAssertTrue(rows.contains { $0.1.contains("Камера X") }, "камера не дошла: \(rows)")
        XCTAssertNil(read[kCGImagePropertyOrientation],
                     "ориентация снята: поворот уже в пикселях, иначе картинку повернёт дважды")

        let bare = path("безописания.jpg")
        try ImageEditor.write(source, to: bare, format: .jpeg)
        let empty = ImageEditor.readableMetadata(try XCTUnwrap(ImageEditor.metadata(ofFile: bare)))
        XCTAssertFalse(empty.contains { $0.1.contains("Камера X") }, "без метаданных — ничего чужого")
        for key in ["viewer.exif.camera", "viewer.exif.title", "viewer.exif.keep"] {
            XCTAssertNotEqual(L(key), key, "нет перевода \(key)")
        }
    }
}

/// Как выглядит полоса инструментов рисования — в обеих темах.
@MainActor
final class ImageAnnotationLookTests: XCTestCase {

    func test_полосаИнструментовРисуется() throws {
        let folder = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] ?? NSTemporaryDirectory()
        for (name, scheme) in [("светлая", ColorScheme.light), ("тёмная", ColorScheme.dark)] {
            let view = ImageAnnotationToolbar(tool: .constant(.frame), colour: .constant(.red),
                                              canUndo: true, onUndo: {}, onDone: {})
                .frame(width: 760)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, name)
            let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
                .representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("рисование-\(name).png"))
        }
    }
}
