import AppKit
import XCTest

@testable import TotumComXLApp

/// Comparing two files: what the C++ core answers, and how that answer becomes two columns.
final class FileDiffTests: XCTestCase {

    private var tmp: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = (FileManager.default.temporaryDirectory.path as NSString)
            .appendingPathComponent("fcxl-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(atPath: tmp) }
        tmp = nil
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ text: String) throws -> String {
        let path = (tmp as NSString).appendingPathComponent(name)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func line(_ kind: FileDiffService.Line.Kind, left: Int? = nil, right: Int? = nil,
                      _ text: String) -> FileDiffService.Line {
        FileDiffService.Line(leftNumber: left, rightNumber: right, kind: kind, text: text)
    }

    // MARK: - Through the core, on real files

    func testTwoIdenticalFilesShowNoDifference() throws {
        let a = try write("a.txt", "один\nдва\nтри\n")
        let b = try write("b.txt", "один\nдва\nтри\n")

        let rows = FileDiffService.rows(from: try FileDiffService.compare(a, b))

        XCTAssertEqual(rows.count, 3)
        XCTAssertFalse(rows.contains { $0.isDifference })
        XCTAssertEqual(rows.map(\.leftText), ["один", "два", "три"])
    }

    /// A changed line has to stand OPPOSITE the line it replaced — that is the whole point of
    /// two columns. The core reports it as "this went, that came"; the pairing is ours.
    func testAChangedLineStandsOppositeTheOneItReplaced() throws {
        let a = try write("a.txt", "первая\nвторая\nтретья\n")
        let b = try write("b.txt", "первая\nдругая\nтретья\n")

        let rows = FileDiffService.rows(from: try FileDiffService.compare(a, b))
        let changed = try XCTUnwrap(rows.first { $0.kind == .changed })

        XCTAssertEqual(changed.leftText, "вторая")
        XCTAssertEqual(changed.rightText, "другая")
        XCTAssertEqual(changed.leftNumber, 2)
        XCTAssertEqual(changed.rightNumber, 2)
        XCTAssertEqual(rows.filter(\.isDifference).count, 1, "one line changed, one row differs")
    }

    func testALineAddedOnTheRightLeavesTheLeftBlank() throws {
        let a = try write("a.txt", "один\nтри\n")
        let b = try write("b.txt", "один\nдва\nтри\n")

        let rows = FileDiffService.rows(from: try FileDiffService.compare(a, b))
        let added = try XCTUnwrap(rows.first { $0.kind == .added })

        XCTAssertEqual(added.rightText, "два")
        XCTAssertNil(added.leftText)
        XCTAssertNil(added.leftNumber)
    }

    func testALineRemovedOnTheLeftLeavesTheRightBlank() throws {
        let a = try write("a.txt", "один\nдва\nтри\n")
        let b = try write("b.txt", "один\nтри\n")

        let rows = FileDiffService.rows(from: try FileDiffService.compare(a, b))
        let removed = try XCTUnwrap(rows.first { $0.kind == .removed })

        XCTAssertEqual(removed.leftText, "два")
        XCTAssertNil(removed.rightText)
    }

    /// A file with NUL bytes has no lines worth standing side by side, and the core would have
    /// to be asked to read it as text to find that out.
    func testABinaryFileIsRefusedBeforeItIsRead() throws {
        let text = try write("a.txt", "текст\n")
        let binary = (tmp as NSString).appendingPathComponent("b.bin")
        try Data([0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04]).write(to: URL(fileURLWithPath: binary))

        XCTAssertThrowsError(try FileDiffService.compare(text, binary)) { error in
            guard case FileDiffService.Failure.binary(let left, let right) = error else {
                return XCTFail("expected .binary, got \(error)")
            }
            XCTAssertFalse(left)
            XCTAssertTrue(right)
        }
    }

    /// …and for those, the only useful answer is whether the bytes match.
    func testBinaryFilesCanStillBeToldApartByTheirBytes() throws {
        let a = (tmp as NSString).appendingPathComponent("a.bin")
        let b = (tmp as NSString).appendingPathComponent("b.bin")
        try Data([0, 1, 2, 3]).write(to: URL(fileURLWithPath: a))
        try Data([0, 1, 2, 3]).write(to: URL(fileURLWithPath: b))
        XCTAssertEqual(FileDiffService.areIdentical(a, b), true)

        try Data([0, 1, 2, 9]).write(to: URL(fileURLWithPath: b))
        XCTAssertEqual(FileDiffService.areIdentical(a, b), false)
    }

    /// A file in some other encoding must not bring the app down on its way through the bridge:
    /// a line that is not UTF-8 used to arrive as nil, and a nil in a dictionary is a crash.
    func testALineThatIsNotUTF8DoesNotBringTheAppDown() throws {
        let a = try write("a.txt", "первая строка\n")
        let b = (tmp as NSString).appendingPathComponent("b.txt")
        // KOI8-R: valid text, not valid UTF-8, and no NUL bytes to give it away as binary.
        let koi8 = Data([0xF0, 0xC5, 0xD2, 0xD7, 0xC1, 0xD1, 0x0A])
        try koi8.write(to: URL(fileURLWithPath: b))

        let rows = FileDiffService.rows(from: try FileDiffService.compare(a, b))

        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.contains { $0.isDifference })
    }

    /// A named pipe must be refused BEFORE anything opens it: opening a FIFO with no writer
    /// blocks forever, and the compare runs on the main thread. This test hangs — not fails,
    /// hangs — if the guard is gone.
    func testAPipeIsRefusedWithoutBeingOpened() throws {
        let text = try write("a.txt", "текст\n")
        let fifo = (tmp as NSString).appendingPathComponent("труба")
        guard mkfifo(fifo, 0o644) == 0 else { throw XCTSkip("mkfifo failed") }

        XCTAssertThrowsError(try FileDiffService.compare(text, fifo)) { error in
            guard case FileDiffService.Failure.notAFile(let name) = error else {
                return XCTFail("expected .notAFile, got \(error)")
            }
            XCTAssertEqual(name, "труба")
        }
        XCTAssertFalse(FileDiffService.isRegularFile(at: fifo))
        XCTAssertTrue(FileDiffService.isRegularFile(at: text))
    }

    /// Files too big for the exact algorithm take a line-by-line fallback. It used to report a
    /// changed line as "modified" with ONE content string — the left file's — so the right
    /// column showed words that were not in the right file at all.
    func testTheHugeFileFallbackShowsTheRightFilesOwnWords() throws {
        // Enough lines that lines(a) × lines(b) crosses the exact algorithm's 10M ceiling.
        let count = 3300
        var left = (0..<count).map { "строка №\($0)" }
        var right = left
        left[1000] = "старый текст слева"
        right[1000] = "новый текст справа"

        let a = try write("big-a.txt", left.joined(separator: "\n") + "\n")
        let b = try write("big-b.txt", right.joined(separator: "\n") + "\n")

        let rows = FileDiffService.rows(from: try FileDiffService.compare(a, b))
        let changed = try XCTUnwrap(rows.first { $0.kind == .changed })

        XCTAssertEqual(changed.leftText, "старый текст слева")
        XCTAssertEqual(changed.rightText, "новый текст справа",
                       "the right column must show the right file, not an echo of the left")
        XCTAssertEqual(rows.filter(\.isDifference).count, 1)
    }

    // MARK: - Laying the answer out in two columns

    func testAnUnevenRunKeepsTheExtraLinesWithABlankBeside() {
        let rows = FileDiffService.rows(from: [
            line(.equal, left: 1, right: 1, "шапка"),
            line(.removed, left: 2, "а"),
            line(.removed, left: 3, "б"),
            line(.added, right: 2, "в"),
        ])

        XCTAssertEqual(rows.map(\.kind), [.equal, .changed, .removed])
        XCTAssertEqual(rows[1].leftText, "а")
        XCTAssertEqual(rows[1].rightText, "в")
        XCTAssertEqual(rows[2].leftText, "б")
        XCTAssertNil(rows[2].rightText)
    }

    func testNothingInNothingOut() {
        XCTAssertTrue(FileDiffService.rows(from: []).isEmpty)
    }

    // MARK: - Walking the differences

    /// "Three differences" means three PLACES, not three lines: a block of five changed lines is
    /// one thing the eye goes to, and one press of the next-difference button.
    func testNeighbouringChangedLinesCountAsOneDifference() {
        let rows = FileDiffService.rows(from: [
            line(.equal, left: 1, right: 1, "="),
            line(.removed, left: 2, "а"),
            line(.removed, left: 3, "б"),
            line(.equal, left: 4, right: 2, "="),
            line(.added, right: 3, "в"),
        ])

        XCTAssertEqual(FileDiffService.differenceRuns(in: rows), [1, 4])
    }

    func testAFileWithNoDifferencesHasNothingToWalk() {
        let rows = FileDiffService.rows(from: [line(.equal, left: 1, right: 1, "=")])
        XCTAssertTrue(FileDiffService.differenceRuns(in: rows).isEmpty)
    }

    // MARK: - Folding away what did not change

    func testFoldingKeepsTheLinesAroundEachDifference() {
        var lines: [FileDiffService.Line] = (1...10).map { (n: Int) in
            line(.equal, left: n, right: n, "\(n)")
        }
        lines.append(line(.added, right: 11, "новая"))
        let rows = FileDiffService.rows(from: lines)

        let folded = FileDiffService.foldingEqualLines(in: rows, context: 2)

        XCTAssertEqual(folded.last?.rightText, "новая")
        XCTAssertEqual(folded.map(\.leftText), [nil, "9", "10", nil],
                       "a strip for what went, then the two lines of context, then the change")
    }

    /// The folded-away lines are replaced by a strip saying how many. Without it, a file that
    /// differs almost everywhere folds almost nothing and the switch looks broken.
    func testWhatWasFoldedAwayIsCounted() {
        var lines: [FileDiffService.Line] = (1...10).map { (n: Int) in
            line(.equal, left: n, right: n, "\(n)")
        }
        lines.append(line(.added, right: 11, "новая"))
        let rows = FileDiffService.rows(from: lines)

        let folded = FileDiffService.foldingEqualLines(in: rows, context: 2)

        XCTAssertEqual(folded.first?.hiddenCount, 8, "lines 1…8 went")
        XCTAssertFalse(folded.first?.isDifference ?? true, "a strip is not a difference to walk")
    }

    /// Two differences far apart get a strip between them, not one run of lines.
    func testAStripStandsBetweenTwoDistantDifferences() {
        var lines: [FileDiffService.Line] = [line(.added, right: 1, "первая")]
        lines += (1...12).map { (n: Int) in line(.equal, left: n, right: n + 1, "\(n)") }
        lines.append(line(.added, right: 14, "последняя"))
        let rows = FileDiffService.rows(from: lines)

        let folded = FileDiffService.foldingEqualLines(in: rows, context: 2)

        XCTAssertEqual(folded.compactMap(\.hiddenCount), [8], "one strip, between the two")
        XCTAssertEqual(folded.filter(\.isDifference).count, 2)
    }

    /// With no context at all, only the differing lines survive — which is what somebody who
    /// asks for "only differences" often means by it.
    func testNoContextLeavesOnlyTheDifferences() {
        var lines: [FileDiffService.Line] = (1...6).map { (n: Int) in
            line(.equal, left: n, right: n, "\(n)")
        }
        lines.append(line(.added, right: 7, "новая"))
        let rows = FileDiffService.rows(from: lines)

        let folded = FileDiffService.foldingEqualLines(in: rows, context: 0)

        XCTAssertEqual(folded.compactMap(\.rightText), ["новая"])
        XCTAssertEqual(folded.compactMap(\.hiddenCount), [6], "all six equal lines went")
    }

    /// Five lines of context keeps more of the file around the change than two.
    func testMoreContextKeepsMoreOfTheFile() {
        var lines: [FileDiffService.Line] = (1...20).map { (n: Int) in
            line(.equal, left: n, right: n, "\(n)")
        }
        lines.append(line(.added, right: 21, "новая"))
        let rows = FileDiffService.rows(from: lines)

        let two = FileDiffService.foldingEqualLines(in: rows, context: 2)
        let five = FileDiffService.foldingEqualLines(in: rows, context: 5)

        XCTAssertEqual(five.count, two.count + 3)
    }

    /// The strips are only for what is hidden: with nothing folded there are none.
    func testNoStripWhenNothingWasHidden() {
        let rows = FileDiffService.rows(from: [
            line(.equal, left: 1, right: 1, "="),
            line(.added, right: 2, "новая"),
        ])

        let folded = FileDiffService.foldingEqualLines(in: rows, context: 2)

        XCTAssertEqual(folded.count, rows.count)
        XCTAssertTrue(folded.allSatisfy { $0.hiddenCount == nil })
    }

    func testFoldingIdenticalFilesLeavesNothing() {
        let rows = FileDiffService.rows(from: [line(.equal, left: 1, right: 1, "=")])
        XCTAssertTrue(FileDiffService.foldingEqualLines(in: rows).isEmpty)
    }

    // MARK: - Telling text from binary

    func testWhatCountsAsBinary() {
        XCTAssertTrue(FileDiffService.looksBinary(sample: Data([0, 0, 0, 65, 66])))
        XCTAssertFalse(FileDiffService.looksBinary(sample: Data("обычный текст".utf8)))
        XCTAssertFalse(FileDiffService.looksBinary(sample: Data()), "an empty file is not binary")
    }
}

/// Which two files the command takes — the part a person notices when it gets it wrong.
@MainActor
final class FilesToCompareTests: XCTestCase {

    private func item(_ name: String, isDirectory: Bool = false, path: String? = nil) -> FileItem {
        FileItem(path: path ?? "/dir/\(name)", name: name,
                 fileExtension: (name as NSString).pathExtension, size: 0,
                 isDirectory: isDirectory, isHidden: false, isSymlink: false,
                 permissions: "-rw-r--r--", dateModified: Date())
    }

    /// Two files picked in one panel are the pair — no need to arrange the panels first.
    func testTwoFilesPickedInOnePanelArethePair() {
        let pair = MainWindowController.filesToCompare(
            active: [item("a.txt"), item("b.txt")], left: nil, right: nil)

        XCTAssertEqual(pair?.0, "/dir/a.txt")
        XCTAssertEqual(pair?.1, "/dir/b.txt")
    }

    /// Otherwise: the file under the cursor in each panel, which is how the two-panel layout is
    /// meant to be used.
    func testOtherwiseItIsTheCursorInEachPanel() {
        let pair = MainWindowController.filesToCompare(
            active: [], left: item("left.txt", path: "/l/left.txt"),
            right: item("right.txt", path: "/r/right.txt"))

        XCTAssertEqual(pair?.0, "/l/left.txt")
        XCTAssertEqual(pair?.1, "/r/right.txt")
    }

    /// One file picked is not two: the cursors decide instead.
    func testOnePickedFileFallsBackToTheCursors() {
        let pair = MainWindowController.filesToCompare(
            active: [item("a.txt")], left: item("l.txt", path: "/l/l.txt"),
            right: item("r.txt", path: "/r/r.txt"))

        XCTAssertEqual(pair?.0, "/l/l.txt")
    }

    func testFoldersAreNotCompared() {
        XCTAssertNil(MainWindowController.filesToCompare(
            active: [], left: item("folder", isDirectory: true), right: item("b.txt")))
    }

    /// Folders picked in a panel are not counted at all — two files and a folder still make a
    /// pair.
    func testAPickedFolderIsIgnoredAmongTheChosen() {
        let pair = MainWindowController.filesToCompare(
            active: [item("a.txt"), item("папка", isDirectory: true), item("b.txt")],
            left: nil, right: nil)

        XCTAssertEqual(pair?.0, "/dir/a.txt")
        XCTAssertEqual(pair?.1, "/dir/b.txt")
    }

    func testTheParentEntryIsNeverAFile() {
        XCTAssertNil(MainWindowController.filesToCompare(
            active: [], left: item(".."), right: item("b.txt")))
    }

    /// The same file on both sides has nothing to show.
    func testAFileIsNotComparedWithItself() {
        let same = item("a.txt", path: "/same/a.txt")
        XCTAssertNil(MainWindowController.filesToCompare(active: [], left: same, right: same))
    }
}
