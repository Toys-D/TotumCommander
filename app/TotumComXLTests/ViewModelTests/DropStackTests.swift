import Foundation
import XCTest

@testable import TotumComXLApp

/// The shelf: files gathered from many folders, remembered as paths. What is tested here is
/// the remembering — the panel side is ordinary listing code that works because what the shelf
/// holds are real files at real paths.
final class DropStackTests: XCTestCase {

    // MARK: - Gathering

    func test_addKeepsArrivalOrder() {
        let (paths, added) = DropStackStore.merge(existing: [], incoming: ["/b", "/a", "/c"])
        XCTAssertEqual(paths, ["/b", "/a", "/c"], "the shelf is a pile, not a sorted list")
        XCTAssertEqual(added, 3)
    }

    /// Putting the same file on twice is one file on the shelf, and the caller is told nothing
    /// new arrived — so it can say "already there" instead of pretending.
    func test_theSameFileTwiceIsOneEntry() {
        let (paths, added) = DropStackStore.merge(existing: ["/a", "/b"], incoming: ["/b", "/c", "/b"])
        XCTAssertEqual(paths, ["/a", "/b", "/c"])
        XCTAssertEqual(added, 1)
    }

    /// ".." is a way back, not a file — it must never land on the shelf.
    func test_theGoUpEntryIsNeverGathered() {
        let (paths, added) = DropStackStore.merge(existing: [], incoming: ["/папка/..", "/папка/файл"])
        XCTAssertEqual(paths, ["/папка/файл"])
        XCTAssertEqual(added, 1)
    }

    func test_emptyPathsAreIgnored() {
        let (paths, added) = DropStackStore.merge(existing: ["/a"], incoming: ["", "  ".trimmingCharacters(in: .whitespaces)])
        XCTAssertEqual(paths, ["/a"])
        XCTAssertEqual(added, 0)
    }

    // MARK: - The shelf as a place

    func test_theShelfPathIsRecognised() {
        XCTAssertTrue(DropStackStore.isStackPath("/STACK"))
        XCTAssertTrue(DropStackStore.isStackPath("/STACK/что-то"))
        XCTAssertFalse(DropStackStore.isStackPath("/Users/x/STACK"))
        XCTAssertFalse(DropStackStore.isStackPath("/"))
    }

    // MARK: - Ghosts

    /// A file moved or deleted behind the shelf's back stops appearing — AND stops being
    /// remembered, so the shelf cannot silently fill with names of things that are gone.
    func test_vanishedFilesLeaveTheShelf() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-stack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let alive = dir.appendingPathComponent("живой.txt")
        let doomed = dir.appendingPathComponent("исчезнет.txt")
        try Data("x".utf8).write(to: alive)
        try Data("x".utf8).write(to: doomed)

        let key = DropStackStore.defaultsKey
        let saved = UserDefaults.standard.stringArray(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        DropStackStore.clear()
        XCTAssertEqual(DropStackStore.add([alive.path, doomed.path]), 2)
        XCTAssertEqual(DropStackStore.items().count, 2)

        try FileManager.default.removeItem(at: doomed)
        let listed = DropStackStore.items()
        XCTAssertEqual(listed.map(\.name), ["живой.txt"])
        XCTAssertEqual(DropStackStore.paths, [alive.path], "the ghost is forgotten, not just hidden")

        DropStackStore.clear()
        XCTAssertTrue(DropStackStore.isEmpty)
    }

    /// The badge is drawn, not written into a label: the toolbar shows icons only, so a count
    /// kept in the item's label is a count nobody sees.
    @MainActor
    func test_theBadgeIsPartOfTheDrawnIcon() {
        let empty = MainWindowController.dropStackSymbol(count: 0)
        let filled = MainWindowController.dropStackSymbol(count: 7)
        XCTAssertTrue(empty.isTemplate, "an empty shelf keeps the plain tray, tinted by the theme")
        XCTAssertFalse(filled.isTemplate,
                       "a coloured badge cannot survive in a template image — only alpha does")
        XCTAssertGreaterThan(filled.size.width, empty.size.width, "the badge takes room")
        XCTAssertEqual(MainWindowController.dropStackSymbol(count: 150).size.width,
                       MainWindowController.dropStackSymbol(count: 999).size.width,
                       "anything past 99 reads as 99+ and stops growing")
    }

    /// Программу закрыли, когда панель стояла на полке. «/STACK» файловой системе неизвестен:
    /// без перехвата в воронке настоящих путей панель открывалась не там, где её закрыли.
    @MainActor
    func test_панельЗакрытаяНаПолкеОткрываетсяНаПолке() {
        let key = "panel.path.stack.restore.\(UUID().uuidString)"
        UserDefaults.standard.set(DropStackStore.stackRoot, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: NSHomeDirectory(),
                                pathDefaultsKey: key, viewModeDefaultsKey: key + ".mode",
                                showHiddenFiles: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        XCTAssertTrue(vm.state.insideStack, "полка осталась полкой")
        XCTAssertEqual(vm.currentPath, DropStackStore.stackRoot)
    }

    /// The shelf survives a restart — it is remembered in the defaults, not in a window.
    func test_theShelfIsRememberedBetweenLaunches() {
        let key = DropStackStore.defaultsKey
        let saved = UserDefaults.standard.stringArray(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        DropStackStore.clear()
        DropStackStore.add(["/tmp/один", "/tmp/два"])
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: key), ["/tmp/один", "/tmp/два"])
        XCTAssertEqual(DropStackStore.remove(["/tmp/один"]), 1)
        XCTAssertEqual(DropStackStore.paths, ["/tmp/два"])
        XCTAssertEqual(DropStackStore.remove(["/tmp/нет-такого"]), 0)
    }
}
