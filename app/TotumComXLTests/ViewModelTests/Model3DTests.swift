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
        }
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
