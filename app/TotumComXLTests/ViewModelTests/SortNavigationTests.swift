import XCTest
@testable import TotumComXLApp

/// Сортировка по умолчанию и память по папкам — в живой панели.
///
/// С памятью: человек переставил сортировку в папке, вошёл во вложенную, вернулся — и ждёт
/// увидеть то, что выставил. Без памяти: щелчок по столбцу действует только на текущий
/// показ, любой переход в другую папку возвращает сортировку из настроек.
@MainActor
final class SortNavigationTests: XCTestCase {

    private var folder = ""
    private var inside = ""
    private var saved: [String: Any?] = [:]
    private let keys = [SortSettings.fieldKey, SortSettings.ascendingKey,
                        SortSettings.perFolderKey, SortSettings.memoryKey]
    private let bySize = PanelSort(field: .size, ascending: true)

    override func setUpWithError() throws {
        let defaults = UserDefaults.standard
        for key in keys {
            saved[key] = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
        }
        SortMemoryStore.shared.reload()

        // Временная папка лежит за символической ссылкой (/var → /private/var): «..»
        // возвращает по настоящему пути, и память обязана считать это той же папкой.
        folder = NSTemporaryDirectory() + "сорт-\(UUID().uuidString)"
        inside = folder + "/внутри"
        try FileManager.default.createDirectory(atPath: inside, withIntermediateDirectories: true)
        for (name, size) in [("а.txt", 1), ("б.txt", 3), ("в.txt", 2)] {
            FileManager.default.createFile(atPath: folder + "/" + name,
                                           contents: Data(repeating: 0x20, count: size))
            FileManager.default.createFile(atPath: inside + "/" + name,
                                           contents: Data(repeating: 0x20, count: size))
        }
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in keys {
            if let value = saved[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        SortMemoryStore.shared.reload()
        try? FileManager.default.removeItem(atPath: folder)
        super.tearDown()
    }

    private func panel() -> PanelViewModel {
        let id = UUID().uuidString
        return PanelViewModel(service: CoreBridgeService(),
                              initialPath: folder,
                              pathDefaultsKey: "panel.path.сорт.\(id)",
                              viewModeDefaultsKey: "panel.mode.сорт.\(id)",
                              showHiddenFiles: false)
    }

    private func same(_ a: String, _ b: String) -> Bool {
        (a as NSString).standardizingPath == (b as NSString).standardizingPath
    }

    private func подождать(_ условие: @escaping () -> Bool) async throws {
        let срок = Date().addingTimeInterval(3)
        while Date() < срок, !условие() {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Панель в папке, содержимое прочитано.
    private func openedPanel() async throws -> PanelViewModel {
        let vm = panel()
        vm.loadDirectory(at: folder)
        // Размеры приходят вторым проходом — ждём и их, иначе «по размеру» ляжет по именам.
        try await подождать {
            self.same(vm.currentPath, self.folder)
                && vm.items.contains { $0.name == "б.txt" && $0.size == 3 }
        }
        XCTAssertTrue(same(vm.currentPath, folder))
        return vm
    }

    private func files(_ vm: PanelViewModel) -> [String] {
        vm.items.filter { !$0.isDirectory }.map(\.name)
    }

    // MARK: - Память включена

    func test_памятьВключена_ПапкаПомнитСвоюСортировку() async throws {
        UserDefaults.standard.set(true, forKey: SortSettings.perFolderKey)
        let vm = try await openedPanel()
        XCTAssertEqual(vm.currentSort, .standard)

        vm.toggleSort(by: .size)
        XCTAssertEqual(vm.currentSort, bySize)
        XCTAssertEqual(files(vm), ["а.txt", "в.txt", "б.txt"], "по размеру")
        XCTAssertEqual(SortMemoryStore.shared.memory.sort(for: (folder as NSString).standardizingPath),
                       bySize, "запомнено за папкой")

        // Вложенная папка своей памяти не имеет — умолчание.
        let item = try XCTUnwrap(vm.items.first { $0.name == "внутри" })
        XCTAssertTrue(vm.open(item))
        try await подождать { self.same(vm.currentPath, self.inside) && vm.items.count >= 3 }
        XCTAssertEqual(vm.currentSort, .standard, "во вложенной — умолчание")
        XCTAssertEqual(files(vm), ["а.txt", "б.txt", "в.txt"])

        // Назад — и снова по размеру.
        vm.goUp()
        try await подождать { self.same(vm.currentPath, self.folder) && vm.items.count >= 4 }
        XCTAssertEqual(vm.currentSort, bySize, "папка вспомнила свою сортировку")
        XCTAssertEqual(files(vm), ["а.txt", "в.txt", "б.txt"])
    }

    func test_памятьВключена_ПеречитываниеНеСбрасывает() async throws {
        UserDefaults.standard.set(true, forKey: SortSettings.perFolderKey)
        let vm = try await openedPanel()
        vm.toggleSort(by: .size)
        vm.reloadKeepingCursor()
        try await подождать { vm.items.count >= 4 }
        XCTAssertEqual(vm.currentSort, bySize)
        vm.loadDirectory(at: folder)
        try await подождать { vm.items.count >= 4 }
        XCTAssertEqual(vm.currentSort, bySize, "тот же путь — та же сортировка")
    }

    /// Вернули умолчание — папка забыта и снова идёт за настройкой.
    func test_памятьВключена_ВозвратКУмолчаниюЗабываетПапку() async throws {
        UserDefaults.standard.set(true, forKey: SortSettings.perFolderKey)
        let vm = try await openedPanel()
        vm.toggleSort(by: .size)
        XCTAssertEqual(SortMemoryStore.shared.memory.count, 1)
        vm.toggleSort(by: .name)
        XCTAssertEqual(vm.currentSort, .standard)
        XCTAssertEqual(SortMemoryStore.shared.memory.count, 0, "равная умолчанию не хранится")
    }

    // MARK: - Память выключена

    /// Щелчок по столбцу — только на текущий показ: вошли во вложенную — умолчание,
    /// вернулись — снова умолчание, а не то, что здесь переставляли.
    func test_памятьВыключена_ЛюбойПереходВозвращаетУмолчание() async throws {
        let vm = try await openedPanel()
        vm.toggleSort(by: .size)
        XCTAssertEqual(files(vm), ["а.txt", "в.txt", "б.txt"], "на текущем показе — по размеру")

        let item = try XCTUnwrap(vm.items.first { $0.name == "внутри" })
        XCTAssertTrue(vm.open(item))
        try await подождать { self.same(vm.currentPath, self.inside) && vm.items.count >= 3 }
        XCTAssertEqual(vm.currentSort, .standard, "во вложенной — умолчание")

        vm.toggleSort(by: .size)
        vm.goUp()
        try await подождать { self.same(vm.currentPath, self.folder) && vm.items.count >= 4 }
        XCTAssertEqual(vm.currentSort, .standard, "вернулись — и здесь умолчание, а не размер")
        XCTAssertEqual(files(vm), ["а.txt", "б.txt", "в.txt"])
        XCTAssertEqual(SortMemoryStore.shared.memory.count, 0, "ничего не запомнено")
    }

    /// Умолчание из настроек — то, к чему возвращает переход, а не вечное «имя».
    func test_памятьВыключена_ПереходВозвращаетНастроенное() async throws {
        UserDefaults.standard.set(PanelSortField.size.rawValue, forKey: SortSettings.fieldKey)
        UserDefaults.standard.set(false, forKey: SortSettings.ascendingKey)
        let vm = try await openedPanel()
        XCTAssertEqual(files(vm), ["б.txt", "в.txt", "а.txt"], "старт — по размеру, по убыванию")
        vm.toggleSort(by: .name)
        XCTAssertEqual(files(vm), ["а.txt", "б.txt", "в.txt"])

        let item = try XCTUnwrap(vm.items.first { $0.name == "внутри" })
        XCTAssertTrue(vm.open(item))
        // Размеры и здесь приходят вторым проходом — без них «по размеру» ляжет по именам.
        try await подождать {
            self.same(vm.currentPath, self.inside)
                && vm.items.contains { $0.name == "б.txt" && $0.size == 3 }
        }
        XCTAssertEqual(vm.currentSort, PanelSort(field: .size, ascending: false))
        XCTAssertEqual(files(vm), ["б.txt", "в.txt", "а.txt"])
    }

    /// Перечитывание той же папки — не переход: переставленное остаётся.
    func test_памятьВыключена_ПеречитываниеНеСбрасывает() async throws {
        let vm = try await openedPanel()
        vm.toggleSort(by: .size)
        vm.reloadKeepingCursor()
        try await подождать { vm.items.count >= 4 }
        XCTAssertEqual(vm.currentSort, bySize)
        XCTAssertEqual(files(vm), ["а.txt", "в.txt", "б.txt"])
    }

    /// Переключение вкладки на ту же папку — другой показ: сортировка решается заново.
    func test_переключениеВкладкиРешаетСортировкуЗаново() async throws {
        let vm = try await openedPanel()
        vm.toggleSort(by: .size)
        vm.forgetAdoptedSort()
        vm.loadDirectory(at: folder)
        try await подождать { vm.currentSort == .standard }
        XCTAssertEqual(vm.currentSort, .standard)
    }

    // MARK: - Умолчание

    func test_умолчаниеИзНастроек_СтартоваяСортировкаПанели() async throws {
        UserDefaults.standard.set(PanelSortField.dateModified.rawValue, forKey: SortSettings.fieldKey)
        UserDefaults.standard.set(false, forKey: SortSettings.ascendingKey)
        let vm = try await openedPanel()
        XCTAssertEqual(vm.currentSort, PanelSort(field: .dateModified, ascending: false))
    }
}
