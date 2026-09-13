import AppKit
import FCXLBridgeObjC
import Foundation

/// Одна сетка модели в виде, не зависящем от того, кто её прочитал.
///
/// Нужна ровно потому, что читаем мы модели ОТДЕЛЬНЫМ процессом (см. ModelReaderProcess):
/// одна сторона собирает это из моста, другая — из переданных байтов, и обе потом строят
/// геометрию одним и тем же кодом.
struct Model3DMesh {
    var name: String?
    var materialName: String?
    var vertexCount: Int = 0
    var faceCount: Int = 0
    var positions = Data()
    var normals = Data()
    /// Наборы развёртки по порядку: на них ссылается uvChannel у картинок.
    var uvSets: [Data] = []
    var indices = Data()
    var diffuseColor: NSColor?
    var emissiveColor: NSColor?
    var metallic: Double?
    var roughness: Double?
    var opacity: Double?
    var emissiveStrength: Double?
    /// Картинки по гнёздам: путь (искать по имени рядом с моделью) или сами байты.
    var textures: [String: Model3DTexture] = [:]
}

struct Model3DTexture {
    var path: String?
    var data: Data?
    var uvChannel: Int = 0
}

extension Model3DMesh {
    /// Из того, что отдал мост.
    init(bridge mesh: FCXLModelMesh) {
        name = mesh.name
        materialName = mesh.materialName
        vertexCount = Int(mesh.vertexCount)
        faceCount = Int(mesh.faceCount)
        positions = mesh.positions
        normals = mesh.normals
        uvSets = mesh.texCoordSets.isEmpty
            ? (mesh.texCoords.isEmpty ? [] : [mesh.texCoords])
            : mesh.texCoordSets
        indices = mesh.indices
        diffuseColor = mesh.diffuseColor
        emissiveColor = mesh.emissiveColor
        metallic = mesh.metallic?.doubleValue
        roughness = mesh.roughness?.doubleValue
        opacity = mesh.opacity?.doubleValue
        emissiveStrength = mesh.emissiveStrength?.doubleValue
        textures = mesh.textures.reduce(into: [:]) { result, pair in
            result[pair.key] = Model3DTexture(path: pair.value.path, data: pair.value.data,
                                              uvChannel: pair.value.uvChannel)
        }
    }
}

/// Модель, переданная от читающего процесса к рисующему.
///
/// Свой простой поток байтов, а не JSON или NSKeyedArchiver: геометрия — это мегабайты
/// чисел, и гонять их через текст или архиватор бессмысленно. Формат нарочно скучный:
/// метка, длины, данные — и обратно.
enum ModelBlob {

    static let magic: UInt32 = 0x4C_44_4D_46   // «FMDL»
    static let version: UInt32 = 1

    // MARK: - Запись

    static func encode(_ meshes: [Model3DMesh]) -> Data {
        var out = Data()
        out.appendWord(magic)
        out.appendWord(version)
        out.appendWord(UInt32(meshes.count))
        for mesh in meshes {
            out.appendText(mesh.name)
            out.appendText(mesh.materialName)
            out.appendWord(UInt32(mesh.vertexCount))
            out.appendWord(UInt32(mesh.faceCount))
            out.appendBlock(mesh.positions)
            out.appendBlock(mesh.normals)
            out.appendWord(UInt32(mesh.uvSets.count))
            for set in mesh.uvSets { out.appendBlock(set) }
            out.appendBlock(mesh.indices)
            out.appendColour(mesh.diffuseColor)
            out.appendColour(mesh.emissiveColor)
            for number in [mesh.metallic, mesh.roughness, mesh.opacity, mesh.emissiveStrength] {
                out.appendNumber(number)
            }
            out.appendWord(UInt32(mesh.textures.count))
            for (slot, texture) in mesh.textures.sorted(by: { $0.key < $1.key }) {
                out.appendText(slot)
                out.appendText(texture.path)
                out.appendBlock(texture.data ?? Data())
                out.appendWord(UInt32(max(texture.uvChannel, 0)))
            }
        }
        return out
    }

    // MARK: - Чтение

    static func decode(_ data: Data) -> [Model3DMesh]? {
        var cursor = 0
        guard data.readWord(&cursor) == magic, data.readWord(&cursor) == version,
              let count = data.readWord(&cursor), count < 1_000_000 else { return nil }
        var meshes: [Model3DMesh] = []
        meshes.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
            var mesh = Model3DMesh()
            guard let name = data.readText(&cursor),
                  let materialName = data.readText(&cursor),
                  let vertexCount = data.readWord(&cursor),
                  let faceCount = data.readWord(&cursor),
                  let positions = data.readBlock(&cursor),
                  let normals = data.readBlock(&cursor),
                  let uvCount = data.readWord(&cursor), uvCount < 16
            else { return nil }
            mesh.name = name.isEmpty ? nil : name
            mesh.materialName = materialName.isEmpty ? nil : materialName
            mesh.vertexCount = Int(vertexCount)
            mesh.faceCount = Int(faceCount)
            mesh.positions = positions
            mesh.normals = normals
            for _ in 0..<Int(uvCount) {
                guard let set = data.readBlock(&cursor) else { return nil }
                mesh.uvSets.append(set)
            }
            guard let indices = data.readBlock(&cursor) else { return nil }
            mesh.indices = indices
            mesh.diffuseColor = data.readColour(&cursor)
            mesh.emissiveColor = data.readColour(&cursor)
            mesh.metallic = data.readNumber(&cursor)
            mesh.roughness = data.readNumber(&cursor)
            mesh.opacity = data.readNumber(&cursor)
            mesh.emissiveStrength = data.readNumber(&cursor)
            guard let textureCount = data.readWord(&cursor), textureCount < 64 else { return nil }
            for _ in 0..<Int(textureCount) {
                guard let slot = data.readText(&cursor),
                      let path = data.readText(&cursor),
                      let bytes = data.readBlock(&cursor),
                      let channel = data.readWord(&cursor)
                else { return nil }
                mesh.textures[slot] = Model3DTexture(path: path.isEmpty ? nil : path,
                                                     data: bytes.isEmpty ? nil : bytes,
                                                     uvChannel: Int(channel))
            }
            meshes.append(mesh)
        }
        return meshes
    }
}

// MARK: - Числа и блоки в потоке

private extension Data {

    mutating func appendWord(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendBlock(_ block: Data) {
        appendWord(UInt32(block.count))
        append(block)
    }

    mutating func appendText(_ text: String?) {
        appendBlock(Data((text ?? "").utf8))
    }

    /// Число: признак «есть» и само значение — чтобы отличать ноль от «файл молчит».
    mutating func appendNumber(_ value: Double?) {
        appendWord(value == nil ? 0 : 1)
        var bits = (value ?? 0).bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &bits) { append(contentsOf: $0) }
    }

    mutating func appendColour(_ colour: NSColor?) {
        guard let srgb = colour?.usingColorSpace(.sRGB) else { appendWord(0); return }
        appendWord(1)
        for value in [srgb.redComponent, srgb.greenComponent, srgb.blueComponent,
                      srgb.alphaComponent] {
            var bits = Float(value).bitPattern.littleEndian
            Swift.withUnsafeBytes(of: &bits) { append(contentsOf: $0) }
        }
    }
}

private extension Data {

    func readWord(_ cursor: inout Int) -> UInt32? {
        guard cursor >= 0, cursor + 4 <= count else { return nil }
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(self[startIndex + cursor + index]) << (8 * index) }
        cursor += 4
        return value
    }

    func readBlock(_ cursor: inout Int) -> Data? {
        guard let length = readWord(&cursor), cursor + Int(length) <= count else { return nil }
        let start = startIndex + cursor
        let block = subdata(in: start..<(start + Int(length)))
        cursor += Int(length)
        return block
    }

    func readText(_ cursor: inout Int) -> String? {
        guard let block = readBlock(&cursor) else { return nil }
        return String(data: block, encoding: .utf8) ?? ""
    }

    func readNumber(_ cursor: inout Int) -> Double? {
        guard let present = readWord(&cursor) else { return nil }
        var bits: UInt64 = 0
        guard cursor + 8 <= count else { return nil }
        for index in 0..<8 { bits |= UInt64(self[startIndex + cursor + index]) << (8 * index) }
        cursor += 8
        return present == 1 ? Double(bitPattern: bits) : nil
    }

    func readColour(_ cursor: inout Int) -> NSColor? {
        guard let present = readWord(&cursor) else { return nil }
        guard present == 1 else { return nil }
        var parts: [CGFloat] = []
        for _ in 0..<4 {
            guard cursor + 4 <= count else { return nil }
            var bits: UInt32 = 0
            for index in 0..<4 { bits |= UInt32(self[startIndex + cursor + index]) << (8 * index) }
            cursor += 4
            parts.append(CGFloat(Float(bitPattern: bits)))
        }
        return NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
    }
}
