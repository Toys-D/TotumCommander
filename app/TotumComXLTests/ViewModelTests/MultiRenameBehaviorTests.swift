import XCTest
import AppKit
@testable import TotumComXLApp

/// End-to-end behavior tests for the Multi-Rename tool: each user action is checked at two levels —
/// (1) the preview / backing variable (what the user sees in the fields and the grid), and
/// (2) the REAL rename on disk (files actually get the expected names). This is the "did the whole
/// feature work" layer above the pure-engine unit tests.
@MainActor
final class MultiRenameBehaviorTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mrt-behav-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func makeFile(_ name: String) -> FileItem {
        let path = dir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        return FileItem(path: path, name: name, fileExtension: (name as NSString).pathExtension,
                        size: 1, isDirectory: false, isHidden: false, isSymlink: false,
                        permissions: "rw-r--r--", dateModified: Date())
    }

    private func makeVM(_ items: [FileItem]) -> MultiRenameViewModel {
        let queue = OperationQueueService(fileOps: FileOperationsService(bridgeService: CoreBridgeService()))
        return MultiRenameViewModel(items: items, rootPath: dir.path, session: nil, queue: queue)
    }

    /// Run the rename the VM would perform, on disk, and wait for it (bypasses the async queue but
    /// uses the SAME planned steps and the SAME real filesystem executor the app uses).
    private func runRename(_ vm: MultiRenameViewModel) async throws {
        let steps = vm.plannedSteps()
        let fileOps = FileOperationsService(bridgeService: CoreBridgeService())
        try await fileOps.executeRenameSteps(steps, reporter: NoopReporter())
    }

    /// The names now present in the test dir (files and folders), sorted.
    private func namesOnDisk() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    // MARK: - Tag insertion mirrors the field's backing variable

    func testInsertingThreeNameTags() {
        let vm = makeVM([makeFile("photo.jpg")])
        vm.rule.nameMask = ""                       // start empty
        vm.rule.nameMask += "[N]"                    // what the "Теги" menu does, ×3
        vm.rule.nameMask += "[N]"
        vm.rule.nameMask += "[N]"
        XCTAssertEqual(vm.rule.nameMask, "[N][N][N]")           // the variable behind the field
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.newName, "photophotophoto.jpg")  // preview reflects it
    }

    func testInsertingTwoNameTagsGivesTwo() {
        let vm = makeVM([makeFile("ab.txt")])
        vm.rule.nameMask = "[N][N]"
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.newName, "abab.txt")
    }

    func testInsertingADateTag() {
        let vm = makeVM([makeFile("a.txt")])
        vm.rule.nameMask += "_[YMD]"                  // appended after the default [N]
        XCTAssertEqual(vm.rule.nameMask, "[N]_[YMD]")
    }

    // MARK: - Counter step / start / digits — preview AND disk

    func testCounterStepTwoPreview() {
        let vm = makeVM([makeFile("a.x"), makeFile("b.x"), makeFile("c.x")])
        vm.rule.nameMask = "[C]"; vm.rule.extMask = "[E]"
        vm.rule.counterStart = 1; vm.rule.counterStep = 2; vm.rule.counterDigits = 1
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.map { $0.newName }, ["1.x", "3.x", "5.x"])
    }

    func testCounterStepTwoRenamesOnDisk() async throws {
        _ = makeFile("a.txt"); _ = makeFile("b.txt"); _ = makeFile("c.txt")
        let items = try namesOnDisk().map { name -> FileItem in
            FileItem(path: dir.appendingPathComponent(name).path, name: name,
                     fileExtension: "txt", size: 1, isDirectory: false, isHidden: false,
                     isSymlink: false, permissions: "rw-r--r--", dateModified: Date())
        }
        let vm = makeVM(items)
        vm.rule.nameMask = "[N]_[C]"; vm.rule.extMask = "[E]"
        vm.rule.counterStart = 1; vm.rule.counterStep = 2; vm.rule.counterDigits = 1
        vm.recomputeNow()
        try await runRename(vm)
        // start 1, step 2 → positions 0,1,2 get 1,3,5
        XCTAssertEqual(try namesOnDisk(), ["a_1.txt", "b_3.txt", "c_5.txt"])
    }

    func testCounterDigitsPadOnDisk() async throws {
        let vm = makeVM([makeFile("x.dat")])
        vm.rule.nameMask = "img_[C]"; vm.rule.extMask = "[E]"
        vm.rule.counterStart = 5; vm.rule.counterStep = 1; vm.rule.counterDigits = 3
        vm.recomputeNow()
        try await runRename(vm)
        XCTAssertEqual(try namesOnDisk(), ["img_005.dat"])
    }

    // MARK: - Search & replace — preview AND disk

    func testReplacePreviewAndDisk() async throws {
        let vm = makeVM([makeFile("holiday_2024.jpg")])
        vm.rule.search = "holiday"; vm.rule.replace = "trip"
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.newName, "trip_2024.jpg")
        try await runRename(vm)
        XCTAssertEqual(try namesOnDisk(), ["trip_2024.jpg"])
    }

    func testRegexReplacePreview() {
        let vm = makeVM([makeFile("12-34.txt")])
        vm.rule.useRegex = true; vm.rule.search = "(\\d+)-(\\d+)"; vm.rule.replace = "$2-$1"
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.newName, "34-12.txt")
    }

    // MARK: - Case conversion — preview AND disk

    func testUppercaseOnDisk() async throws {
        let vm = makeVM([makeFile("report.txt")])
        vm.rule.caseMode = .upper
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.newName, "REPORT.TXT")
        try await runRename(vm)
        // case-insensitive volume: the name should now read REPORT.TXT
        XCTAssertEqual(try namesOnDisk().first?.uppercased(), "REPORT.TXT")
        XCTAssertEqual(try namesOnDisk().first, "REPORT.TXT")
    }

    // MARK: - Subfolder sorting via "/" — files actually move into a created folder

    func testSubfolderMoveOnDisk() async throws {
        _ = makeFile("a.txt"); _ = makeFile("b.txt")
        let items = ["a.txt", "b.txt"].map { name in
            FileItem(path: dir.appendingPathComponent(name).path, name: name, fileExtension: "txt",
                     size: 1, isDirectory: false, isHidden: false, isSymlink: false,
                     permissions: "rw-r--r--", dateModified: Date())
        }
        let vm = makeVM(items)
        vm.rule.nameMask = "sub/[N]"; vm.rule.extMask = "[E]"
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.newName, "sub/a.txt")
        try await runRename(vm)
        // top level now holds only the "sub" folder…
        XCTAssertEqual(try namesOnDisk(), ["sub"])
        // …and the files are inside it
        let inSub = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("sub").path).sorted()
        XCTAssertEqual(inSub, ["a.txt", "b.txt"])
    }

    // MARK: - Case-only rename is staged safely (would fail without temp-name staging)

    func testCaseOnlyRenameOnDisk() async throws {
        let vm = makeVM([makeFile("photo.jpg")])
        vm.rule.nameMask = "Photo"; vm.rule.extMask = "[E]"
        vm.recomputeNow()
        try await runRename(vm)
        XCTAssertEqual(try namesOnDisk(), ["Photo.jpg"])
    }

    // MARK: - Swap (cycle) rename is staged safely

    func testSwapNamesOnDisk() async throws {
        _ = makeFile("a.txt"); _ = makeFile("b.txt")
        let items = ["a.txt", "b.txt"].map { name in
            FileItem(path: dir.appendingPathComponent(name).path, name: name, fileExtension: "txt",
                     size: 1, isDirectory: false, isHidden: false, isSymlink: false,
                     permissions: "rw-r--r--", dateModified: Date())
        }
        // write distinct contents so we can verify the swap really happened
        try "AAA".write(toFile: items[0].path, atomically: true, encoding: .utf8)
        try "BBB".write(toFile: items[1].path, atomically: true, encoding: .utf8)
        let vm = makeVM(items)
        // a.txt -> b.txt and b.txt -> a.txt (search/replace swap via a mask trick: manual overrides)
        vm.setManualName("b.txt", for: items[0].path)
        vm.setManualName("a.txt", for: items[1].path)
        try await runRename(vm)
        XCTAssertEqual(try String(contentsOfFile: dir.appendingPathComponent("b.txt").path), "AAA")
        XCTAssertEqual(try String(contentsOfFile: dir.appendingPathComponent("a.txt").path), "BBB")
    }

    // MARK: - Conflict detection blocks execution

    func testDuplicateNamesBlock() {
        let vm = makeVM([makeFile("a.x"), makeFile("b.x")])
        vm.rule.nameMask = "same"; vm.rule.extMask = "txt"
        vm.recomputeNow()
        XCTAssertTrue(vm.hasBlockingIssues)
        XCTAssertFalse(vm.canExecute)
    }

    func testManualEditReflectedInPreview() {
        let a = makeFile("a.txt")
        let vm = makeVM([a, makeFile("b.txt")])
        vm.setManualName("myname.txt", for: a.path)
        XCTAssertEqual(vm.plans.first { $0.sourcePath == a.path }?.newName, "myname.txt")
    }

    // MARK: - Extension mask

    func testExtensionMaskChangeOnDisk() async throws {
        let vm = makeVM([makeFile("clip.jpeg")])
        vm.rule.nameMask = "[N]"; vm.rule.extMask = "jpg"   // force a fixed extension
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.newName, "clip.jpg")
        try await runRename(vm)
        XCTAssertEqual(try namesOnDisk(), ["clip.jpg"])
    }

    func testNameOnlyDropsExtension() {
        let vm = makeVM([makeFile("note.txt")])
        vm.rule.nameMask = "[N]"; vm.rule.extMask = ""
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.newName, "note")   // no trailing dot
    }

    // MARK: - Search & replace option switches

    func testReplaceOnceSwitch() {
        let vm = makeVM([makeFile("a_b_c.txt")])
        vm.rule.search = "_"; vm.rule.replace = "-"
        vm.rule.replaceOnce = true
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.newName, "a-b_c.txt")   // only the first "_"
    }

    func testReplaceAllWhenOnceOff() {
        let vm = makeVM([makeFile("a_b_c.txt")])
        vm.rule.search = "_"; vm.rule.replace = "-"
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.newName, "a-b-c.txt")
    }

    func testRespectCaseSwitch() {
        let vm = makeVM([makeFile("IMG_photo.jpg")])
        // respect case ON: lowercase "img" should NOT match "IMG"
        vm.rule.search = "img"; vm.rule.replace = "X"; vm.rule.respectCase = true
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.newName, "IMG_photo.jpg")   // unchanged (no match)
        // respect case OFF: it matches
        vm.rule.respectCase = false
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.newName, "X_photo.jpg")
    }

    func testInExtensionSwitch() {
        let vm = makeVM([makeFile("video.tmp")])   // stem "video" has no "m"; ext "tmp" does
        vm.rule.search = "m"; vm.rule.replace = "M"
        // OFF: extension untouched, and the name has no "m" → unchanged
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.newName, "video.tmp")
        // ON: the extension's "m" is replaced too
        vm.rule.searchInExtension = true
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.newName, "video.tMp")
    }

    // MARK: - Unchanged rows are skipped, not renamed

    func testUnchangedRowIsSkipped() {
        let vm = makeVM([makeFile("keep.txt")])
        // default mask reproduces the same name → status .unchanged, nothing to do
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.status, .unchanged)
        XCTAssertTrue(vm.actionablePlans.isEmpty)
        XCTAssertFalse(vm.canExecute)
    }

    // MARK: - Undo restores the original names on disk

    func testUndoRoundTripOnDisk() async throws {
        let vm = makeVM([makeFile("a.txt"), makeFile("b.txt")])
        vm.rule.nameMask = "renamed_[C]"; vm.rule.extMask = "[E]"
        vm.rule.counterStart = 1; vm.rule.counterStep = 1; vm.rule.counterDigits = 1
        vm.recomputeNow()

        // forward: capture the reverse moves the VM would use, then rename for real
        let forward = vm.currentMoves()
        try await runSteps(vm.plannedSteps())
        XCTAssertEqual(try namesOnDisk(), ["renamed_1.txt", "renamed_2.txt"])

        // undo: reverse every move (new -> old) through the same real executor
        let reverse = forward.map { RenameExecutionPlanner.Move(source: $0.final, final: $0.source) }
        let undoSteps = RenameExecutionPlanner().plan(reverse) { i in ".undo-\(i)" }
        try await runSteps(undoSteps)
        XCTAssertEqual(try namesOnDisk(), ["a.txt", "b.txt"])
    }

    private func runSteps(_ steps: [RenameExecutionPlanner.Step]) async throws {
        let fileOps = FileOperationsService(bridgeService: CoreBridgeService())
        try await fileOps.executeRenameSteps(steps, reporter: NoopReporter())
    }

    // MARK: - Image dimension tags [=tc.width] / [=tc.height]

    /// Write a real PNG of the given pixel size and return its FileItem.
    @discardableResult
    private func makePNG(_ name: String, width: Int, height: Int) -> FileItem {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let data = rep.representation(using: .png, properties: [:])!
        let path = dir.appendingPathComponent(name).path
        try? data.write(to: URL(fileURLWithPath: path))
        return FileItem(path: path, name: name, fileExtension: "png", size: UInt64(data.count),
                        isDirectory: false, isHidden: false, isSymlink: false,
                        permissions: "rw-r--r--", dateModified: Date())
    }

    func testImageDimensionsReadFromHeader() {
        makePNG("pic.png", width: 40, height: 30)
        let dims = MultiRenameViewModel.imageDimensions(path: dir.appendingPathComponent("pic.png").path)
        XCTAssertEqual(dims?.0, 40)
        XCTAssertEqual(dims?.1, 30)
    }

    // MARK: - Date/time tags stamp the CURRENT clock, not the file's date

    func testDateTagsUseCurrentDateNotFileDate() {
        // The file is dated far in the past; [YMD] must still show TODAY.
        let old = Date(timeIntervalSince1970: 946_684_800)  // 2000-01-01
        let item = FileItem(path: dir.appendingPathComponent("f.txt").path, name: "f.txt",
                            fileExtension: "txt", size: 1, isDirectory: false, isHidden: false,
                            isSymlink: false, permissions: "rw-r--r--", dateModified: old)
        FileManager.default.createFile(atPath: item.path, contents: Data("x".utf8))
        let vm = makeVM([item])
        vm.rule.nameMask = "[YMD]"; vm.rule.extMask = "[E]"
        vm.recomputeNow()

        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day], from: Date())
        let expected = String(format: "%04d%02d%02d.txt", c.year!, c.month!, c.day!)
        XCTAssertEqual(vm.plans.first?.newName, expected)   // today, not 2000-01-01
    }

    func testTimeTagsMatchClockWithinTolerance() {
        let item = FileItem(path: dir.appendingPathComponent("g.txt").path, name: "g.txt",
                            fileExtension: "txt", size: 1, isDirectory: false, isHidden: false,
                            isSymlink: false, permissions: "rw-r--r--", dateModified: Date())
        FileManager.default.createFile(atPath: item.path, contents: Data("x".utf8))
        let vm = makeVM([item])
        vm.rule.nameMask = "[hms]"; vm.rule.extMask = ""
        vm.recomputeNow()

        // Parse HHMMSS from the preview and compare to the wall clock: within 59 s.
        let name = vm.plans.first?.newName ?? ""
        XCTAssertEqual(name.count, 6, "expected HHMMSS, got \(name)")
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute, .second], from: Date())
        let nowSecs = (c.hour! * 3600) + (c.minute! * 60) + c.second!
        let h = Int(name.prefix(2)) ?? -1
        let m = Int(name.dropFirst(2).prefix(2)) ?? -1
        let s = Int(name.suffix(2)) ?? -1
        let tagSecs = (h * 3600) + (m * 60) + s
        XCTAssertLessThanOrEqual(abs(nowSecs - tagSecs), 59, "[hms] \(name) drifted from the clock")
    }

    func testWidthHeightTagsInPreview() async {
        let item = makePNG("shot.png", width: 40, height: 30)
        let vm = makeVM([item])
        vm.rule.nameMask = "[=tc.width]x[=tc.height]"; vm.rule.extMask = "[E]"
        await vm.loadDimensions()             // fills the cache off-main, then recomputes
        XCTAssertEqual(vm.plans.first?.newName, "40x30.png")
    }

    // MARK: - Presets: save current settings, change them, apply → settings restored

    func testPresetSaveChangeApply() {
        let suite = "mrt-preset-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = RenamePresetStore(defaults: defaults)
        let queue = OperationQueueService(fileOps: FileOperationsService(bridgeService: CoreBridgeService()))
        let vm = MultiRenameViewModel(items: [makeFile("a.txt")], rootPath: dir.path,
                                      session: nil, queue: queue, presetStore: store)

        vm.rule.nameMask = "[N]_[C]"; vm.rule.counterStep = 5; vm.rule.caseMode = .upper
        vm.savePreset(name: "MyPreset")
        XCTAssertEqual(vm.presets.map { $0.name }, ["MyPreset"])

        // change everything
        vm.rule.nameMask = "[N]"; vm.rule.counterStep = 1; vm.rule.caseMode = .unchanged

        // apply the preset → settings come back
        vm.applyPreset(vm.presets.first { $0.name == "MyPreset" }!)
        XCTAssertEqual(vm.rule.nameMask, "[N]_[C]")
        XCTAssertEqual(vm.rule.counterStep, 5)
        XCTAssertEqual(vm.rule.caseMode, .upper)

        vm.deletePreset(name: "MyPreset")
        XCTAssertTrue(vm.presets.isEmpty)
        defaults.removePersistentDomain(forName: suite)
    }
}

/// Progress reporter that does nothing — for driving executeRenameSteps in tests.
private final class NoopReporter: OperationProgressReporter {
    nonisolated var isCancelled: Bool { false }
    nonisolated var isPaused: Bool { false }
    nonisolated var isSentToQueue: Bool { false }
    nonisolated func waitWhilePaused() -> Bool { false }
    func update(currentFile: String, progress: Double, bytesDone: Int64, bytesTotal: Int64,
                filesDone: Int, filesTotal: Int) {}
    func close() {}
}
