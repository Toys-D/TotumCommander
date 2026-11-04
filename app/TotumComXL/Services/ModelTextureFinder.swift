import AppKit
import Foundation

/// Поиск картинок модели там, где их обычно держат.
///
/// Путь внутри файла модели верен только на той машине, где модель собирали: Blender под
/// Windows пишет `C:/slug_launcher_baseColor.png`, экспортёр из Maya — `D:\work\tex\...`,
/// а на диске рядом с моделью лежит папка `textures`, `Texture`, `tex`, «Текстуры» или
/// просто те же картинки россыпью. Поэтому ищем не путь, а ИМЯ — и не в одном месте.
///
/// Порядок такой: как написано в файле → рядом с моделью по относительному пути → по имени
/// в папке модели и в папках, похожих на «текстуры» (внутри модели и рядом с ней, на
/// уровень выше тоже) → по имени без расширения, если картинку пересохранили в другом
/// формате (в файле `.tga`, а на диске `.png` — обычное дело после конвертации).
///
/// Обход ограничен: вглубь не дальше трёх уровней и не больше нескольких тысяч файлов,
/// чтобы папка с гигабайтом мелочи не задержала открытие модели.
final class ModelTextureFinder {

    /// Расширения картинок, которые может нести материал.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "tga", "bmp", "tif", "tiff", "gif", "heic", "webp",
        "psd", "exr", "hdr", "dds", "ktx", "ktx2", "jp2", "pict", "pnm", "ppm"
    ]

    /// По этим словам узнаём папку с картинками — в любом регистре и в любом языке из
    /// тех, что встречаются в наборах моделей.
    static let textureWords = [
        "tex", "map", "mat", "image", "img", "skin", "surface", "shader",
        "текстур", "картинк", "материал"
    ]

    static func looksLikeTextureFolder(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return textureWords.contains { lowered.contains($0) }
    }

    static func isImage(_ name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Сколько файлов и папок готовы просмотреть.
    static let fileLimit = 6000
    static let folderLimit = 400
    static let depthLimit = 3

    private let folder: URL
    private let list: (URL) -> [(name: String, isDirectory: Bool)]
    /// Имя файла (в нижнем регистре) → путь. Строится по первой надобности.
    private var byName: [String: String] = [:]
    /// Имя без расширения → путь: для случая «в файле .tga, на диске .png».
    private var byBaseName: [String: String] = [:]
    private var indexed = false

    init(modelFolder: URL,
         list: @escaping (URL) -> [(name: String, isDirectory: Bool)] = ModelTextureFinder.listOnDisk) {
        self.folder = modelFolder
        self.list = list
    }

    /// Обычное чтение папки с диска.
    static func listOnDisk(_ url: URL) -> [(name: String, isDirectory: Bool)] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: url.path) else { return [] }
        return names.map { name in
            var isDirectory: ObjCBool = false
            _ = manager.fileExists(atPath: url.appendingPathComponent(name).path,
                                   isDirectory: &isDirectory)
            return (name, isDirectory.boolValue)
        }
    }

    // MARK: - Поиск

    /// Путь к картинке по ссылке из модели — или nil.
    func locate(_ reference: String) -> String? {
        let clean = ModelTextureRescue.normalized(reference)
        guard !clean.isEmpty else { return nil }
        // Сперва прямые попадания — они дешёвые и не требуют обхода папок.
        if let direct = ModelTextureRescue.locate(reference: clean, modelFolder: folder.path) {
            return direct
        }
        buildIndexIfNeeded()
        let name = ModelTextureRescue.fileName(of: clean).lowercased()
        if let found = byName[name] { return found }
        let base = (name as NSString).deletingPathExtension
        if !base.isEmpty, let found = byBaseName[base] { return found }
        return nil
    }

    func image(for reference: String) -> NSImage? {
        guard let path = locate(reference) else { return nil }
        return NSImage(contentsOfFile: path)
    }

    /// Что нашлось при обходе — для проверок и для отчёта.
    var indexedCount: Int {
        buildIndexIfNeeded()
        return byName.count
    }

    // MARK: - Обход

    private func buildIndexIfNeeded() {
        guard !indexed else { return }
        indexed = true
        var files = 0, folders = 0
        // Папка модели — всегда, целиком (первый уровень). Затем внутрь идут только папки,
        // похожие на «текстуры»: незачем перебирать чужие сцены и архивы.
        var queue: [(url: URL, depth: Int)] = [(folder, 0)]
        // На уровень выше — только похожие папки-соседи: модель часто лежит в `source`,
        // а картинки в `../textures`.
        let parent = folder.deletingLastPathComponent()
        if parent.path != folder.path {
            for entry in list(parent) where entry.isDirectory
                && Self.looksLikeTextureFolder(entry.name) {
                queue.append((parent.appendingPathComponent(entry.name), 1))
            }
        }
        while !queue.isEmpty, files < Self.fileLimit, folders < Self.folderLimit {
            let (url, depth) = queue.removeFirst()
            folders += 1
            for entry in list(url) {
                if entry.isDirectory {
                    guard depth + 1 <= Self.depthLimit else { continue }
                    // Внутрь папки модели заходим только в «текстурные»; внутри них —
                    // в любые (там раскладывают по материалам).
                    if depth == 0, !Self.looksLikeTextureFolder(entry.name) { continue }
                    queue.append((url.appendingPathComponent(entry.name), depth + 1))
                    continue
                }
                guard Self.isImage(entry.name) else { continue }
                files += 1
                let path = url.appendingPathComponent(entry.name).path
                let lowered = entry.name.lowercased()
                // Первое найденное важнее: папка модели просматривается раньше соседей.
                if byName[lowered] == nil { byName[lowered] = path }
                let base = (lowered as NSString).deletingPathExtension
                if !base.isEmpty, byBaseName[base] == nil { byBaseName[base] = path }
            }
        }
    }
}
