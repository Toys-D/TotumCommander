import SwiftUI
import XCTest

@testable import TotumComXLApp

/// Tests for `PanelTab` — the per-tab model (title derivation, per-kind defaults, Codable
/// persistence used to save/restore tabs) and the `TabAccentColor` palette. All deterministic.
final class PanelTabTests: XCTestCase {

    // MARK: - Вкладка сетевого тома, ушедшая на обычный диск

    func test_networkTab_becomesOrdinaryWhenItLeavesTheMount() {
        // Была «SERVER_SO: E», человек переключился на диск C — вкладка обязана стать
        // обычной. Иначе она оранжевая и с чужим именем поверх файлов диска C, а щелчок
        // по тому заводит рядом вторую такую же.
        XCTAssertEqual(PanelTabsViewModel.kindAfterNavigation(current: .networkMount,
                                                              isMount: false,
                                                              isNetworkBrowser: false),
                       .directory)
    }

    func test_networkTab_staysNetworkInsideTheMount() {
        XCTAssertEqual(PanelTabsViewModel.kindAfterNavigation(current: .networkMount,
                                                              isMount: true,
                                                              isNetworkBrowser: false),
                       .networkMount)
    }

    func test_networkTab_staysNetworkAtTheBrowserRoot() {
        // Вернуться к списку компьютеров — не уход из сети.
        XCTAssertEqual(PanelTabsViewModel.kindAfterNavigation(current: .networkMount,
                                                              isMount: false,
                                                              isNetworkBrowser: true),
                       .networkMount)
    }

    func test_ordinaryTab_becomesNetworkWhenItEntersAMount() {
        XCTAssertEqual(PanelTabsViewModel.kindAfterNavigation(current: .directory,
                                                              isMount: true,
                                                              isNetworkBrowser: false),
                       .networkMount)
    }

    func test_terminalAndRemoteTabsAreLeftAlone() {
        XCTAssertEqual(PanelTabsViewModel.kindAfterNavigation(current: .terminal,
                                                              isMount: false,
                                                              isNetworkBrowser: false),
                       .terminal)
        XCTAssertEqual(PanelTabsViewModel.kindAfterNavigation(current: .remote,
                                                              isMount: false,
                                                              isNetworkBrowser: false),
                       .remote)
    }

    // MARK: - Directory tabs: title derived from the path

    func test_directory_titleIsLastPathComponent() {
        let tab = PanelTab(path: "/Users/dima/Documents")
        XCTAssertEqual(tab.title, "Documents")
        XCTAssertEqual(tab.kind, .directory)
        XCTAssertNil(tab.colorHex)
        XCTAssertFalse(tab.isTerminal)
        XCTAssertFalse(tab.isRemote)
        XCTAssertFalse(tab.isNetworkMount)
    }

    func test_directory_trailingSlashStillYieldsLeaf() {
        XCTAssertEqual(PanelTab(path: "/Users/dima/Documents/").title, "Documents")
    }

    func test_directory_rootPathTitle() {
        XCTAssertEqual(PanelTab(path: "/").title, "/")
    }

    func test_directory_explicitTitleOverridesPath() {
        let tab = PanelTab(path: "/Users/dima/Documents", title: "Мои документы")
        XCTAssertEqual(tab.title, "Мои документы")
    }

    // MARK: - Terminal tabs

    func test_terminal_defaults() {
        let tab = PanelTab(path: "/tmp", kind: .terminal)
        XCTAssertEqual(tab.title, "Terminal")
        XCTAssertEqual(tab.colorHex, PanelTab.terminalDefaultColorHex)
        XCTAssertTrue(tab.isTerminal)
    }

    func test_terminal_explicitColourOverridesDefault() {
        let tab = PanelTab(path: "/tmp", colorHex: "#123456", kind: .terminal)
        XCTAssertEqual(tab.colorHex, "#123456")
    }

    // MARK: - Remote / network-mount tabs

    func test_remote_defaults() {
        let id = UUID()
        let tab = PanelTab(path: "/", kind: .remote, remoteConnectionID: id)
        XCTAssertEqual(tab.title, "Remote")
        XCTAssertEqual(tab.colorHex, PanelTab.remoteDefaultColorHex)
        XCTAssertTrue(tab.isRemote)
        XCTAssertEqual(tab.remoteConnectionID, id)
    }

    func test_networkMount_defaults() {
        let tab = PanelTab(path: "/Volumes/share", kind: .networkMount)
        XCTAssertEqual(tab.title, "Remote")
        XCTAssertEqual(tab.colorHex, PanelTab.remoteDefaultColorHex)
        XCTAssertTrue(tab.isNetworkMount)
    }

    // MARK: - Pinned flag

    /// Один сетевой том — одна вкладка: повторный вход находит открытую, чужой том — нет.
    @MainActor
    func test_networkMountTab_isReusedPerVolume() {
        let tabs = PanelTabsViewModel(panelKey: "panel.tabs.netmount.\(UUID().uuidString)",
                                      initialPath: NSHomeDirectory())
        XCTAssertNil(tabs.indexOfNetworkMountTab(onVolume: "/Volumes/SERVER"))

        tabs.newNetworkMountTab(path: "/Volumes/SERVER", title: "SERVER: Доки")
        let index = tabs.indexOfNetworkMountTab(onVolume: "/Volumes/SERVER")
        XCTAssertEqual(index, tabs.activeIndex, "вкладка тома найдена и активна")

        tabs.updateTabPath(at: tabs.activeIndex, to: "/Volumes/SERVER/глубже/папка")
        XCTAssertEqual(tabs.indexOfNetworkMountTab(onVolume: "/Volumes/SERVER"), index,
                       "и когда вкладка ушла вглубь тома — тоже")
        XCTAssertNil(tabs.indexOfNetworkMountTab(onVolume: "/Volumes/SERVER2"),
                     "похожее имя другого тома — не тот том")
        XCTAssertNil(tabs.indexOfNetworkMountTab(onVolume: "/Volumes/OTHER"))
    }

    /// Полка и Корзина — вид поверх вкладки, а не её место: вкладка помнит последнюю
    /// настоящую папку. Иначе при возврате на вкладку открывалась полка с дорогой назад
    /// из чужой вкладки.
    @MainActor
    func test_виртуальныеМестаНеСтановятсяПутёмВкладки() {
        let tabs = PanelTabsViewModel(panelKey: "panel.tabs.virtual.\(UUID().uuidString)",
                                      initialPath: NSHomeDirectory())
        tabs.panelNavigated(to: "/Volumes/SERVER/Доки")
        XCTAssertEqual(tabs.activeTab.path, "/Volumes/SERVER/Доки")

        tabs.panelNavigated(to: DropStackStore.stackRoot)
        XCTAssertEqual(tabs.activeTab.path, "/Volumes/SERVER/Доки", "полка не место вкладки")
        tabs.panelNavigated(to: TrashService.trashRoot)
        XCTAssertEqual(tabs.activeTab.path, "/Volumes/SERVER/Доки", "корзина тоже")

        tabs.panelNavigated(to: NSHomeDirectory())
        XCTAssertEqual(tabs.activeTab.path, NSHomeDirectory(), "настоящая папка запоминается")
    }

    func test_pinnedFlag() {
        XCTAssertFalse(PanelTab(path: "/a").pinned)
        XCTAssertTrue(PanelTab(path: "/a", pinned: true).pinned)
    }

    // MARK: - Codable persistence (save / restore tabs)

    func test_codableRoundTrip_preservesState() throws {
        var tab = PanelTab(path: "/Users/dima/Downloads", pinned: true)
        tab.savedViewMode = "detailed"
        tab.viewModePinned = true
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(PanelTab.self, from: data)
        XCTAssertEqual(decoded.id, tab.id)
        XCTAssertEqual(decoded.path, "/Users/dima/Downloads")
        XCTAssertEqual(decoded.title, "Downloads")
        XCTAssertEqual(decoded.kind, .directory)
        XCTAssertTrue(decoded.pinned)
        XCTAssertEqual(decoded.savedViewMode, "detailed")
        XCTAssertTrue(decoded.viewModePinned)
    }

    func test_viewModePinned_defaultsFalse() {
        XCTAssertFalse(PanelTab(path: "/a").viewModePinned)
    }

    // MARK: - TabAccentColor palette

    func test_tabAccentColor_hasSixDistinctCases() {
        XCTAssertEqual(TabAccentColor.allCases.count, 6)
        XCTAssertEqual(Set(TabAccentColor.allCases.map(\.id)).count, 6)
    }

    func test_tabAccentColor_titlesNonEmptyAndUnique() {
        let titles = TabAccentColor.allCases.map(\.title)
        XCTAssertTrue(titles.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(titles).count, titles.count)
    }
}
