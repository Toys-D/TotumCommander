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
        rescueMaterials(in: scene, modelURL: url, ext: ext)
        let counts = counted(scene.rootNode)
        return finished(scene: scene, counts: counts, reader: .apple)
    }

    /// Довести материалы до вида, в котором модель видно.
    ///
    /// Две беды, обе замерены на настоящей модели из Blender. Первая: путь к текстуре
    /// внутри файла — с чужой машины (`C:/slug_launcher_baseColor.png`), Model I/O
    /// доносит его до SceneKit как строку, а тот по такому пути ничего не читает —
    /// ищем файл по ИМЕНИ рядом с моделью. Вторая: Model I/O превращает «окружающий
    /// свет» Ka в свечение материала, и белый Ka заливает модель ровным белым — на
    /// снимке был ровно один оттенок. Обе правки — только там, где система не справилась.
    private static func rescueMaterials(in scene: SCNScene, modelURL: URL, ext: String) {
        let finder = ModelTextureFinder(modelFolder: modelURL.deletingLastPathComponent())
        let mtl = ext == "obj" ? wavefrontMaterials(for: modelURL) : [:]
        for material in materials(in: scene.rootNode) {
            let named = material.name.flatMap { mtl[$0] }
            // Своя картинка: либо спасаем ту, что назвала система, либо берём из .mtl.
            if let reference = textReference(material.diffuse.contents),
               let image = finder.image(for: reference) {
                material.diffuse.contents = image
            } else if !(material.diffuse.contents is NSImage),
                      let reference = named?.diffuse,
                      let image = finder.image(for: reference) {
                material.diffuse.contents = image
            } else if !(material.diffuse.contents is NSImage), let colour = named?.diffuseColour {
                material.diffuse.contents = nsColour(colour)
            }
            // Карта нормалей: Model I/O теряет map_Bump по дороге, а без неё модель —
            // гладкая болванка.
            if !(material.normal.contents is NSImage), let reference = named?.normal,
               let image = finder.image(for: reference) {
                material.normal.contents = image
            }
            if let reference = textReference(material.normal.contents),
               let image = finder.image(for: reference) {
                material.normal.contents = image
            }
            // Свечение.
            if let reference = named?.emission ?? textReference(material.emission.contents),
               let image = finder.image(for: reference) {
                material.emission.contents = image
            } else if let colour = named?.emissionColour {
                material.emission.contents = nsColour(colour)
            } else if WavefrontMTL.emissionShouldBeBlack(
                        material: named,
                        currentIsImage: material.emission.contents is NSImage) {
                material.emission.contents = NSColor.black
            }
            if let reference = named?.specular ?? textReference(material.specular.contents),
               let image = finder.image(for: reference) {
                material.specular.contents = image
            }
            // Остальные карты — просто спасаем путь, если система оставила строку.
            for property in [material.metalness, material.roughness, material.ambientOcclusion,
                             material.displacement, material.transparent] {
                if let reference = textReference(property.contents),
                   let image = finder.image(for: reference) {
                    property.contents = image
                }
            }
        }
    }

    /// Ссылка на файл, оставленная системой вместо картинки, — строкой или ссылкой.
    private static func textReference(_ contents: Any?) -> String? {
        switch contents {
        case let text as String: return text.isEmpty ? nil : text
        case let url as URL: return url.path
        case let url as NSURL: return url.path
        default: return nil
        }
    }

    private static func nsColour(_ components: [Double]) -> NSColor {
        NSColor(srgbRed: CGFloat(components.count > 0 ? components[0] : 0),
                green: CGFloat(components.count > 1 ? components[1] : 0),
                blue: CGFloat(components.count > 2 ? components[2] : 0),
                alpha: 1)
    }

    /// Материалы .obj — из файла, на который он сам ссылается (`mtllib`), иначе из
    /// одноимённого рядом.
    private static func wavefrontMaterials(for modelURL: URL) -> [String: WavefrontMaterial] {
        let folder = modelURL.deletingLastPathComponent()
        var candidates: [URL] = []
        if let text = try? String(contentsOf: modelURL, encoding: .utf8),
           let name = WavefrontMTL.materialFileName(inOBJ: text) {
            candidates.append(folder.appendingPathComponent(name))
        }
        candidates.append(modelURL.deletingPathExtension().appendingPathExtension("mtl"))
        for candidate in candidates {
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                let parsed = WavefrontMTL.parse(text)
                if !parsed.isEmpty { return parsed }
            }
        }
        return [:]
    }

    private static func materials(in node: SCNNode) -> [SCNMaterial] {
        var result: [SCNMaterial] = []
        func walk(_ node: SCNNode) {
            result.append(contentsOf: node.geometry?.materials ?? [])
            node.childNodes.forEach(walk)
        }
        walk(node)
        return result
    }

    private static func libraryScene(url: URL) throws -> Model3DScene {
        let meshes: [Model3DMesh]
        do {
            // Читает отдельный процесс: на некоторых файлах разбор падает, и падать
            // должен он, а не файловый менеджер. См. ModelReaderProcess.
            meshes = try ModelReaderProcess.read(path: url.path)
        } catch {
            throw Model3DError.unreadable(reason: reason(for: error))
        }
        let scene = SCNScene()
        let finder = ModelTextureFinder(modelFolder: url.deletingLastPathComponent())
        let glow = GLTFEmissiveStrength.table(forModelAt: url.path)
        for mesh in meshes {
            guard let geometry = geometry(from: mesh, finder: finder, glow: glow) else { continue }
            scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        }
        let counts = (meshes: meshes.count,
                      vertices: meshes.reduce(0) { $0 + $1.vertexCount },
                      faces: meshes.reduce(0) { $0 + $1.faceCount })
        guard counts.meshes > 0 else { throw Model3DError.unreadable(reason: "no meshes") }
        return finished(scene: scene, counts: counts, reader: .library)
    }

    /// Отчего не прочиталось — словами, которые что-то значат для человека.
    private static func reason(for error: Error) -> String {
        switch error {
        case ModelReaderProcess.Failure.died(let how):
            return L("viewer.model.readerDied") + " (" + how + ")"
        case ModelReaderProcess.Failure.timedOut:
            return L("viewer.model.readerSlow")
        default:
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Из сырых чисел — геометрия SceneKit.
    private static func geometry(from mesh: Model3DMesh, finder: ModelTextureFinder,
                                glow: [String: Double] = [:]) -> SCNGeometry? {
        let vertices = mesh.vertexCount
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
        // Все наборы развёртки, а не только первый: разные карты пользуются разными
        // наборами. У этой машины цвет фонаря лежит в наборе 0, а красное стекло —
        // в наборе 1; наложишь вторым набором первый — фонарь останется белым.
        let uvSets = mesh.uvSets
        for set in uvSets where !set.isEmpty {
            sources.append(SCNGeometrySource(data: set, semantic: .texcoord,
                                             vectorCount: vertices, usesFloatComponents: true,
                                             componentsPerVector: 2, bytesPerComponent: 4,
                                             dataOffset: 0, dataStride: 8))
        }
        let element = SCNGeometryElement(data: mesh.indices, primitiveType: .triangles,
                                         primitiveCount: mesh.faceCount, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.name = mesh.materialName
        material.lightingModel = .physicallyBased
        material.isDoubleSided = true    // у половины моделей нормали смотрят внутрь
        if let colour = mesh.diffuseColor { material.diffuse.contents = colour }
        // Дальше, если у материала есть картинка цвета, она заменит этот цвет — уже
        // умноженная на него.
        // Числа материала: без металличности и шероховатости физически верный материал
        // выходит матовой болванкой — чёрный кузов «металлик» так и остаётся чёрным
        // силуэтом, сколько света вокруг ни ставь.
        if let metallic = mesh.metallic { material.metalness.contents = metallic }
        if let roughness = mesh.roughness { material.roughness.contents = roughness }
        if let opacity = mesh.opacity, opacity < 0.999 { material.transparency = CGFloat(opacity) }
        if let emissive = mesh.emissiveColor?.usingColorSpace(.sRGB),
           emissive.brightnessComponent > 0.01 {
            material.emission.contents = emissive
        }
        // Сила свечения из файла: у стекла фонаря она бывает десятикратной, и без неё
        // красное стекло еле теплится. Выше разумного не поднимаем — иначе кадр
        // засвечивается в белое.
        if let strength = mesh.emissiveStrength, strength > 1 {
            material.emission.intensity = CGFloat(min(strength, 6))
        }
        // Карты по гнёздам. Путь может быть и с чужой машины, и внутрь файла — обе
        // возможности разбирает texture(_:folder:).
        let slots: [(String, SCNMaterialProperty)] = [
            (FCXLModelTextureBaseColor, material.diffuse),
            (FCXLModelTextureNormal, material.normal),
            (FCXLModelTextureEmissive, material.emission),
            (FCXLModelTextureRoughness, material.roughness),
            (FCXLModelTextureMetallic, material.metalness),
            (FCXLModelTextureOcclusion, material.ambientOcclusion),
            (FCXLModelTextureSpecular, material.specular)
        ]
        for (slot, property) in slots {
            if let texture = mesh.textures[slot],
               var image = self.image(for: texture, finder: finder) {
                // Свой цвет материала умножается на картинку, а не заменяется ею: у стекла
                // фонаря картинка белая, а цвет чёрный — красным его делает свечение
                // поверх. Без умножения фонарь выходил белым пятном.
                if slot == FCXLModelTextureBaseColor, let tint = mesh.diffuseColor,
                   let tinted = ModelTextureRescue.tinted(image, by: tint) {
                    image = tinted
                }
                // Сила свечения из файла — запечённая в картинку: иначе красное стекло
                // фонаря остаётся тёмным (см. GLTFEmissiveStrength).
                if slot == FCXLModelTextureEmissive,
                   let strength = mesh.materialName.flatMap({ glow[$0] }) ?? mesh.emissiveStrength,
                   let brighter = ModelTextureRescue.brightened(image,
                                                                by: CGFloat(min(strength, 8))) {
                    image = brighter
                }
                property.contents = image
                // Каким набором развёртки накладывать — так, как сказал файл.
                property.mappingChannel = max(0, min(texture.uvChannel, uvSets.count - 1))
            }
            // Развёртка у моделей часто выходит за 0…1; при обрезке (так у SceneKit по
            // умолчанию) край картинки размазывается по всей поверхности.
            property.wrapS = .repeat
            property.wrapT = .repeat
        }
        geometry.materials = [material]
        geometry.name = mesh.name
        return geometry
    }

    /// Картинка гнезда: вшитая в файл — из байтов, иначе ищем по имени рядом с моделью.
    private static func image(for texture: Model3DTexture,
                              finder: ModelTextureFinder) -> NSImage? {
        if let data = texture.data, let image = NSImage(data: data) { return image }
        if let path = texture.path { return finder.image(for: path) }
        return nil
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

    /// Свет вокруг модели.
    ///
    /// Без него зеркальные и металлические материалы не видно вовсе: физически верный
    /// материал показывает то, что ОТРАЖАЕТ, а отражать нечего — и машина с кузовом
    /// «металлик» выходит чёрным силуэтом. Замерено на настоящей модели: средняя яркость
    /// снимка 10 из 255.
    ///
    /// Поэтому даём сцене простое окружение: светлее сверху, темнее снизу — как небо над
    /// землёй. Своё окружение файла (бывает в usdz) не трогаем.
    /// Шесть граней куба окружения: небо сверху, земля снизу, по бокам — переход.
    ///
    /// Именно куб, а не одна картинка: SceneKit принимает в окружение либо готовую
    /// кубическую карту (шесть изображений), либо развёртку — одиночную картинку он
    /// молча не берёт, и свет не меняется вовсе (проверено: средняя яркость снимка та же).
    static func environmentCube(size: Int = 64) -> [NSImage] {
        func face(_ top: CGFloat, _ bottom: CGFloat) -> NSImage {
            let image = NSImage(size: NSSize(width: size, height: size))
            image.lockFocus()
            if top == bottom {
                NSColor(white: top, alpha: 1).setFill()
                NSRect(x: 0, y: 0, width: size, height: size).fill()
            } else {
                NSGradient(starting: NSColor(white: bottom, alpha: 1),
                           ending: NSColor(white: top, alpha: 1))?
                    .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: 90)
            }
            image.unlockFocus()
            return image
        }
        // Значения подобраны замером: слишком яркое окружение засвечивает матовую
        // модель в ровное белое пятно, слишком тусклое оставляет зеркальную чёрной.
        let side = face(Self.environmentSky, Self.environmentGround)
        return [side, side, face(Self.environmentSky, Self.environmentSky),   // +X, -X, +Y
                face(Self.environmentGround, Self.environmentGround), side, side]  // -Y, +Z, -Z
    }

    /// Подобрано замером на трёх настоящих моделях (чёрная машина «металлик», белая
    /// матовая фигура, оружие с текстурами): ярче — матовое выцветает в ровное пятно,
    /// тусклее — зеркальное остаётся чёрным силуэтом.
    static let environmentSky: CGFloat = 0.9
    static let environmentGround: CGFloat = 0.25
    static let environmentIntensity: CGFloat = 1.8

    /// Камера для модели — одна на просмотрщик и на проверки, чтобы «как в тесте» и «как
    /// на экране» не расходились.
    ///
    /// Плёночная кривая (wantsHDR) здесь не роскошь: без неё яркое место просто упирается
    /// в белое. Замерено — белая матовая модель без неё даёт РОВНО ОДИН оттенок на
    /// снимке: всё, что светлее единицы, обрезается в чистый белый, и формы не видно.
    static func camera(for model: Model3DScene) -> SCNNode {
        let distance = cameraDistance(radius: model.radius)
        let camera = SCNCamera()
        camera.fieldOfView = 60
        // Ближнюю и дальнюю границы тоже от размера: постоянные 1 и 100 режут и мелкую
        // модель, и крупную.
        camera.zNear = Double(distance) / 100
        camera.zFar = Double(distance) * 20
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false   // подстройка «на глаз» мешает сравнивать
        camera.whitePoint = 1.6
        camera.bloomIntensity = 0
        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(model.center.x, model.center.y,
                                   model.center.z + CGFloat(distance))
        node.look(at: model.center)
        return node
    }

    private static func lightScene(_ scene: SCNScene) {
        guard scene.lightingEnvironment.contents == nil else { return }
        scene.lightingEnvironment.contents = environmentCube()
        scene.lightingEnvironment.intensity = environmentIntensity
    }

    private static func finished(scene: SCNScene,
                                 counts: (meshes: Int, vertices: Int, faces: Int),
                                 reader: Model3DReader) -> Model3DScene {
        lightScene(scene)
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
