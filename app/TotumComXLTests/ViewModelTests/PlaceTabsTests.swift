import XCTest
@testable import TotumComXLApp

/// Где открывается подключаемое место — сетевая папка, обзор сети, внешний диск, образ, облако:
/// в своей вкладке или в той, где стоит человек. Раньше это было зашито: сетевая папка всегда
/// заводила вкладку, всё остальное всегда открывалось на месте.
@MainActor
final class PlaceTabsTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var panelKeys: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "place-tabs-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        // Вкладки сохраняют себя сами — убрать за собой.
        for key in panelKeys {
            UserDefaults.standard.removeObject(forKey: "panelTabs_\(key)")
            UserDefaults.standard.removeObject(forKey: "panelTabs_\(key)_activeTabID")
        }
        try await super.tearDown()
    }

    private func tabs() -> PanelTabsViewModel {
        let key = "place.\(UUID().uuidString)"
        panelKeys.append(key)
        return PanelTabsViewModel(panelKey: key, initialPath: "/Users/anna")
    }

    // MARK: - Настройка

    /// Без настройки — как было: сетевая папка в своей вкладке, остальное на месте.
    func test_поУмолчанию_какБыло() {
        for place in MountedPlace.allCases {
            XCTAssertEqual(PlaceTabs.mode(for: place, savedRawValue: nil),
                           place == .networkShare ? .newTab : .currentTab, "\(place)")
        }
    }

    func test_сохранённыйВыборЧитается_мусорНет() {
        XCTAssertEqual(PlaceTabs.mode(for: .cloud, savedRawValue: "newTab"), .newTab)
        XCTAssertEqual(PlaceTabs.mode(for: .networkShare, savedRawValue: "currentTab"), .currentTab)
        XCTAssertEqual(PlaceTabs.mode(for: .networkShare, savedRawValue: "чепуха"), .newTab)
        XCTAssertEqual(PlaceTabs.mode(for: .externalDisk, savedRawValue: ""), .currentTab)
    }

    func test_уКаждогоМестаСвойКлюч() {
        XCTAssertEqual(Set(MountedPlace.allCases.map(\.defaultsKey)).count, MountedPlace.allCases.count)
        defaults.set(PlaceTabMode.newTab.rawValue, forKey: MountedPlace.externalDisk.defaultsKey)
        XCTAssertEqual(PlaceTabs.mode(for: .externalDisk, defaults: defaults), .newTab)
        XCTAssertEqual(PlaceTabs.mode(for: .cloud, defaults: defaults), .currentTab, "соседнее место не задето")
    }

    /// Закреплённая вкладка место принять может, но своей папки не забудет: вернёшься на неё —
    /// диск придётся открывать заново. Отдельный выключатель уводит такие открытия в свою вкладку.
    func test_изЗакреплённой_поВыключателю() {
        XCTAssertFalse(PlaceTabs.opensNewTab(mode: .currentTab, tabPinned: true, fromPinnedNew: false))
        XCTAssertTrue(PlaceTabs.opensNewTab(mode: .currentTab, tabPinned: true, fromPinnedNew: true))
        XCTAssertFalse(PlaceTabs.opensNewTab(mode: .currentTab, tabPinned: false, fromPinnedNew: true),
                       "обычной вкладки выключатель не касается")
        XCTAssertTrue(PlaceTabs.opensNewTab(mode: .newTab, tabPinned: false, fromPinnedNew: false))

        var pinned = PanelTab(path: "/Users/anna/Работа", pinned: true)
        XCTAssertFalse(PlaceTabs.opensNewTab(.cloud, from: pinned, defaults: defaults))
        defaults.set(true, forKey: PlaceTabs.fromPinnedKey)
        XCTAssertTrue(PlaceTabs.opensNewTab(.cloud, from: pinned, defaults: defaults))
        pinned.pinned = false
        XCTAssertFalse(PlaceTabs.opensNewTab(.cloud, from: pinned, defaults: defaults))
    }

    /// Смонтированный образ и сейф — тоже диск на полосе, но у них своя строка настроек.
    func test_образНаПолосе_своёМесто() {
        XCTAssertEqual(PlaceTabs.refined(.externalDisk, busType: .diskImage), .diskImage)
        XCTAssertEqual(PlaceTabs.refined(.externalDisk, busType: .usb3), .externalDisk)
        XCTAssertEqual(PlaceTabs.refined(.cloud, busType: .diskImage), .cloud, "уточняется только диск")
    }

    // MARK: - Что сделать панели

    func test_сетеваяПапка_вСвоейВкладке() {
        let vm = tabs()
        XCTAssertEqual(vm.opening(of: .networkShare, root: "/Volumes/Обмен", wantsOwnTab: true), .newTab)

        vm.newNetworkMountTab(path: "/Volumes/Обмен", title: "OFFICE-PC: Обмен")
        XCTAssertEqual(vm.opening(of: .networkShare, root: "/Volumes/Обмен", wantsOwnTab: true), .inCurrentTab,
                       "уже стоим на ней")
        vm.selectTab(at: 0)
        XCTAssertEqual(vm.opening(of: .networkShare, root: "/Volumes/Обмен", wantsOwnTab: true), .switchTo(1),
                       "один том — одна вкладка")
        XCTAssertEqual(vm.opening(of: .networkShare, root: "/Volumes/Обмен2", wantsOwnTab: true), .newTab,
                       "похожее имя — другой том")
    }

    func test_сетеваяПапка_вТекущейВкладке() {
        let vm = tabs()
        vm.newNetworkMountTab(path: "/Volumes/Обмен", title: "OFFICE-PC: Обмен")
        vm.selectTab(at: 0)
        XCTAssertEqual(vm.opening(of: .networkShare, root: "/Volumes/Обмен", wantsOwnTab: false), .inCurrentTab,
                       "всё показывается там, где человек стоит, — даже когда вкладка тома уже есть")
    }

    /// Терминал и сервер папку показать не могут — место уходит в свою вкладку при любой настройке.
    func test_изТерминалаИСервера_всегдаСвояВкладка() {
        let vm = tabs()
        vm.newTerminalTab(directory: "/Users/anna")
        XCTAssertEqual(vm.opening(of: .networkShare, root: "/Volumes/Обмен", wantsOwnTab: false), .newTab)
        XCTAssertEqual(vm.opening(of: .networkBrowser, root: NetworkBrowserService.networkRoot,
                                  wantsOwnTab: false), .newTab)
        vm.newRemoteTab(title: "сервер", connectionID: UUID())
        XCTAssertEqual(vm.opening(of: .networkShare, root: "/Volumes/Обмен", wantsOwnTab: false), .newTab)
    }

    /// Обзор сети, открытый в своей вкладке, сам становится вкладкой общей папки: иначе каждая
    /// папка оставляла бы за собой ещё и вкладку со списком компьютеров.
    func test_вкладкаОбзораСети_становитсяВкладкойПапки() {
        let vm = tabs()
        XCTAssertEqual(vm.opening(of: .networkBrowser, root: NetworkBrowserService.networkRoot,
                                  wantsOwnTab: true), .newTab)
        vm.newNetworkMountTab(path: NetworkBrowserService.networkRoot, title: "Локальная сеть")
        vm.updateTabPath(at: vm.activeIndex, to: NetworkBrowserService.networkRoot + "/OFFICE-PC")
        XCTAssertEqual(vm.opening(of: .networkShare, root: "/Volumes/Обмен", wantsOwnTab: true),
                       .adoptCurrentTab)

        // А когда том уже открыт в другой вкладке — идём туда.
        vm.newNetworkMountTab(path: "/Volumes/Обмен", title: "OFFICE-PC: Обмен")
        vm.selectTab(at: 1)
        XCTAssertEqual(vm.opening(of: .networkShare, root: "/Volumes/Обмен", wantsOwnTab: true), .switchTo(2))

        // Обзор сети уже открыт — вторую вкладку под него не заводим.
        vm.selectTab(at: 0)
        XCTAssertEqual(vm.opening(of: .networkBrowser, root: NetworkBrowserService.networkRoot,
                                  wantsOwnTab: true), .switchTo(1))
    }

    func test_обзорСети_вТекущейВкладке() {
        let vm = tabs()
        XCTAssertEqual(vm.opening(of: .networkBrowser, root: NetworkBrowserService.networkRoot,
                                  wantsOwnTab: false), .inCurrentTab)
    }

    func test_внешнийДиск_вСвоейВкладке() {
        let vm = tabs()
        let disk = "/Volumes/Флешка"
        XCTAssertEqual(vm.opening(of: .externalDisk, root: disk, wantsOwnTab: true), .newTab)

        vm.newTab(path: disk + "/Фото", openedFrom: vm.activeTab.id)
        XCTAssertEqual(vm.opening(of: .externalDisk, root: disk, wantsOwnTab: true), .inCurrentTab)
        vm.selectTab(at: 0)
        XCTAssertEqual(vm.opening(of: .externalDisk, root: disk, wantsOwnTab: true), .switchTo(1),
                       "вкладка этого диска уже есть — вторую не заводим")
        XCTAssertEqual(vm.opening(of: .externalDisk, root: "/Volumes/Флешка 2", wantsOwnTab: true), .newTab)
        XCTAssertEqual(vm.opening(of: .externalDisk, root: disk, wantsOwnTab: false), .inCurrentTab)
    }

    /// Закреплённую вкладку, стоящую в глубине диска, щелчок по диску не уводит в его корень:
    /// у неё своя папка. Закреплённая в самом корне — это и есть вкладка диска.
    func test_закреплённаяВГлубинеДиска_неВкладкаДиска() {
        let vm = tabs()
        let disk = "/Volumes/Флешка"
        vm.newTab(path: disk + "/Фото")
        vm.togglePin(at: 1)
        vm.selectTab(at: 0)
        XCTAssertEqual(vm.opening(of: .externalDisk, root: disk, wantsOwnTab: true), .newTab)

        vm.newTab(path: disk)
        vm.togglePin(at: vm.activeIndex)
        let rootTab = vm.activeIndex
        vm.selectTab(at: 0)
        XCTAssertEqual(vm.opening(of: .externalDisk, root: disk, wantsOwnTab: true), .switchTo(rootTab))
    }

    func test_облако_вСвоейВкладке() {
        let vm = tabs()
        let cloud = "/Users/anna/Library/CloudStorage/GoogleDrive-anna@example.com"
        XCTAssertEqual(vm.opening(of: .cloud, root: cloud, wantsOwnTab: true), .newTab)
        vm.newTab(path: cloud, title: "Google Drive", openedFrom: vm.activeTab.id)
        XCTAssertEqual(vm.activeTab.title, "Google Drive")
        XCTAssertEqual(vm.activeTab.openedFromTabID, vm.tabs[0].id)
        vm.selectTab(at: 0)
        XCTAssertEqual(vm.opening(of: .cloud, root: cloud, wantsOwnTab: true), .switchTo(1))
    }

    /// Вкладка, открытая под диск, помнит, из какой её открыли: извлекли диск — она закрывается,
    /// а панель возвращается на ту. Так уже жила вкладка сетевой папки; теперь и диск, и образ.
    func test_дискИзвлекли_егоВкладкаЗакрывается_возвратНаПрежнюю() {
        let vm = tabs()
        let disk = "/Volumes/Флешка"
        vm.mountTable = { [OperationDisks.Mount(point: "/", device: "disk3s1"),
                           OperationDisks.Mount(point: disk, device: "disk5s1")] }
        let home = vm.activeTab.id
        vm.newTab(path: disk, title: "Флешка", openedFrom: home)
        let diskTab = vm.activeTab.id
        vm.panelNavigated(to: disk)
        vm.panelNavigated(to: disk + "/Фото")
        XCTAssertEqual(vm.activeTab.openedFromTabID, home, "память держится, пока вкладка на диске")

        let exit = vm.leaveVolume(disk)
        XCTAssertEqual(exit.close, [diskTab])
        XCTAssertEqual(exit.activate, home)
    }

    // MARK: - Вкладка помнит своё место

    /// Во вкладке iCloud ушли на свой диск и снова щёлкнули по iCloud: это всё ещё его вкладка.
    /// Раньше под каждый такой щелчок заводилась новая — вкладки плодились.
    func test_вкладкаМеста_ушлаВДругуюПапку_остаётсяЕгоВкладкой() {
        let cloud = "/Users/anna/Library/Mobile Documents/com~apple~CloudDocs"
        for place in [MountedPlace.cloud, .externalDisk, .diskImage] {
            let vm = tabs()
            vm.newTab(path: cloud, title: "место", openedFrom: vm.activeTab.id, placeRoot: cloud)
            vm.panelNavigated(to: "/Users/anna")
            XCTAssertEqual(vm.activeTab.path, "/Users/anna")
            XCTAssertEqual(vm.opening(of: place, root: cloud, wantsOwnTab: true), .inCurrentTab,
                           "\(place): стоим в его вкладке — возвращаемся в ней же")
            vm.selectTab(at: 0)
            XCTAssertEqual(vm.opening(of: place, root: cloud, wantsOwnTab: true), .switchTo(1),
                           "\(place): с другой вкладки — переходим на вкладку места")
        }
    }

    func test_вкладкаСетевойПапки_ушлаНаСвойДиск_остаётсяЕёВкладкой() {
        let vm = tabs()
        let share = "/Volumes/Обмен"
        vm.newNetworkMountTab(path: share, title: "OFFICE-PC: Обмен", openedFrom: vm.activeTab.id,
                              placeRoot: share)
        // Вверх из корня тома, по избранному, по набранному пути — вкладка становится обычной.
        vm.panelNavigated(to: "/Users/anna/Документы")
        XCTAssertEqual(vm.activeTab.kind, .directory)
        XCTAssertEqual(vm.opening(of: .networkShare, root: share, wantsOwnTab: true), .inCurrentTab)
        vm.selectTab(at: 0)
        XCTAssertEqual(vm.opening(of: .networkShare, root: share, wantsOwnTab: true), .switchTo(1))
    }

    /// Вкладка, которая уже стоит на месте, показывает его прямо сейчас — идём на неё, а
    /// ушедшую вкладку места не дёргаем.
    func test_стоящаяНаМесте_важнееУшедшей() {
        let vm = tabs()
        let disk = "/Volumes/Флешка"
        vm.newTab(path: disk, openedFrom: vm.activeTab.id, placeRoot: disk)
        vm.panelNavigated(to: "/Users/anna")                // вкладка диска ушла
        vm.newTab(path: disk + "/Фото")                     // а эта стоит на диске
        XCTAssertEqual(vm.opening(of: .externalDisk, root: disk, wantsOwnTab: true), .inCurrentTab)
        vm.selectTab(at: 0)
        XCTAssertEqual(vm.opening(of: .externalDisk, root: disk, wantsOwnTab: true), .switchTo(2))
    }

    /// Закрепили вкладку места на другой папке — она теперь вкладка этой папки.
    func test_закреплённаяНаДругойПапке_большеНеВкладкаМеста() {
        let vm = tabs()
        let disk = "/Volumes/Флешка"
        vm.newTab(path: disk, openedFrom: vm.activeTab.id, placeRoot: disk)
        vm.panelNavigated(to: "/Users/anna/Работа")
        vm.togglePin(at: vm.activeIndex)
        vm.selectTab(at: 0)
        XCTAssertEqual(vm.opening(of: .externalDisk, root: disk, wantsOwnTab: true), .newTab)
    }

    /// Вкладка обзора сети, ставшая вкладкой общей папки, обзору больше не принадлежит:
    /// «Локальная сеть» её не отбирает.
    func test_вкладкаОбзора_ставПапкой_неВозвращаетсяВОбзор() {
        let vm = tabs()
        let network = NetworkBrowserService.networkRoot
        vm.newNetworkMountTab(path: network, title: "Локальная сеть", openedFrom: vm.activeTab.id,
                              placeRoot: network)
        vm.updateTabPath(at: vm.activeIndex, to: network + "/OFFICE-PC")
        XCTAssertEqual(vm.opening(of: .networkShare, root: "/Volumes/Обмен", wantsOwnTab: true),
                       .adoptCurrentTab)
        vm.adoptPlace("/Volumes/Обмен")
        vm.updateTabPath(at: vm.activeIndex, to: "/Volumes/Обмен")
        XCTAssertEqual(vm.activeTab.placeRoot, "/Volumes/Обмен")
        vm.selectTab(at: 0)
        XCTAssertEqual(vm.opening(of: .networkBrowser, root: network, wantsOwnTab: true), .newTab)
        XCTAssertEqual(vm.opening(of: .networkShare, root: "/Volumes/Обмен", wantsOwnTab: true), .switchTo(1))
    }

    /// Место вкладки переживает перезапуск вместе с ней.
    func test_местоВкладкиСохраняется() {
        let key = "place.keep.\(UUID().uuidString)"
        panelKeys.append(key)
        let disk = "/Volumes/Флешка"
        let first = PanelTabsViewModel(panelKey: key, initialPath: "/Users/anna")
        first.newTab(path: disk, openedFrom: first.activeTab.id, placeRoot: disk)
        let second = PanelTabsViewModel(panelKey: key, initialPath: "/Users/anna")
        XCTAssertEqual(second.tabs.map(\.placeRoot), [nil, disk])
    }

    /// Сетевая вкладка оранжевая; уйдя на свой диск, цвет теряет, вернувшись — получает снова.
    /// Свой цвет, выбранный человеком, остаётся при любом переходе.
    func test_цветВкладки_уходитИВозвращаетсяВместеСВидом() {
        let orange = PanelTab.remoteDefaultColorHex
        XCTAssertNil(PanelTabsViewModel.colorAfterKindChange(orange, to: .directory))
        XCTAssertEqual(PanelTabsViewModel.colorAfterKindChange(nil, to: .networkMount), orange)
        XCTAssertEqual(PanelTabsViewModel.colorAfterKindChange("#123456", to: .directory), "#123456")
        XCTAssertEqual(PanelTabsViewModel.colorAfterKindChange("#123456", to: .networkMount), "#123456")
    }

    // MARK: - Место убрали

    private let userCloud = CloudStatusService.cloudDriveRoot

    /// Облако не отключают, а убирают с полосы дисков — но для вкладок это то же, что извлечь
    /// диск: вкладка облака закрывается, панель возвращается на ту, из которой его открыли.
    func test_облакоУбралиСПолосы_егоВкладкаЗакрывается() {
        let vm = tabs()
        let home = vm.activeTab.id
        vm.newTab(path: userCloud, title: "iCloud Drive", openedFrom: home, placeRoot: userCloud)
        let cloudTab = vm.activeTab.id
        vm.panelNavigated(to: userCloud)
        vm.panelNavigated(to: userCloud + "/Отчёты")

        let exit = vm.leaveVolume(userCloud)
        XCTAssertEqual(exit.close, [cloudTab])
        XCTAssertEqual(exit.activate, home)
    }

    /// Облако в текущей вкладке (так по умолчанию): вкладка не закрывается, а возвращается в
    /// папку, из которой в облако ушла, — как вкладка, ушедшая на диск.
    func test_облакоУбрали_вкладкаУшедшаяВНегоВозвращается() {
        let vm = tabs()
        let tab = vm.activeTab.id
        vm.panelNavigated(to: userCloud, leaving: .init(path: "/Users/anna", cursorPath: "/Users/anna/отчёт.pdf"))
        vm.panelNavigated(to: userCloud + "/Отчёты")

        let exit = vm.leaveVolume(userCloud)
        XCTAssertEqual(exit.close, [], "обычную вкладку человека не закрываем")
        XCTAssertTrue(exit.reloadActive)
        XCTAssertEqual(exit.cursorPath, "/Users/anna/отчёт.pdf")
        XCTAssertEqual(vm.activeTab.id, tab)
        XCTAssertEqual(vm.activeTab.path, "/Users/anna")
    }

    func test_корниОблаков() {
        let storage = CloudStorageVolumes.root
        XCTAssertEqual(PanelTabsViewModel.awayRoot(of: userCloud + "/Отчёты/2025", mounts: []), userCloud)
        XCTAssertEqual(PanelTabsViewModel.awayRoot(of: userCloud, mounts: []), userCloud)
        XCTAssertEqual(PanelTabsViewModel.awayRoot(of: storage + "/GoogleDrive-anna@example.com/Мой диск",
                                                   mounts: []),
                       storage + "/GoogleDrive-anna@example.com")
        XCTAssertNil(PanelTabsViewModel.awayRoot(of: storage, mounts: []), "сама папка CloudStorage — не облако")
        XCTAssertNil(PanelTabsViewModel.awayRoot(of: "/Users/anna/Документы", mounts: []))
    }

    /// Вкладка диска ушла на свой диск и вернулась на диск — она всё ещё открыта под него:
    /// диск извлекли — закрывается и она, а панель возвращается на ту, из которой её открыли.
    func test_вкладкаДиска_ушлаИВернулась_сДискомЗакрывается() {
        let vm = tabs()
        let disk = "/Volumes/Флешка"
        vm.mountTable = { [OperationDisks.Mount(point: "/", device: "disk3s1"),
                           OperationDisks.Mount(point: disk, device: "disk5s1")] }
        let home = vm.activeTab.id
        vm.newTab(path: disk, openedFrom: home, placeRoot: disk)
        let diskTab = vm.activeTab.id
        vm.panelNavigated(to: disk)
        vm.panelNavigated(to: "/Users/anna/Загрузки")           // «C:» в этой же вкладке
        vm.panelNavigated(to: disk, leaving: .init(path: "/Users/anna/Загрузки", cursorPath: nil))

        let exit = vm.leaveVolume(disk)
        XCTAssertEqual(exit.close, [diskTab])
        XCTAssertEqual(exit.activate, home)
    }

    /// А та, что в миг извлечения стоит в другой папке, диска не показывает — её не закрываем:
    /// она становится обычной вкладкой, и вернувшийся диск получит свою, новую.
    func test_вкладкаДиска_стоитВДругойПапке_остаётсяОбычной() {
        let vm = tabs()
        let disk = "/Volumes/Флешка"
        vm.mountTable = { [OperationDisks.Mount(point: "/", device: "disk3s1"),
                           OperationDisks.Mount(point: disk, device: "disk5s1")] }
        vm.newTab(path: disk, openedFrom: vm.activeTab.id, placeRoot: disk)
        vm.panelNavigated(to: disk)
        vm.panelNavigated(to: "/Users/anna/Загрузки")

        let exit = vm.leaveVolume(disk)
        XCTAssertEqual(exit.close, [])
        XCTAssertNil(exit.activate)
        XCTAssertEqual(vm.tabs.count, 2)
        XCTAssertNil(vm.activeTab.placeRoot)
        XCTAssertNil(vm.activeTab.openedFromTabID)
        vm.selectTab(at: 0)
        XCTAssertEqual(vm.opening(of: .externalDisk, root: disk, wantsOwnTab: true), .newTab)
    }

    // MARK: - Имя вкладки

    /// Корень облака называется как облако: «com~apple~CloudDocs» на вкладке — служебная папка,
    /// а не место.
    func test_имяВкладки_корняОблака() {
        let storage = "/Users/anna/Library/CloudStorage"
        let icloud = "/Users/anna/Library/Mobile Documents/com~apple~CloudDocs"
        let title = { PanelTabsViewModel.folderTitle($0, cloudStorageRoot: storage, iCloudRoot: icloud) }
        XCTAssertEqual(title(icloud), L("volume.icloud"))
        XCTAssertEqual(title(icloud + "/"), L("volume.icloud"))
        XCTAssertEqual(title(icloud + "/Отчёты"), "Отчёты")
        XCTAssertEqual(title(storage + "/GoogleDrive-anna@example.com"), "Google Drive")
        XCTAssertEqual(title(storage + "/GoogleDrive-anna@example.com/Мой диск"), "Мой диск")
        XCTAssertEqual(title("/Volumes/Флешка"), "Флешка")
        XCTAssertEqual(title("/"), "/")
    }

    func test_вкладкаВКорнеICloud_называетсяОблаком() {
        let vm = tabs()
        vm.panelNavigated(to: CloudStatusService.cloudDriveRoot)
        XCTAssertEqual(vm.activeTab.title, L("volume.icloud"))
        vm.panelNavigated(to: CloudStatusService.cloudDriveRoot + "/Отчёты")
        XCTAssertEqual(vm.activeTab.title, "Отчёты")
    }
}
