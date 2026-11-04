import Foundation
import XCTest

@testable import TotumComXLApp

/// The three READY numbers behind the status bar — the fix for the Big Stutter: the bar
/// re-renders on every cursor tick, so it must never count the folder itself.
@MainActor
final class StatusNumbersTests: XCTestCase {

    private var tmp: URL!
    private var vm: PanelViewModel!

    override func setUp() async throws {
        try await super.setUp()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let id = UUID().uuidString
        vm = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: tmp.path,
            pathDefaultsKey: "panel.path.status.\(id)",
            viewModeDefaultsKey: "panel.mode.status.\(id)",
            showHiddenFiles: false)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
        try await super.tearDown()
    }

    private func item(_ name: String, size: UInt64) -> FileItem {
        FileItem(path: tmp.appendingPathComponent(name).path, name: name,
                 fileExtension: (name as NSString).pathExtension, size: size,
                 isDirectory: false, isHidden: false, isSymlink: false,
                 permissions: "644", dateModified: Date())
    }

    private func parentRow() -> FileItem {
        FileItem(path: "/", name: "..", fileExtension: "", size: 0, isDirectory: true,
                 isHidden: false, isSymlink: false, permissions: "", dateModified: Date())
    }

    func test_visibleCount_excludesTheParentRow() {
        vm.allItems = [parentRow(), item("а.txt", size: 10), item("б.txt", size: 20)]
        XCTAssertEqual(vm.statusVisibleCount, 2)
        XCTAssertEqual(vm.statusSelectedCount, 0)
        XCTAssertEqual(vm.statusSelectedBytes, 0)
    }

    func test_selection_updatesCountAndBytes_withoutTouchingTheList() {
        let a = item("а.txt", size: 100)
        let b = item("б.txt", size: 250)
        vm.allItems = [parentRow(), a, b]

        vm.selectedPaths = [a.path, b.path]
        XCTAssertEqual(vm.statusSelectedCount, 2)
        XCTAssertEqual(vm.statusSelectedBytes, 350)

        vm.selectedPaths = [b.path]
        XCTAssertEqual(vm.statusSelectedCount, 1)
        XCTAssertEqual(vm.statusSelectedBytes, 250)
    }

    /// A path that is not on screen (filtered out, or stale) must not count.
    func test_selection_countsOnlyVisibleItems() {
        let a = item("а.txt", size: 100)
        vm.allItems = [a]
        vm.selectedPaths = [a.path, "/нет/такого.txt"]
        XCTAssertEqual(vm.statusSelectedCount, 1)
        XCTAssertEqual(vm.statusSelectedBytes, 100)
    }

    /// A new list resets the numbers — including the selected ones, recomputed against it.
    func test_newList_recomputesEverything() {
        let a = item("а.txt", size: 100)
        vm.allItems = [a]
        vm.selectedPaths = [a.path]
        XCTAssertEqual(vm.statusSelectedBytes, 100)

        vm.allItems = [item("в.txt", size: 7)]
        XCTAssertEqual(vm.statusVisibleCount, 1)
        XCTAssertEqual(vm.statusSelectedCount, 0, "the old selection is not in the new list")
    }
}
