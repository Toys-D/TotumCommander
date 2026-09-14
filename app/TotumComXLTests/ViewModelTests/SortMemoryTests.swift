import XCTest
@testable import TotumComXLApp

/// Сортировка по умолчанию и память сортировки по папкам — чистые правила.
///
/// Раньше каждый запуск и каждая вкладка начинались с имени по возрастанию, а сортировка,
/// переставленная в одной папке, уходила во все следующие. Теперь умолчание задаётся в
/// настройках, а с включённой памятью папка помнит то, что в ней выставили сами.
final class SortMemoryTests: XCTestCase {

    private let bySize = PanelSort(field: .size, ascending: false)
    private let byDate = PanelSort(field: .dateModified, ascending: false)
    private var defaults: UserDefaults!
    private let suite = "fcxl.tests.sort.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: - Вход в папку

    /// Память выключена: в любую папку входим с умолчанием из настроек — переставленное
    /// щелчком по столбцу действовало только на тот показ, и старая память не смотрится.
    func test_памятьВыключена_ВходВПапкуВозвращаетУмолчание() {
        var memory = SortMemory()
        memory.remember(byDate, for: "/a")
        let standard = PanelSort(field: .type, ascending: true)
        XCTAssertEqual(SortChoice.entering(path: "/a", memory: memory,
                                           standard: standard, perFolder: false), standard)
    }

    func test_памятьВключена_УПапкиСвояСортировка() {
        var memory = SortMemory()
        memory.remember(byDate, for: "/a")
        XCTAssertEqual(SortChoice.entering(path: "/a", memory: memory,
                                           standard: .standard, perFolder: true), byDate)
    }

    /// Папка без своей памяти идёт за умолчанием, а не за тем, что было в предыдущей.
    func test_памятьВключена_БезСвоей_Умолчание() {
        let standard = PanelSort(field: .type, ascending: true)
        XCTAssertEqual(SortChoice.entering(path: "/b", memory: SortMemory(),
                                           standard: standard, perFolder: true), standard)
    }

    func test_хвостоваяКосаяНеДелаетПапкуДругой() {
        var memory = SortMemory()
        memory.remember(byDate, for: "/a/b/")
        XCTAssertEqual(memory.sort(for: "/a/b"), byDate)
        XCTAssertEqual(memory.sort(for: "/a/b/"), byDate)
        XCTAssertNil(memory.sort(for: "/a"), "родитель — другая папка")
    }

    // MARK: - После перестановки

    func test_переставленная_Запоминается() {
        var memory = SortMemory()
        SortChoice.afterChange(to: bySize, in: "/a", memory: &memory,
                               standard: .standard, perFolder: true)
        XCTAssertEqual(memory.sort(for: "/a"), bySize)
    }

    /// Вернули умолчание — папка забывается и снова идёт за настройкой.
    func test_равнаяУмолчанию_Забывается() {
        var memory = SortMemory()
        memory.remember(bySize, for: "/a")
        SortChoice.afterChange(to: .standard, in: "/a", memory: &memory,
                               standard: .standard, perFolder: true)
        XCTAssertNil(memory.sort(for: "/a"))
    }

    func test_памятьВыключена_НичегоНеЗапоминается() {
        var memory = SortMemory()
        SortChoice.afterChange(to: bySize, in: "/a", memory: &memory,
                               standard: .standard, perFolder: false)
        XCTAssertEqual(memory.count, 0)
    }

    // MARK: - Границы памяти

    /// Больше предела — забываются самые давние, а не самые свежие.
    func test_памятьОграничена_ДавниеЗабываются() {
        var memory = SortMemory()
        for index in 0..<(SortMemory.limit + 10) {
            memory.remember(bySize, for: "/папка\(index)")
        }
        XCTAssertEqual(memory.count, SortMemory.limit)
        XCTAssertNil(memory.sort(for: "/папка0"), "самая давняя забыта")
        XCTAssertNotNil(memory.sort(for: "/папка\(SortMemory.limit + 9)"), "свежая на месте")
    }

    /// Повторное обращение к папке делает её свежей — её не выдавит новыми.
    func test_повторноеОбращениеОсвежает() {
        var memory = SortMemory()
        for index in 0..<SortMemory.limit {
            memory.remember(bySize, for: "/папка\(index)")
        }
        memory.remember(byDate, for: "/папка0")
        memory.remember(bySize, for: "/новая")
        XCTAssertEqual(memory.sort(for: "/папка0"), byDate, "освежённая осталась")
        XCTAssertNil(memory.sort(for: "/папка1"), "вместо неё ушла следующая по давности")
        XCTAssertEqual(memory.count, SortMemory.limit)
    }

    // MARK: - Хранение

    func test_памятьПереживаетЗаписьИЧтение() {
        var memory = SortMemory()
        memory.remember(bySize, for: "/a")
        memory.remember(byDate, for: "/б/в")
        memory.save(to: defaults)
        let read = SortMemory.load(from: defaults)
        XCTAssertEqual(read, memory)
        XCTAssertEqual(read.sort(for: "/б/в"), byDate)
    }

    func test_пустаяПамятьНеОставляетСледаВНастройках() {
        var memory = SortMemory()
        memory.remember(bySize, for: "/a")
        memory.save(to: defaults)
        memory.forgetAll()
        memory.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: SortSettings.memoryKey))
        XCTAssertEqual(SortMemory.load(from: defaults).count, 0)
    }

    func test_испорченноеВНастройках_КакПустое() {
        defaults.set(Data("ерунда".utf8), forKey: SortSettings.memoryKey)
        XCTAssertEqual(SortMemory.load(from: defaults).count, 0)
    }

    /// Хранилище читает один раз и пишет при каждой перемене.
    @MainActor
    func test_хранилищеЧитаетИПишет() {
        let store = SortMemoryStore(defaults: defaults)
        XCTAssertEqual(store.memory.count, 0)
        var memory = store.memory
        memory.remember(bySize, for: "/a")
        store.memory = memory
        XCTAssertEqual(SortMemory.load(from: defaults).sort(for: "/a"), bySize, "записано сразу")
        XCTAssertEqual(SortMemoryStore(defaults: defaults).memory.sort(for: "/a"), bySize)
    }

    // MARK: - Умолчание из настроек

    func test_умолчаниеБезНастроек_ИмяПоВозрастанию() {
        XCTAssertEqual(SortSettings.defaultSort(in: defaults), .standard)
    }

    func test_умолчаниеЧитаетсяИзНастроек() {
        defaults.set(PanelSortField.size.rawValue, forKey: SortSettings.fieldKey)
        defaults.set(false, forKey: SortSettings.ascendingKey)
        XCTAssertEqual(SortSettings.defaultSort(in: defaults), bySize)
    }

    /// Поле, которого нет среди выбираемых (мусор или «откуда» из корзины), — умолчание.
    func test_чужоеПолеВНастройках_Умолчание() {
        defaults.set("ерунда", forKey: SortSettings.fieldKey)
        XCTAssertEqual(SortSettings.defaultSort(in: defaults), .standard)
        defaults.set(PanelSortField.origin.rawValue, forKey: SortSettings.fieldKey)
        XCTAssertEqual(SortSettings.defaultSort(in: defaults), .standard)
    }

    /// Строковые значения полей — договор с настройками и вкладками: не должны меняться.
    func test_значенияПолейУстойчивы() {
        let expected: [PanelSortField: String] = [
            .name: "name", .type: "type", .fileExtension: "extension", .size: "size",
            .dateCreated: "created", .dateModified: "modified", .dateAdded: "added",
            .permissions: "permissions", .owner: "owner", .origin: "origin"
        ]
        for (field, raw) in expected {
            XCTAssertEqual(field.rawValue, raw)
            XCTAssertEqual(PanelSortField(rawValue: raw), field)
        }
        XCTAssertEqual(SortSettings.choices.count, 9)
        XCTAssertFalse(SortSettings.choices.contains(.origin), "«откуда» есть только в корзине")
        for field in SortSettings.choices {
            XCTAssertFalse(L(field.titleKey).hasPrefix("column."), "нет перевода: \(field)")
            XCTAssertFalse(L(field.titleKey).hasPrefix("properties."), "нет перевода: \(field)")
        }
    }
}
