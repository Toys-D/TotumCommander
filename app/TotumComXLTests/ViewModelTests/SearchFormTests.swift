import Foundation
import XCTest

@testable import TotumComXLApp

// Форма окна поиска после перестройки 2026-11-16: режимы вкладками, одно главное поле,
// общий блок «Фильтры». Здесь — правила, по которым она считает; сам вид проверяется глазами.

private func makeOwnFolder(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fcxl-search-form-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Свои настройки на проверку: настоящие настройки программы не читаются и не пишутся.
private func ownDefaults() -> UserDefaults {
    let name = "fcxl-search-form-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: - Режимы

final class SearchModeOrderTests: XCTestCase {

    func test_вкладкиИдутОтПростогоКОсобому() {
        XCTAssertEqual(SearchMode.allCases, [.byName, .byContent, .spotlight, .duplicates])
    }

    func test_уКаждойВкладкиЕстьПодписьИЗначок() {
        for mode in SearchMode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.title.hasPrefix("search."), "нет перевода: \(mode.title)")
            XCTAssertFalse(mode.symbol.isEmpty)
        }
    }

    func test_критерииДубликатов_начинаютсяСТочныхКопий() {
        XCTAssertEqual(DuplicateMode.shown.first, .byHash)
    }
}

// MARK: - Сроки даты

final class SearchDatePresetTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0,
                      _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute, second: second))!
    }

    private func range(_ preset: SearchDatePreset, from: Date? = nil, to: Date? = nil)
        -> (from: Date?, to: Date?) {
        SearchDateRange.range(for: preset, customFrom: from, customTo: to,
                              now: date(2026, 11, 16, 14, 30), calendar: calendar)
    }

    func test_любая_безГраниц() {
        let any = range(.any)
        XCTAssertNil(any.from)
        XCTAssertNil(any.to)
    }

    func test_готовыеСроки_считаютсяОтСегодня_иБерутДниЦеликом() {
        let endOfToday = date(2026, 11, 16, 23, 59, 59)
        XCTAssertEqual(range(.today).from, date(2026, 11, 16))
        XCTAssertEqual(range(.today).to, endOfToday)
        XCTAssertEqual(range(.week).from, date(2026, 11, 9))
        XCTAssertEqual(range(.week).to, endOfToday)
        XCTAssertEqual(range(.month).from, date(2026, 10, 16))
        XCTAssertEqual(range(.year).from, date(2025, 11, 16))
        XCTAssertEqual(range(.year).to, endOfToday)
    }

    func test_свойСрок_берётВыбранныеДни() {
        let custom = range(.custom, from: date(2026, 1, 10, 18, 0), to: date(2026, 2, 5, 9, 0))
        XCTAssertEqual(custom.from, date(2026, 1, 10))
        XCTAssertEqual(custom.to, date(2026, 2, 5, 23, 59, 59))
    }

    @MainActor
    func test_выбралиСвойСрок_вПоляхСразуПоследняяНеделя() {
        let vm = AdvancedSearchViewModel()
        XCTAssertEqual(vm.datePreset, .any)
        XCTAssertNil(vm.dateFrom)
        vm.datePreset = .custom
        XCTAssertNotNil(vm.dateFrom)
        XCTAssertNotNil(vm.dateTo)
        XCTAssertLessThan(vm.dateFrom!, vm.dateTo!)
    }

    @MainActor
    func test_ушлиСоСвоегоСрокаИВернулись_датыТеЖе() {
        let vm = AdvancedSearchViewModel()
        vm.datePreset = .custom
        let chosen = date(2026, 1, 15)
        vm.dateFrom = chosen
        vm.datePreset = .week
        vm.datePreset = .custom
        XCTAssertEqual(vm.dateFrom, chosen)
    }
}

// MARK: - Размер

final class SearchSizeTests: XCTestCase {

    func test_единицыСчитаютсяПоТысяче_какРазмерыВПанели() {
        // Панель и Finder пишут «10 МБ» про десять миллионов байт. По 1024 такой файл не
        // проходил условие «от 10 МБ», хотя на экране у него стояло ровно «10 МБ».
        XCTAssertEqual(SizeUnit.kb.rawValue, 1_000)
        XCTAssertEqual(SizeUnit.mb.rawValue, 1_000_000)
        XCTAssertEqual(SizeUnit.gb.rawValue, 1_000_000_000)
    }

    func test_подписиЕдиниц_наЯзыкеПрограммы() {
        for unit in SizeUnit.allCases {
            XCTAssertFalse(unit.label.hasPrefix("search."), "нет перевода: \(unit.label)")
        }
    }

    func test_числоСДробью_черезТочкуИлиЗапятую() {
        XCTAssertEqual(SearchSize.bytes("10", unit: .mb), 10_000_000)
        XCTAssertEqual(SearchSize.bytes("1.5", unit: .mb), 1_500_000)
        XCTAssertEqual(SearchSize.bytes("1,5", unit: .gb), 1_500_000_000)
        XCTAssertEqual(SearchSize.bytes(" 2 ", unit: .kb), 2_000)
    }

    func test_пустоИНеЧисло_условияНет() {
        XCTAssertEqual(SearchSize.bytes("", unit: .mb), 0)
        XCTAssertEqual(SearchSize.bytes("много", unit: .mb), 0)
        XCTAssertEqual(SearchSize.bytes("-5", unit: .mb), 0)
    }
}

// MARK: - Сводка фильтров

final class SearchFilterSummaryTests: XCTestCase {

    func test_ничегоНеЗадано_сводкаПуста() {
        XCTAssertTrue(SearchFilterSummary.parts(SearchFilterState()).isEmpty)
        XCTAssertFalse(SearchFilterState().isNarrowing)
    }

    func test_заданныеУсловия_названыКоротко() {
        var state = SearchFilterState()
        state.nameMask = "*.txt;*.md"
        state.exclude = "node_modules; .cache"
        state.minSize = "10"
        state.unit = .mb
        state.type = .filesOnly
        state.datePreset = .week
        let parts = SearchFilterSummary.parts(state)
        XCTAssertEqual(parts.count, 5)
        XCTAssertTrue(parts[0].contains("*.txt;*.md"), parts[0])
        XCTAssertTrue(parts.contains { $0.contains("node_modules") })
        XCTAssertTrue(parts.contains { $0.contains("10") && $0.contains(SizeUnit.mb.label) })
        XCTAssertTrue(parts.contains(L("search.filters.sum.files")))
        XCTAssertTrue(parts.contains(SearchDatePreset.week.title))
        XCTAssertTrue(state.isNarrowing)
    }

    func test_размерОтИДо_однимКуском() {
        var state = SearchFilterState()
        state.minSize = "1"
        state.maxSize = "5"
        state.unit = .gb
        let parts = SearchFilterSummary.parts(state)
        XCTAssertEqual(parts.count, 1)
        XCTAssertTrue(parts[0].contains("1") && parts[0].contains("5"), parts[0])
    }

    func test_пропускать_виднаВСводке_ноСужениемНеСчитается() {
        // «Пропускать» — постоянная привычка (node_modules), а не условие этого поиска:
        // в сводке она есть, но кнопку «Сбросить» сама не зажигает.
        var state = SearchFilterState()
        state.exclude = "node_modules"
        XCTAssertEqual(SearchFilterSummary.parts(state).count, 1)
        XCTAssertFalse(state.isNarrowing)
    }

    @MainActor
    func test_маска_фильтрТолькоТам_гдеОнаНеГлавноеПоле() {
        let vm = AdvancedSearchViewModel()
        vm.pattern = "*.txt"
        vm.searchMode = .byName
        XCTAssertEqual(vm.filterState.nameMask, "", "по имени маска — главное поле, не фильтр")
        vm.searchMode = .byContent
        XCTAssertEqual(vm.filterState.nameMask, "*.txt")
        vm.searchMode = .duplicates
        XCTAssertEqual(vm.filterState.nameMask, "*.txt")
    }

    @MainActor
    func test_тип_фильтрТолькоТам_гдеБываютПапки() {
        let vm = AdvancedSearchViewModel()
        vm.fileType = .dirsOnly
        vm.searchMode = .byName
        XCTAssertEqual(vm.filterState.type, .dirsOnly)
        vm.searchMode = .byContent
        XCTAssertEqual(vm.filterState.type, .all, "внутри папки текста нет — условие не действует")
        vm.searchMode = .duplicates
        XCTAssertEqual(vm.filterState.type, .all)
    }

    @MainActor
    func test_сбросить_убираетУсловия_ноНеПропускать() {
        let vm = AdvancedSearchViewModel()
        let excludeBefore = vm.excludeSpec
        vm.searchMode = .byContent
        vm.pattern = "*.txt"
        vm.minSizeValue = "5"
        vm.maxSizeValue = "9"
        vm.fileType = .filesOnly
        vm.datePreset = .month
        vm.resetFilters()
        XCTAssertEqual(vm.pattern, "*")
        XCTAssertEqual(vm.minSizeValue, "")
        XCTAssertEqual(vm.maxSizeValue, "")
        XCTAssertEqual(vm.fileType, .all)
        XCTAssertEqual(vm.datePreset, .any)
        XCTAssertEqual(vm.excludeSpec, excludeBefore)
        XCTAssertFalse(vm.filterState.isNarrowing)
    }

    @MainActor
    func test_сбросить_поИмени_неСтираетГлавноеПоле() {
        let vm = AdvancedSearchViewModel()
        vm.searchMode = .byName
        vm.pattern = "отчёт"
        vm.minSizeValue = "5"
        vm.resetFilters()
        XCTAssertEqual(vm.pattern, "отчёт")
        XCTAssertEqual(vm.minSizeValue, "")
    }
}

// MARK: - Недавние места

final class SearchRecentPlacesTests: XCTestCase {

    func test_новоеМестоВстаётПервым_аПовторПоднимается() {
        let defaults = ownDefaults()
        SearchRecentPlaces.remember("/Users/me/Documents", in: defaults)
        SearchRecentPlaces.remember("/Users/me/Music", in: defaults)
        SearchRecentPlaces.remember("/Users/me/Documents/", in: defaults)
        XCTAssertEqual(SearchRecentPlaces.load(from: defaults),
                       ["/Users/me/Documents", "/Users/me/Music"])
    }

    func test_помнитНеБольшеВосьми() {
        let defaults = ownDefaults()
        for index in 1...12 { SearchRecentPlaces.remember("/место/\(index)", in: defaults) }
        let places = SearchRecentPlaces.load(from: defaults)
        XCTAssertEqual(places.count, SearchRecentPlaces.limit)
        XCTAssertEqual(places.first, "/место/12")
    }

    func test_пустоеМестоНеЗапоминается() {
        let defaults = ownDefaults()
        SearchRecentPlaces.remember("   ", in: defaults)
        XCTAssertTrue(SearchRecentPlaces.load(from: defaults).isEmpty)
    }
}

// MARK: - «Найти» не молчит

final class SearchValidationTests: XCTestCase {

    @MainActor
    func test_поСодержимому_безТекста_говоритЧегоНеХватает() {
        let vm = AdvancedSearchViewModel()
        vm.searchMode = .byContent
        vm.contentQuery = "   "
        // Раньше кнопка «Найти» в этом случае просто ничего не делала.
        XCTAssertEqual(vm.problemBeforeSearch, L("search.error.needText"))
    }

    @MainActor
    func test_поИмени_пустаяМаска_значитВсёПодряд() {
        let vm = AdvancedSearchViewModel()
        vm.searchMode = .byName
        vm.pattern = ""
        XCTAssertNil(vm.problemBeforeSearch)
    }

    @MainActor
    func test_spotlight_безИмениИТекста_проситЗапрос() {
        let vm = AdvancedSearchViewModel()
        vm.searchMode = .spotlight
        vm.pattern = "*"
        vm.contentQuery = ""
        XCTAssertEqual(vm.problemBeforeSearch, L("search.spot.needQuery"))
        vm.contentQuery = "договор"
        XCTAssertNil(vm.problemBeforeSearch)
    }

    @MainActor
    func test_дубликаты_запросНеНужен() {
        let vm = AdvancedSearchViewModel()
        vm.searchMode = .duplicates
        vm.pattern = ""
        XCTAssertNil(vm.problemBeforeSearch)
    }
}

// MARK: - Новый поиск начинается с чистого листа

final class SearchStartTests: XCTestCase {

    @MainActor
    func test_новыйПоиск_сбрасываетВыбор_иЗапоминаетМесто() throws {
        let folder = try makeOwnFolder("start")
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = ownDefaults()
        let vm = AdvancedSearchViewModel()
        vm.placesDefaults = defaults
        vm.searchMode = .byName
        vm.rootPath = folder.path
        vm.selectedResults = ["/x/прошлая находка.txt"]

        vm.search()
        defer { vm.cancelSearch() }

        XCTAssertTrue(vm.selectedResults.isEmpty, "выбор относился к прошлому списку")
        XCTAssertTrue(vm.hasSearched)
        XCTAssertEqual(vm.resultsMode, .byName)
        XCTAssertEqual(SearchRecentPlaces.load(from: defaults),
                       [(folder.path as NSString).standardizingPath])
    }

    @MainActor
    func test_сменаВкладки_неПерекраиваетСписокПрошлогоПоиска() {
        let vm = AdvancedSearchViewModel()
        vm.resultsMode = .duplicates
        vm.duplicateResults = [DuplicateGroup(size: 9, hash: "a",
                                              files: ["/x/a1.bin", "/x/a2.bin"])]
        vm.selectedResults = ["/x/a2.bin"]

        // Вкладку переключили, чтобы готовить следующий вопрос; ответ на прошлый остаётся.
        vm.searchMode = .byName

        XCTAssertEqual(vm.resultCount, 2)
        XCTAssertEqual(vm.selectedPaths, ["/x/a2.bin"])
        XCTAssertEqual(vm.primarySelection, "/x/a2.bin")
        let rows = SearchResultRows.build(mode: vm.resultsMode, results: vm.results,
                                          duplicates: vm.duplicateResults)
        XCTAssertEqual(rows.count, 3, "заголовок группы и две копии")
    }

    @MainActor
    func test_поискКоторыйНеНачался_ничегоНеТрогает() {
        let defaults = ownDefaults()
        let vm = AdvancedSearchViewModel()
        vm.placesDefaults = defaults
        vm.searchMode = .byContent
        vm.contentQuery = ""
        vm.selectedResults = ["/x/находка.txt"]

        vm.search()

        XCTAssertEqual(vm.selectedResults, ["/x/находка.txt"])
        XCTAssertFalse(vm.hasSearched)
        XCTAssertFalse(vm.isSearching)
        XCTAssertEqual(vm.errorMessage, L("search.error.needText"))
        XCTAssertTrue(SearchRecentPlaces.load(from: defaults).isEmpty)
    }
}

// MARK: - Пределы доходят до ядра и в новых режимах

final class SearchLimitsBridgeTests: XCTestCase {

    func test_содержимое_размерИДата() throws {
        let folder = try makeOwnFolder("content-limits")
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = folder.appendingPathComponent("малый.txt")
        let big = folder.appendingPathComponent("большой.txt")
        let old = folder.appendingPathComponent("старый.txt")
        try Data("договор\n".utf8).write(to: small)
        try Data(("договор\n" + String(repeating: "x", count: 5000)).utf8).write(to: big)
        try Data("договор\n".utf8).write(to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: old.path)
        let service = CoreBridgeService()

        let bigOnly = try service.searchContent(rootPath: folder.path, pattern: "договор",
                                                useRegex: false, minSize: 1000)
        XCTAssertEqual(bigOnly.map(\.name), ["большой.txt"])

        let recent = try service.searchContent(rootPath: folder.path, pattern: "договор",
                                               useRegex: false,
                                               dateFrom: Date().addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(recent.map(\.name).sorted(), ["большой.txt", "малый.txt"])
    }

    func test_дубликаты_размер() throws {
        let folder = try makeOwnFolder("duplicate-limits")
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["м1.bin", "м2.bin"] {
            try Data("мало".utf8).write(to: folder.appendingPathComponent(name))
        }
        for name in ["б1.bin", "б2.bin"] {
            try Data(String(repeating: "b", count: 5000).utf8)
                .write(to: folder.appendingPathComponent(name))
        }
        let service = CoreBridgeService()

        XCTAssertEqual(try service.findDuplicates(rootPath: folder.path).count, 2)
        let big = try service.findDuplicates(rootPath: folder.path, minSize: 1000)
        XCTAssertEqual(big.count, 1)
        XCTAssertEqual(big.first?.size, 5000)
    }

    func test_находкиВКартинках_проходятТеЖеПределы() throws {
        let folder = try makeOwnFolder("picture-limits")
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = folder.appendingPathComponent("малый.png")
        let big = folder.appendingPathComponent("большой.png")
        try Data(count: 100).write(to: small)
        try Data(count: 5000).write(to: big)

        let limits = SearchFileLimits(minBytes: 1000, maxBytes: 0, from: nil, to: nil)
        XCTAssertFalse(limits.allows(path: small.path))
        XCTAssertTrue(limits.allows(path: big.path))
        XCTAssertTrue(SearchFileLimits(minBytes: 0, maxBytes: 0, from: nil, to: nil)
            .allows(path: small.path))
        XCTAssertFalse(SearchFileLimits(minBytes: 0, maxBytes: 0,
                                        from: Date().addingTimeInterval(3600), to: nil)
            .allows(path: big.path), "изменён раньше, чем «от»")
    }
}
