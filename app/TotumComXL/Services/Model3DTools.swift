import AppKit
import ModelIO
import SceneKit
import SceneKit.ModelIO
import simd

// Всё, что просмотрщик делает с уже прочитанной моделью: снимок для эскиза, размеры,
// дерево узлов, анимация, свет и фон, запись в другой формат. Без вида — чтобы каждое
// правило можно было проверить на настоящей сцене в тесте.

// MARK: - Эскиз

/// Эскиз модели для вида «Эскизы»: модель читается тем же путём, что и в просмотрщике,
/// и снимается за кадром.
///
/// По одной за раз: папка с сотней моделей иначе подняла бы сотню чтений сразу, и каждое
/// тянет модель целиком в память.
actor ModelThumbnailer {
    static let shared = ModelThumbnailer()

    /// Крупнее этого эскиз не делаем: чтение длится секунды, а панель листают быстро.
    static let sizeLimit = 40 * 1024 * 1024

    func thumbnail(path: String, side: CGFloat) -> NSImage? {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?
            .intValue ?? 0
        guard size > 0, size <= Self.sizeLimit,
              let model = try? Model3DLoader.load(path: path) else { return nil }
        return ModelSnapshot.image(of: model, side: side)
    }
}

enum ModelSnapshot {
    /// Модель на прозрачном фоне, вид чуть сверху и сбоку — так её узнают с одного
    /// взгляда; спереди в упор многие модели выглядят плоским силуэтом.
    static func image(of model: Model3DScene, side: CGFloat, scale: CGFloat = 2) -> NSImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        model.scene.background.contents = NSColor.clear
        renderer.scene = model.scene
        renderer.autoenablesDefaultLighting = true
        renderer.pointOfView = angledCamera(for: model)
        let pixels = CGSize(width: side * scale, height: side * scale)
        let image = renderer.snapshot(atTime: 0, with: pixels, antialiasingMode: .multisampling4X)
        image.size = NSSize(width: side, height: side)
        return image
    }

    static func angledCamera(for model: Model3DScene) -> SCNNode {
        let node = Model3DLoader.camera(for: model)
        let distance = Float(Model3DLoader.cameraDistance(radius: model.radius))
        let direction = simd_normalize(SIMD3<Float>(0.8, 0.6, 1.4))
        let center = SIMD3<Float>(Float(model.center.x), Float(model.center.y), Float(model.center.z))
        node.simdPosition = center + direction * distance
        node.look(at: model.center)
        return node
    }
}

// MARK: - Размеры

/// Размеры модели в её собственных единицах: габариты, площадь поверхности, объём.
///
/// Единицы — те, в которых модель записана: у одних это метры, у других миллиметры,
/// а файл часто об этом молчит. Поэтому числа даются как есть, без подписи «м».
struct ModelMeasurements: Equatable {
    var width: Double
    var height: Double
    var depth: Double
    var area: Double
    /// Объём по знаковым тетраэдрам — верен для замкнутой поверхности; у открытой сетки
    /// (плоскость, лист) это просто число, поэтому подпись говорит «≈».
    var volume: Double
    var triangles: Int

    static func measure(_ root: SCNNode) -> ModelMeasurements {
        var low = SIMD3<Double>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
        var area = 0.0, volume = 0.0, triangles = 0

        func walk(_ node: SCNNode) {
            if let geometry = node.geometry,
               let points = positions(of: geometry) {
                let transform = node.simdWorldTransform
                let world = points.map { point -> SIMD3<Double> in
                    let moved = transform * SIMD4<Float>(Float(point.x), Float(point.y), Float(point.z), 1)
                    return SIMD3<Double>(Double(moved.x), Double(moved.y), Double(moved.z))
                }
                for point in world {
                    low = simd_min(low, point)
                    high = simd_max(high, point)
                }
                for element in geometry.elements {
                    for (a, b, c) in Self.triangles(of: element) where a < world.count && b < world.count && c < world.count {
                        let p0 = world[a], p1 = world[b], p2 = world[c]
                        area += simd_length(simd_cross(p1 - p0, p2 - p0)) / 2
                        volume += simd_dot(p0, simd_cross(p1, p2)) / 6
                        triangles += 1
                    }
                }
            }
            node.childNodes.forEach(walk)
        }
        walk(root)
        guard low.x <= high.x else {
            return ModelMeasurements(width: 0, height: 0, depth: 0, area: 0, volume: 0, triangles: 0)
        }
        let span = high - low
        return ModelMeasurements(width: span.x, height: span.y, depth: span.z,
                                 area: area, volume: abs(volume), triangles: triangles)
    }

    /// Точки сетки, какой бы ширины числа в ней ни лежали.
    static func positions(of geometry: SCNGeometry) -> [SIMD3<Double>]? {
        guard let source = geometry.sources(for: .vertex).first,
              source.componentsPerVector >= 3, source.usesFloatComponents else { return nil }
        let data = source.data
        let count = source.vectorCount
        let stride = source.dataStride
        let offset = source.dataOffset
        let width = source.bytesPerComponent
        guard width == 4 || width == 8 else { return nil }
        var points: [SIMD3<Double>] = []
        points.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let base = offset + index * stride
                guard base + width * 3 <= raw.count else { break }
                if width == 4 {
                    points.append(SIMD3<Double>(
                        Double(raw.loadUnaligned(fromByteOffset: base, as: Float.self)),
                        Double(raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self)),
                        Double(raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self))))
                } else {
                    points.append(SIMD3<Double>(
                        raw.loadUnaligned(fromByteOffset: base, as: Double.self),
                        raw.loadUnaligned(fromByteOffset: base + 8, as: Double.self),
                        raw.loadUnaligned(fromByteOffset: base + 16, as: Double.self)))
                }
            }
        }
        return points
    }

    /// Треугольники элемента. Многоугольники (так Model I/O отдаёт четырёхугольники OBJ)
    /// режутся веером; линии и точки поверхности не имеют.
    static func triangles(of element: SCNGeometryElement) -> [(Int, Int, Int)] {
        let indices = Self.indices(of: element)
        switch element.primitiveType {
        case .triangles:
            return stride(from: 0, to: indices.count - 2, by: 3).map { (indices[$0], indices[$0 + 1], indices[$0 + 2]) }
        case .triangleStrip:
            guard indices.count >= 3 else { return [] }
            return (0..<(indices.count - 2)).map { i in
                i % 2 == 0 ? (indices[i], indices[i + 1], indices[i + 2])
                           : (indices[i + 1], indices[i], indices[i + 2])
            }
        case .polygon:
            // Сначала число углов каждого многоугольника, следом сами вершины.
            let polygons = element.primitiveCount
            guard indices.count >= polygons else { return [] }
            var result: [(Int, Int, Int)] = []
            var cursor = polygons
            for p in 0..<polygons {
                let corners = indices[p]
                guard corners >= 3, cursor + corners <= indices.count else { cursor += max(corners, 0); continue }
                for k in 1..<(corners - 1) {
                    result.append((indices[cursor], indices[cursor + k], indices[cursor + k + 1]))
                }
                cursor += corners
            }
            return result
        default:
            return []
        }
    }

    static func indices(of element: SCNGeometryElement) -> [Int] {
        let width = element.bytesPerIndex
        let data = element.data
        guard width > 0 else { return [] }
        let count = data.count / width
        var result: [Int] = []
        result.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                switch width {
                case 1: result.append(Int(raw.load(fromByteOffset: i, as: UInt8.self)))
                case 2: result.append(Int(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)))
                case 4: result.append(Int(raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
                default: result.append(Int(raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)))
                }
            }
        }
        return result
    }

    /// Число в подписи: три значащие цифры хватает и миллиметрам, и километрам.
    static func number(_ value: Double) -> String {
        guard value.isFinite, value != 0 else { return "0" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 4
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - Дерево узлов и материалы

/// Глазки узлов, проведённые мышью: нажал на глазок и повёл — все глазки, над которыми
/// прошла мышь, становятся такими же, как первый после щелчка. Первый решает: был виден —
/// всё пройденное прячется, был скрыт — показывается. Пройденное копится: вернулся назад —
/// уже переключённые так и остаются.
struct ModelVisibilitySweep: Equatable {
    /// Прятать (true) или показывать.
    let hide: Bool
    private(set) var rows: ClosedRange<Int>

    init(from row: Int, wasHidden: Bool) {
        hide = !wasHidden
        rows = row...row
    }

    mutating func reach(_ row: Int) {
        rows = min(rows.lowerBound, row)...max(rows.upperBound, row)
    }

    /// Строка под мышью в списке строк одной высоты; ниже последней — последняя, выше первой —
    /// первая: мышь, ушедшая за край, тянет до края.
    static func row(at y: CGFloat, rowHeight: CGFloat, count: Int) -> Int {
        min(max(Int((y / rowHeight).rounded(.down)), 0), max(count - 1, 0))
    }
}

/// Строка бокового списка: узел сцены с его глубиной и тем, есть ли у него сетка.
struct ModelNodeRow: Identifiable {
    let id: ObjectIdentifier
    let node: SCNNode
    let depth: Int
    let title: String
    let hasMesh: Bool

    /// Узлы сверху вниз. Пустые ветки без единой сетки внутри не показываются — это служебные
    /// узлы читателя, человеку в них смотреть не на что.
    static func rows(of root: SCNNode) -> [ModelNodeRow] {
        var result: [ModelNodeRow] = []
        func holdsMesh(_ node: SCNNode) -> Bool {
            node.geometry != nil || node.childNodes.contains(where: holdsMesh)
        }
        func walk(_ node: SCNNode, depth: Int) {
            guard holdsMesh(node), node.camera == nil else { return }
            let name = node.name.flatMap { $0.isEmpty ? nil : $0 }
                ?? node.geometry?.name.flatMap { $0.isEmpty ? nil : $0 }
                ?? L("viewer.model.unnamed")
            result.append(ModelNodeRow(id: ObjectIdentifier(node), node: node, depth: depth,
                                       title: name, hasMesh: node.geometry != nil))
            node.childNodes.forEach { walk($0, depth: depth + 1) }
        }
        root.childNodes.forEach { walk($0, depth: 0) }
        return result
    }
}

struct ModelMaterialRow: Identifiable {
    let id: ObjectIdentifier
    let title: String
    /// Основной цвет, если он задан цветом; у текстурного материала — nil.
    let colour: NSColor?
    let hasTexture: Bool

    static func rows(of root: SCNNode) -> [ModelMaterialRow] {
        var seen: Set<ObjectIdentifier> = []
        var result: [ModelMaterialRow] = []
        func walk(_ node: SCNNode) {
            for material in node.geometry?.materials ?? [] where seen.insert(ObjectIdentifier(material)).inserted {
                let contents = material.diffuse.contents
                result.append(ModelMaterialRow(
                    id: ObjectIdentifier(material),
                    title: material.name.flatMap { $0.isEmpty ? nil : $0 } ?? L("viewer.model.unnamed"),
                    colour: contents as? NSColor,
                    hasTexture: contents is NSImage || contents is URL || contents is String
                        || contents is MDLTexture))
            }
            node.childNodes.forEach(walk)
        }
        walk(root)
        return result
    }
}

// MARK: - Анимация

/// Анимации сцены, переведённые на время сцены: тогда полоса воспроизведения ставит
/// модель в любой момент, а «Пауза» останавливает всё сразу.
enum ModelAnimation {
    /// Длительность самой долгой анимации; 0 — анимаций нет.
    @discardableResult
    static func prepare(_ root: SCNNode) -> TimeInterval {
        var longest: TimeInterval = 0
        func walk(_ node: SCNNode) {
            for key in node.animationKeys {
                guard let player = node.animationPlayer(forKey: key) else { continue }
                player.animation.usesSceneTimeBase = true
                player.animation.repeatCount = .greatestFiniteMagnitude
                player.play()
                let duration = player.animation.duration
                if duration.isFinite { longest = max(longest, duration) }
            }
            node.childNodes.forEach(walk)
        }
        walk(root)
        return longest
    }
}

// MARK: - Свет и фон

enum ModelLighting: String, CaseIterable {
    /// Как было: свет SceneKit по умолчанию и окружение, которое ставит Model3DLoader.
    case standard
    /// Три источника — ключевой, заполняющий и контровой: форма читается лучше.
    case studio
    /// Ровный свет без теней — чтобы разглядеть цвет и текстуры.
    case flat

    var titleKey: String { "viewer.model.light.\(rawValue)" }

    static let key = "fcxl.model.lighting"
    private static let rigName = "fcxl.lightRig"

    /// Поставить свет в сцену. Свои источники живут в одном узле, который снимается
    /// и ставится заново, — чужие источники модели не трогаются.
    func apply(to scene: SCNScene, view: SCNView?, radius: CGFloat) {
        scene.rootNode.childNodes(passingTest: { node, _ in node.name == Self.rigName })
            .forEach { $0.removeFromParentNode() }
        view?.autoenablesDefaultLighting = self == .standard
        guard self != .standard else { return }
        let rig = SCNNode()
        rig.name = Self.rigName
        let distance = Float(max(radius, 0.001) * 4)
        func light(_ type: SCNLight.LightType, intensity: CGFloat, at direction: SIMD3<Float>?) {
            let light = SCNLight()
            light.type = type
            light.intensity = intensity
            let node = SCNNode()
            node.light = light
            if let direction {
                node.simdPosition = simd_normalize(direction) * distance
                node.simdLook(at: .zero)
            }
            rig.addChildNode(node)
        }
        switch self {
        case .studio:
            light(.directional, intensity: 1000, at: SIMD3(1, 1.2, 1.5))
            light(.directional, intensity: 400, at: SIMD3(-1.5, 0.3, 0.8))
            light(.directional, intensity: 600, at: SIMD3(0, 1, -1.5))
            light(.ambient, intensity: 200, at: nil)
        case .flat:
            light(.ambient, intensity: 1000, at: nil)
        case .standard:
            break
        }
        scene.rootNode.addChildNode(rig)
    }
}

enum ModelBackdrop: String, CaseIterable {
    /// Цвет окна — сам переворачивается со сменой темы.
    case window
    case dark
    case light
    /// Мягкий серый перелив, как на студийном фоне.
    case studio

    var titleKey: String { "viewer.model.backdrop.\(rawValue)" }

    static let key = "fcxl.model.backdrop"

    var colour: NSColor {
        switch self {
        case .window: return .windowBackgroundColor
        case .dark: return NSColor(white: 0.12, alpha: 1)
        case .light: return NSColor(white: 0.95, alpha: 1)
        case .studio: return NSColor(white: 0.5, alpha: 1)
        }
    }

    /// Перелив для «студии» — картинкой: SceneKit берёт фон сцены из картинки как есть.
    static func studioGradient() -> NSImage {
        let size = NSSize(width: 4, height: 256)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: NSColor(white: 0.78, alpha: 1), ending: NSColor(white: 0.32, alpha: 1))?
            .draw(in: NSRect(origin: .zero, size: size), angle: 270)
        image.unlockFocus()
        return image
    }

    func apply(to scene: SCNScene, view: SCNView?) {
        if self == .studio {
            scene.background.contents = Self.studioGradient()
            view?.backgroundColor = colour
        } else {
            scene.background.contents = nil
            view?.backgroundColor = colour
        }
    }
}

// MARK: - Запись в другой формат

enum ModelExportFormat: String, CaseIterable {
    case usdz, obj, stl, ply

    var title: String { rawValue.uppercased() }

    /// Что этот Мак умеет записать: USDZ пишет SceneKit, остальное — Model I/O, и его
    /// спрашиваем, а не верим списку.
    static var available: [ModelExportFormat] {
        allCases.filter { $0 == .usdz || MDLAsset.canExportFileExtension($0.rawValue) }
    }
}

enum ModelExporter {
    enum Failure: LocalizedError {
        case cannotWrite(String)
        var errorDescription: String? {
            switch self {
            case .cannotWrite(let name): return String(format: L("viewer.model.saveFailed"), name)
            }
        }
    }

    /// Рядом с моделью, под тем же именем с новым расширением; занятое имя получает номер.
    static func destination(for path: String, format: ModelExportFormat,
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var candidate = (folder as NSString).appendingPathComponent("\(stem).\(format.rawValue)")
        var index = 2
        while exists(candidate) {
            candidate = (folder as NSString).appendingPathComponent("\(stem) \(index).\(format.rawValue)")
            index += 1
        }
        return candidate
    }

    static func write(_ scene: SCNScene, to path: String, format: ModelExportFormat) throws {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        // Свой свет — не часть модели: снимаем на время записи.
        let rigs = scene.rootNode.childNodes.filter { $0.name == "fcxl.lightRig" }
        rigs.forEach { $0.removeFromParentNode() }
        let background = scene.background.contents
        scene.background.contents = nil
        defer {
            rigs.forEach { scene.rootNode.addChildNode($0) }
            scene.background.contents = background
        }
        switch format {
        case .usdz:
            guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
                throw Failure.cannotWrite(name)
            }
        default:
            let asset = MDLAsset(scnScene: scene)
            do { try asset.export(to: url) } catch { throw Failure.cannotWrite(name) }
        }
        guard FileManager.default.fileExists(atPath: path) else { throw Failure.cannotWrite(name) }
    }
}
