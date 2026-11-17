import Foundation
import XCTest

@testable import TotumComXLApp

// Ошибки окна поиска, найденные разбором 2026-11-16. Каждая проверка здесь — одна из них.

private func hit(_ path: String, line: String? = nil) -> SearchHit {
    SearchHit(path: path, name: (path as NSString).lastPathComponent,
              lineNumber: line == nil ? nil : 1, column: nil, lineContent: line,
              dateModified: nil, size: 1, isDirectory: false)
}

/// Свой временный каталог на проверку: настоящие папки пользователя не трогаются.
private func makeOwnFolder(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fcxl-search-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

// MARK: - Несколько масок

final class SearchNameMaskTests: XCTestCase {

    func test_несколькоМасокЧерезТочкуСЗапятой() {
        XCTAssertTrue(SearchNameMask.matches("*.jpg;*.png", name: "снимок.PNG"))
        XCTAssertTrue(SearchNameMask.matches(" *.jpg ; *.png ;", name: "фото.jpg"))
        XCTAssertFalse(SearchNameMask.matches("*.jpg;*.png", name: "письмо.txt"))
    }

    func test_словоБезЗвёздочек_этоЧастьИмени() {
        XCTAssertTrue(SearchNameMask.matches("отчёт", name: "годовой отчёт 2026.pdf"))
        XCTAssertTrue(SearchNameMask.matches("отчёт;*.png", name: "годовой отчёт 2026.pdf"))
        XCTAssertFalse(SearchNameMask.matches("отчёт;*.png", name: "письмо.txt"))
    }

    func test_пустаяМаскаИЗвёздочка_пропускаютВсё() {
        for mask in ["", "*", "  ", " ; ", "*.txt;*"] {
            XCTAssertTrue(SearchNameMask.matchesEverything(mask), "«\(mask)»")
            XCTAssertTrue(SearchNameMask.matches(mask, name: "что угодно.bin"), "«\(mask)»")
        }
        XCTAssertFalse(SearchNameMask.matchesEverything("*.txt;*.md"))
    }

    func test_находки_просеиваютсяНесколькимиМасками() {
        let hits = [hit("/x/скан.png", line: "договор"), hit("/x/фото.jpg", line: "договор"),
                    hit("/x/письмо.txt", line: "договор")]
        let kept = AdvancedSearchViewModel.filterHitsByName(hits, namePattern: "*.png;*.jpg")
        XCTAssertEqual(kept.map(\.name), ["скан.png", "фото.jpg"])
    }

    func test_группыДубликатов_просеиваютсяНесколькимиМасками() {
        let groups = [
            DuplicateGroup(size: 1, hash: "a", files: ["/x/a.png", "/y/a-копия.png"]),
            DuplicateGroup(size: 1, hash: "b", files: ["/x/b.txt", "/y/b.txt"]),
            DuplicateGroup(size: 1, hash: "c", files: ["/x/c.jpg", "/y/c.bin"]),
        ]
        let kept = AdvancedSearchViewModel.filterDuplicateGroups(groups, namePattern: "*.png;*.jpg")
        XCTAssertEqual(kept.map(\.hash), ["a", "c"])
    }

    func test_spotlight_несколькоМасок_складываютсяЧерезИли() {
        let plan = SpotlightQueryBuilder.maskPlan("*.jpg;*.png")
        let format = plan.predicate?.predicateFormat ?? ""
        XCTAssertTrue(format.contains(" OR "), format)
        XCTAssertTrue(format.contains("jpg") && format.contains("png"), format)
        XCTAssertFalse(plan.postFilter, "обе маски выражаются точно — сито не нужно")
    }

    func test_spotlight_маскаСоЗвёздочкойВнутри_требуетСита_иОноЗнаетВсеМаски() {
        let plan = SpotlightQueryBuilder.maskPlan("отчёт*2026.pdf;*.png")
        XCTAssertTrue(plan.postFilter)
        XCTAssertTrue(SpotlightQueryBuilder.nameMatches(mask: "отчёт*2026.pdf;*.png",
                                                        name: "снимок.png"))
        XCTAssertTrue(SpotlightQueryBuilder.nameMatches(mask: "отчёт*2026.pdf;*.png",
                                                        name: "отчёт за 2026.pdf"))
        XCTAssertFalse(SpotlightQueryBuilder.nameMatches(mask: "отчёт*2026.pdf;*.png",
                                                         name: "отчёт за 2025.pdf"))
    }

    func test_spotlight_звёздочкаСредиМасок_условияНаИмяНет() {
        XCTAssertEqual(SpotlightQueryBuilder.maskPlan("*.txt;*"), .everything)
    }
}

// MARK: - Дата

final class SearchDateRangeTests: XCTestCase {

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

    func test_приВключении_предлагаетсяПоследняяНеделя() {
        let range = SearchDateRange.initial(now: date(2026, 11, 16, 14, 30), calendar: calendar)
        XCTAssertEqual(range.from, date(2026, 11, 9))
        XCTAssertEqual(range.to, date(2026, 11, 16))
    }

    func test_границы_сНачалаПервогоДняДоКонцаПоследнего() {
        // Поле даты хранит и время суток — то, в которое его тронули. День выбирают целиком.
        let bounds = SearchDateRange.bounds(from: date(2026, 11, 9, 17, 45),
                                            to: date(2026, 11, 16, 9, 5), calendar: calendar)
        XCTAssertEqual(bounds.from, date(2026, 11, 9))
        XCTAssertEqual(bounds.to, date(2026, 11, 16, 23, 59, 59))
    }

    func test_границы_пустоеОстаётсяПустым() {
        let bounds = SearchDateRange.bounds(from: nil, to: nil, calendar: calendar)
        XCTAssertNil(bounds.from)
        XCTAssertNil(bounds.to)
    }
}

// MARK: - «Перейти» при нескольких выбранных

final class SearchSelectionTests: XCTestCase {

    @MainActor
    func test_перейти_ведётНаПервыйВыбранныйПоСписку() {
        let vm = AdvancedSearchViewModel()
        vm.resultsMode = .byName
        vm.results = (1...40).map { hit("/x/файл\($0).txt") }
        vm.selectedResults = ["/x/файл31.txt", "/x/файл7.txt", "/x/файл19.txt"]
        // Раньше брался «первый» из множества — то есть какой придётся.
        XCTAssertEqual(vm.primarySelection, "/x/файл7.txt")
    }

    @MainActor
    func test_перейти_вДубликатах_поПорядкуГрупп() {
        let vm = AdvancedSearchViewModel()
        vm.resultsMode = .duplicates
        vm.duplicateResults = [
            DuplicateGroup(size: 9, hash: "a", files: ["/x/a1.bin", "/x/a2.bin"]),
            DuplicateGroup(size: 5, hash: "b", files: ["/x/b1.bin", "/x/b2.bin"]),
        ]
        vm.selectedResults = ["/x/b1.bin", "/x/a2.bin"]
        XCTAssertEqual(vm.primarySelection, "/x/a2.bin")
    }

    @MainActor
    func test_ничегоНеВыбрано_переходитьНекуда() {
        let vm = AdvancedSearchViewModel()
        vm.results = [hit("/x/файл.txt")]
        XCTAssertNil(vm.primarySelection)
    }
}

// MARK: - «Где» при открытии окна

final class SearchRootTests: XCTestCase {

    func test_первоеОткрытие_папкаПанели() {
        XCTAssertEqual(AdvancedSearchPanelController.rootOnOpen(
            panelPath: "/Users/me/Documents", previousRoot: nil, visitedFromResults: nil),
                       "/Users/me/Documents")
    }

    func test_панельУшлаВДругуюПапку_ищемВНей() {
        // Раньше «Где» оставалось от прошлого поиска, и F9 в новой папке искал в старой.
        XCTAssertEqual(AdvancedSearchPanelController.rootOnOpen(
            panelPath: "/Users/me/Music", previousRoot: "/Users/me/Documents",
            visitedFromResults: nil), "/Users/me/Music")
        XCTAssertEqual(AdvancedSearchPanelController.rootOnOpen(
            panelPath: "/Users/me/Music", previousRoot: "/Users/me/Documents",
            visitedFromResults: "/Users/me/Documents/Договоры"), "/Users/me/Music")
    }

    func test_панельСтоитТамКудаПривелаНаходка_поискОстаётсяГдеБыл() {
        // «Перейти» увело панель в папку находки. Открыли окно снова — чтобы идти по списку
        // дальше или уточнить запрос; искать при этом надо там же, где искали.
        XCTAssertEqual(AdvancedSearchPanelController.rootOnOpen(
            panelPath: "/Users/me/Documents/Договоры/", previousRoot: "/Users/me/Documents",
            visitedFromResults: "/Users/me/Documents/Договоры"), "/Users/me/Documents")
    }

    @MainActor
    func test_переходКНаходке_запоминаетЕёПапку() {
        let vm = AdvancedSearchViewModel()
        var opened: String?
        vm.onNavigateToFile = { opened = $0 }
        vm.navigateToResult("/Users/me/Documents/Договоры/аренда.txt")
        XCTAssertEqual(opened, "/Users/me/Documents/Договоры/аренда.txt")
        XCTAssertEqual(vm.visitedFromResults, "/Users/me/Documents/Договоры")
    }
}

// MARK: - «Удалить» спрашивает, как F8

final class SearchDeletionTests: XCTestCase {

    @MainActor
    func test_отказ_ничегоНеУдаляет() async throws {
        let folder = try makeOwnFolder("delete-no")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("нужный.txt")
        try write("x", to: file)

        var asked: [String] = []
        var trashed: [String] = []
        let deleted = try await SearchDeletion.run(
            paths: [file.path],
            confirm: { items, _ in asked = items.map(\.path); return false },
            trash: { trashed = $0.map(\.path) })

        XCTAssertFalse(deleted)
        XCTAssertEqual(asked, [file.path], "вопрос задан — и про тот самый файл")
        XCTAssertTrue(trashed.isEmpty, "без согласия в корзину не уходит ничего")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    func test_согласие_удаляетВыбранное_иСчитаетРазмер() async throws {
        let folder = try makeOwnFolder("delete-yes")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("a.txt")
        let second = folder.appendingPathComponent("b.txt")
        try write("12345", to: first)
        try write("123", to: second)

        var askedBytes: Int64 = 0
        var trashed: [String] = []
        let deleted = try await SearchDeletion.run(
            paths: [first.path, second.path],
            confirm: { _, bytes in askedBytes = bytes; return true },
            trash: { trashed = $0.map(\.path) })

        XCTAssertTrue(deleted)
        XCTAssertEqual(askedBytes, 8)
        XCTAssertEqual(trashed, [first.path, second.path])
    }

    @MainActor
    func test_файловУжеНет_неСпрашиваетИНеУдаляет() async throws {
        var asked = false
        let deleted = try await SearchDeletion.run(
            paths: ["/нет/такого/файла-\(UUID().uuidString)"],
            confirm: { _, _ in asked = true; return true },
            trash: { _ in XCTFail("удалять нечего") })
        XCTAssertFalse(deleted)
        XCTAssertFalse(asked)
    }
}

// MARK: - Сообщения движка — на языке программы

final class SearchErrorTextTests: XCTestCase {

    private func coreError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "com.fcxl.error", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    func test_ошибкиЯдра_переведены() {
        XCTAssertEqual(SearchErrorText.text(for: coreError(5, "Invalid regex pattern")),
                       L("search.error.badRegex"))
        XCTAssertEqual(SearchErrorText.text(for: coreError(1, "Root path does not exist")),
                       L("search.error.rootMissing"))
        XCTAssertEqual(SearchErrorText.text(for: coreError(11, "Root path is not a directory")),
                       L("search.error.rootNotFolder"))
        XCTAssertEqual(SearchErrorText.text(for: coreError(2, "Failed to iterate root path")),
                       L("search.error.noAccess"))
    }

    func test_чужаяОшибка_показываетсяКакЕсть() {
        let other = NSError(domain: "другое", code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "что-то своё"])
        XCTAssertEqual(SearchErrorText.text(for: other), "что-то своё")
    }

    func test_обрывSpotlight_называетНастоящийПредел() {
        let text = String(format: L("search.spot.truncated"), SpotlightSearchService.defaultCap)
        XCTAssertTrue(text.contains("10000") || text.contains("10 000"), text)
    }
}

// MARK: - Условия доходят до ядра

final class SearchBridgeConditionsTests: XCTestCase {

    func test_содержимое_регистр_скрытое_маска() throws {
        let folder = try makeOwnFolder("content")
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("Договор аренды\n", to: folder.appendingPathComponent("видимый.txt"))
        try write("Договор аренды\n", to: folder.appendingPathComponent("видимый.log"))
        try write("Договор аренды\n", to: folder.appendingPathComponent(".git/HEAD.txt"))
        let service = CoreBridgeService()

        func names(caseSensitive: Bool = false, includeHidden: Bool = false,
                   nameMask: String = "") throws -> [String] {
            try service.searchContent(rootPath: folder.path, pattern: "договор", useRegex: false,
                                      caseSensitive: caseSensitive, includeHidden: includeHidden,
                                      nameMask: nameMask)
                .map(\.name).sorted()
        }

        XCTAssertEqual(try names(), ["видимый.log", "видимый.txt"],
                       "регистр не различается, скрытая папка не читается")
        XCTAssertEqual(try names(caseSensitive: true), [], "с учётом регистра «договор» ≠ «Договор»")
        XCTAssertEqual(try names(includeHidden: true), ["HEAD.txt", "видимый.log", "видимый.txt"])
        XCTAssertEqual(try names(nameMask: "*.txt"), ["видимый.txt"])
    }

    func test_дубликаты_скрытоеИСсылки() throws {
        let folder = try makeOwnFolder("duplicates")
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("оригинал.bin")
        try write("одно и то же", to: original)
        try write("одно и то же", to: folder.appendingPathComponent(".git/objects/копия.bin"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("ссылка.bin"), withDestinationURL: original)
        let service = CoreBridgeService()

        XCTAssertTrue(try service.findDuplicates(rootPath: folder.path).isEmpty,
                      "ссылка — не копия, скрытая папка не сравнивается")
        let withHidden = try service.findDuplicates(rootPath: folder.path, includeHidden: true)
        XCTAssertEqual(withHidden.count, 1)
        XCTAssertEqual(withHidden.first?.files.count, 2, "ссылка не копия и здесь")
    }

    func test_поИмени_скрытаяПапкаЦеликом_иНесколькоМасок() throws {
        let folder = try makeOwnFolder("names")
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("x", to: folder.appendingPathComponent("фото.JPG"))
        try write("x", to: folder.appendingPathComponent("снимок.png"))
        try write("x", to: folder.appendingPathComponent("письмо.txt"))
        try write("x", to: folder.appendingPathComponent(".git/внутри.png"))
        let service = CoreBridgeService()

        let hits = try service.advancedSearch(rootPath: folder.path, pattern: "*.jpg;*.png",
                                              useRegex: false)
        XCTAssertEqual(hits.map(\.name).sorted(), ["снимок.png", "фото.JPG"])
    }
}
