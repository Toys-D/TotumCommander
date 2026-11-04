import Foundation

/// Сортировка списка: поле и направление — одним значением, чтобы хранить и сравнивать.
struct PanelSort: Equatable, Codable {
    var field: PanelSortField
    var ascending: Bool

    /// Сортировка, с которой программа жила всегда: по имени, по возрастанию.
    static let standard = PanelSort(field: .name, ascending: true)
}

/// Настройки сортировки из раздела «Вид списка»: умолчание и память по папкам.
///
/// Раньше сортировка жила только в памяти панели: каждый запуск и каждая новая вкладка
/// начинались с имени по возрастанию, а переставленная в одной папке сортировка уходила
/// вместе с человеком во все следующие. Теперь умолчание выбирается в настройках и
/// возвращается при каждом переходе в другую папку; переставленная щелчком по столбцу
/// живёт только до перехода. А по желанию каждая папка помнит то, что в ней выставили.
enum SortSettings {
    static let fieldKey = "fcxl.sort.defaultField"
    static let ascendingKey = "fcxl.sort.defaultAscending"
    static let perFolderKey = "fcxl.sort.rememberPerFolder"
    static let memoryKey = "fcxl.sort.memory"

    /// Поля, из которых выбирается умолчание — в том же порядке, что в меню «Сортировать по».
    static let choices: [PanelSortField] = [
        .name, .fileExtension, .type, .size, .dateModified, .dateCreated, .dateAdded,
        .owner, .permissions
    ]

    static func defaultSort(in defaults: UserDefaults = .standard) -> PanelSort {
        let field = defaults.string(forKey: fieldKey).flatMap(PanelSortField.init(rawValue:))
        guard let field, choices.contains(field) else { return .standard }
        let ascending = defaults.object(forKey: ascendingKey) as? Bool ?? true
        return PanelSort(field: field, ascending: ascending)
    }

    static func rememberPerFolder(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: perFolderKey)
    }
}

/// Память сортировок по папкам: ограниченный список, свежие в конце.
///
/// Помнится только то, что человек выставил сам: сортировка, равная умолчанию, из памяти
/// убирается — такая папка снова идёт за настройкой, и смена умолчания её не обходит.
struct SortMemory: Equatable, Codable {
    struct Entry: Equatable, Codable {
        var path: String
        var sort: PanelSort
    }

    /// Сколько папок помнится: дальше самые давние забываются.
    static let limit = 500

    private(set) var entries: [Entry] = []

    var count: Int { entries.count }

    func sort(for path: String) -> PanelSort? {
        let key = Self.normalized(path)
        return entries.last { $0.path == key }?.sort
    }

    mutating func remember(_ sort: PanelSort, for path: String) {
        let key = Self.normalized(path)
        entries.removeAll { $0.path == key }
        entries.append(Entry(path: key, sort: sort))
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
    }

    mutating func forget(_ path: String) {
        let key = Self.normalized(path)
        entries.removeAll { $0.path == key }
    }

    mutating func forgetAll() { entries = [] }

    /// Хвостовая косая черта не делает папку другой.
    static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: - Хранение

    static func load(from defaults: UserDefaults) -> SortMemory {
        guard let data = defaults.data(forKey: SortSettings.memoryKey),
              let memory = try? JSONDecoder().decode(SortMemory.self, from: data) else {
            return SortMemory()
        }
        return memory
    }

    func save(to defaults: UserDefaults) {
        if entries.isEmpty {
            defaults.removeObject(forKey: SortSettings.memoryKey)
        } else if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: SortSettings.memoryKey)
        }
    }
}

/// Решения о сортировке — чистые функции, которые проверяет тест.
enum SortChoice {

    /// Какую сортировку взять, входя в папку.
    ///
    /// Память выключена — умолчание из настроек: переставленная щелчком по столбцу
    /// действовала только на тот показ. Включена — своя у папки, а без своей умолчание.
    /// Перечитывание той же папки сюда не приходит: что человек в ней переставил, остаётся.
    static func entering(path: String, memory: SortMemory, standard: PanelSort,
                         perFolder: Bool) -> PanelSort {
        guard perFolder else { return standard }
        return memory.sort(for: path) ?? standard
    }

    /// Что делать с памятью после того, как человек сам переставил сортировку в папке.
    /// Равную умолчанию — забыть, иную — запомнить; при выключенной памяти — ничего.
    static func afterChange(to sort: PanelSort, in path: String, memory: inout SortMemory,
                            standard: PanelSort, perFolder: Bool) {
        guard perFolder else { return }
        if sort == standard {
            memory.forget(path)
        } else {
            memory.remember(sort, for: path)
        }
    }
}

/// Одна память на всю программу: обе панели и все вкладки видят одно и то же.
@MainActor
final class SortMemoryStore {
    static let shared = SortMemoryStore(defaults: .standard)

    private let defaults: UserDefaults
    private var loaded: SortMemory?

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var memory: SortMemory {
        get {
            if let loaded { return loaded }
            let fresh = SortMemory.load(from: defaults)
            loaded = fresh
            return fresh
        }
        set {
            loaded = newValue
            newValue.save(to: defaults)
        }
    }

    /// Забыть всё, что читалось, — чтобы после правки настроек снаружи перечитать заново.
    func reload() { loaded = nil }
}
