import AppKit
import XCTest

@testable import TotumComXLApp

/// The name cell during an inline rename. The editor laid over it is transparent, so the
/// cell's own drawing MUST go away — a broken contract here shows two overlapping texts, and
/// it broke once already, silently, when the plain label became a marquee (build 1148).
@MainActor
final class NameCellEditingTests: XCTestCase {

    func test_setEditing_hidesEverythingTheCellDraws() {
        let cell = NameCellView()
        cell.label.stringValue = "имя файла.txt"
        cell.setHiddenEye(NSImage(size: NSSize(width: 10, height: 10)))
        cell.setTags([.red], font: .systemFont(ofSize: 12))

        cell.setEditing(true)
        let drawn = cell.subviews.filter { !$0.isHidden }
        XCTAssertTrue(drawn.isEmpty,
                      "everything the cell draws must be hidden under the editor, still visible: \(drawn)")

        cell.setEditing(false)
        XCTAssertFalse(cell.label.isHidden, "the name must come back when the editor leaves")
        XCTAssertEqual(cell.subviews.filter { !$0.isHidden }.count, cell.subviews.count)
    }

    /// The old rename code hid `NSTableCellView.textField`, which this cell never sets — the
    /// exact shape of the bug. Nail the assumption down so nobody restores that road by
    /// accident: hiding must go through setEditing, not through the AppKit property.
    func test_theCellDoesNotUseAppKitsTextFieldOutlet() {
        let cell = NameCellView()
        XCTAssertNil(cell.textField,
                     "the label is a plain subview on purpose — AppKit would repaint it on every background change")
    }
}
