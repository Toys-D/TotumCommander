import AppKit
import Foundation

/// Где искать картинку материала, когда путь внутри модели ведёт не туда.
///
/// Модели приходят с чужих машин, и путь к текстуре в них записан так, как он выглядел
/// ТАМ. Blender под Windows пишет в .mtl буквально `map_Kd C:/slug_launcher_baseColor.png`
/// — на Mac такого пути нет, картинка не находится, и модель выходит белой, хотя все
/// текстуры лежат рядом с ней в той же папке. Замерено на настоящей модели: Model I/O
/// честно доносит эту строку до SceneKit, а тот не может по ней ничего прочитать.
///
/// Поэтому ищем не путь, а ИМЯ файла — рядом с моделью и в папках, где текстуры принято
/// держать.
enum ModelTextureRescue {

    /// Папки рядом с моделью, куда стоит заглянуть. Пустая строка — сама папка модели.
    static let neighbourFolders = [
        "", "textures", "Textures", "texture", "tex", "maps", "Maps",
        "images", "Images", "materials", "Materials", "source", "images/textures"
    ]

    /// Путь из файла — в пригодный вид: обратные косые Windows на прямые, без кавычек
    /// и пробелов по краям.
    static func normalized(_ reference: String) -> String {
        reference
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
    }

    /// Только имя файла — то единственное, чему можно верить в чужом пути.
    static func fileName(of reference: String) -> String {
        (normalized(reference) as NSString).lastPathComponent
    }

    /// Где искать, по порядку: как написано, рядом с моделью по относительному пути,
    /// и по имени — в папке модели и у соседей.
    static func candidates(reference: String, modelFolder: String) -> [String] {
        let clean = normalized(reference)
        guard !clean.isEmpty else { return [] }
        let folder = modelFolder.hasSuffix("/") ? String(modelFolder.dropLast()) : modelFolder
        let name = fileName(of: clean)
        var result: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            result.append(path)
        }
        if clean.hasPrefix("/") { add(clean) }
        add(folder + "/" + clean)
        for sub in neighbourFolders {
            add(sub.isEmpty ? folder + "/" + name : folder + "/" + sub + "/" + name)
        }
        return result
    }

    /// Первый путь, который существует. `exists` отдельным доводом — чтобы проверять
    /// порядок поиска, не раскладывая файлы по диску.
    static func locate(reference: String, modelFolder: String,
                       exists: (String) -> Bool) -> String? {
        candidates(reference: reference, modelFolder: modelFolder).first(where: exists)
    }

    static func locate(reference: String, modelFolder: String) -> String? {
        locate(reference: reference, modelFolder: modelFolder) {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    /// Картинка, умноженная на цвет.
    ///
    /// В физически верном материале цвет и картинка НЕ соперничают, а перемножаются:
    /// у стекла фонаря картинка белая, а свой цвет — чёрный, и красным его делает
    /// свечение поверх. Пока мы просто заменяли цвет картинкой, фонарь выходил белым
    /// пятном вместо тёмного стекла.
    ///
    /// Почти белый цвет ничего не меняет — такую работу не делаем вовсе.
    static func tinted(_ image: NSImage, by colour: NSColor) -> NSImage? {
        guard let srgb = colour.usingColorSpace(.sRGB) else { return nil }
        let red = srgb.redComponent, green = srgb.greenComponent, blue = srgb.blueComponent
        guard min(red, min(green, blue)) < 0.98 else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let result = NSImage(size: size)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        srgb.withAlphaComponent(1).setFill()
        NSRect(origin: .zero, size: size).fill(using: .multiply)
        result.unlockFocus()
        return result
    }

    /// Картинка, умноженная на число (ярче единицы — светлее).
    ///
    /// Нужна для силы свечения из glTF: у стекла фонаря она бывает десятикратной. Ставить
    /// её через `SCNMaterialProperty.intensity` не выходит — замерено, на снимке ничего не
    /// меняется, — поэтому запекаем в саму картинку.
    static func brightened(_ image: NSImage, by factor: CGFloat) -> NSImage? {
        guard factor > 1.01, image.size.width > 0, image.size.height > 0 else { return nil }
        let size = image.size
        let result = NSImage(size: size)
        let rect = NSRect(origin: .zero, size: size)
        result.lockFocus()
        image.draw(in: rect)
        // Сложение с самой собой нужное число раз — чем светлее исходная точка, тем
        // быстрее она упирается в белое, как и должно быть.
        var left = factor - 1
        while left > 0.01 {
            NSGraphicsContext.current?.compositingOperation = .plusLighter
            image.draw(in: rect, from: .zero, operation: .plusLighter,
                       fraction: min(left, 1))
            left -= 1
        }
        result.unlockFocus()
        return result
    }

    /// Картинка по ссылке из модели — или nil, если её нигде нет.
    static func image(reference: String, modelFolder: String) -> NSImage? {
        guard let path = locate(reference: reference, modelFolder: modelFolder) else { return nil }
        return NSImage(contentsOfFile: path)
    }
}

/// Материалы формата Wavefront (.mtl) — ровно те строки, что нужны для показа.
///
/// Читаем сами, хотя .obj читает система: Model I/O доносит до SceneKit только цветовую
/// карту, а карту нормалей (`map_Bump`) и свечение (`map_Ke`) теряет по дороге —
/// проверено на модели из Blender. Без нормалей модель выглядит гладкой болванкой.
struct WavefrontMaterial: Equatable {
    var diffuse: String?
    var normal: String?
    var emission: String?
    var specular: String?
    /// Цвета из файла: `Kd` — свой цвет, `Ke` — свечение.
    var diffuseColour: [Double]?
    var emissionColour: [Double]?

    var isEmpty: Bool {
        diffuse == nil && normal == nil && emission == nil && specular == nil
            && diffuseColour == nil && emissionColour == nil
    }
}

enum WavefrontMTL {

    /// Разбор .mtl: имя материала → его картинки.
    static func parse(_ text: String) -> [String: WavefrontMaterial] {
        var result: [String: WavefrontMaterial] = [:]
        var current: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let keyword = parts.first?.lowercased() else { continue }
            let rest = parts.count > 1 ? String(parts[1]) : ""
            if keyword == "newmtl" {
                current = rest.trimmingCharacters(in: .whitespaces)
                if let current, !current.isEmpty, result[current] == nil {
                    result[current] = WavefrontMaterial()
                }
                continue
            }
            guard let name = current, var material = result[name] else { continue }
            if keyword == "kd" || keyword == "ke" {
                let numbers = rest.split(separator: " ").compactMap { Double($0) }
                if numbers.count >= 3 {
                    if keyword == "kd" { material.diffuseColour = Array(numbers.prefix(3)) }
                    else { material.emissionColour = Array(numbers.prefix(3)) }
                    result[name] = material
                }
                continue
            }
            let path = texturePath(in: rest)
            guard !path.isEmpty else { continue }
            switch keyword {
            case "map_kd", "map_basecolor":              material.diffuse = path
            case "map_bump", "bump", "norm", "map_norm": material.normal = path
            case "map_ke", "map_emissive":               material.emission = path
            case "map_ks", "map_specular":               material.specular = path
            default: continue
            }
            result[name] = material
        }
        return result
    }

    /// Путь из строки вида `-bm 1.000000 C:/x_normal.png`.
    ///
    /// У карт бывают ключи с числами (`-bm`, `-s`, `-o`, `-clamp`); всё, что начинается
    /// с минуса, и числа за ними отбрасываем. Остаток — путь, и в нём могут быть пробелы,
    /// поэтому склеиваем его назад, а не берём последнее слово.
    static func texturePath(in value: String) -> String {
        var words = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let first = words.first,
              first.hasPrefix("-") || Double(first) != nil || first.lowercased() == "on"
                || first.lowercased() == "off" {
            words.removeFirst()
        }
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
    }

    /// Гасить ли свечение, которое придумал Model I/O.
    ///
    /// Он превращает «окружающий свет» `Ka` в СВЕЧЕНИЕ материала, а Blender пишет
    /// `Ka 1.000000 1.000000 1.000000` по умолчанию — и модель заливает ровным белым.
    /// Замерено на настоящей модели: на снимке ровно ОДИН различимый оттенок, силуэт
    /// вместо предмета; стоит погасить свечение — их одиннадцать, а с текстурой
    /// шестьдесят. Гасим только тогда, когда сам .mtl о свечении ничего не говорит.
    static func emissionShouldBeBlack(material: WavefrontMaterial?, currentIsImage: Bool) -> Bool {
        guard let material, !currentIsImage else { return false }
        return material.emission == nil && material.emissionColour == nil
    }

    /// Имя файла материалов, на который ссылается сам .obj (`mtllib`). Если ссылки нет —
    /// пробуем одноимённый файл рядом.
    static func materialFileName(inOBJ text: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines).prefix(200) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("mtllib ") else { continue }
            let name = String(line.dropFirst("mtllib ".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            if !name.isEmpty { return name }
        }
        return nil
    }
}

/// Сила свечения материалов из самого файла glTF.
///
/// В glTF она живёт в расширении `KHR_materials_emissive_strength`, а библиотека чтения
/// его не передаёт: у стекла фонаря в файле стоит десятикратная сила, и без неё стекло
/// остаётся тёмным. Читаем сами — это обычный JSON, а у .glb он лежит первым куском
/// двоичного файла.
enum GLTFEmissiveStrength {

    /// Имя материала → сила свечения. Пусто, если файл не glTF или расширения в нём нет.
    static func table(forModelAt path: String) -> [String: Double] {
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "gltf" || ext == "glb" else { return [:] }
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        guard let json = ext == "glb" ? jsonChunk(inGLB: data) : data else { return [:] }
        return table(json: json)
    }

    /// Первый кусок .glb — это JSON: заголовок 12 байт, затем длина и метка «JSON».
    static func jsonChunk(inGLB data: Data) -> Data? {
        guard data.count > 20 else { return nil }
        func word(at offset: Int) -> UInt32 {
            data.withUnsafeBytes { raw in
                var value: UInt32 = 0
                for index in 0..<4 { value |= UInt32(raw[offset + index]) << (8 * index) }
                return value
            }
        }
        guard word(at: 0) == 0x46546C67 else { return nil }   // «glTF»
        let length = Int(word(at: 12))
        guard word(at: 16) == 0x4E4F534A, length > 0,        // «JSON»
              20 + length <= data.count else { return nil }
        return data.subdata(in: 20..<(20 + length))
    }

    static func table(json: Data) -> [String: Double] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let materials = root["materials"] as? [[String: Any]] else { return [:] }
        var result: [String: Double] = [:]
        for material in materials {
            guard let name = material["name"] as? String,
                  let extensions = material["extensions"] as? [String: Any],
                  let strength = extensions["KHR_materials_emissive_strength"] as? [String: Any],
                  let value = strength["emissiveStrength"] as? Double, value > 1
            else { continue }
            result[name] = value
        }
        return result
    }
}
