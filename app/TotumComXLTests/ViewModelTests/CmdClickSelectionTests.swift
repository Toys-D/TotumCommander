import XCTest

@testable import TotumComXLApp

/// Tests for `PanelViewModel.cmdClickSelection` — the pure rule behind Cmd+click marking.
/// A Cmd+click toggles the clicked file, and when the selection was empty (a fresh pick) it
/// also pulls in the file already under the cursor: the point the user started from. No UI,
/// no filesystem — the items are built with the memberwise initialiser.
final class CmdClickSelectionTests: XCTestCase {

    private func item(_ name: String) -> FileItem {
        FileItem(path: "/d/\(name)", name: name, fileExtension: "", size: 0,
                 isDirectory: false, isHidden: false, isSymlink: false,
                 hardlinkCount: 1, permissions: "rw-r--r--",
                 dateModified: Date(timeIntervalSince1970: 0))
    }

    /// Three files. The cursor sits on file 0; the user Cmd+clicks 1, then 2.
    /// The reported bug: only 1 and 2 got marked. File 0 — where the pick began — must join.
    func test_cursorFileJoinsTheFreshSelection() {
        let items = [item("one"), item("two"), item("three")]

        // Cmd+click "two" while the cursor is on "one".
        var sel = PanelViewModel.cmdClickSelection(
            current: [], items: items, cursorIndex: 0, clickedIndex: 1)
        XCTAssertEqual(sel, ["/d/one", "/d/two"], "the cursor file must be pulled into a fresh pick")

        // The click moved the cursor to "two"; now Cmd+click "three".
        sel = PanelViewModel.cmdClickSelection(
            current: sel, items: items, cursorIndex: 1, clickedIndex: 2)
        XCTAssertEqual(sel, ["/d/one", "/d/two", "/d/three"], "already selecting: just add the clicked file")
    }

    /// Seeding is only for the FIRST pick. Once something is marked, the cursor is merely where
    /// the last click landed, so it must not be re-added.
    func test_cursorFileNotAddedMidSelection() {
        let items = [item("a"), item("b"), item("c"), item("d")]
        // Already marked {a}; cursor on c; Cmd+click d.
        let sel = PanelViewModel.cmdClickSelection(
            current: ["/d/a"], items: items, cursorIndex: 2, clickedIndex: 3)
        XCTAssertEqual(sel, ["/d/a", "/d/d"], "c (the cursor) must not sneak in mid-selection")
    }

    /// Cmd+click on the very file the cursor is on: just marks that one, no duplicate work.
    func test_clickingTheCursorFileItself() {
        let items = [item("a"), item("b")]
        let sel = PanelViewModel.cmdClickSelection(
            current: [], items: items, cursorIndex: 0, clickedIndex: 0)
        XCTAssertEqual(sel, ["/d/a"])
    }

    /// Cmd+click is still a toggle: clicking a marked file removes it.
    func test_cmdClickTogglesOff() {
        let items = [item("a"), item("b")]
        let sel = PanelViewModel.cmdClickSelection(
            current: ["/d/a", "/d/b"], items: items, cursorIndex: 1, clickedIndex: 1)
        XCTAssertEqual(sel, ["/d/a"], "clicking a marked file unmarks it")
    }

    /// The ".." parent entry is never selectable — neither when clicked nor as the seeded cursor.
    func test_parentEntryIsNeverSelected() {
        let items = [item(".."), item("real")]

        // Clicking ".." does nothing.
        XCTAssertEqual(
            PanelViewModel.cmdClickSelection(current: [], items: items, cursorIndex: 1, clickedIndex: 0),
            [])

        // Cursor parked on ".."; Cmd+click a real file → only the real file, ".." not seeded.
        XCTAssertEqual(
            PanelViewModel.cmdClickSelection(current: [], items: items, cursorIndex: 0, clickedIndex: 1),
            ["/d/real"])
    }

    /// Out-of-range indices (stale click after the listing shrank) must not crash.
    func test_outOfRangeIndicesAreIgnored() {
        let items = [item("a")]
        XCTAssertEqual(
            PanelViewModel.cmdClickSelection(current: ["/d/a"], items: items, cursorIndex: 9, clickedIndex: 9),
            ["/d/a"], "a stale index leaves the selection untouched")
    }
}
