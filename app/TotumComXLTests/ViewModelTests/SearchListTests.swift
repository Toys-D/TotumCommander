import Foundation
import XCTest

@testable import TotumComXLApp

// Список находок окна поиска (третий шаг разбора 2026-11-16): порядок по колонкам, подписи,
// одна строка на файл.

private func file(_ path: String, size: UInt64? = 1, date: Date? = nil) -> SearchHit {
    SearchHit(path: path, name: (path as NSString).lastPathComponent,
              lineNumber: nil, column: nil, lineContent: nil,
              dateModified: date, size: size, isDirectory: false)
}

private func folder(_ path: String) -> SearchHit {
    SearchHit(path: path, name: (path as NSString).lastPathComponent,
              lineNumber: nil, column: nil, lineContent: nil,
              dateModified: nil, size: nil, isDirectory: true)
}

private func makeOwnFolder(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fcxl-search-list-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Порядок

final class SearchSortTests: XCTestCase {

    private func names(_ hits: [SearchHit], by key: SearchSortKey, ascending: Bool = true) -> [String] {
        SearchSort.sorted(hits, by: key, ascending: ascending).map(\.name)
    }

    func test_поИмени_папкиСверху_числаПоСмыслу() {
        let hits = [file("/x/файл10.txt"), file("/x/файл2.txt"), folder("/x/яблоки"),
                    file("/x/Арбуз.txt"), folder("/x/архив")]
        XCTAssertEqual(names(hits, by: .name),
                       ["архив", "яблоки", "Арбуз.txt", "файл2.txt", "файл10.txt"])
    }

    func test_поИмениПоУбыванию_папкиВсёРавноСверху() {
        let hits = [file("/x/а.txt"), folder("/x/б"), file("/x/в.txt"), folder("/x/г")]
        XCTAssertEqual(names(hits, by: .name, ascending: false), ["г", "б", "в.txt", "а.txt"])
    }

    func test_поРазмеру_уКогоРазмераНет_вКонцеВОбеСтороны() {
        let hits = [file("/x/средний", size: 50), folder("/x/папка"), file("/x/большой", size: 900),
                    file("/x/малый", size: 1), file("/x/неизвестный", size: nil)]
        XCTAssertEqual(names(hits, by: .size),
                       ["малый", "средний", "большой", "неизвестный", "папка"])
        XCTAssertEqual(names(hits, by: .size, ascending: false),
                       ["большой", "средний", "малый", "неизвестный", "папка"])
    }

    func test_поДате_безДаты_вКонце() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 9_000)
        let hits = [file("/x/новый", date: new), file("/x/без даты"), file("/x/старый", date: old)]
        XCTAssertEqual(names(hits, by: .date), ["старый", "новый", "без даты"])
        XCTAssertEqual(names(hits, by: .date, ascending: false), ["новый", "старый", "без даты"])
    }

    func test_поПапке_аВнутриПапки_поИмени() {
        let hits = [file("/б/2.txt"), file("/а/2.txt"), file("/б/1.txt"), file("/а/1.txt")]
        XCTAssertEqual(SearchSort.sorted(hits, by: .folder, ascending: true).map(\.path),
                       ["/а/1.txt", "/а/2.txt", "/б/1.txt", "/б/2.txt"])
        XCTAssertEqual(SearchSort.sorted(hits, by: .folder, ascending: false).map(\.path),
                       ["/б/1.txt", "/б/2.txt", "/а/1.txt", "/а/2.txt"])
    }

    @MainActor
    func test_щелчокПоКолонке_меняетПорядокСписка_аПовторный_направление() {
        let vm = AdvancedSearchViewModel()
        vm.sortDefaults = nil
        vm.setSort(key: .name, ascending: true)   // с чего бы ни начинали настройки программы
        vm.results = [file("/x/б", size: 5), file("/x/а", size: 9), file("/x/в", size: 1)]
        vm.sort(by: .size)
        XCTAssertEqual(vm.results.map(\.name), ["в", "б", "а"])
        vm.sort(by: .size)
        XCTAssertEqual(vm.results.map(\.name), ["а", "б", "в"], "тот же заголовок — в обратную сторону")
        vm.sort(by: .name)
        XCTAssertEqual(vm.results.map(\.name), ["а", "б", "в"])
        XCTAssertEqual(vm.sortKey, .name)
        XCTAssertTrue(vm.sortAscending, "новая колонка начинается по возрастанию")
    }
}

// MARK: - Подписи

final class SearchListTextTests: XCTestCase {

    func test_числоСоСловом_поПравиламРусского() {
        let forms = [1: CountText.Form.one, 2: .few, 4: .few, 5: .many, 11: .many, 12: .many,
                     14: .many, 21: .one, 22: .few, 25: .many, 101: .one, 111: .many]
        for (count, form) in forms {
            XCTAssertEqual(CountText.form(count, slavic: true), form, "\(count)")
        }
    }

    func test_числоСоСловом_поПравиламАнглийского() {
        XCTAssertEqual(CountText.form(1, slavic: false), .one)
        for count in [0, 2, 5, 21, 101] {
            XCTAssertEqual(CountText.form(count, slavic: false), .many, "\(count)")
        }
    }

    func test_подписьГруппы_неГоворит_дваФайлов() {
        let text = CountText.files(2)
        XCTAssertTrue(text.contains("2"))
        XCTAssertFalse(text.hasPrefix("search."), "нет перевода: \(text)")
        if L("count.rule") == "slavic" { XCTAssertEqual(text, "2 файла") }
    }

    func test_строкаНаходки_номерТекстИСколькоЕщё() {
        XCTAssertEqual(SearchMatchText.text(line: 12, content: "    договор аренды", count: 1),
                       "12: договор аренды")
        XCTAssertEqual(SearchMatchText.text(line: 12, content: "договор", count: 4),
                       "12: договор   (+3)")
        XCTAssertNil(SearchMatchText.text(line: nil, content: nil, count: 1))
    }
}

// MARK: - Одна строка на файл

final class SearchContentRowsTests: XCTestCase {

    func test_поСодержимому_файлВСпискеОдинРаз_сЧисломСовпаденийРазмеромИДатой() throws {
        let folder = try makeOwnFolder("content-rows")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("первый договор\nпусто\nвторой договор\nтретий договор\n".utf8)
            .write(to: folder.appendingPathComponent("много.txt"))
        try Data("один договор\n".utf8).write(to: folder.appendingPathComponent("один.txt"))

        let hits = try CoreBridgeService().searchContent(rootPath: folder.path,
                                                         pattern: "договор", useRegex: false)
            .sorted { $0.name < $1.name }

        XCTAssertEqual(hits.map(\.name), ["много.txt", "один.txt"])
        XCTAssertEqual(hits[0].matchCount, 3)
        XCTAssertEqual(hits[0].lineNumber, 1)
        XCTAssertEqual(hits[0].lineContent, "первый договор")
        XCTAssertEqual(hits[1].matchCount, 1)
        XCTAssertNotNil(hits[0].dateModified, "колонке «Изменён» есть что показать")
        XCTAssertGreaterThan(hits[0].size ?? 0, 0)
    }
}

// MARK: - Клавиши окна поиска

final class SearchKeysTests: XCTestCase {

    func test_fКлавиши_относятсяКНаходкам() {
        XCTAssertEqual(SearchKeys.action(keyCode: 99, modifiers: []), .quickLook)   // F3
        XCTAssertEqual(SearchKeys.action(keyCode: 118, modifiers: []), .edit)       // F4
        XCTAssertEqual(SearchKeys.action(keyCode: 96, modifiers: []), .copy)        // F5
        XCTAssertEqual(SearchKeys.action(keyCode: 97, modifiers: []), .move)        // F6
        XCTAssertEqual(SearchKeys.action(keyCode: 100, modifiers: []), .delete)     // F8
        // Сама F-клавиша несёт признак «функциональная» — он действию не мешает.
        XCTAssertEqual(SearchKeys.action(keyCode: 100, modifiers: [.function]), .delete)
    }

    func test_сМодификатором_этоДругиеКомандыПрограммы() {
        XCTAssertNil(SearchKeys.action(keyCode: 96, modifiers: [.command]), "⌘F5 — упаковать")
        XCTAssertNil(SearchKeys.action(keyCode: 100, modifiers: [.shift]), "⇧F8 — мимо корзины")
        XCTAssertNil(SearchKeys.action(keyCode: 118, modifiers: [.shift]), "⇧F4 — создать файл")
    }

    func test_остальныеКлавиши_окноНеЗабирает() {
        for code: UInt16 in [98 /* F7 */, 101 /* F9 */, 120 /* F2 */, 36 /* ↩ */, 49 /* пробел */] {
            XCTAssertNil(SearchKeys.action(keyCode: code, modifiers: []), "\(code)")
        }
    }
}

// MARK: - Колонка «Папка»

final class SearchFolderTextTests: XCTestCase {

    func test_путьСчитаетсяОтМестаПоиска() {
        XCTAssertEqual(SearchFolderText.text(itemPath: "/Users/me/docs/a.txt",
                                             root: "/Users/me/docs"), "docs")
        XCTAssertEqual(SearchFolderText.text(itemPath: "/Users/me/docs/договоры/2026/a.txt",
                                             root: "/Users/me/docs/"), "docs/договоры/2026")
    }

    func test_находкаВнеМестаПоиска_полныйПуть() {
        XCTAssertEqual(SearchFolderText.text(itemPath: "/Volumes/Диск/a.txt",
                                             root: "/Users/me/docs"), "/Volumes/Диск")
        XCTAssertEqual(SearchFolderText.text(itemPath: "/Users/me/docs-старые/a.txt",
                                             root: "/Users/me/docs"), "/Users/me/docs-старые",
                       "похожее начало имени — ещё не та папка")
        XCTAssertEqual(SearchFolderText.text(itemPath: "/Volumes/Диск/a.txt", root: "/"),
                       "/Volumes/Диск", "поиск по всему Mac — пути полные")
    }
}

// MARK: - Действия над находками

final class SearchActionsTests: XCTestCase {

    @MainActor
    private func model() -> AdvancedSearchViewModel {
        let vm = AdvancedSearchViewModel()
        vm.sortDefaults = nil
        vm.resultsMode = .byName
        vm.resultsRoot = "/x"
        vm.results = (1...9).map { file("/x/файл\($0).txt") }
        return vm
    }

    @MainActor
    func test_копироватьИПереместить_отдаютВыбранноеВПорядкеСписка() {
        let vm = model()
        vm.selectedResults = ["/x/файл7.txt", "/x/файл2.txt", "/x/файл5.txt"]
        var calls: [(paths: [String], isCopy: Bool)] = []
        vm.onTransfer = { calls.append(($0, $1)) }

        vm.perform(.copy)
        vm.perform(.move)

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].paths, ["/x/файл2.txt", "/x/файл5.txt", "/x/файл7.txt"])
        XCTAssertTrue(calls[0].isCopy)
        XCTAssertFalse(calls[1].isCopy)
    }

    @MainActor
    func test_редактировать_иПерейти_берутПервыйВыбранный() {
        let vm = model()
        vm.selectedResults = ["/x/файл8.txt", "/x/файл3.txt"]
        var edited: String?
        var opened: String?
        var closed = 0
        vm.onEdit = { edited = $0 }
        vm.onNavigateToFile = { opened = $0 }
        vm.onClose = { closed += 1 }

        vm.perform(.edit)
        XCTAssertEqual(edited, "/x/файл3.txt")
        XCTAssertEqual(closed, 0, "правка окно поиска не закрывает")

        vm.perform(.goTo)
        XCTAssertEqual(opened, "/x/файл3.txt")
        XCTAssertEqual(closed, 1, "панель с курсором на находке должна быть видна")
    }

    @MainActor
    func test_вПанель_отдаётВесьСписокИМестоПоиска_дажеБезВыбора() {
        let vm = model()
        vm.selectedResults = []
        var sent: (paths: [String], root: String)?
        var closed = 0
        vm.onShowInPanel = { sent = ($0, $1) }
        vm.onClose = { closed += 1 }

        vm.perform(.toPanel)

        XCTAssertEqual(sent?.paths.count, 9)
        XCTAssertEqual(sent?.paths.first, "/x/файл1.txt")
        XCTAssertEqual(sent?.root, "/x")
        XCTAssertEqual(closed, 1)
    }

    @MainActor
    func test_безВыбора_действияНадВыбраннымМолчат() {
        let vm = model()
        vm.selectedResults = []
        vm.onTransfer = { _, _ in XCTFail("копировать нечего") }
        vm.onDeleteFiles = { _ in XCTFail("удалять нечего") }
        vm.onEdit = { _ in XCTFail("править нечего") }
        vm.onQuickLook = { XCTFail("смотреть нечего") }
        vm.onNavigateToFile = { _ in XCTFail("идти некуда") }
        for action: SearchResultAction in [.copy, .move, .delete, .edit, .quickLook, .goTo] {
            vm.perform(action)
        }
    }

    @MainActor
    func test_пустойСписок_вПанельНеИдёт() {
        let vm = AdvancedSearchViewModel()
        vm.onShowInPanel = { _, _ in XCTFail("показывать нечего") }
        vm.onClose = { XCTFail("окно закрывать незачем") }
        vm.perform(.toPanel)
    }

    @MainActor
    func test_дубликаты_выбранноеИдётПоПорядкуГрупп() {
        let vm = AdvancedSearchViewModel()
        vm.resultsMode = .duplicates
        vm.duplicateResults = [
            DuplicateGroup(size: 9, hash: "a", files: ["/x/a1.bin", "/x/a2.bin"]),
            DuplicateGroup(size: 5, hash: "b", files: ["/x/b1.bin", "/x/b2.bin"]),
        ]
        vm.selectedResults = ["/x/b2.bin", "/x/a2.bin"]
        var deleted: [String] = []
        vm.onDeleteFiles = { deleted = $0 }

        vm.perform(.delete)

        XCTAssertEqual(deleted, ["/x/a2.bin", "/x/b2.bin"])
        XCTAssertEqual(vm.allResultPaths, ["/x/a1.bin", "/x/a2.bin", "/x/b1.bin", "/x/b2.bin"])
    }

    @MainActor
    func test_правоеМеню_теЖеДействия_чтоУКнопокИКлавиш() {
        let vm = model()
        let titles = vm.resultsMenu().items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, [L("search.menu.goto"), L("search.menu.quickLook"),
                                L("search.menu.edit"), L("search.menu.toPanel"),
                                L("search.menu.copy"), L("search.menu.move"),
                                L("search.menu.copyPath"), L("search.menu.delete")])
        for title in titles { XCTAssertFalse(title.hasPrefix("search."), "нет перевода: \(title)") }
    }
}

// MARK: - «Результаты в панель»

final class FoundFilesPanelTests: XCTestCase {

    func test_находкиСтановятсяСтрокамиПанели_сПутёмОтМестаПоиска() throws {
        let folder = try makeOwnFolder("found")
        defer { try? FileManager.default.removeItem(at: folder) }
        let deep = folder.appendingPathComponent("договоры/2026")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("письмо.txt")
        let second = deep.appendingPathComponent("аренда.txt")
        try Data("x".utf8).write(to: first)
        try Data("x".utf8).write(to: second)

        let items = PanelViewModel.buildFoundItems(
            paths: [first.path, second.path, folder.appendingPathComponent("уже удалён.txt").path,
                    deep.path],
            root: folder.path)

        XCTAssertEqual(items.map(\.name), ["письмо.txt", "аренда.txt", "2026"],
                       "чего на диске уже нет, в списке нет")
        XCTAssertEqual(items.map(\.branchPath), ["письмо.txt", "договоры/2026/аренда.txt",
                                                 "договоры/2026"])
        XCTAssertTrue(items[2].isDirectory, "найденная папка — тоже строка")
    }
}

// MARK: - Дубликаты: лишние копии

final class DuplicateSelectionTests: XCTestCase {

    private let groups = [
        DuplicateGroup(size: 1000, hash: "a", files: ["/x/a1", "/x/a2", "/x/a3"]),
        DuplicateGroup(size: 50, hash: "b", files: ["/x/b1", "/x/b2"]),
    ]
    private let dates: [String: Date] = [
        "/x/a1": Date(timeIntervalSince1970: 200), "/x/a2": Date(timeIntervalSince1970: 300),
        "/x/a3": Date(timeIntervalSince1970: 100),
        "/x/b1": Date(timeIntervalSince1970: 500), "/x/b2": Date(timeIntervalSince1970: 500),
    ]

    private func extras(_ keep: DuplicateKeep) -> Set<String> {
        DuplicateSelection.extras(in: groups, keep: keep) { self.dates[$0] }
    }

    func test_оставитьСамыйНовый_остальныеЛишние() {
        XCTAssertEqual(extras(.newest), ["/x/a1", "/x/a3", "/x/b2"],
                       "при равных датах остаётся первый по списку")
    }

    func test_оставитьСамыйСтарый() {
        XCTAssertEqual(extras(.oldest), ["/x/a1", "/x/a2", "/x/b2"])
    }

    func test_оставитьПервыйПоПути() {
        XCTAssertEqual(extras(.firstByPath), ["/x/a2", "/x/a3", "/x/b2"])
    }

    func test_вКаждойГруппеВсегдаОстаётсяОдин_дажеЕслиДатНет() {
        let chosen = DuplicateSelection.extras(in: groups, keep: .newest) { _ in nil }
        XCTAssertEqual(chosen, ["/x/a2", "/x/a3", "/x/b2"])
        for group in groups {
            XCTAssertEqual(group.files.filter { !chosen.contains($0) }.count, 1)
        }
    }

    func test_сколькоОсвободится_иГдеВыбраныВсеКопии() {
        let partly = DuplicateSelection.summary(groups: groups, selected: ["/x/a1", "/x/a3", "/x/b2"])
        XCTAssertEqual(partly.bytes, 2050)
        XCTAssertEqual(partly.emptiedGroups, 0)

        let all = DuplicateSelection.summary(groups: groups, selected: ["/x/b1", "/x/b2", "/x/a1"])
        XCTAssertEqual(all.bytes, 1100)
        XCTAssertEqual(all.emptiedGroups, 1, "в группе «b» не останется ни одной копии")

        XCTAssertEqual(DuplicateSelection.summary(groups: groups, selected: []).bytes, 0)
    }

    @MainActor
    func test_окно_выбратьЛишние_поДатамСДиска() throws {
        let folder = try makeOwnFolder("dup-select")
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("старая.bin")
        let new = folder.appendingPathComponent("новая.bin")
        try Data("одно".utf8).write(to: old)
        try Data("одно".utf8).write(to: new)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: old.path)

        let vm = AdvancedSearchViewModel()
        vm.resultsMode = .duplicates
        vm.duplicateResults = [DuplicateGroup(size: 4, hash: "h", files: [new.path, old.path])]

        vm.selectDuplicateExtras(keep: .newest)
        XCTAssertEqual(vm.selectedResults, [old.path])
        XCTAssertEqual(vm.duplicateSummary?.bytes, 4)

        vm.selectDuplicateExtras(keep: .oldest)
        XCTAssertEqual(vm.selectedResults, [new.path])
    }

    func test_поРазмеру_большеНеПредлагается() {
        // Одинаковый размер — ещё не копия; критерий остался только у движка.
        XCTAssertEqual(DuplicateMode.shown, [.byHash, .byName])
    }
}

// MARK: - История запросов

final class SearchHistoryTests: XCTestCase {

    private func ownDefaults() -> UserDefaults {
        let name = "fcxl-search-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func test_новыйЗапросПервым_повторПоднимается_именаИТекстыПорознь() {
        let defaults = ownDefaults()
        SearchHistory.remember("*.txt", kind: .name, in: defaults)
        SearchHistory.remember("отчёт", kind: .name, in: defaults)
        SearchHistory.remember(" *.txt ", kind: .name, in: defaults)
        SearchHistory.remember("договор", kind: .text, in: defaults)
        XCTAssertEqual(SearchHistory.load(.name, from: defaults), ["*.txt", "отчёт"])
        XCTAssertEqual(SearchHistory.load(.text, from: defaults), ["договор"])
    }

    func test_пустоеИЗвёздочка_неЗапоминаются() {
        let defaults = ownDefaults()
        for query in ["", "   ", "*"] { SearchHistory.remember(query, kind: .name, in: defaults) }
        XCTAssertTrue(SearchHistory.load(.name, from: defaults).isEmpty)
    }

    func test_помнитНеБольшеПятнадцати_иОчищается() {
        let defaults = ownDefaults()
        for index in 1...20 { SearchHistory.remember("запрос \(index)", kind: .text, in: defaults) }
        XCTAssertEqual(SearchHistory.load(.text, from: defaults).count, SearchHistory.limit)
        XCTAssertEqual(SearchHistory.load(.text, from: defaults).first, "запрос 20")
        SearchHistory.clear(.text, in: defaults)
        XCTAssertTrue(SearchHistory.load(.text, from: defaults).isEmpty)
    }

    @MainActor
    func test_поиск_запоминаетТоЧтоИскали() throws {
        let folder = try makeOwnFolder("history")
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = ownDefaults()
        let vm = AdvancedSearchViewModel()
        vm.placesDefaults = defaults
        vm.sortDefaults = nil
        vm.rootPath = folder.path

        vm.searchMode = .byName
        vm.pattern = "*.swift"
        vm.search()
        vm.cancelSearch()
        vm.searchMode = .byContent
        vm.contentQuery = "договор"
        vm.search()
        vm.cancelSearch()

        XCTAssertEqual(SearchHistory.load(.name, from: defaults), ["*.swift"],
                       "по содержимому маска — фильтр, в историю имён она не идёт")
        XCTAssertEqual(SearchHistory.load(.text, from: defaults), ["договор"])
    }
}

// MARK: - Находки по мере поиска

final class SearchStreamingTests: XCTestCase {

    func test_поИмени_находкиПриходятПоХодуОбхода_иСовпадаютСИтогом() throws {
        let folder = try makeOwnFolder("stream-names")
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 1...600 {
            try Data().write(to: folder.appendingPathComponent("файл\(index).txt"))
        }
        var streamed: [String] = []
        var batches = 0

        let final = try CoreBridgeService().advancedSearch(
            rootPath: folder.path, pattern: "*.txt", useRegex: false,
            onFound: { batch in
                batches += 1
                streamed.append(contentsOf: batch.map(\.name))
            })

        XCTAssertEqual(final.count, 600)
        XCTAssertGreaterThan(batches, 1, "шестьсот находок приходят не одним куском в конце")
        XCTAssertEqual(Set(streamed), Set(final.map(\.name)), "по ходу пришло всё то же, что в итоге")
        XCTAssertEqual(streamed.count, 600, "и ничего дважды")
    }

    func test_поСодержимому_файлПриходитКогдаПрочитанДоКонца() throws {
        let folder = try makeOwnFolder("stream-content")
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 1...300 {
            try Data("договор\nещё договор\n".utf8)
                .write(to: folder.appendingPathComponent("файл\(index).txt"))
        }
        var streamed: [SearchHit] = []

        let final = try CoreBridgeService().searchContent(
            rootPath: folder.path, pattern: "договор", useRegex: false,
            onFound: { streamed.append(contentsOf: $0) })

        XCTAssertEqual(final.count, 300)
        XCTAssertEqual(streamed.count, 300)
        XCTAssertTrue(streamed.allSatisfy { $0.matchCount == 2 }, "число совпадений уже окончательное")
    }

    @MainActor
    func test_окно_дописываетНаходки_держитПорядок_иНеПереполняется() {
        let vm = AdvancedSearchViewModel()
        vm.sortDefaults = nil
        vm.setSort(key: .name, ascending: true)
        vm.appendFound([file("/x/в.txt"), file("/x/а.txt")], limit: 3)
        XCTAssertEqual(vm.results.map(\.name), ["а.txt", "в.txt"])
        vm.appendFound([file("/x/б.txt"), file("/x/г.txt"), file("/x/д.txt")], limit: 3)
        XCTAssertEqual(vm.results.map(\.name), ["а.txt", "б.txt", "в.txt"],
                       "сверх предела не берётся — итог поиска скажет, сколько было всего")
        vm.appendFound([file("/x/е.txt")], limit: 3)
        XCTAssertEqual(vm.results.count, 3)
    }
}
