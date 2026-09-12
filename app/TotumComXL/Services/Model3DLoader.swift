import AppKit
import FCXLBridgeObjC
import ModelIO
import SceneKit
import SceneKit.ModelIO

/// Кто читает какой формат модели.
///
/// Не одно и то же «умеем показывать» и «умеем читать сами»: половину форматов macOS
/// разбирает своими силами, и там, где так, мы идём этим путём — быстрее и с материалами
/// в придачу. Остальное читает Assimp (BSD/MIT — с нашей лицензией совместимо).
enum Model3DReader: String, Equatable {
    /// Model I/O и SceneKit — фреймворки самой системы.
    case apple
    /// Assimp — через мост FCXLModelBridge.
    case library
}

/// Какие файлы просмотрщик берётся показывать как трёхмерную модель.
enum Model3DFormats {

    /// Что macOS читает сам. Замерено на машине автора: `MDLAsset.canImportFileExtension`
    /// отвечает «да» на obj, stl, ply, abc, usd, usda, usdc, usdz; dae и scn читает
    /// SceneKit (проверено на системном файле Collada).
    static let appleExtensions: Set<String> = [
        "obj", "stl", "ply", "abc",
        "usd", "usda", "usdc", "usdz",
        "dae", "scn"
    ]

    /// Что добавляет библиотека. Список выписан здесь, а не взят у неё целиком, намеренно:
    /// она заявляет и `xml`, и `raw`, и `mesh` — расширения, которые в файловом
    /// менеджере значат совсем другое, и отдать их просмотрщику моделей нельзя. Здесь —
    /// только то, что однозначно модель. Что библиотека их и правда читает, проверяет тест.
    static let libraryExtensions: Set<String> = [
        "gltf", "glb",                  // glTF 2.0 — главный формат обмена сегодня
        "fbx", "3ds", "ase",            // Autodesk
        "blend",                        // Blender
        "3mf", "amf",                   // печать
        "x3d", "x3db", "zae", "x",      // сетевые и старые обменные
        "lwo", "lws", "lxo",            // LightWave / modo
        "ms3d", "md2", "md3", "md5mesh", "mdl", "smd", "iqm",   // игровые
        "pmx", "vrm",                   // персонажи
        "cob", "sib", "off", "ac", "ac3d", "b3d", "ter", "q3o", "q3s", "irrmesh", "ogex",
        "step", "stp", "ifc", "ifczip"  // обмен с САПР: геометрия без чертёжной обвязки
    ]

    static var all: Set<String> { appleExtensions.union(libraryExtensions) }

    /// Расширение — в нижнем регистре и без точки.
    static func normalized(_ ext: String) -> String {
        ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    static func isModel(extension ext: String) -> Bool {
        all.contains(normalized(ext))
    }

    /// Кем читать. nil — не наш файл.
    static func reader(forExtension ext: String) -> Model3DReader? {
        let key = normalized(ext)
        if appleExtensions.contains(key) { return .apple }
        if libraryExtensions.contains(key) { return .library }
        return nil
    }
}

/// Прочитанная модель: сцена для SceneKit и то, что стоит сказать о ней человеку.
struct Model3DScene {
    let scene: SCNScene
    let meshCount: Int
    let vertexCount: Int
    let faceCount: Int
    let reader: Model3DReader
    /// Радиус модели и её середина — по ним ставится камера.
    let radius: CGFloat
    let center: SCNVector3
}

enum Model3DLoader {

    /// Выше этого файл не открываем: модель читается целиком в память, и полугигабайтная
    /// сборка съест её всю, ничего не показав. Лучше честно сказать, чем повесить окно.
    static let sizeLimit: Int = 512 * 1024 * 1024

    static func isTooBig(size: Int, limit: Int = sizeLimit) -> Bool { size > limit }

    /// Насколько отвести камеру, чтобы модель радиуса `radius` вошла в кадр целиком.
    ///
    /// Чистая тригонометрия: половина модели должна попасть в половину угла обзора.
    /// Запас нужен, иначе модель упирается в рамки кадра.
    static func cameraDistance(radius: CGFloat, fovDegrees: CGFloat = 60,
                               margin: CGFloat = 1.25) -> CGFloat {
        let safeRadius = max(radius, 0.001)
        let fov = max(min(fovDegrees, 170), 1) * .pi / 180
        return safeRadius / tan(fov / 2) * max(margin, 1)
    }

    // MARK: - Чтение

    static func load(path: String) throws -> Model3DScene {
        let url = URL(fileURLWithPath: path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if isTooBig(size: size) { throw Model3DError.tooBig(size: size) }
        let ext = Model3DFormats.normalized(url.pathExtension)
        guard let reader = Model3DFormats.reader(forExtension: ext) else {
            throw Model3DError.unsupported(ext: ext)
        }

        if reader == .apple {
            // Системный путь. Если он вернул пустую сцену — не сдаёмся, а пробуем
            // библиотекой: битый OBJ Model I/O читает «успешно», но без единой сетки.
            if let scene = try? appleScene(url: url, ext: ext), scene.meshCount > 0 {
                return scene
            }
            if let fallback = try? libraryScene(url: url) { return fallback }
            return try appleScene(url: url, ext: ext)
        }
        return try libraryScene(url: url)
    }

    private static func appleScene(url: URL, ext: String) throws -> Model3DScene {
        let scene: SCNScene
        if ext == "scn" || ext == "dae" {
            scene = try SCNScene(url: url, options: nil)
        } else {
            let asset = MDLAsset(url: url)
            asset.loadTextures()
            scene = SCNScene(mdlAsset: asset)
        }
        let counts = counted(scene.rootNode)
        return finished(scene: scene, counts: counts, reader: .apple)
    }

    private static func libraryScene(url: URL) throws -> Model3DScene {
        let loaded: FCXLModelScene
        do {
            loaded = try FCXLModelBridge.loadModel(atPath: url.path)
        } catch {
            throw Model3DError.unreadable(reason: error.localizedDescription)
        }
        let scene = SCNScene()
        let folder = url.deletingLastPathComponent()
        for mesh in loaded.meshes {
            guard let geometry = geometry(from: mesh, folder: folder) else { continue }
            scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        }
        let counts = (meshes: loaded.meshes.count,
                      vertices: Int(loaded.vertexCount),
                      faces: Int(loaded.faceCount))
        guard counts.meshes > 0 else { throw Model3DError.unreadable(reason: "no meshes") }
        return finished(scene: scene, counts: counts, reader: .library)
    }

    /// Из сырых чисел моста — геометрия SceneKit.
    private static func geometry(from mesh: FCXLModelMesh, folder: URL) -> SCNGeometry? {
        let vertices = Int(mesh.vertexCount)
        guard vertices > 0, mesh.faceCount > 0, !mesh.positions.isEmpty else { return nil }
        var sources = [SCNGeometrySource(data: mesh.positions, semantic: .vertex,
                                         vectorCount: vertices, usesFloatComponents: true,
                                         componentsPerVector: 3, bytesPerComponent: 4,
                                         dataOffset: 0, dataStride: 12)]
        if !mesh.normals.isEmpty {
            sources.append(SCNGeometrySource(data: mesh.normals, semantic: .normal,
                                             vectorCount: vertices, usesFloatComponents: true,
                                             componentsPerVector: 3, bytesPerComponent: 4,
                                             dataOffset: 0, dataStride: 12))
        }
        if !mesh.texCoords.isEmpty {
            sources.append(SCNGeometrySource(data: mesh.texCoords, semantic: .texcoord,
                                             vectorCount: vertices, usesFloatComponents: true,
                                             componentsPerVector: 2, bytesPerComponent: 4,
                                             dataOffset: 0, dataStride: 8))
        }
        let element = SCNGeometryElement(data: mesh.indices, primitiveType: .triangles,
                                         primitiveCount: Int(mesh.faceCount), bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.isDoubleSided = true    // у половины моделей нормали смотрят внутрь
        if let colour = mesh.diffuseColor { material.diffuse.contents = colour }
        // Картинка материала: сперва вшитая в файл (так делает .glb), иначе — рядом с ним.
        if let data = mesh.textureData, let image = NSImage(data: data) {
            material.diffuse.contents = image
        } else if let relative = mesh.texturePath {
            let file = folder.appendingPathComponent(relative)
            if let image = NSImage(contentsOf: file) { material.diffuse.contents = image }
        }
        geometry.materials = [material]
        geometry.name = mesh.name
        return geometry
    }

    private static func counted(_ node: SCNNode) -> (meshes: Int, vertices: Int, faces: Int) {
        var meshes = 0, vertices = 0, faces = 0
        func walk(_ node: SCNNode) {
            if let geometry = node.geometry {
                meshes += 1
                vertices += geometry.sources(for: .vertex).first?.vectorCount ?? 0
                faces += geometry.elements.reduce(0) { $0 + $1.primitiveCount }
            }
            node.childNodes.forEach(walk)
        }
        walk(node)
        return (meshes, vertices, faces)
    }

    private static func finished(scene: SCNScene,
                                 counts: (meshes: Int, vertices: Int, faces: Int),
                                 reader: Model3DReader) -> Model3DScene {
        let (minimum, maximum) = scene.rootNode.boundingBox
        let center = SCNVector3((minimum.x + maximum.x) / 2,
                                (minimum.y + maximum.y) / 2,
                                (minimum.z + maximum.z) / 2)
        let span = SCNVector3(maximum.x - minimum.x, maximum.y - minimum.y, maximum.z - minimum.z)
        let radius = CGFloat(max(max(span.x, span.y), span.z)) / 2
        return Model3DScene(scene: scene, meshCount: counts.meshes, vertexCount: counts.vertices,
                            faceCount: counts.faces, reader: reader,
                            radius: max(radius, 0.001), center: center)
    }
}

enum Model3DError: LocalizedError, Equatable {
    case unsupported(ext: String)
    case unreadable(reason: String)
    case tooBig(size: Int)

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext):
            return String(format: L("viewer.model.unsupported"), ext)
        case .unreadable(let reason):
            return reason.isEmpty
                ? L("viewer.model.unreadable")
                : L("viewer.model.unreadable") + " (" + reason + ")"
        case .tooBig(let size):
            return String(format: L("viewer.model.tooBig"), ByteText.file(Int64(size)))
        }
    }
}
