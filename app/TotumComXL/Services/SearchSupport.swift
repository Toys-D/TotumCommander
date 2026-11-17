import AppKit
import Foundation

// Мелкие правила окна поиска, вынесенные из окна, чтобы их можно было проверить без него.

/// Маска имён на стороне Swift — по тем же правилам, что у ядра (`NameMaskSet`): одна маска
/// или несколько через «;», имя подходит, если подошло любой. Кусок без `*` и `?` — часть
/// имени: «отчёт» значит «*отчёт*». Пустая маска и «*» пропускают всё.
///
/// Нужна там, где имена просеивает не ядро: находки в картинках, группы дубликатов и ответ
/// Spotlight.
enum SearchNameMask {

    /// Куски маски как шаблоны для `LIKE`; nil — подходит любое имя.
    nonisolated static func patterns(_ raw: String) -> [String]? {
        var patterns: [String] = []
        for piece in raw.split(separator: ";") {
            let mask = piece.trimmingCharacters(in: .whitespaces)
            if mask.isEmpty { continue }
            if mask == "*" { return nil }
            patterns.append(mask.contains("*") || mask.contains("?") ? mask : "*\(mask)*")
        }
        return patterns.isEmpty ? nil : patterns
    }

    nonisolated static func matchesEverything(_ raw: String) -> Bool {
        patterns(raw) == nil
    }

    /// Готовый вопрос к имени: маска разбирается один раз, а имён — тысячи.
    ///
    /// `LIKE[cd]`, а не побайтное сравнение: имя с диска приходит в разложенном виде Юникода
    /// («ё» — два знака), маска с клавиатуры — в составном, и байты у них разные.
    nonisolated static func matcher(_ raw: String) -> (String) -> Bool {
        guard let patterns = patterns(raw) else { return { _ in true } }
        let predicates = patterns.map { NSPredicate(format: "SELF LIKE[cd] %@", $0) }
        return { name in predicates.contains { $0.evaluate(with: name) } }
    }

    nonisolated static func matches(_ raw: String, name: String) -> Bool {
        matcher(raw)(name)
    }
}

/// Дата в условиях поиска. Человек выбирает дни, а поле даты хранит ещё и время суток — то,
/// в которое его тронули; без поправки «по 15 ноября» обрывалось посреди пятнадцатого.
enum SearchDateRange {

    /// Что стоит в полях, когда фильтр включили впервые: последняя неделя. Раньше поля
    /// показывали «01.01.0001 — сегодня», а условия не было вовсе, пока их не тронешь.
    nonisolated static func initial(now: Date = Date(),
                                    calendar: Calendar = .current) -> (from: Date, to: Date) {
        let today = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        return (weekAgo, today)
    }

    /// Границы для движка: с первой секунды дня «от» по последнюю секунду дня «до».
    nonisolated static func bounds(from: Date?, to: Date?,
                                   calendar: Calendar = .current) -> (from: Date?, to: Date?) {
        let start = from.map { calendar.startOfDay(for: $0) }
        let end = to.map { day -> Date in
            let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
            return (nextDay ?? day).addingTimeInterval(-1)
        }
        return (start, end)
    }
}

/// «Удалить» в окне поиска: тот же вопрос, что задаёт F8 в панели, и только потом корзина.
/// Раньше выбранное уходило в корзину сразу, без вопроса.
enum SearchDeletion {

    /// true — удалено; false — человек отказался или удалять уже нечего.
    @MainActor
    static func run(paths: [String],
                    confirm: @MainActor ([FileItem], Int64) async -> Bool,
                    trash: @MainActor ([FileItem]) async throws -> Void) async throws -> Bool {
        let items = paths.compactMap { FileItem.fromPath($0) }
        guard !items.isEmpty else { return false }
        let totalBytes = items.reduce(Int64(0)) { $0 + Int64($1.size) }
        guard await confirm(items, totalBytes) else { return false }
        try await trash(items)
        return true
    }
}

/// Отказ движка поиска — словами программы. Ядро сообщает по-английски («Invalid regex
/// pattern»), и это шло в окно как есть.
enum SearchErrorText {

    /// Коды ядра (`fcxl::common::ErrorCode`), которые поиск умеет назвать.
    private enum CoreCode: Int {
        case notFound = 1
        case permissionDenied = 2
        case invalidArgument = 5
        case notADirectory = 11
    }

    nonisolated static func text(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == "com.fcxl.error", let code = CoreCode(rawValue: nsError.code) else {
            return error.localizedDescription
        }
        switch code {
        case .notFound: return L("search.error.rootMissing")
        case .permissionDenied: return L("search.error.noAccess")
        case .notADirectory: return L("search.error.rootNotFolder")
        case .invalidArgument:
            // Неверных доводов ядро знает два: выражение, которое не разобрать, и пустое «Где».
            return nsError.localizedDescription.lowercased().contains("regex")
                ? L("search.error.badRegex")
                : L("search.error.rootMissing")
        }
    }
}

// MARK: - Форма: сроки, размер, сводка фильтров, недавние места

/// Готовые сроки условия «Дата». Свой срок — два дня, выбранные вручную.
enum SearchDatePreset: String, CaseIterable {
    case any, today, week, month, year, custom

    var title: String { L("search.date.\(rawValue)") }
}

extension SearchDateRange {

    /// Границы срока для движка — уже целыми днями. У «Любая» границ нет.
    nonisolated static func range(for preset: SearchDatePreset,
                                  customFrom: Date?, customTo: Date?,
                                  now: Date = Date(),
                                  calendar: Calendar = .current) -> (from: Date?, to: Date?) {
        let today = calendar.startOfDay(for: now)
        func back(_ component: Calendar.Component, _ value: Int) -> Date {
            calendar.date(byAdding: component, value: -value, to: today) ?? today
        }
        switch preset {
        case .any: return (nil, nil)
        case .today: return bounds(from: today, to: today, calendar: calendar)
        case .week: return bounds(from: back(.day, 7), to: today, calendar: calendar)
        case .month: return bounds(from: back(.month, 1), to: today, calendar: calendar)
        case .year: return bounds(from: back(.year, 1), to: today, calendar: calendar)
        case .custom: return bounds(from: customFrom, to: customTo, calendar: calendar)
        }
    }
}

/// Число из поля размера — в байты.
enum SearchSize {

    /// «1,5» и «1.5» — одно и то же; пусто, не число и минус — условия нет (0).
    nonisolated static func bytes(_ text: String, unit: SizeUnit) -> UInt64 {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value > 0, value.isFinite else { return 0 }
        let bytes = value * Double(unit.rawValue)
        return bytes >= Double(UInt64.max) ? UInt64.max : UInt64(bytes.rounded())
    }
}

/// Пределы размера и даты для находок, которые просеивает не ядро (текст в картинках).
/// 0 и nil — предела нет, как у ядра.
struct SearchFileLimits {
    let minBytes: UInt64
    let maxBytes: UInt64
    let from: Date?
    let to: Date?

    var isUnlimited: Bool { minBytes == 0 && maxBytes == 0 && from == nil && to == nil }

    func allows(path: String) -> Bool {
        if isUnlimited { return true }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return false
        }
        let size = (attributes[.size] as? UInt64) ?? 0
        if size < minBytes { return false }
        if maxBytes > 0, size > maxBytes { return false }
        let modified = attributes[.modificationDate] as? Date
        if let from, let modified, modified < from { return false }
        if let to, let modified, modified > to { return false }
        return true
    }
}

/// То, что задано в блоке «Фильтры», — в том виде, в каком это действует в текущем режиме:
/// условие, которого у режима нет, сюда приходит уже пустым.
struct SearchFilterState: Equatable {
    /// Маска имён — там, где она фильтр, а не главное поле (содержимое, дубликаты).
    var nameMask: String = ""
    var exclude: String = ""
    var minSize: String = ""
    var maxSize: String = ""
    var unit: SizeUnit = .mb
    var type: FileTypeOption = .all
    var datePreset: SearchDatePreset = .any
    var dateFrom: Date? = nil
    var dateTo: Date? = nil

    /// Сужают ли условия ЭТОТ поиск. «Пропускать» не в счёт: это постоянная привычка
    /// (node_modules, кэши), её набирают один раз и не сбрасывают вместе с остальным.
    var isNarrowing: Bool {
        !SearchNameMask.matchesEverything(nameMask)
            || SearchSize.bytes(minSize, unit: unit) > 0
            || SearchSize.bytes(maxSize, unit: unit) > 0
            || type != .all
            || datePreset != .any
    }
}

/// Действующие условия короткими словами — для свёрнутого блока «Фильтры». Спрятанное
/// условие, которое молча меняет ответ поиска, — худшее, что может сделать форма; поэтому
/// свёрнутый блок всегда говорит, что в нём задано.
enum SearchFilterSummary {

    nonisolated static func parts(_ state: SearchFilterState) -> [String] {
        var parts: [String] = []
        if !SearchNameMask.matchesEverything(state.nameMask) {
            parts.append(state.nameMask.trimmingCharacters(in: .whitespaces))
        }
        let min = SearchSize.bytes(state.minSize, unit: state.unit)
        let max = SearchSize.bytes(state.maxSize, unit: state.unit)
        let low = state.minSize.trimmingCharacters(in: .whitespaces)
        let high = state.maxSize.trimmingCharacters(in: .whitespaces)
        if min > 0, max > 0 {
            parts.append("\(low)–\(high) \(state.unit.label)")
        } else if min > 0 {
            parts.append(String(format: L("search.filters.sum.from"), "\(low) \(state.unit.label)"))
        } else if max > 0 {
            parts.append(String(format: L("search.filters.sum.to"), "\(high) \(state.unit.label)"))
        }
        switch state.type {
        case .all: break
        case .filesOnly: parts.append(L("search.filters.sum.files"))
        case .dirsOnly: parts.append(L("search.filters.sum.dirs"))
        }
        switch state.datePreset {
        case .any: break
        case .custom:
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            let from = state.dateFrom.map(formatter.string(from:)) ?? "…"
            let to = state.dateTo.map(formatter.string(from:)) ?? "…"
            parts.append("\(from) – \(to)")
        default: parts.append(state.datePreset.title)
        }
        let exclude = state.exclude.trimmingCharacters(in: .whitespaces)
        if !exclude.isEmpty {
            parts.append(String(format: L("search.filters.sum.skip"), exclude))
        }
        return parts
    }
}

/// Места, где недавно искали, — для списка у поля «Где».
enum SearchRecentPlaces {
    static let key = "fcxl.search.recentRoots"
    static let limit = 8

    static func load(from defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// Новое место встаёт первым; то же место не повторяется, а поднимается наверх.
    static func remember(_ raw: String, in defaults: UserDefaults = .standard) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let path = (trimmed as NSString).standardizingPath
        var places = load(from: defaults).filter { $0 != path }
        places.insert(path, at: 0)
        defaults.set(Array(places.prefix(limit)), forKey: key)
    }
}

// MARK: - Список находок: порядок, подписи

/// По какой колонке стоит список находок.
enum SearchSortKey: String, CaseIterable {
    case name, folder, size, date
}

/// Порядок списка находок. Чистая функция — щелчок по заголовку колонки проверяется без окна.
enum SearchSort {

    /// Правила те же, что у панели: папки стоят сверху при любом направлении, а то, чего у
    /// строки нет (размер у папки, дата у неизвестного), уходит в конец, а не в начало —
    /// «по убыванию размера» не должно начинаться с пустых мест.
    nonisolated static func sorted(_ hits: [SearchHit], by key: SearchSortKey,
                                   ascending: Bool) -> [SearchHit] {
        func byName(_ a: SearchHit, _ b: SearchHit) -> ComparisonResult {
            let names = a.name.localizedStandardCompare(b.name)
            return names != .orderedSame ? names : a.path.compare(b.path)
        }
        func directed(_ result: ComparisonResult) -> Bool {
            ascending ? result == .orderedAscending : result == .orderedDescending
        }
        func compare<Value: Comparable>(_ a: Value, _ b: Value) -> ComparisonResult {
            a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        }
        return hits.sorted { a, b in
            switch key {
            case .name:
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return directed(byName(a, b))
            case .folder:
                let folders = (a.path as NSString).deletingLastPathComponent
                    .localizedStandardCompare((b.path as NSString).deletingLastPathComponent)
                return folders != .orderedSame ? directed(folders) : byName(a, b) == .orderedAscending
            case .size:
                let sizeA = a.isDirectory ? nil : a.size
                let sizeB = b.isDirectory ? nil : b.size
                switch (sizeA, sizeB) {
                case (nil, nil): return byName(a, b) == .orderedAscending
                case (nil, _): return false
                case (_, nil): return true
                case let (x?, y?):
                    return x != y ? directed(compare(x, y)) : byName(a, b) == .orderedAscending
                }
            case .date:
                switch (a.dateModified, b.dateModified) {
                case (nil, nil): return byName(a, b) == .orderedAscending
                case (nil, _): return false
                case (_, nil): return true
                case let (x?, y?):
                    return x != y ? directed(compare(x, y)) : byName(a, b) == .orderedAscending
                }
            }
        }
    }
}

/// «1 файл», «2 файла», «5 файлов» — число с существительным в нужной форме. Раньше в
/// заголовке группы дубликатов стояло «2 файлов».
enum CountText {
    enum Form { case one, few, many }

    /// Правило языка программы берётся из самих строк перевода (`count.rule`), а не из
    /// настроек системы: язык программы может с ними не совпадать.
    nonisolated static func form(_ count: Int, slavic: Bool) -> Form {
        let number = abs(count)
        guard slavic else { return number == 1 ? .one : .many }
        let lastTwo = number % 100
        let last = number % 10
        if last == 1, lastTwo != 11 { return .one }
        if (2...4).contains(last), !(12...14).contains(lastTwo) { return .few }
        return .many
    }

    static func files(_ count: Int) -> String {
        let key: String
        switch form(count, slavic: L("count.rule") == "slavic") {
        case .one: key = "search.count.files.one"
        case .few: key = "search.count.files.few"
        case .many: key = "search.count.files.many"
        }
        return String(format: L(key), count)
    }
}

/// Строка находки по содержимому: номер строки, её текст и сколько ещё строк совпало.
enum SearchMatchText {

    nonisolated static func text(line: UInt64?, content: String?, count: Int) -> String? {
        guard let content else { return nil }
        // Отступ кода в начале строки только отодвигает то, ради чего её показывают.
        let shown = content.trimmingCharacters(in: .whitespaces)
        var text = line.map { "\($0): \(shown)" } ?? shown
        if count > 1 { text += "   (+\(count - 1))" }
        return text
    }
}

// MARK: - Действия над находками

/// Что можно сделать с находками. Одно перечисление на кнопки, клавиши и правое меню — чтобы
/// клавиша и пункт меню не могли разойтись в том, что они делают.
enum SearchResultAction: Equatable {
    case goTo, quickLook, edit, copy, move, delete, toPanel, copyPath
}

/// F-клавиши окна поиска. Пока оно впереди, они относятся к находкам. Раньше F8 в окне
/// поиска доходила до главного меню и удаляла то, что выбрано в панели ПОЗАДИ окна.
enum SearchKeys {

    nonisolated static func action(keyCode: UInt16,
                                   modifiers: NSEvent.ModifierFlags) -> SearchResultAction? {
        // С ⌘, ⌥, ⌃ и ⇧ это уже другие команды программы (⌘F5 — упаковать, ⇧F8 — мимо
        // корзины): их окно поиска не трогает.
        guard modifiers.intersection([.command, .option, .control, .shift]).isEmpty else { return nil }
        switch keyCode {
        case 99: return .quickLook    // F3
        case 118: return .edit        // F4
        case 96: return .copy         // F5
        case 97: return .move         // F6
        case 100: return .delete      // F8
        default: return nil
        }
    }
}

/// Колонка «Папка»: путь от места поиска, а не от корня диска. Длинное начало пути у всех
/// строк одно и то же — оно только заслоняло то, чем строки различаются.
enum SearchFolderText {

    /// Папка находки, начиная с самой папки поиска: «docs», «docs/договоры». Находка вне
    /// места поиска (Spotlight по всему Mac) — полный путь с «~».
    nonisolated static func text(itemPath: String, root: String) -> String {
        let folder = ((itemPath as NSString).deletingLastPathComponent as NSString).standardizingPath
        let base = (root as NSString).standardizingPath
        guard base.count > 1, folder == base || folder.hasPrefix(base + "/") else {
            return (folder as NSString).abbreviatingWithTildeInPath
        }
        let rootName = (base as NSString).lastPathComponent
        return folder == base ? rootName : rootName + folder.dropFirst(base.count)
    }
}

// MARK: - Дубликаты: какие копии лишние

/// Какую копию в группе оставить; остальные — лишние.
enum DuplicateKeep: String, CaseIterable {
    case newest, oldest, firstByPath

    var title: String { L("search.dup.keep.\(rawValue)") }
}

/// Выбор лишних копий. Ради этого дубликаты и ищут — а выбирать их приходилось руками, по
/// одной в каждой группе.
enum DuplicateSelection {

    /// Все файлы каждой группы, кроме одного. `modified` — дата файла; её может не быть
    /// (файл исчез): такой файл оставленным не становится, пока в группе есть другой.
    nonisolated static func extras(in groups: [DuplicateGroup], keep: DuplicateKeep,
                                   modified: (String) -> Date?) -> Set<String> {
        var extras = Set<String>()
        for group in groups where group.files.count > 1 {
            let kept: String
            switch keep {
            case .firstByPath:
                kept = group.files[0]
            case .newest, .oldest:
                // При равных датах остаётся первый по порядку списка: выбор не должен
                // зависеть от случая.
                var best: (path: String, date: Date)?
                for path in group.files {
                    guard let date = modified(path) else { continue }
                    let better = best.map { keep == .newest ? date > $0.date : date < $0.date } ?? true
                    if better { best = (path, date) }
                }
                kept = best?.path ?? group.files[0]
            }
            for path in group.files where path != kept { extras.insert(path) }
        }
        return extras
    }

    /// Сколько места освободит удаление выбранного — и в скольких группах выбраны ВСЕ копии:
    /// там после удаления не останется ни одной.
    nonisolated static func summary(groups: [DuplicateGroup],
                                    selected: Set<String>) -> (bytes: UInt64, emptiedGroups: Int) {
        guard !selected.isEmpty else { return (0, 0) }
        var bytes: UInt64 = 0
        var emptied = 0
        for group in groups {
            let chosen = group.files.reduce(0) { $0 + (selected.contains($1) ? 1 : 0) }
            guard chosen > 0 else { continue }
            bytes += group.size * UInt64(chosen)
            if chosen == group.files.count { emptied += 1 }
        }
        return (bytes, emptied)
    }

    /// Дата изменения файла на диске.
    nonisolated static func modifiedOnDisk(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}

// MARK: - История запросов

/// Что искали раньше — для списка у главного поля. Имена и тексты помнятся порознь.
enum SearchHistory {
    enum Kind: String { case name, text }

    static let limit = 15

    static func key(_ kind: Kind) -> String { "fcxl.search.history.\(kind.rawValue)" }

    static func load(_ kind: Kind, from defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key(kind)) ?? []
    }

    /// Новый запрос встаёт первым; повтор поднимается наверх. Пустой запрос и «*» — не
    /// запросы, их помнить незачем.
    static func remember(_ raw: String, kind: Kind, in defaults: UserDefaults = .standard) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query != "*" else { return }
        var queries = load(kind, from: defaults).filter { $0 != query }
        queries.insert(query, at: 0)
        defaults.set(Array(queries.prefix(limit)), forKey: key(kind))
    }

    static func clear(_ kind: Kind, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(kind))
    }
}
