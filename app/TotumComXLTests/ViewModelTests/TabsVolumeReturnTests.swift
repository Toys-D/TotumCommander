import XCTest
@testable import TotumComXLApp

/// Извлекли диск — вкладка возвращается туда, откуда на него ушла, курсором на тот же файл, а
/// вкладка, открытая под диск, закрывается в пользу той, из которой её открыли. Раньше панель с
/// диска уходила в домашнюю папку, а его вкладки просто закрывались. Тома здесь выдуманные.
@MainActor
final class TabsVolumeReturnTests: XCTestCase {
    private let mounts = [
        OperationDisks.Mount(point: "/", device: "/dev/disk3s3s1"),
        OperationDisks.Mount(point: "/Volumes/USB", device: "/dev/disk9s1"),
        OperationDisks.Mount(point: "/Volumes/USB 2", device: "/dev/disk10s1"),
        OperationDisks.Mount(point: "/Volumes/share", device: "//guest@pc/share"),
    ]
    private let temp = "/Users/x/Documents/TEMP"

    private func tabs() -> PanelTabsViewModel {
        let vm = PanelTabsViewModel(panelKey: "eject.\(UUID().uuidString)", initialPath: temp)
        vm.mountTable = { [mounts] in mounts }
        return vm
    }

    private func go(_ vm: PanelTabsViewModel, to path: String, cursor: String? = nil) {
        vm.panelNavigated(to: path, leaving: .init(path: vm.activeTab.path, cursorPath: cursor))
    }

    func test_корниТомов() {
        XCTAssertEqual(PanelTabsViewModel.awayRoot(of: "/Volumes/USB/a/b", mounts: mounts), "/Volumes/USB")
        XCTAssertEqual(PanelTabsViewModel.awayRoot(of: "/Volumes/USB 2/a", mounts: mounts), "/Volumes/USB 2")
        XCTAssertEqual(PanelTabsViewModel.awayRoot(of: NetworkBrowserService.networkRoot + "/PC", mounts: mounts),
                       NetworkBrowserService.networkRoot)
        XCTAssertNil(PanelTabsViewModel.awayRoot(of: temp, mounts: mounts))
        XCTAssertNil(PanelTabsViewModel.awayRoot(of: "/Volumes/Macintosh HD/Users", mounts: mounts),
                     "не подключённый том — не чужой диск")
    }

    func test_таЖеВкладкаВозвращаетсяКФайлу() {
        let vm = tabs()
        go(vm, to: "/Volumes/USB", cursor: temp + "/отчёт.pdf")
        go(vm, to: "/Volumes/USB/фото/2025")

        let exit = vm.leaveVolume("/Volumes/USB")
        XCTAssertEqual(vm.activeTab.path, temp)
        XCTAssertEqual(vm.activeTab.title, "TEMP")
        XCTAssertTrue(exit.reloadActive)
        XCTAssertEqual(exit.cursorPath, temp + "/отчёт.pdf")
        XCTAssertTrue(exit.close.isEmpty)
        XCTAssertNil(vm.activeTab.returnPath, "дорога забыта")
    }

    func test_сДискаНаДиск_возвратТудаГдеНачали() {
        let vm = tabs()
        go(vm, to: "/Volumes/USB/a")
        go(vm, to: "/Volumes/USB 2/b")
        _ = vm.leaveVolume("/Volumes/USB 2")
        XCTAssertEqual(vm.activeTab.path, temp)
    }

    func test_вернулсяСам_памятьЗабыта() {
        let vm = tabs()
        go(vm, to: "/Volumes/USB/a")
        go(vm, to: "/Users/x/Desktop")
        XCTAssertNil(vm.activeTab.returnPath)
        let exit = vm.leaveVolume("/Volumes/USB")
        XCTAssertEqual(exit, .init(), "вкладка не на диске — делать нечего")
        XCTAssertEqual(vm.activeTab.path, "/Users/x/Desktop")
    }

    /// Из TEMP — в «Сеть», оттуда общая папка компьютера открылась своей вкладкой. Отключили
    /// компьютер — вкладка папки закрывается, а TEMP возвращается из обзора сети к себе.
    func test_сетеваяВкладкаЗакрывается_исходнаяВозвращается() {
        let vm = tabs()
        let origin = vm.activeTab.id
        go(vm, to: NetworkBrowserService.networkRoot + "/PC", cursor: temp + "/a.txt")
        vm.newNetworkMountTab(path: "/Volumes/share", title: "PC: share", openedFrom: origin)
        let shareTab = vm.activeTab.id

        let exit = vm.leaveVolume("/Volumes/share")
        XCTAssertEqual(exit.activate, origin)
        XCTAssertEqual(exit.close, [shareTab])
        XCTAssertEqual(exit.cursorPath, temp + "/a.txt")
        XCTAssertEqual(vm.tabs.first { $0.id == origin }?.path, temp)

        // Как панель: сначала встать на исходную вкладку, потом закрыть вкладку диска.
        vm.selectTab(at: vm.tabs.firstIndex { $0.id == origin }!)
        XCTAssertFalse(vm.closeTabs(exit.close), "активная уже исходная — закрывать её не пришлось")
        XCTAssertEqual(vm.activeTab.id, origin)
        XCTAssertFalse(vm.tabs.contains { $0.id == shareTab })
    }

    func test_безПамяти_какРаньше() {
        let vm = tabs()
        vm.newTab(path: "/Volumes/USB/x")
        let loose = vm.activeTab.id
        vm.newTab(path: "/Volumes/USB/y")
        vm.togglePin(at: vm.activeIndex)
        let pinned = vm.activeTab.id

        let exit = vm.leaveVolume("/Volumes/USB")
        XCTAssertEqual(exit.close, [loose], "незакреплённая без памяти закрывается, закреплённая остаётся")
        XCTAssertFalse(exit.close.contains(pinned))
    }
}
