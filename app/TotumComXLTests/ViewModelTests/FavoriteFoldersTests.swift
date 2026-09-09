import XCTest

@testable import TotumComXLApp

/// The hotlist behind Cmd+D: one list for the whole app.
final class FavoriteFoldersTests: XCTestCase {

    private var saved: [String]?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.stringArray(forKey: FavoriteFolders.key)
        UserDefaults.standard.removeObject(forKey: FavoriteFolders.key)
    }

    override func tearDown() {
        UserDefaults.standard.set(saved, forKey: FavoriteFolders.key)
        super.tearDown()
    }

    /// Newest at the BOTTOM: a hotlist is used by remembered position, and a list re-ordered on
    /// every addition cannot be learned.
    func testAdditionsKeepTheirOrder() {
        FavoriteFolders.add("/Users/a/Проекты")
        FavoriteFolders.add("/Users/a/Загрузки")
        FavoriteFolders.add("/Users/a/Архив")

        XCTAssertEqual(FavoriteFolders.paths,
                       ["/Users/a/Проекты", "/Users/a/Загрузки", "/Users/a/Архив"])
    }

    /// Adding the folder that is already there changes nothing — not even its place.
    func testAddingTwiceIsAddingOnce() {
        FavoriteFolders.add("/Users/a/Проекты")
        FavoriteFolders.add("/Users/a/Загрузки")
        FavoriteFolders.add("/Users/a/Проекты")

        XCTAssertEqual(FavoriteFolders.paths, ["/Users/a/Проекты", "/Users/a/Загрузки"])
    }

    func testRemovingLeavesTheRestInPlace() {
        FavoriteFolders.add("/a")
        FavoriteFolders.add("/b")
        FavoriteFolders.add("/c")

        FavoriteFolders.remove("/b")

        XCTAssertEqual(FavoriteFolders.paths, ["/a", "/c"])
        XCTAssertFalse(FavoriteFolders.contains("/b"))
        XCTAssertTrue(FavoriteFolders.contains("/a"))
    }

    /// Both panels ask the same defaults — an addition made through one view model is visible
    /// through another at once, with no per-panel copy to go stale.
    @MainActor
    func testBothPanelsSeeOneList() {
        FavoriteFolders.add("/общая")
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(),
                                initialPath: NSHomeDirectory(),
                                pathDefaultsKey: "panel.path.fav.test.\(id)",
                                viewModeDefaultsKey: "panel.mode.fav.test.\(id)",
                                showHiddenFiles: false)

        XCTAssertEqual(vm.bookmarks, ["/общая"])
        vm.addBookmark("/ещё")
        XCTAssertEqual(FavoriteFolders.paths, ["/общая", "/ещё"])
    }
}
