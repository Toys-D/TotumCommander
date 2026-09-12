import AppKit
import FCXLBridgeObjC
import Metal
import ModelIO
import SceneKit
import XCTest
@testable import TotumComXLApp

/// Трёхмерные модели в просмотрщике: кто какой формат читает и получается ли картинка.
final class Model3DTests: XCTestCase {

    /// Образцы. В хранилище лежат три крошечных (obj, stl, gltf — меньше килобайта на
    /// всех); папку можно подменить переменной среды и прогнать этот же тест по своему
    /// набору моделей, ничего не добавляя в хранилище:
    ///   FCXL_MODEL_FIXTURES=/путь/к/моделям swift test --filter Model3DTests
    private static var fixtures: String {
        if let own = ProcessInfo.processInfo.environment["FCXL_MODEL_FIXTURES"], !own.isEmpty {
            return own.hasSuffix("/") ? own : own + "/"
        }
        return FileManager.default.currentDirectoryPath + "/app/TotumComXLTests/Fixtures/Models/"
    }

    private func fixture(_ name: String) throws -> String {
        let path = Self.fixtures + name
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "нет образца \(name)")
        return path
    }

    // MARK: - Кто читает

    func test_форматыApple_ИдутСистемнымПутём() {
        for ext in ["obj", "stl", "ply", "abc", "usd", "usda", "usdc", "usdz", "dae", "scn"] {
            XCTAssertEqual(Model3DFormats.reader(forExtension: ext), .apple, ext)
        }
    }

    func test_остальныеФорматы_ИдутЧерезБиблиотеку() {
        for ext in ["gltf", "glb", "fbx", "3ds", "blend", "3mf", "x3d", "step"] {
            XCTAssertEqual(Model3DFormats.reader(forExtension: ext), .library, ext)
        }
    }

    func test_расширениеБезРазницыВРегистреИТочке() {
        XCTAssertEqual(Model3DFormats.reader(forExtension: "OBJ"), .apple)
        XCTAssertEqual(Model3DFormats.reader(forExtension: ".Gltf"), .library)
    }

    /// Чужое не берём: чертёж остаётся чертежом, а `xml`, `raw` и `mesh` библиотека
    /// заявляет как модели — в файловом менеджере это значит совсем другое.
    func test_чужиеРасширенияНеЗабираем() {
        for ext in ["dxf", "xml", "raw", "mesh", "txt", "png", "pdf", "dwg", "iges", "max", "c4d"] {
            XCTAssertNil(Model3DFormats.reader(forExtension: ext), ext)
        }
    }

    /// Сторож: всё, что мы обещаем читать библиотекой, она и правда читает. Обновится
    /// библиотека, выпадет формат — тест скажет об этом, а не пользователь.
    func test_библиотекаПодтверждаетСвойСписок() {
        let readable = Set(FCXLModelBridge.readableExtensions())
        XCTAssertGreaterThan(readable.count, 40, "мост не отвечает — не собрана библиотека?")
        let promised = Model3DFormats.libraryExtensions
        XCTAssertTrue(promised.isSubset(of: readable),
                      "библиотека больше не читает: \(promised.subtracting(readable).sorted())")
    }

    /// И системный список — не на слово: спрашиваем сам Model I/O (dae и scn у SceneKit,
    /// их Model I/O не знает — они здесь исключение и проверяются чтением образца).
    func test_ModelIOПодтверждаетСвойСписок() {
        for ext in Model3DFormats.appleExtensions.subtracting(["dae", "scn"]) {
            XCTAssertTrue(MDLAsset.canImportFileExtension(ext), ext)
        }
    }

    // MARK: - Камера и пределы

    func test_камераОтодвигаетсяПоРазмеруМодели() {
        let near = Model3DLoader.cameraDistance(radius: 1)
        let far = Model3DLoader.cameraDistance(radius: 10)
        XCTAssertGreaterThan(far, near * 9, "вдесятеро крупнее — вдесятеро дальше")
        // Узкий угол обзора требует большего расстояния, чем широкий.
        XCTAssertGreaterThan(Model3DLoader.cameraDistance(radius: 1, fovDegrees: 20),
                             Model3DLoader.cameraDistance(radius: 1, fovDegrees: 90))
    }

    func test_камераНеВырождаетсяНаПустойМодели() {
        let distance = Model3DLoader.cameraDistance(radius: 0)
        XCTAssertTrue(distance.isFinite)
        XCTAssertGreaterThan(distance, 0)
        XCTAssertTrue(Model3DLoader.cameraDistance(radius: 1, fovDegrees: 0).isFinite,
                      "нулевой угол обзора не должен давать бесконечность")
    }

    func test_слишкомБольшойФайлНеОткрываем() {
        XCTAssertFalse(Model3DLoader.isTooBig(size: 10_000_000))
        XCTAssertTrue(Model3DLoader.isTooBig(size: Model3DLoader.sizeLimit + 1))
    }

    // MARK: - Чтение образцов

    func test_читаетOBJСистемнымПутём() throws {
        let model = try Model3DLoader.load(path: try fixture("cube.obj"))
        XCTAssertEqual(model.reader, .apple)
        XCTAssertGreaterThan(model.meshCount, 0)
        XCTAssertGreaterThan(model.vertexCount, 0)
        XCTAssertGreaterThan(model.radius, 0)
    }

    func test_читаетSTLСистемнымПутём() throws {
        let model = try Model3DLoader.load(path: try fixture("pyramid.stl"))
        XCTAssertEqual(model.reader, .apple)
        XCTAssertGreaterThan(model.faceCount, 0)
    }

    /// Главное приобретение: glTF, которого у Apple нет.
    func test_читаетGLTFБиблиотекой() throws {
        let model = try Model3DLoader.load(path: try fixture("triangle.gltf"))
        XCTAssertEqual(model.reader, .library)
        XCTAssertEqual(model.meshCount, 1)
        XCTAssertEqual(model.vertexCount, 3)
        XCTAssertEqual(model.faceCount, 1)
    }

    func test_чужойФайлОтвергаетсяВнятно() {
        let path = FileManager.default.currentDirectoryPath + "/Package.swift"
        XCTAssertThrowsError(try Model3DLoader.load(path: path)) { error in
            XCTAssertEqual(error as? Model3DError, .unsupported(ext: "swift"))
        }
    }

    /// Каждая модель в папке образцов читается — сколько бы их там ни лежало и какого бы
    /// формата они ни были. Тем же кодом, каким её прочтёт просмотрщик.
    func test_всеОбразцыВПапкеЧитаются() throws {
        let folder = Self.fixtures
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let models = names.filter { Model3DFormats.isModel(extension: ($0 as NSString).pathExtension) }
        try XCTSkipIf(models.isEmpty, "в папке образцов нет моделей")
        for name in models.sorted() {
            let model = try Model3DLoader.load(path: folder + name)
            XCTAssertGreaterThan(model.meshCount, 0, name)
            XCTAssertGreaterThan(model.vertexCount, 0, name)
            XCTAssertGreaterThan(model.faceCount, 0, name)
            XCTAssertTrue(model.radius.isFinite && model.radius > 0, name)
            // В журнал — сколько материалов получили картинку: по этой строке видно,
            // нашлись ли текстуры у своего набора моделей.
            let all = Self.materials(in: model.scene)
            let textured = all.filter { $0.diffuse.contents is NSImage }.count
            let glowing = all.filter { $0.emission.contents is NSImage }.count
            print("  \(name): сеток \(model.meshCount), материалов \(all.count),"
                  + " с картинкой \(textured), со свечением \(glowing),"
                  + " оттенков на снимке \(Self.shades(of: model))")
        }
    }

    // MARK: - Текстуры с чужой машины

    /// Та самая жалоба: «текстуры есть, а почему не подтягиваются».
    ///
    /// Модель из Blender под Windows называет свои картинки как `C:/baseColor.png` —
    /// такого пути на Mac нет, и модель выходит белой, хотя картинки лежат рядом с ней.
    /// Здесь такая модель собирается на месте, в отдельной папке (в хранилище двоичных
    /// картинок не держим), и проверяется весь путь: имя нашлось, карта нормалей встала,
    /// свечение погасло и модель РИСУЕТСЯ не одним белым пятном.
    func test_текстураСЧужимПутёмНаходитсяПоИмени() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try Self.write(png: NSColor.systemOrange, to: folder.appendingPathComponent("skin.png"))
        try Self.write(png: NSColor.systemBlue, to: folder.appendingPathComponent("skin_normal.png"))
        // Ka 1 1 1 — то, что Model I/O принимает за свечение; Ke в файле нет намеренно.
        let mtl = """
        newmtl painted
        Ka 1.000000 1.000000 1.000000
        Ks 0.500000 0.500000 0.500000
        map_Kd C:/skin.png
        map_Bump -bm 1.000000 C:\\tex\\skin_normal.png
        """
        try mtl.write(to: folder.appendingPathComponent("thing.mtl"), atomically: true,
                      encoding: .utf8)
        try Self.cubeOBJ(material: "painted", mtlFile: "thing.mtl")
            .write(to: folder.appendingPathComponent("thing.obj"), atomically: true, encoding: .utf8)

        let model = try Model3DLoader.load(path: folder.appendingPathComponent("thing.obj").path)
        XCTAssertEqual(model.reader, .apple)
        let materials = Self.materials(in: model.scene)
        let painted = try XCTUnwrap(materials.first)
        XCTAssertTrue(painted.diffuse.contents is NSImage, "цветная карта не нашлась по имени")
        XCTAssertTrue(painted.normal.contents is NSImage, "карта нормалей не нашлась")
        let emission = painted.emission.contents as? NSColor
        XCTAssertEqual(emission?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1, 0, accuracy: 0.01,
                       "белое свечение от Ka заливает модель ровным белым")
    }

    /// Порядок поиска картинки: как написано, рядом по относительному пути, потом по имени.
    func test_гдеИщемКартинкуМатериала() {
        let folder = "/models/thing"
        let candidates = ModelTextureRescue.candidates(reference: "C:\\tex\\skin.png",
                                                       modelFolder: folder)
        XCTAssertEqual(candidates.first, folder + "/C:/tex/skin.png", "сперва как написано")
        XCTAssertTrue(candidates.contains(folder + "/skin.png"), "потом по имени рядом с моделью")
        XCTAssertTrue(candidates.contains(folder + "/textures/skin.png"), "и в соседних папках")
        // Абсолютный путь пробуется как есть — модель могла прийти со своей же машины.
        XCTAssertEqual(ModelTextureRescue.candidates(reference: "/tmp/a/skin.png",
                                                     modelFolder: folder).first,
                       "/tmp/a/skin.png")
        XCTAssertTrue(ModelTextureRescue.candidates(reference: "  ", modelFolder: folder).isEmpty)
    }

    func test_находитПервыйСуществующий() {
        let folder = "/models"
        let found = ModelTextureRescue.locate(reference: "D:\\art\\skin.png", modelFolder: folder) {
            $0 == folder + "/textures/skin.png"
        }
        XCTAssertEqual(found, folder + "/textures/skin.png")
        XCTAssertNil(ModelTextureRescue.locate(reference: "D:/skin.png", modelFolder: folder) { _ in false })
    }

    /// Разбор .mtl — включая ключи с числами перед путём и пробелы в имени файла.
    func test_разборФайлаМатериалов() {
        let text = """
        # Blender 5.2.0 LTS MTL File
        newmtl lights
        Ka 1.000000 1.000000 1.000000
        Kd 0.000000 0.000000 0.000000
        map_Ke C:/lights_emissive.png

        newmtl slug_launcher
        Ke 0.000000 0.000000 0.000000
        map_Kd C:/slug launcher baseColor.png
        map_Bump -bm 1.000000 C:/slug_launcher_normal.png
        """
        let parsed = WavefrontMTL.parse(text)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed["lights"]?.emission, "C:/lights_emissive.png")
        XCTAssertEqual(parsed["lights"]?.diffuseColour, [0, 0, 0])
        XCTAssertEqual(parsed["slug_launcher"]?.diffuse, "C:/slug launcher baseColor.png",
                       "пробелы в имени файла — часть пути")
        XCTAssertEqual(parsed["slug_launcher"]?.normal, "C:/slug_launcher_normal.png",
                       "-bm 1.000000 — это ключ, а не путь")
        XCTAssertEqual(parsed["slug_launcher"]?.emissionColour, [0, 0, 0])
    }

    func test_гаситьСвечениеТолькоКогдаФайлОНёмМолчит() {
        var material = WavefrontMaterial()
        XCTAssertTrue(WavefrontMTL.emissionShouldBeBlack(material: material, currentIsImage: false))
        material.emissionColour = [0.2, 0.2, 0.2]
        XCTAssertFalse(WavefrontMTL.emissionShouldBeBlack(material: material, currentIsImage: false))
        material = WavefrontMaterial()
        material.emission = "glow.png"
        XCTAssertFalse(WavefrontMTL.emissionShouldBeBlack(material: material, currentIsImage: false))
        XCTAssertFalse(WavefrontMTL.emissionShouldBeBlack(material: nil, currentIsImage: false),
                       "без .mtl не трогаем")
        XCTAssertFalse(WavefrontMTL.emissionShouldBeBlack(material: WavefrontMaterial(),
                                                          currentIsImage: true),
                       "картинку свечения не гасим")
    }

    func test_имяФайлаМатериаловБерётсяИзСамойМодели() {
        XCTAssertEqual(WavefrontMTL.materialFileName(inOBJ: "# x\nmtllib Sem título.mtl\nv 0 0 0"),
                       "Sem título.mtl")
        XCTAssertNil(WavefrontMTL.materialFileName(inOBJ: "v 0 0 0"))
    }

    /// Сколько различимых оттенков даёт снимок модели. Один — плоский силуэт: ровно так
    /// выглядела модель, пока её свечение оставалось белым.
    static func shades(of model: Model3DScene) -> Int {
        guard let device = MTLCreateSystemDefaultDevice() else { return -1 }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = model.scene
        renderer.autoenablesDefaultLighting = true
        renderer.pointOfView = camera(for: model)
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 160, height: 160),
                                      antialiasingMode: .none)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return -1 }
        var seen = Set<Int>()
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.1 else { continue }
                let key = Int(colour.redComponent * 20) * 441
                    + Int(colour.greenComponent * 20) * 21 + Int(colour.blueComponent * 20)
                seen.insert(key)
            }
        }
        return seen.count
    }

    private static func materials(in scene: SCNScene) -> [SCNMaterial] {
        var result: [SCNMaterial] = []
        func walk(_ node: SCNNode) {
            result.append(contentsOf: node.geometry?.materials ?? [])
            node.childNodes.forEach(walk)
        }
        walk(scene.rootNode)
        return result
    }

    private static func write(png colour: NSColor, to url: URL) throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        colour.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    /// Куб с нормалями и развёрткой — чтобы текстуре было куда лечь.
    private static func cubeOBJ(material: String, mtlFile: String) -> String {
        """
        mtllib \(mtlFile)
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        vt 0 0
        vt 1 0
        vt 1 1
        vt 0 1
        vn 0 0 1
        usemtl \(material)
        f 1/1/1 2/2/1 3/3/1
        f 1/1/1 3/3/1 4/4/1
        """
    }

    // MARK: - Получается ли картинка

    /// Проверка целиком: прочитать, поставить камеру по размеру модели и нарисовать за
    /// кадром. Если камера смотрит мимо — точек не будет, и тест это поймает.
    func test_модельРисуетсяИПопадаетВКадр() throws {
        let device = MTLCreateSystemDefaultDevice()
        try XCTSkipIf(device == nil, "нет Metal")
        for name in ["cube.obj", "triangle.gltf", "pyramid.stl"] {
            let model = try Model3DLoader.load(path: try fixture(name))
            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = model.scene
            renderer.autoenablesDefaultLighting = true
            renderer.pointOfView = Self.camera(for: model)
            let image = renderer.snapshot(atTime: 0, with: CGSize(width: 128, height: 128),
                                          antialiasingMode: .none)
            let drawn = Self.opaquePoints(in: image)
            XCTAssertGreaterThan(drawn, 20, "\(name): модель не попала в кадр")
        }
    }

    private static func camera(for model: Model3DScene) -> SCNNode {
        let distance = Model3DLoader.cameraDistance(radius: model.radius)
        let camera = SCNCamera()
        camera.fieldOfView = 60
        camera.zNear = Double(distance) / 100
        camera.zFar = Double(distance) * 20
        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(model.center.x, model.center.y,
                                   model.center.z + CGFloat(distance))
        node.look(at: model.center)
        return node
    }

    private static func opaquePoints(in image: NSImage) -> Int {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        var drawn = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.05 { drawn += 1 }
            }
        }
        return drawn
    }

    // MARK: - Просмотрщик знает, что это модель

    func test_просмотрщикОтноситФайлыКМоделям() {
        for name in ["a.obj", "b.gltf", "c.glb", "d.usdz", "e.fbx", "f.dae", "g.stl"] {
            XCTAssertEqual(fileCategory(forFileName: name), .model, name)
        }
        XCTAssertEqual(fileCategory(forFileName: "plan.dxf"), .drawing, "чертёж остаётся чертежом")
        XCTAssertEqual(fileCategory(forFileName: "photo.raw"), .image)
        XCTAssertEqual(autoMode(for: .model), .model)
    }

    func test_строкаОСоставеМодели() {
        let line = ModelStats.line(meshes: 3, vertices: 1240, faces: 2480)
        XCTAssertTrue(line.contains("3"))
        XCTAssertTrue(line.contains("2") && line.contains("480"), "число разбито по разрядам")
        XCTAssertEqual(line.components(separatedBy: "·").count, 3)
    }
}
