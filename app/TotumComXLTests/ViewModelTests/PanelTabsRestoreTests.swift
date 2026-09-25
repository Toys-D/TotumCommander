import XCTest

@testable import TotumComXLApp

/// Tests for restoring a panel's tabs across an app restart — specifically WHICH tab comes
/// back active. The tab strip highlights `activeIndex` while the panel loads `activeTab.path`,
/// so if the active tab isn't restored faithfully the highlight ends up on one tab while the
/// panel shows another's folder.
@MainActor
final class PanelTabsRestoreTests: XCTestCase {

    private var panelKey = ""

    override func setUp() {
        super.setUp()
        panelKey = "test-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "panelTabs_\(panelKey)")
        UserDefaults.standard.removeObject(forKey: "panelTabs_\(panelKey)_activeTabID")
        super.tearDown()
    }

    /// Simulates quitting and relaunching: a brand-new view model reading the same storage.
    private func relaunch() -> PanelTabsViewModel {
        PanelTabsViewModel(panelKey: panelKey, initialPath: "/tmp")
    }

    // MARK: - The reported bug

    /// Three tabs, the last one active, quit, relaunch. The user saw the FIRST tab highlighted
    /// while the panel still showed the last tab's folder.
    func test_lastActiveTabIsStillActiveAfterRestart() {
        let vm = PanelTabsViewModel(panelKey: panelKey, initialPath: "/tmp")
        vm.newTab(path: "/tmp/documents")
        vm.newTab(path: "/tmp/pictures")
        XCTAssertEqual(vm.activeTab.path, "/tmp/pictures")

        let restored = relaunch()
        XCTAssertEqual(restored.activeTab.path, "/tmp/pictures",
                       "the tab that was active at quit must come back active")
        XCTAssertEqual(restored.activeIndex, 2)
    }

    /// Clicking a tab is what makes it active — that click must outlive the session too.
    func test_selectingATabIsRemembered() {
        let vm = PanelTabsViewModel(panelKey: panelKey, initialPath: "/tmp")
        vm.newTab(path: "/tmp/documents")
        vm.newTab(path: "/tmp/pictures")
        vm.selectTab(at: 0)

        XCTAssertEqual(relaunch().activeTab.path, "/tmp",
                       "selectTab must persist, not just live in memory")
    }

    /// Terminal/remote/network tabs are dropped on restore, so positions shift. Remembering a
    /// bare index would resurrect the WRONG tab (or get clamped to the last one); the active tab
    /// has to be identified by something that survives the filtering.
    func test_activeTabSurvivesTheFilteringOfNonPersistedTabs() {
        let vm = PanelTabsViewModel(panelKey: panelKey, initialPath: "/tmp")
        vm.newTerminalTab(directory: "/tmp")          // index 1 — dropped on restore
        vm.newTab(path: "/tmp/pictures")              // index 2 — active
        XCTAssertEqual(vm.activeIndex, 2)

        let restored = relaunch()
        XCTAssertEqual(restored.tabs.count, 2, "the terminal tab must not persist")
        XCTAssertEqual(restored.activeTab.path, "/tmp/pictures",
                       "the active tab moved from index 2 to 1 — it must be found by identity")
        XCTAssertEqual(restored.activeIndex, 1)
    }

    /// The active tab itself may be one of the tabs that don't persist. Nothing to restore
    /// then — but the panel must still come back on a real, valid tab.
    func test_whenTheActiveTabItselfIsNotPersisted_fallsBackToAValidTab() {
        let vm = PanelTabsViewModel(panelKey: panelKey, initialPath: "/tmp")
        vm.newTab(path: "/tmp/documents")
        vm.newTerminalTab(directory: "/tmp")          // active, but won't persist

        let restored = relaunch()
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertTrue(restored.tabs.indices.contains(restored.activeIndex),
                      "activeIndex must always point at an existing tab")
        XCTAssertFalse(restored.activeTab.isTerminal)
    }

    /// Closing tabs renumbers the ones after it; the survivor that was active must stay active.
    func test_activeTabSurvivesRestartAfterClosingAnEarlierTab() {
        let vm = PanelTabsViewModel(panelKey: panelKey, initialPath: "/tmp")
        vm.newTab(path: "/tmp/documents")
        vm.newTab(path: "/tmp/pictures")              // active at index 2
        vm.closeTab(at: 0)                            // now [documents, pictures], active = 1

        XCTAssertEqual(vm.activeTab.path, "/tmp/pictures")
        XCTAssertEqual(relaunch().activeTab.path, "/tmp/pictures")
    }

    /// First ever launch: no storage at all. One tab, active, no crash.
    func test_firstLaunchHasOneActiveTab() {
        let vm = relaunch()
        XCTAssertEqual(vm.tabs.count, 1)
        XCTAssertEqual(vm.activeIndex, 0)
        XCTAssertEqual(vm.activeTab.path, "/tmp")
    }

    /// On startup the panel view controller subscribes to the panel's `currentPath` and a
    /// `@Published` sink fires immediately with the current value — so the restored panel path
    /// is pushed straight into `panelNavigated`, which writes it into the ACTIVE tab. Restore
    /// the wrong active tab and that write lands on an innocent tab, silently replacing its
    /// saved folder with the panel's. The tab list quietly rots one tab per launch.
    func test_startupPathSyncDoesNotRewriteAnInnocentTab() {
        let vm = PanelTabsViewModel(panelKey: panelKey, initialPath: "/tmp")
        vm.newTab(path: "/tmp/documents")
        vm.newTab(path: "/tmp/pictures")              // active — the panel's last folder

        let restored = relaunch()
        // Exactly what PanelViewController does when it wires up the path sink.
        restored.panelNavigated(to: "/tmp/pictures")

        XCTAssertEqual(restored.tabs.map(\.path), ["/tmp", "/tmp/documents", "/tmp/pictures"],
                       "the startup sync must land on the active tab and leave the others alone")
        XCTAssertEqual(restored.tabs[0].title, "tmp", "the first tab's title must survive a launch")
    }

    /// Upgrade path: tabs saved by an older build carry no active-tab record. Restoring must
    /// not crash or land out of range — it just starts at the first tab.
    func test_tabsSavedWithoutAnActiveTabRecordStillRestore() {
        let vm = PanelTabsViewModel(panelKey: panelKey, initialPath: "/tmp")
        vm.newTab(path: "/tmp/documents")
        UserDefaults.standard.removeObject(forKey: "panelTabs_\(panelKey)_activeTabID")

        let restored = relaunch()
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.activeIndex, 0)
    }
}
