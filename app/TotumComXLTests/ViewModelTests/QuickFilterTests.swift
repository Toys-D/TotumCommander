import Foundation
import XCTest

@testable import TotumComXLApp

/// The quick filter narrows what the panel shows while the folder itself stays whole. That split is
/// the thing worth pinning down: everything that reasons about the FOLDER — the directory cache,
/// the selection rebuilt after a reload, the metadata written back from the background — must keep
/// seeing every file, or a filtered panel silently loses the ones it was hiding.
@MainActor
final class QuickFilterTests: XCTestCase {

    private func makeItem(_ name: String, isDirectory: Bool = false) -> FileItem {
        FileItem(path: "/test/\(name)", name: name,
                 fileExtension: (name as NSString).pathExtension,
                 size: 10, isDirectory: isDirectory, isHidden: false, isSymlink: false,
                 permissions: "rw-r--r--", dateModified: Date())
    }

    private func makePanelViewModel() -> PanelViewModel {
        PanelViewModel(
            service: CoreBridgeService(),
            initialPath: NSHomeDirectory(),
            pathDefaultsKey: "panel.path.quickfilter.test.\(UUID().uuidString)",
            viewModeDefaultsKey: "panel.mode.quickfilter.test.\(UUID().uuidString)",
            showHiddenFiles: true
        )
    }

    private func loaded() -> PanelViewModel {
        let vm = makePanelViewModel()
        vm.allItems = [makeItem("..", isDirectory: true),
                       makeItem("report.txt"), makeItem("Report_final.txt"),
                       makeItem("photo.png"), makeItem("notes.md")]
        return vm
    }

    private func visibleNames(_ vm: PanelViewModel) -> [String] { vm.items.map(\.name) }

    // MARK: - Typing a mask

    /// The complaint that started this: typing "*.png" reported "nothing found", because the
    /// filter was matching it as a SUBSTRING — and no file is called "*.png".
    func testTypingAMaskFiltersByIt() {
        let vm = loaded()
        vm.setQuickFilter("*.png")

        XCTAssertEqual(visibleNames(vm), ["..", "photo.png"],
                       "the mask must select the png, and \"..\" always stays")
    }

    func testAMaskWithAQuestionMarkCountsCharacters() {
        let vm = loaded()
        vm.allItems += [makeItem("IMG_0042.jpg"), makeItem("IMG_42.jpg")]
        vm.setQuickFilter("IMG_????.jpg")

        XCTAssertEqual(visibleNames(vm), ["..", "IMG_0042.jpg"])
    }

    /// macOS keeps a name in whichever Unicode form it was written with, and everything made
    /// through Cocoa — Finder, this app, an unpacked archive — writes the DECOMPOSED one: "\u{451}"
    /// is stored as "\u{435}" followed by U+0308, while a mask typed into the panel arrives
    /// composed. A mask runs through a regular expression, which compares UTF-16 units and would
    /// never put the two forms together on its own.
    func testAMaskFindsANameTheSystemStoredDecomposed() {
        let vm = loaded()
        let decomposed = "\u{43e}\u{442}\u{447}\u{451}\u{442} 2026.pdf".decomposedStringWithCanonicalMapping
        vm.allItems += [makeItem(decomposed)]
        vm.setQuickFilter("\u{43e}\u{442}\u{447}\u{451}\u{442}*")

        XCTAssertEqual(visibleNames(vm), ["..", decomposed])
    }

    /// And the other way about, since a mask is often pasted from a name that came off the disk.
    func testADecomposedMaskFindsAComposedName() {
        let vm = loaded()
        let composed = "\u{43e}\u{442}\u{447}\u{451}\u{442} 2026.pdf"
        vm.allItems += [makeItem(composed)]
        vm.setQuickFilter(composed.decomposedStringWithCanonicalMapping + "*")

        XCTAssertEqual(visibleNames(vm), ["..", composed])
    }

    /// Plain text takes the other road — Swift compares strings by canonical equivalence, so the
    /// substring path folded the two forms together all along. Pinned so the paths stay level.
    func testPlainTextFindsANameTheSystemStoredDecomposed() {
        let vm = loaded()
        let decomposed = "\u{43e}\u{442}\u{447}\u{451}\u{442} 2026.pdf".decomposedStringWithCanonicalMapping
        vm.allItems += [makeItem(decomposed)]
        vm.setQuickFilter("\u{43e}\u{442}\u{447}\u{451}\u{442}")

        XCTAssertEqual(visibleNames(vm), ["..", decomposed])
    }

    /// …while plain text keeps behaving as it always did — as a substring, anywhere in the name.
    func testPlainTextStillMatchesAnywhereInTheName() {
        let vm = loaded()
        vm.setQuickFilter("port")

        XCTAssertEqual(visibleNames(vm), ["..", "report.txt", "Report_final.txt"])
    }

    /// A mask that matches nothing says so — the panel keeps only "..", which is navigation.
    func testAMaskThatMatchesNothingLeavesOnlyTheWayUp() {
        let vm = loaded()
        vm.setQuickFilter("*.psd")

        XCTAssertEqual(visibleNames(vm), [".."])
    }

    // MARK: - The buttons in the filter bubble

    /// All three buttons act on what is SHOWN, so none of them needs a mask: plain text
    /// narrows the list just as well, and marking what it left is the same job.
    func testPlainTextIsEnoughToMarkWhatIsShown() {
        let vm = loaded()
        vm.setQuickFilter("port")          // no wildcard at all
        XCTAssertEqual(visibleNames(vm), ["..", "report.txt", "Report_final.txt"])

        vm.selectVisible()

        XCTAssertEqual(vm.selectedPaths.sorted(),
                       ["/test/Report_final.txt", "/test/report.txt"],
                       "a plain search marks its own results")
    }

    /// Unselect stays asleep while nothing is marked — there would be nothing to unmark.
    /// Invert does NOT: with nothing marked, the filter's own catch is what gets turned over.
    func testUnselectSleepsUntilSomethingIsSelected() {
        let vm = loaded()
        vm.setQuickFilter("*.txt")
        XCTAssertTrue(vm.selectedPaths.isEmpty, "nothing marked yet")

        // What the bubble asks before drawing itself.
        let matches = vm.items.filter { $0.name != ".." }.count
        XCTAssertGreaterThan(matches, 0, "there is something to act on")
        XCTAssertEqual(vm.selectedPaths.count, 0, "…but nothing to act WITH")

        vm.selectByMask("*.txt")
        XCTAssertGreaterThan(vm.selectedPaths.count, 0, "now there is")
        XCTAssertNotEqual(L("quickFilter.nothingSelected"), "quickFilter.nothingSelected",
                          "and the sleeping buttons can say why")
    }

    /// What the Select button does: mark what the filter is showing — and the filter STAYS, so
    /// a second mask can add to the selection without reopening anything.
    func testTheSelectButtonMarksAndTheFilterStays() {
        let vm = loaded()
        vm.setQuickFilter("*.txt")
        vm.selectByMask(vm.quickFilterText)

        XCTAssertEqual(vm.quickFilterText, "*.txt", "the filter is still on")
        XCTAssertEqual(visibleNames(vm), ["..", "report.txt", "Report_final.txt"],
                       "and still narrowing the list")
        XCTAssertEqual(vm.selectedPaths.sorted(),
                       ["/test/Report_final.txt", "/test/report.txt"])

        // A second mask, marking on top of the first — the point of keeping it open.
        vm.setQuickFilter("*.png")
        vm.selectByMask(vm.quickFilterText)
        XCTAssertEqual(vm.selectedPaths.sorted(),
                       ["/test/Report_final.txt", "/test/photo.png", "/test/report.txt"])

        // Esc: the folder comes back whole, the marks stay on it.
        vm.clearQuickFilter()
        XCTAssertEqual(visibleNames(vm).count, 5)
        XCTAssertEqual(vm.selectedPaths.count, 3)
    }

    /// The help behind the "?" must actually describe what the box does — every rule the
    /// matcher implements, in the language the user reads.
    func testTheHelpDescribesTheRulesTheMatcherKeeps() {
        let help = L("quickFilter.helpText")
        XCTAssertNotEqual(help, "quickFilter.helpText", "the help is translated")
        XCTAssertNotEqual(L("quickFilter.help"), "quickFilter.help")

        for fragment in ["*.png", "*.pdf", "!", "?", "*2026*.png"] {
            XCTAssertTrue(help.contains(fragment), "the help never mentions \(fragment)")
        }
        XCTAssertTrue(help.contains("\n"), "it is a list, not one long line")

        // And the examples it gives must behave as promised.
        XCTAssertTrue(PanelViewModel.name("photo.png", matchesMask: "*.png&*.pdf"))
        XCTAssertTrue(PanelViewModel.name("scan.pdf", matchesMask: "*.png&*.pdf"))
        XCTAssertFalse(PanelViewModel.name("build.tmp", matchesMask: "!*.tmp"))
        XCTAssertTrue(PanelViewModel.name("отчёт-2026.png", matchesMask: "*2026*.png"))
    }

    /// Press clear and the button goes out with the marks it cleared.
    func testClearingTheSelectionPutsItsButtonOut() {
        let vm = loaded()
        vm.setQuickFilter("*.txt")
        vm.selectVisible()
        XCTAssertTrue(vm.hasSelectionAmongVisible, "there is something to clear")

        vm.deselectVisible()

        XCTAssertFalse(vm.hasSelectionAmongVisible, "and now there is not")
    }

    /// The button is judged by what IT can reach: files marked outside the filter are none of
    /// its business, and counting them left it lit with nothing to do.
    func testMarksHiddenByTheFilterDoNotKeepTheButtonLit() {
        let vm = loaded()
        vm.selectVisible()                     // everything in the folder
        vm.setQuickFilter("*.png")             // now showing one file
        vm.deselectVisible()                   // clears that one

        XCTAssertFalse(vm.selectedPaths.isEmpty, "the txt files stay marked behind the filter")
        XCTAssertFalse(vm.hasSelectionAmongVisible,
                       "but nothing shown is marked, so the button must be out")
    }

    // MARK: - Turning the filter over

    /// Inverting swaps the MARKS over: what was marked lets go, what was not is marked. The
    /// complaint that brought this back: after inverting, pressing Select again ended with
    /// EVERYTHING marked, because inverting had only changed the view.
    func testInvertingSwapsTheMarksOver() {
        let vm = loaded()
        vm.setQuickFilter("*.txt")
        vm.selectVisible()
        XCTAssertEqual(vm.selectedPaths.sorted(),
                       ["/test/Report_final.txt", "/test/report.txt"])

        vm.invertSelectionInFolder()
        vm.toggleQuickFilterInversion()

        XCTAssertEqual(vm.selectedPaths.sorted(), ["/test/notes.md", "/test/photo.png"],
                       "the txt files let go, the others are marked")
        XCTAssertEqual(visibleNames(vm).sorted(), ["..", "notes.md", "photo.png"],
                       "and the list shows what is now marked")

        // Pressing Select here marks what is shown — already marked, so nothing grows.
        vm.selectVisible()
        XCTAssertEqual(vm.selectedPaths.count, 2, "everything must NOT end up marked")
    }

    /// Pressed with nothing marked, the filter's own catch stands in as the thing turned over.
    func testInvertingWithNothingMarkedTurnsTheCatchOver() {
        let vm = loaded()
        vm.setQuickFilter("*.txt")
        XCTAssertTrue(vm.selectedPaths.isEmpty)

        vm.selectVisible()                  // what the button does when nothing is marked
        vm.invertSelectionInFolder()
        vm.toggleQuickFilterInversion()

        XCTAssertEqual(vm.selectedPaths.sorted(), ["/test/notes.md", "/test/photo.png"])
        XCTAssertEqual(visibleNames(vm).sorted(), ["..", "notes.md", "photo.png"])
    }

    /// And pressing it again comes back — marks and list together.
    func testInvertingTwiceReturns() {
        let vm = loaded()
        vm.setQuickFilter("*.txt")
        vm.selectVisible()

        vm.invertSelectionInFolder(); vm.toggleQuickFilterInversion()
        vm.invertSelectionInFolder(); vm.toggleQuickFilterInversion()

        XCTAssertEqual(visibleNames(vm), ["..", "report.txt", "Report_final.txt"])
        XCTAssertEqual(vm.selectedPaths.sorted(),
                       ["/test/Report_final.txt", "/test/report.txt"])
        XCTAssertFalse(vm.quickFilterInverted)
    }

    /// Select and Unselect still act on what is SHOWN, so after a flip they mark the files the
    /// pattern missed — which is how a mask turns into "everything except".
    func testMarkingAfterAFlipCatchesWhatThePatternMissed() {
        let vm = loaded()
        vm.setQuickFilter("*.txt")
        vm.toggleQuickFilterInversion()

        vm.selectVisible()

        XCTAssertEqual(vm.selectedPaths.sorted(), ["/test/notes.md", "/test/photo.png"])
    }

    /// Typing a new pattern starts the right way up.
    func testANewPatternIsNotInverted() {
        let vm = loaded()
        vm.setQuickFilter("*.txt")
        vm.toggleQuickFilterInversion()
        XCTAssertTrue(vm.quickFilterInverted)

        vm.setQuickFilter("*.png")
        XCTAssertFalse(vm.quickFilterInverted)
        XCTAssertEqual(visibleNames(vm), ["..", "photo.png"])
    }

    /// The buttons act on what is SHOWN, so they keep meaning the same thing after a flip.
    func testSelectingActsOnWhatIsShownEvenWhenInverted() {
        let vm = loaded()
        vm.setQuickFilter("*.txt")
        vm.toggleQuickFilterInversion()          // now showing the non-txt files

        vm.selectVisible()

        XCTAssertEqual(vm.selectedPaths.sorted(), ["/test/notes.md", "/test/photo.png"])
    }

    // MARK: - Selecting what the mask found

    func testSelectByMaskTakesTheVisibleMatches() {
        let vm = loaded()
        let added = vm.selectByMask("*.txt")

        XCTAssertEqual(added, 2)
        XCTAssertEqual(vm.selectedPaths.sorted(),
                       ["/test/Report_final.txt", "/test/report.txt"])
    }

    func testDeselectByMaskTakesThemBackOut() {
        let vm = loaded()
        vm.selectByMask("*.txt")
        vm.selectByMask("*.png")
        let removed = vm.deselectByMask("*.txt")

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(vm.selectedPaths, ["/test/photo.png"])
    }

    /// ".." is the way out of the folder, not a file — a mask must never select it.
    func testAMaskNeverSelectsTheWayUp() {
        let vm = loaded()
        vm.selectByMask("*")

        XCTAssertFalse(vm.selectedPaths.contains("/test/.."))
        XCTAssertEqual(vm.selectedPaths.count, 4, "every real file, and only those")
    }

    /// Selection follows what is ON SCREEN: a mask applied while the filter narrows the list
    /// must not reach the files the filter is hiding.
    func testSelectByMaskOnlyTouchesWhatTheFilterShows() {
        let vm = loaded()
        vm.setQuickFilter("*.txt")
        vm.selectByMask("*")

        XCTAssertEqual(vm.selectedPaths.sorted(),
                       ["/test/Report_final.txt", "/test/report.txt"],
                       "the hidden png must stay unselected")
    }

    // MARK: - Narrowing

    func test_narrowsToMatchesAndBackAgain() {
        let vm = loaded()
        vm.setQuickFilter("report")
        XCTAssertEqual(visibleNames(vm), ["..", "report.txt", "Report_final.txt"])
        XCTAssertTrue(vm.isQuickFiltering)

        vm.clearQuickFilter()
        XCTAssertEqual(visibleNames(vm).count, 5)
        XCTAssertFalse(vm.isQuickFiltering)
    }

    func test_matchingIgnoresCase() {
        let vm = loaded()
        vm.setQuickFilter("REPORT")
        XCTAssertEqual(visibleNames(vm), ["..", "report.txt", "Report_final.txt"])
    }

    /// ".." is navigation, not content. Hiding it would strand the user in the folder with no way
    /// back except the mouse.
    func test_parentEntryIsNeverFilteredOut() {
        let vm = loaded()
        vm.setQuickFilter("zzz-matches-nothing")
        XCTAssertEqual(visibleNames(vm), [".."])
    }

    /// The whole point of the split: the folder is untouched, whatever the panel is showing.
    func test_folderKeepsEveryFileWhileFiltered() {
        let vm = loaded()
        vm.setQuickFilter("photo")
        XCTAssertEqual(vm.items.count, 2)
        XCTAssertEqual(vm.allItems.count, 5, "the folder itself must not shrink")
        XCTAssertEqual(vm.unfilteredItemCount, 4, "counted without the parent entry")
    }

    /// removeDeletedItems does a read-modify-write of the listing. Against the visible array it
    /// would store the matches back as the whole folder and drop everything else for good.
    func test_deletingWhileFilteredKeepsTheHiddenFiles() {
        let vm = loaded()
        vm.setQuickFilter("report")
        vm.removeDeletedItems(["/test/report.txt"], preferredCursorPath: nil)

        XCTAssertEqual(visibleNames(vm), ["..", "Report_final.txt"])
        vm.clearQuickFilter()
        XCTAssertEqual(visibleNames(vm).sorted(),
                       ["..", "Report_final.txt", "notes.md", "photo.png"].sorted(),
                       "files the filter was hiding were lost by a delete")
    }

    // MARK: - Cursor

    func test_cursorStaysOnTheSameFileThroughAKeystroke() {
        let vm = loaded()
        vm.setCursor(index: 2)                       // Report_final.txt
        XCTAssertEqual(vm.cursorItem?.name, "Report_final.txt")

        vm.setQuickFilter("report")
        XCTAssertEqual(vm.cursorItem?.name, "Report_final.txt",
                       "the cursor followed the row number instead of the file")
    }

    /// A cursor left pointing past the end is not merely wrong: a Shift-range selection indexes the
    /// array unguarded, so a stale index is a crash waiting for the next keypress.
    func test_cursorNeverPointsPastTheEndAfterNarrowing() {
        let vm = loaded()
        vm.setCursor(index: 4)
        vm.setQuickFilter("photo")
        XCTAssertTrue(vm.items.indices.contains(vm.cursorIndex),
                      "cursorIndex \(vm.cursorIndex) is outside \(vm.items.count) visible rows")
    }

    func test_cursorSurvivesTheFilterBeingCleared() {
        let vm = loaded()
        vm.setQuickFilter("notes")
        vm.setCursor(index: 1)                       // notes.md
        vm.clearQuickFilter()
        XCTAssertEqual(vm.cursorItem?.name, "notes.md")
    }

    // MARK: - Repaint

    /// Brief and thumbnails only reload when the count, path, sort token or tags change. Two
    /// different queries can leave the same number of matches, and without a token bump those two
    /// modes would keep showing the previous set while the detailed list filtered correctly.
    func test_everyFilterEditBumpsTheSortToken() {
        let vm = loaded()
        let start = vm.sortToken

        vm.setQuickFilter("report")
        let afterFirst = vm.sortToken
        XCTAssertNotEqual(afterFirst, start)

        vm.setQuickFilter("photo")                   // same match count as "notes"
        XCTAssertNotEqual(vm.sortToken, afterFirst)
    }

    func test_settingTheSameTextChangesNothing() {
        let vm = loaded()
        vm.setQuickFilter("report")
        let token = vm.sortToken
        vm.setQuickFilter("report")
        XCTAssertEqual(vm.sortToken, token, "a no-op edit still forced every mode to reload")
    }

    // MARK: - Lifecycle

    /// Walking into another folder is a fresh start; the filter belonged to the previous listing.
    func test_navigatingToAnotherFolderClearsTheFilter() {
        let vm = loaded()
        vm.setQuickFilter("report")
        vm.currentPath = "/somewhere/else"
        XCTAssertFalse(vm.isQuickFiltering)
    }

    /// The file watcher re-assigns the SAME path a moment after any change on disk. If that cleared
    /// the filter, it would vanish under the user mid-typing.
    func test_reloadingTheSameFolderKeepsTheFilter() {
        let vm = loaded()
        vm.currentPath = "/test"
        vm.setQuickFilter("report")
        vm.currentPath = "/test"
        XCTAssertTrue(vm.isQuickFiltering)
        XCTAssertEqual(visibleNames(vm), ["..", "report.txt", "Report_final.txt"])
    }

    /// Files arriving from a background load must be filtered too, not shown raw.
    func test_freshListingIsNarrowedByTheActiveFilter() {
        let vm = loaded()
        vm.setQuickFilter("report")
        vm.allItems = [makeItem("..", isDirectory: true),
                       makeItem("report2.txt"), makeItem("other.bin")]
        XCTAssertEqual(visibleNames(vm), ["..", "report2.txt"])
    }
}

/// The road a preset chip takes is setQuickFilter with the SAME text that is already typed —
/// and the press still means "this mask, the right way up".
@MainActor
final class QuickFilterPresetReapplyTests: XCTestCase {
    func testTheSameMaskPressedAgainUndoesTheInversion() {
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(),
                                initialPath: NSHomeDirectory(),
                                pathDefaultsKey: "panel.path.preset.test.\(id)",
                                viewModeDefaultsKey: "panel.mode.preset.test.\(id)",
                                showHiddenFiles: false)
        vm.setQuickFilter("*.png")
        vm.toggleQuickFilterInversion()
        XCTAssertTrue(vm.quickFilterInverted)

        vm.setQuickFilter("*.png")

        XCTAssertFalse(vm.quickFilterInverted,
                       "the chip looked dead: the guard returned before the reset")
    }
}
