import AppKit
import FCXLBridgeObjC
import XCTest
@testable import TotumComXLApp

/// Чтение модели отдельным процессом и передача её обратно.
///
/// Зачем отдельным: библиотека чтения падает на некоторых файлах. Проверено на её же
/// наборе образцов — сигнал 11 дают девять файлов, и среди них обычный `camera.ogex`.
/// В файловом менеджере такое падение уносило бы всю программу вместе с очередью работ.
final class ModelReaderTests: XCTestCase {

    // MARK: - Служебный ключ

    func test_разбираетСлужебныеДоводы() {
        let request = ModelReaderProcess.request(in: ["/путь/к/программе",
                                                      ModelReaderProcess.flag,
                                                      "/модель.glb", "/ответ.blob"])
        XCTAssertEqual(request?.input, "/модель.glb")
        XCTAssertEqual(request?.output, "/ответ.blob")
        XCTAssertNil(ModelReaderProcess.request(in: ["/программа"]), "обычный запуск")
        XCTAssertNil(ModelReaderProcess.request(in: ["/программа", ModelReaderProcess.flag]),
                     "ключ без доводов — не просьба")
    }

    /// Ключ понимает только сама программа; рядом с тестом лежит xctest, и там читаем
    /// на месте, а не отдельным процессом.
    func test_читателемМожетБытьТолькоНашаПрограмма() {
        XCTAssertTrue(ModelReaderProcess.canServe(
            executablePath: "/Программы/Totum Commander.app/Contents/MacOS/TotumComXL"))
        XCTAssertFalse(ModelReaderProcess.canServe(executablePath: "/usr/bin/xctest"))
        XCTAssertFalse(ModelReaderProcess.canServe(executablePath: ""))
    }

    // MARK: - Передача модели

    private func sample() -> [Model3DMesh] {
        var mesh = Model3DMesh()
        mesh.name = "куб"
        mesh.materialName = "краска"
        mesh.vertexCount = 3
        mesh.faceCount = 1
        mesh.positions = Data([1, 2, 3, 4])
        mesh.normals = Data([9, 9])
        mesh.uvSets = [Data([1, 1]), Data([2, 2, 2])]
        mesh.indices = Data([0, 1, 2])
        mesh.diffuseColor = NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        mesh.emissiveColor = nil
        mesh.metallic = 0.8
        mesh.roughness = 0
        mesh.opacity = nil
        mesh.emissiveStrength = 10
        mesh.textures = [
            FCXLModelTextureBaseColor: Model3DTexture(path: "C:/краска.png", data: nil, uvChannel: 0),
            FCXLModelTextureEmissive: Model3DTexture(path: nil, data: Data([7, 7, 7]), uvChannel: 1)
        ]
        var second = Model3DMesh()
        second.vertexCount = 1
        second.faceCount = 1
        second.positions = Data([5])
        second.indices = Data([0])
        return [mesh, second]
    }

    func test_модельПереживаетПередачуБезПотерь() throws {
        let original = sample()
        let decoded = try XCTUnwrap(ModelBlob.decode(ModelBlob.encode(original)))
        XCTAssertEqual(decoded.count, 2)
        let mesh = decoded[0]
        XCTAssertEqual(mesh.name, "куб")
        XCTAssertEqual(mesh.materialName, "краска")
        XCTAssertEqual(mesh.vertexCount, 3)
        XCTAssertEqual(mesh.faceCount, 1)
        XCTAssertEqual(mesh.positions, Data([1, 2, 3, 4]))
        XCTAssertEqual(mesh.normals, Data([9, 9]))
        XCTAssertEqual(mesh.uvSets, [Data([1, 1]), Data([2, 2, 2])])
        XCTAssertEqual(mesh.indices, Data([0, 1, 2]))
        XCTAssertEqual(mesh.metallic, 0.8)
        // Ноль и «файл молчит» — разные вещи, и это должно дойти целым.
        XCTAssertEqual(mesh.roughness, 0)
        XCTAssertNil(mesh.opacity)
        XCTAssertEqual(mesh.emissiveStrength, 10)
        XCTAssertNil(mesh.emissiveColor)
        let colour = try XCTUnwrap(mesh.diffuseColor?.usingColorSpace(.sRGB))
        XCTAssertEqual(colour.redComponent, 0.25, accuracy: 0.01)
        XCTAssertEqual(colour.blueComponent, 0.75, accuracy: 0.01)
        XCTAssertEqual(mesh.textures[FCXLModelTextureBaseColor]?.path, "C:/краска.png")
        XCTAssertEqual(mesh.textures[FCXLModelTextureEmissive]?.data, Data([7, 7, 7]))
        XCTAssertEqual(mesh.textures[FCXLModelTextureEmissive]?.uvChannel, 1,
                       "номер набора развёртки обязан доехать — иначе картинка ляжет не туда")
        XCTAssertEqual(decoded[1].vertexCount, 1)
    }

    /// Обрывок, чужие байты и пустота не должны приниматься за модель.
    func test_испорченныйОтветНеПринимается() {
        let good = ModelBlob.encode(sample())
        XCTAssertNil(ModelBlob.decode(Data()))
        XCTAssertNil(ModelBlob.decode(Data([1, 2, 3, 4, 5, 6, 7, 8])))
        XCTAssertNil(ModelBlob.decode(good.prefix(good.count / 2)), "обрубленный ответ")
        var wrongVersion = good
        wrongVersion[4] = 99
        XCTAssertNil(ModelBlob.decode(wrongVersion))
    }

    func test_пустаяМодельЭтоПустойСписок() throws {
        XCTAssertEqual(try XCTUnwrap(ModelBlob.decode(ModelBlob.encode([]))).count, 0)
    }
}
