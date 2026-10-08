import AppKit

/// Картинку не взять: что именно нарушено.
struct FolderStyleRejection: Error {
    let problems: [FolderStyleProblem]
}

/// Свои стили папок — картинки, которые человек добавил сам. Лежат копиями в папке программы
/// (исходник можно стереть) со списком имён. В библиотеку попадает только то, что прошло
/// проверку (FolderStyleValidator).
enum FolderStyleLibrary {

    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        var name: String
        let format: Format
        /// Только для PNG: перекрашивать в цвет папок или показывать как есть.
        var recolor: Bool
    }

    enum Format: String, Codable {
        case svg, png
    }

    /// Поколение библиотеки — растёт при каждой правке. Панели наблюдают его, как остальные
    /// настройки вида, и перерисовывают папки. Без точек: на ключах с точкой наблюдение за
    /// настройками молча не срабатывает.
    static let generationKey = "folderStyleLibraryGeneration"

    static var generation: Int { defaults.integer(forKey: generationKey) }

    // MARK: - Где лежит

    struct Storage {
        let directory: URL
        let defaults: UserDefaults
    }

    /// Подмена для проверок: своя папка и свои настройки.
    nonisolated(unsafe) static var storageOverride: Storage? {
        didSet { forgetCachedEntries() }
    }

    /// Идёт проверка — настоящие стили и настройки человека недоступны в принципе, даже если
    /// проверка забыла подменить хранилище.
    private static var underTest: Bool { NSClassFromString("XCTestCase") != nil }

    nonisolated(unsafe) private static let testStorage: Storage = {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-folder-styles-tests-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        let name = "fcxl.folder.styles.tests"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return Storage(directory: directory, defaults: defaults)
    }()

    static var defaults: UserDefaults {
        if let storageOverride { return storageOverride.defaults }
        return underTest ? testStorage.defaults : .standard
    }

    static var directory: URL {
        if let storageOverride { return storageOverride.directory }
        if underTest { return testStorage.directory }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TotumCommander/FolderStyles", isDirectory: true)
    }

    private static var indexURL: URL { directory.appendingPathComponent("styles.json") }

    static func fileURL(of entry: Entry) -> URL {
        directory.appendingPathComponent("\(entry.id).\(entry.format.rawValue)")
    }

    // MARK: - Список

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedEntries: [Entry]?

    /// В том порядке, в каком добавлены.
    static var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedEntries { return cachedEntries }
        let list = (try? Data(contentsOf: indexURL))
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        cachedEntries = list
        return list
    }

    static func entry(_ id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    private static func forgetCachedEntries() {
        lock.lock()
        cachedEntries = nil
        lock.unlock()
    }

    // MARK: - Правка

    /// Проверить картинку и добавить копию. Не по правилам — FolderStyleRejection со всем, что
    /// нарушено.
    @discardableResult
    static func add(contentsOf url: URL) throws -> Entry {
        let problems = FolderStyleValidator.problems(at: url)
        guard problems.isEmpty else { throw FolderStyleRejection(problems: problems) }
        let entry = Entry(id: UUID().uuidString,
                          name: url.deletingPathExtension().lastPathComponent,
                          format: url.pathExtension.lowercased() == "svg" ? .svg : .png,
                          recolor: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: fileURL(of: entry))
        save(entries + [entry])
        return entry
    }

    static func remove(_ id: String) {
        guard let entry = entry(id) else { return }
        try? FileManager.default.removeItem(at: fileURL(of: entry))
        // Убран выбранный — папки снова в стиле macOS, а не в стиле, которого нет.
        if defaults.string(forKey: FolderIconStyle.storageKey) == FolderIconStyle.custom(id).rawValue {
            defaults.set(FolderIconStyle.macos.rawValue, forKey: FolderIconStyle.storageKey)
        }
        save(entries.filter { $0.id != id })
    }

    static func setRecolor(_ recolor: Bool, for id: String) {
        var list = entries
        guard let index = list.firstIndex(where: { $0.id == id }), list[index].recolor != recolor else { return }
        list[index].recolor = recolor
        save(list)
    }

    private static func save(_ list: [Entry]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: indexURL, options: .atomic)
        }
        forgetCachedEntries()
        FolderStyleArt.forget(keeping: Set(list.map(\.id)))
        FolderIconRenderer.clearCache()
        defaults.set(generation + 1, forKey: generationKey)
    }

    // MARK: - Образец

    /// Образец своего SVG — та же папка, что «Каталог V4», нарисованная цветами-ролями.
    /// Отдаётся человеку как есть: открыть, перерисовать, сохранить, добавить.
    static let sampleSVG = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!--
      Totum Commander — образец своей иконки папки / custom folder icon sample.

      Цвета-роли / colour roles (других цветов быть не может / no other colours allowed):
        #FF00FF — цвет папки / folder colour
        #B000B0 — цвет папки темнее / folder colour, darker
        #FFFFFF — остаётся белым / stays white
        #000000 — тень, можно с прозрачностью / shadow, may be translucent

      Правила / rules: квадратный viewBox, только залитые фигуры (path, rect, circle, ellipse,
      polygon, polyline, line, g), без текста, картинок, ссылок, скриптов, скрытых слоёв,
      градиентов, масок и фильтров; стили — только простыми классами (.st0 { fill: … }); до 200 КБ.
      Square viewBox, filled shapes only, no text, images, links, scripts, hidden layers,
      gradients, masks or filters; styles only as plain classes (.st0 { fill: … }); up to 200 KB.
    -->
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 500">
      <g transform="scale(1 1.2285)">
        <path fill="#B000B0" d="M442.16,116.31V350.32C442.16,364.29 430.82,375.63 416.85,375.63H25.84C11.85,375.63 0.51,364.29 0.51,350.32V56.71C0.51,42.72 11.85,31.38 25.84,31.38H93.07C107.23,31.38 120.76,37.26 130.44,47.59L155.93,74.79C165.61,85.12 179.13,91 193.28,91H416.86C430.83,91 442.16,102.32 442.16,116.31Z"/>
        <rect fill="#FFFFFF" fill-opacity="0.92" x="36.1" y="72.07" width="370.46" height="262.85" rx="34.67"/>
        <path fill="#FF00FF" d="M499.25,139.81L448.66,349.86C445.24,364.08 431.11,375.63 417.14,375.63H26.13C12.14,375.63 3.58,364.08 7.01,349.86L57.6,139.81C61.02,125.59 75.15,114.04 89.14,114.04H480.16C494.13,114.04 502.69,125.59 499.25,139.81Z"/>
      </g>
    </svg>

    """
}
