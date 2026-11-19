import XCTest
@testable import TotumComXLApp

/// Настройка вкладок подключаемых мест на настоящей панели: щелчок по диску на полосе, вход в
/// сетевую папку и в образ открывают место там, где велено, — в своей вкладке или в текущей.
/// Диски здесь — временные папки; настройки — в своём наборе, не в настройках программы.
@MainActor
final class PlaceTabsFlowTests: XCTestCase {

    private var base = ""
    private var disk = ""
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var panelKey = ""
    private var commonViewMode: Any?

    override func setUp() async throws {
        try await super.setUp()
        base = NSTemporaryDirectory() + "места-\(UUID().uuidString)"
        disk = base + "/Флешка"
        try FileManager.default.createDirectory(atPath: disk + "/Фото", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: base + "/Работа", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: disk + "/заметка.txt", contents: Data("x".utf8))
        suiteName = "place-flow-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        panelKey = "place.flow.\(UUID().uuidString)"
        // Переключение вкладки записывает общий вид панели — вернём как было.
        commonViewMode = UserDefaults.standard.object(forKey: "fcxl.commonViewMode")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        let standard = UserDefaults.standard
        standard.removeObject(forKey: "panelTabs_\(panelKey)")
        standard.removeObject(forKey: "panelTabs_\(panelKey)_activeTabID")
        if let commonViewMode {
            standard.set(commonViewMode, forKey: "fcxl.commonViewMode")
        } else {
            standard.removeObject(forKey: "fcxl.commonViewMode")
        }
        try? FileManager.default.removeItem(atPath: base)
        try await super.tearDown()
    }

    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Панель, стоящая в папке «Работа», с одной вкладкой.
    private func panel() -> PanelViewController {
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: base + "/Работа",
                                pathDefaultsKey: "panel.path.места.\(id)",
                                viewModeDefaultsKey: "panel.mode.места.\(id)",
                                showHiddenFiles: false)
        let tabs = PanelTabsViewModel(panelKey: panelKey, initialPath: base + "/Работа")
        let vc = PanelViewController(viewModel: vm, tabsVM: tabs, side: .left)
        vc.placeTabDefaults = defaults
        vc.loadViewIfNeeded()
        addTeardownBlock { [weak vm] in MainActor.assumeIsolated { vm?.stopWatching() } }
        settle()
        return vc
    }

    private func choose(_ mode: PlaceTabMode, for place: MountedPlace) {
        defaults.set(mode.rawValue, forKey: place.defaultsKey)
    }

    // MARK: - Диск на полосе

    func test_диск_поУмолчаниюОткрываетсяНаМесте() {
        let vc = panel()
        vc.openLocalVolume(at: disk, place: .externalDisk)
        settle()
        XCTAssertEqual(vc.tabsVM.tabs.count, 1, "вкладка та же")
        XCTAssertEqual(vc.viewModel.currentPath, disk)
    }

    func test_диск_вСвоейВкладке_однаНаДиск() {
        choose(.newTab, for: .externalDisk)
        let vc = panel()

        vc.openLocalVolume(at: disk, place: .externalDisk)
        settle()
        XCTAssertEqual(vc.tabsVM.tabs.count, 2)
        XCTAssertEqual(vc.tabsVM.activeIndex, 1, "вкладка диска — рядом с той, откуда открыли")
        XCTAssertEqual(vc.tabsVM.activeTab.path, disk)
        XCTAssertEqual(vc.tabsVM.activeTab.title, "Флешка")
        XCTAssertEqual(vc.tabsVM.activeTab.kind, .directory)
        XCTAssertEqual(vc.viewModel.currentPath, disk)
        XCTAssertEqual(vc.tabsVM.tabs[0].path, base + "/Работа", "прежняя вкладка на своей папке")

        // Ушли вглубь диска, вернулись на первую вкладку и снова щёлкнули по диску.
        vc.viewModel.loadDirectory(at: disk + "/Фото")
        settle()
        vc.handleSelectTab(0)
        settle()
        vc.openLocalVolume(at: disk, place: .externalDisk)
        settle()
        XCTAssertEqual(vc.tabsVM.tabs.count, 2, "второй вкладки под тот же диск нет")
        XCTAssertEqual(vc.tabsVM.activeIndex, 1)
        XCTAssertEqual(vc.viewModel.currentPath, disk, "щелчок по диску ведёт в его корень")
    }

    /// Во вкладке диска ушли на свой диск (щелчок по «C:») и снова щёлкнули по диску: это всё
    /// ещё его вкладка — она и возвращается в корень диска. Раньше заводилась новая, и с каждым
    /// таким кругом вкладок становилось на одну больше.
    func test_вкладкаДиска_ушлаНаСвойДиск_возвращаетсяАНеПлодится() {
        choose(.newTab, for: .externalDisk)
        let vc = panel()
        vc.openLocalVolume(at: disk, place: .externalDisk)
        settle()
        XCTAssertEqual(vc.tabsVM.tabs.count, 2)

        for _ in 0..<2 {
            vc.openLocalVolume(at: base + "/Работа")          // «C:» — в этой же вкладке
            settle()
            XCTAssertEqual(vc.tabsVM.activeIndex, 1)
            XCTAssertEqual(vc.viewModel.currentPath, base + "/Работа")
            vc.openLocalVolume(at: disk, place: .externalDisk)
            settle()
            XCTAssertEqual(vc.tabsVM.tabs.count, 2, "новой вкладки нет")
            XCTAssertEqual(vc.tabsVM.activeIndex, 1)
            XCTAssertEqual(vc.viewModel.currentPath, disk, "вкладка диска вернулась в его корень")
        }
    }

    /// То же с другой вкладки: вкладка диска стоит где-то ещё — переходим на неё, и она
    /// возвращается в корень диска.
    func test_вкладкаДиска_ушлаВДругуюПапку_находитсяСДругойВкладки() {
        choose(.newTab, for: .externalDisk)
        let vc = panel()
        vc.openLocalVolume(at: disk, place: .externalDisk)
        settle()
        vc.openLocalVolume(at: base + "/Работа")
        settle()
        vc.handleSelectTab(0)
        settle()

        vc.openLocalVolume(at: disk, place: .externalDisk)
        settle()
        XCTAssertEqual(vc.tabsVM.tabs.count, 2, "новой вкладки нет")
        XCTAssertEqual(vc.tabsVM.activeIndex, 1, "перешли на вкладку диска")
        XCTAssertEqual(vc.viewModel.currentPath, disk)
        XCTAssertEqual(vc.tabsVM.activeTab.path, disk)
        XCTAssertEqual(vc.tabsVM.activeTab.title, "Флешка")
    }

    /// Облако убрали с полосы дисков: его вкладка закрывается, панель — на той, откуда открыли.
    func test_облакоУбралиСПолосы_вкладкаЗакрыласьПанельВернулась() {
        choose(.newTab, for: .cloud)
        let vc = panel()
        vc.openLocalVolume(at: disk, place: .cloud)
        settle()
        vc.viewModel.loadDirectory(at: disk + "/Фото")
        settle()
        XCTAssertEqual(vc.tabsVM.tabs.count, 2)

        vc.leaveHiddenCloud(disk)
        settle()
        XCTAssertEqual(vc.tabsVM.tabs.count, 1, "вкладка облака закрылась")
        XCTAssertEqual(vc.tabsVM.activeTab.path, base + "/Работа")
        XCTAssertEqual(vc.viewModel.currentPath, base + "/Работа", "панель показывает прежнюю вкладку")
    }

    /// Строка настроек — на свой вид места: облако в своей вкладке диска не касается.
    func test_настройкаОдногоМеста_неТрогаетДругое() {
        choose(.newTab, for: .cloud)
        let vc = panel()
        vc.openLocalVolume(at: disk, place: .externalDisk)
        settle()
        XCTAssertEqual(vc.tabsVM.tabs.count, 1)

        vc.openLocalVolume(at: base + "/Работа", place: .cloud)
        settle()
        XCTAssertEqual(vc.tabsVM.tabs.count, 2, "а облако завело вкладку")
    }

    /// Системный диск и домашняя папка — не подключаемые места: всегда на месте.
    func test_свойДиск_всегдаНаМесте() {
        for place in MountedPlace.allCases { choose(.newTab, for: place) }
        let vc = panel()
        vc.openLocalVolume(at: disk)
        settle()
        XCTAssertEqual(vc.tabsVM.tabs.count, 1)
        XCTAssertEqual(vc.viewModel.currentPath, disk)
    }

    func test_изЗакреплённойВкладки_поВыключателю() {
        let vc = panel()
        vc.tabsVM.togglePin(at: 0)

        vc.openLocalVolume(at: disk, place: .externalDisk)
        settle()
        XCTAssertEqual(vc.tabsVM.tabs.count, 1, "без выключателя — на месте, как у обычной вкладки")
        XCTAssertEqual(vc.tabsVM.activeTab.path, base + "/Работа", "закреплённая помнит свою папку")

        defaults.set(true, forKey: PlaceTabs.fromPinnedKey)
        vc.handleSelectTab(0)
        settle()
        vc.openLocalVolume(at: disk, place: .externalDisk)
        settle()
        XCTAssertEqual(vc.tabsVM.tabs.count, 2, "с выключателем диск уходит в свою вкладку")
        XCTAssertEqual(vc.tabsVM.activeTab.path, disk)
        XCTAssertFalse(vc.tabsVM.activeTab.pinned)
    }

    // MARK: - Сетевая папка

    /// Том здесь — временная папка, не настоящий: «один том — одна вкладка» проверено на
    /// модели вкладок (PlaceTabsTests), а тут — что вкладка заводится и панель в неё входит.
    func test_сетеваяПапка_поУмолчаниюВСвоейВкладке() {
        let vc = panel()
        vc.openNetworkMount(at: disk)
        settle()
        XCTAssertEqual(vc.tabsVM.tabs.count, 2)
        XCTAssertEqual(vc.tabsVM.activeIndex, 1)
        XCTAssertEqual(vc.tabsVM.activeTab.path, disk)
        XCTAssertEqual(vc.viewModel.currentPath, disk)
        XCTAssertEqual(vc.tabsVM.tabs[0].path, base + "/Работа")
    }

    func test_сетеваяПапка_вТекущейВкладке() {
        choose(.currentTab, for: .networkShare)
        let vc = panel()
        vc.openNetworkMount(at: disk)
        settle()
        XCTAssertEqual(vc.tabsVM.tabs.count, 1, "вкладка не завелась")
        XCTAssertEqual(vc.viewModel.currentPath, disk)
        XCTAssertEqual(vc.tabsVM.activeTab.path, disk, "вкладка ушла в папку вместе с панелью")
    }

    // MARK: - Образ и хранилище

    func test_образПоEnter_поНастройке() throws {
        let vc = panel()
        let enter = try XCTUnwrap(vc.viewModel.openMountedImage, "панель слушает открытие образа")
        XCTAssertFalse(enter(disk), "по умолчанию панель входит в том на месте")
        XCTAssertEqual(vc.tabsVM.tabs.count, 1)

        choose(.newTab, for: .diskImage)
        XCTAssertTrue(enter(disk), "вкладку завела панель — модели входить не надо")
        settle()
        XCTAssertEqual(vc.tabsVM.tabs.count, 2)
        XCTAssertEqual(vc.tabsVM.activeTab.path, disk)
        XCTAssertEqual(vc.viewModel.currentPath, disk)
    }
}
