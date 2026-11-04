import AppKit
import XCTest

@testable import TotumComXLApp

/// What the disk buttons are CALLED.
///
/// The external disks were always "letter + name" ("D: DATA"); the two built-in ones were a bare
/// "System:" and "C:", which said nothing about which disk or whose home they open. They follow
/// the same rule now.
@MainActor
final class VolumeBarLabelTests: XCTestCase {

    func testTheHomeButtonSaysWhoseHomeItIs() {
        XCTAssertEqual(PanelVolumeBar.homeLabel(userName: "dimas"), "C: dimas")
    }

    func testTheSystemButtonSaysWhichDiskTheMacBootedFrom() {
        XCTAssertEqual(PanelVolumeBar.systemLabel(bootVolumeName: "Macintosh HD"),
                       "System: Macintosh HD")
    }

    /// The letter comes FIRST, the way every external disk is written — so the column of buttons
    /// reads down its letters instead of down a jumble of names.
    func testTheLetterLeadsTheName() {
        for label in [PanelVolumeBar.homeLabel(userName: "dimas"),
                      PanelVolumeBar.systemLabel(bootVolumeName: "Macintosh HD")] {
            XCTAssertTrue(label.contains(": "), "\(label) must read as letter, then name")
            XCTAssertFalse(label.hasPrefix("dimas"), "the name must not lead")
        }
    }

    /// Nothing to add is not an error: the bare letter is what the button always was.
    func testAnEmptyNameLeavesTheBareLetter() {
        XCTAssertEqual(PanelVolumeBar.systemLabel(bootVolumeName: nil), "System:")
        XCTAssertEqual(PanelVolumeBar.systemLabel(bootVolumeName: "   "), "System:")
        XCTAssertEqual(PanelVolumeBar.homeLabel(userName: ""), "C:")
    }

    /// A long name is cut instead of pushing the other disks off the bar.
    func testALongNameIsTrimmed() {
        let label = PanelVolumeBar.systemLabel(bootVolumeName: "Macintosh HD — Big External Disk")
        XCTAssertTrue(label.hasSuffix("…"), "a long name must be cut: \(label)")
        XCTAssertLessThanOrEqual(label.count, "System: ".count + 16)
    }

    /// The real machine's answers are sane — the labels are built from live values, after all.
    func testTheLiveLabelsAreWellFormed() {
        XCTAssertTrue(PanelVolumeBar.homeLabel().hasPrefix("C:"))
        XCTAssertTrue(PanelVolumeBar.systemLabel().hasPrefix("System:"))
        XCTAssertFalse(PanelVolumeBar.homeLabel().hasSuffix(" "), "no dangling separator")
    }
}
