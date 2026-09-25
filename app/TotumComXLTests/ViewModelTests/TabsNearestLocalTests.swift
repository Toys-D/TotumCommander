import XCTest
@testable import TotumComXLApp

/// Щелчок по диску из вкладки хранилища не должен отключать хранилище: диск открывается в
/// ближайшей местной вкладке, а вкладка хранилища остаётся жить. Здесь — выбор той вкладки.
@MainActor
final class TabsNearestLocalTests: XCTestCase {

    /// Вкладки заданных видов по порядку; первая, домашняя, закрывается в конце.
    private func tabs(_ kinds: [TabKind]) -> PanelTabsViewModel {
        let vm = PanelTabsViewModel(panelKey: "near.\(UUID().uuidString)", initialPath: NSHomeDirectory())
        for kind in kinds {
            switch kind {
            case .directory:    vm.newTab(path: "/")
            case .terminal:     vm.newTerminalTab(directory: "/")
            case .remote:       vm.newRemoteTab(title: "х", connectionID: UUID())
            case .networkMount: vm.newNetworkMountTab(path: "/Volumes/х", title: "х")
            }
        }
        vm.closeTab(at: 0)
        XCTAssertEqual(vm.tabs.map(\.kind), kinds)
        return vm
    }

    func test_сначалаСлева_потомСправа() {
        let vm = tabs([.directory, .remote, .directory])
        XCTAssertEqual(vm.nearestLocalTabIndex(from: 1), 0, "слева ближе")
        let right = tabs([.terminal, .remote, .directory])
        XCTAssertEqual(right.nearestLocalTabIndex(from: 1), 2, "слева не местная — берём справа")
    }

    func test_ближайшаяПоРасстоянию() {
        let vm = tabs([.directory, .terminal, .remote, .directory])
        XCTAssertEqual(vm.nearestLocalTabIndex(from: 2), 3, "справа в одном шаге, слева в двух")
    }

    func test_безМестныхВкладок_Нет() {
        XCTAssertNil(tabs([.remote]).nearestLocalTabIndex(from: 0))
        XCTAssertNil(tabs([.terminal, .remote, .networkMount]).nearestLocalTabIndex(from: 1),
                     "терминал и сетевой том — не место для диска")
    }
}
