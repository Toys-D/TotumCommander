import AppKit
import SceneKit
import XCTest
@testable import TotumComXLApp

/// Что просмотрщик моделей делает с уже прочитанной сценой: размеры, список узлов,
/// анимация, свет, запись в другой формат, эскиз.
final class Model3DToolsTests: XCTestCase {

    /// Коробка 1 × 2 × 3 из настоящих вершин: площадь 22, объём 6 — проверять есть с чем.
    /// Не SCNBox: у того вершины единичного куба, а размер он добавляет уже при отрисовке.
    private func cuboid() -> SCNGeometry {
        let w: CGFloat = 1, h: CGFloat = 2, d: CGFloat = 3
        let corners = [SCNVector3(0, 0, 0), SCNVector3(w, 0, 0), SCNVector3(w, h, 0), SCNVector3(0, h, 0),
                       SCNVector3(0, 0, d), SCNVector3(w, 0, d), SCNVector3(w, h, d), SCNVector3(0, h, d)]
        let faces: [UInt16] = [0, 2, 1, 0, 3, 2,  4, 5, 6, 4, 6, 7,  0, 1, 5, 0, 5, 4,
                               3, 7, 6, 3, 6, 2,  0, 4, 7, 0, 7, 3,  1, 2, 6, 1, 6, 5]
        return SCNGeometry(sources: [SCNGeometrySource(vertices: corners)],
                           elements: [SCNGeometryElement(indices: faces, primitiveType: .triangles)])
    }

    private func boxScene() -> (SCNScene, SCNNode) {
        let scene = SCNScene()
        let node = SCNNode(geometry: cuboid())
        node.name = "Коробка"
        let holder = SCNNode()
        holder.name = "Группа"
        holder.addChildNode(node)
        scene.rootNode.addChildNode(holder)
        return (scene, node)
    }

    private func model(_ scene: SCNScene) -> Model3DScene {
        Model3DScene(scene: scene, meshCount: 1, vertexCount: 24, faceCount: 12, reader: .apple,
                     radius: 1.5, center: SCNVector3(0, 0, 0))
    }

    func test_размерыКоробки() {
        let (scene, _) = boxScene()
        let m = ModelMeasurements.measure(scene.rootNode)
        XCTAssertEqual(m.width, 1, accuracy: 1e-4)
        XCTAssertEqual(m.height, 2, accuracy: 1e-4)
        XCTAssertEqual(m.depth, 3, accuracy: 1e-4)
        XCTAssertEqual(m.area, 22, accuracy: 1e-3)
        XCTAssertEqual(m.volume, 6, accuracy: 1e-3)
    }

    func test_размерыУчитываютМасштабУзла() {
        let (scene, node) = boxScene()
        node.scale = SCNVector3(2, 2, 2)
        let m = ModelMeasurements.measure(scene.rootNode)
        XCTAssertEqual(m.depth, 6, accuracy: 1e-4)
        XCTAssertEqual(m.volume, 48, accuracy: 1e-2)
    }

    func test_многоугольникРежетсяВеером() {
        // Один четырёхугольник: сначала число углов, потом вершины.
        let indices: [UInt16] = [4, 0, 1, 2, 3]
        let element = SCNGeometryElement(data: Data(bytes: indices, count: indices.count * 2),
                                         primitiveType: .polygon, primitiveCount: 1, bytesPerIndex: 2)
        let triangles = ModelMeasurements.triangles(of: element)
        XCTAssertEqual(triangles.count, 2)
        XCTAssertEqual(triangles[0].0, 0); XCTAssertEqual(triangles[0].1, 1); XCTAssertEqual(triangles[0].2, 2)
        XCTAssertEqual(triangles[1].0, 0); XCTAssertEqual(triangles[1].1, 2); XCTAssertEqual(triangles[1].2, 3)
    }

    func test_узлыБезСетокНеПоказываются() {
        let (scene, _) = boxScene()
        let empty = SCNNode()
        empty.name = "Пустой"
        scene.rootNode.addChildNode(empty)
        let rows = ModelNodeRow.rows(of: scene.rootNode)
        XCTAssertEqual(rows.map(\.title), ["Группа", "Коробка"])
        XCTAssertEqual(rows.map(\.depth), [0, 1])
        XCTAssertEqual(rows.map(\.hasMesh), [false, true])
    }

    func test_материалыПоОдномуРазу() {
        let (scene, node) = boxScene()
        let material = SCNMaterial()
        material.name = "Краска"
        material.diffuse.contents = NSColor.red
        node.geometry?.materials = [material, material]
        let rows = ModelMaterialRow.rows(of: scene.rootNode)
        XCTAssertEqual(rows.map(\.title), ["Краска"])
        XCTAssertNotNil(rows.first?.colour)
    }

    func test_анимацияНаходитсяИПереводитсяНаВремяСцены() {
        let (scene, node) = boxScene()
        XCTAssertEqual(ModelAnimation.prepare(scene.rootNode), 0, "без анимаций — ноль")
        let spin = CABasicAnimation(keyPath: "rotation")
        spin.toValue = NSValue(scnVector4: SCNVector4(0, 1, 0, CGFloat.pi * 2))
        spin.duration = 2.5
        node.addAnimation(SCNAnimation(caAnimation: spin), forKey: "spin")
        XCTAssertEqual(ModelAnimation.prepare(scene.rootNode), 2.5, accuracy: 1e-9)
        XCTAssertTrue(node.animationPlayer(forKey: "spin")?.animation.usesSceneTimeBase == true)
    }

    func test_свойСветСтавитсяИСнимается() {
        let (scene, _) = boxScene()
        func rigs() -> Int { scene.rootNode.childNodes.filter { $0.name == "fcxl.lightRig" }.count }
        ModelLighting.studio.apply(to: scene, view: nil, radius: 1)
        XCTAssertEqual(rigs(), 1)
        ModelLighting.flat.apply(to: scene, view: nil, radius: 1)
        XCTAssertEqual(rigs(), 1, "второй набор света не копится поверх первого")
        ModelLighting.standard.apply(to: scene, view: nil, radius: 1)
        XCTAssertEqual(rigs(), 0)
    }

    func test_имяКопииНеЗанимаетЧужое() {
        let taken: Set<String> = ["/папка/модель.obj", "/папка/модель 2.obj"]
        XCTAssertEqual(ModelExporter.destination(for: "/папка/модель.fbx", format: .obj,
                                                 exists: { taken.contains($0) }),
                       "/папка/модель 3.obj")
        XCTAssertEqual(ModelExporter.destination(for: "/папка/модель.fbx", format: .usdz,
                                                 exists: { taken.contains($0) }),
                       "/папка/модель.usdz")
    }

    func test_записьВUSDZИOBJ() throws {
        let folder = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-model-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let (scene, _) = boxScene()
        ModelLighting.studio.apply(to: scene, view: nil, radius: 1)
        XCTAssertTrue(ModelExportFormat.available.contains(.usdz))
        for format in ModelExportFormat.available where format == .usdz || format == .obj {
            let path = (folder as NSString).appendingPathComponent("коробка.\(format.rawValue)")
            try ModelExporter.write(scene, to: path, format: format)
            let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
            XCTAssertGreaterThan(size, 0, format.rawValue)
        }
        XCTAssertEqual(scene.rootNode.childNodes.filter { $0.name == "fcxl.lightRig" }.count, 1,
                       "свой свет после записи вернулся на место")
    }

    func test_эскизМоделиНеПустой() throws {
        let (scene, _) = boxScene()
        let image = try XCTUnwrap(ModelSnapshot.image(of: model(scene), side: 64, scale: 1))
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        var opaque = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                opaque += 1
            }
        }
        XCTAssertGreaterThan(opaque, 10, "коробка видна на снимке")
        XCTAssertLessThan(opaque, 256, "фон вокруг прозрачный")
    }
}
