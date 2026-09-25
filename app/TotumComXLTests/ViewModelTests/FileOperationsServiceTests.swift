import XCTest

@testable import TotumComXLApp

/// Tests for FileOperationsService — the engine that touches real user files. Covers the
/// dialog-free operations end-to-end against a throwaway temp directory: create folder /
/// text file, rename, symlink / hardlink, properties, size math, unique-copy naming and
/// archive base-name parsing. Includes the Cyrillic-name path (the "й" regression area)
/// and the error cases (duplicates, slash-in-name, dir hardlink). No mocks, no UI.
final class FileOperationsServiceTests: XCTestCase {

    private var ops: FileOperationsService!
    private var tmp: String!   // per-test throwaway directory

    override func setUp() {
        super.setUp()
        ops = FileOperationsService(bridgeService: CoreBridgeService())
        tmp = (FileManager.default.temporaryDirectory.path as NSString)
            .appendingPathComponent("fcxl-ops-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        ops = nil
        tmp = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func path(_ name: String) -> String {
        (tmp as NSString).appendingPathComponent(name)
    }

    @discardableResult
    private func makeFile(_ name: String, _ contents: String = "x") -> String {
        let p = path(name)
        FileManager.default.createFile(atPath: p, contents: Data(contents.utf8))
        return p
    }

    private func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

    private func isDir(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }

    private func read(_ p: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: p))).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func code(of error: Error) -> Int { (error as NSError).code }

    // MARK: - createDirectory

    func test_createDirectory_createsFolder() throws {
        try ops.createDirectory(at: tmp, name: "NewFolder")
        XCTAssertTrue(isDir(path("NewFolder")))
    }

    func test_createDirectory_cyrillicName() throws {
        try ops.createDirectory(at: tmp, name: "Новая папка")
        XCTAssertTrue(isDir(path("Новая папка")))
    }

    func test_createDirectory_trimsWhitespace() throws {
        try ops.createDirectory(at: tmp, name: "  Docs  ")
        XCTAssertTrue(isDir(path("Docs")))
    }

    func test_createDirectory_emptyNameIsNoop() throws {
        try ops.createDirectory(at: tmp, name: "   ")
        // Nothing created; the temp dir stays empty.
        let contents = try FileManager.default.contentsOfDirectory(atPath: tmp)
        XCTAssertTrue(contents.isEmpty)
    }

    func test_createDirectory_duplicateThrowsFileExists() throws {
        try ops.createDirectory(at: tmp, name: "Dup")
        XCTAssertThrowsError(try ops.createDirectory(at: tmp, name: "Dup")) { error in
            XCTAssertEqual(self.code(of: error), NSFileWriteFileExistsError)
        }
    }

    // MARK: - createTextFile

    /// Одно правило имени для создания, курсора и редактора: .txt только без расширения.
    func test_textFileName_добавляетTxtТолькоБезРасширения() {
        XCTAssertEqual(FileOperationsService.textFileName(for: "  заметки "), "заметки.txt")
        XCTAssertEqual(FileOperationsService.textFileName(for: "main.swift"), "main.swift")
        XCTAssertEqual(FileOperationsService.textFileName(for: "   "), "")
    }

    func test_createTextFile_writesContents() throws {
        try ops.createTextFile(at: tmp, name: "note.txt", contents: "hello world")
        XCTAssertEqual(read(path("note.txt")), "hello world")
    }

    func test_createTextFile_appendsTxtWhenNoExtension() throws {
        try ops.createTextFile(at: tmp, name: "readme")
        XCTAssertTrue(exists(path("readme.txt")))
    }

    func test_createTextFile_keepsExplicitExtension() throws {
        try ops.createTextFile(at: tmp, name: "data.json", contents: "{}")
        XCTAssertTrue(exists(path("data.json")))
        XCTAssertFalse(exists(path("data.json.txt")))
    }

    func test_createTextFile_cyrillicNameAndContentRoundTrip() throws {
        // The 'й' regression: non-ASCII names + content must survive intact.
        try ops.createTextFile(at: tmp, name: "Заметка", contents: "Привет, мир! й ё")
        XCTAssertEqual(read(path("Заметка.txt")), "Привет, мир! й ё")
    }

    func test_createTextFile_duplicateThrowsFileExists() throws {
        try ops.createTextFile(at: tmp, name: "a.txt")
        XCTAssertThrowsError(try ops.createTextFile(at: tmp, name: "a.txt")) { error in
            XCTAssertEqual(self.code(of: error), NSFileWriteFileExistsError)
        }
    }

    // MARK: - renameItem

    private func item(at p: String) throws -> FileItem {
        try XCTUnwrap(FileItem.fromPath(p), "FileItem.fromPath returned nil for \(p)")
    }

    func test_renameItem_renamesFile() throws {
        let src = makeFile("old.txt", "data")
        try ops.renameItem(try item(at: src), to: "new.txt")
        XCTAssertFalse(exists(src))
        XCTAssertEqual(read(path("new.txt")), "data")
    }

    func test_renameItem_cyrillicTarget() throws {
        let src = makeFile("file.txt")
        try ops.renameItem(try item(at: src), to: "Файл й.txt")
        XCTAssertTrue(exists(path("Файл й.txt")))
    }

    func test_renameItem_slashInNameThrows() throws {
        let src = makeFile("f.txt")
        XCTAssertThrowsError(try ops.renameItem(try item(at: src), to: "a/b.txt")) { error in
            XCTAssertEqual(self.code(of: error), NSFileWriteInvalidFileNameError)
        }
        XCTAssertTrue(exists(src), "source must be untouched after a rejected rename")
    }

    func test_renameItem_existingTargetThrows() throws {
        let src = makeFile("a.txt")
        makeFile("b.txt")
        XCTAssertThrowsError(try ops.renameItem(try item(at: src), to: "b.txt")) { error in
            XCTAssertEqual(self.code(of: error), NSFileWriteFileExistsError)
        }
        XCTAssertTrue(exists(src))
    }

    func test_renameItem_sameNameIsNoop() throws {
        let src = makeFile("keep.txt", "v")
        XCTAssertNoThrow(try ops.renameItem(try item(at: src), to: "keep.txt"))
        XCTAssertEqual(read(src), "v")
    }

    func test_renameItem_emptyNameIsNoop() throws {
        let src = makeFile("keep.txt")
        XCTAssertNoThrow(try ops.renameItem(try item(at: src), to: "   "))
        XCTAssertTrue(exists(src))
    }

    // MARK: - symlink / hardlink

    func test_createSymlink_createsLinkToTarget() throws {
        let target = makeFile("target.txt", "payload")
        let link = path("link.txt")
        try ops.createSymlink(at: link, pointingTo: target)
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: link)
        XCTAssertEqual(dest, target)
        XCTAssertEqual(read(link), "payload")   // follows the link
    }

    func test_createSymlink_existingPathThrows() throws {
        let target = makeFile("t.txt")
        let link = makeFile("link.txt")
        XCTAssertThrowsError(try ops.createSymlink(at: link, pointingTo: target)) { error in
            XCTAssertEqual(self.code(of: error), NSFileWriteFileExistsError)
        }
    }

    func test_createHardlink_sharesContent() throws {
        let target = makeFile("orig.txt", "shared")
        let link = path("hard.txt")
        try ops.createHardlink(at: link, pointingTo: target)
        XCTAssertEqual(read(link), "shared")
        // A hardlink is the same inode: editing through one path shows via the other.
        try "changed".data(using: .utf8)!.write(to: URL(fileURLWithPath: target))
        XCTAssertEqual(read(link), "changed")
    }

    func test_createHardlink_directoryTargetThrows() throws {
        try ops.createDirectory(at: tmp, name: "dir")
        XCTAssertThrowsError(try ops.createHardlink(at: path("hl"), pointingTo: path("dir"))) { error in
            XCTAssertEqual(self.code(of: error), -200)
        }
    }

    // MARK: - properties

    func test_properties_file() throws {
        let p = makeFile("f.txt", "12345")   // 5 bytes
        let props = try ops.properties(path: p)
        XCTAssertFalse(props.isDirectory)
        XCTAssertEqual(props.itemSizeBytes, 5)
    }

    func test_properties_directoryRecursiveSize() throws {
        try ops.createDirectory(at: tmp, name: "box")
        let box = path("box")
        FileManager.default.createFile(atPath: (box as NSString).appendingPathComponent("a"), contents: Data(count: 100))
        try FileManager.default.createDirectory(atPath: (box as NSString).appendingPathComponent("sub"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: (box as NSString).appendingPathComponent("sub/b"), contents: Data(count: 40))

        let props = try ops.properties(path: box)
        XCTAssertTrue(props.isDirectory)
        XCTAssertEqual(props.totalSizeBytes, 140)
        XCTAssertEqual(props.filesCount, 2)
    }

    func test_properties_missingPathThrows() {
        XCTAssertThrowsError(try ops.properties(path: path("nope.txt"))) { error in
            XCTAssertEqual(self.code(of: error), NSFileNoSuchFileError)
        }
    }

    // MARK: - size math

    func test_totalSize_sumsItems() throws {
        let a = makeFile("a", String(repeating: "x", count: 10))
        let b = makeFile("b", String(repeating: "y", count: 25))
        let sum = ops.totalSize(for: [try item(at: a), try item(at: b)])
        XCTAssertEqual(sum, 35)
    }

    func test_directoryTotalSize_recursive() throws {
        try ops.createDirectory(at: tmp, name: "tree")
        let tree = path("tree")
        FileManager.default.createFile(atPath: (tree as NSString).appendingPathComponent("x"), contents: Data(count: 200))
        XCTAssertEqual(ops.directoryTotalSize(at: tree), 200)
    }

    // MARK: - unique copy name

    func test_uniqueCopyPath_incrementsIndex() throws {
        makeFile("doc.txt")
        let first = ops.uniqueCopyPathForDestination(path("doc.txt"))
        XCTAssertEqual((first as NSString).lastPathComponent, "doc (1).txt")

        // If "(1)" also exists, it advances to "(2)".
        makeFile("doc (1).txt")
        let second = ops.uniqueCopyPathForDestination(path("doc.txt"))
        XCTAssertEqual((second as NSString).lastPathComponent, "doc (2).txt")
    }

    func test_uniqueCopyPath_noExtension() throws {
        makeFile("folder")
        let unique = ops.uniqueCopyPathForDestination(path("folder"))
        XCTAssertEqual((unique as NSString).lastPathComponent, "folder (1)")
    }

    // MARK: - archive base name

    func test_archiveBaseName_stripsKnownSuffixes() {
        XCTAssertEqual(ops.archiveBaseName(from: "backup.tar.gz"), "backup")
        XCTAssertEqual(ops.archiveBaseName(from: "photos.zip"), "photos")
        XCTAssertEqual(ops.archiveBaseName(from: "data.7z"), "data")
        XCTAssertEqual(ops.archiveBaseName(from: "notes.txt"), "notes")   // non-archive: drop last ext
        XCTAssertEqual(ops.archiveBaseName(from: "README"), "README")     // no extension: unchanged
    }

    // MARK: - existingDestinationPaths (unpack conflict pre-scan)

    /// libarchive decides overwrite-vs-skip from one flag at start-up, so the UI has to know
    /// what would be clobbered BEFORE extraction begins. These cover that pre-scan.

    func test_existingDestinationPaths_noArchiveReturnsEmpty() {
        let missing = path("nope.zip")
        XCTAssertTrue(ops.existingDestinationPaths(forUnpacking: missing,
                                                   to: tmp,
                                                   createSubfolder: false).isEmpty)
    }

    func test_existingDestinationPaths_emptyDestinationHasNoConflicts() throws {
        // A real archive, extracted into a folder where nothing exists yet.
        let src = path("payload.txt")
        try "hello".write(toFile: src, atomically: true, encoding: .utf8)
        let archive = path("bundle.zip")
        try zip(files: [src], to: archive)

        let dest = path("emptydir")
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        XCTAssertTrue(ops.existingDestinationPaths(forUnpacking: archive,
                                                   to: dest,
                                                   createSubfolder: false).isEmpty)
    }

    func test_existingDestinationPaths_reportsCollision() throws {
        let src = path("payload.txt")
        try "hello".write(toFile: src, atomically: true, encoding: .utf8)
        let archive = path("bundle2.zip")
        try zip(files: [src], to: archive)

        // Same file already sitting in the destination → must be reported.
        let dest = path("busydir")
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        let clash = (dest as NSString).appendingPathComponent("payload.txt")
        try "older".write(toFile: clash, atomically: true, encoding: .utf8)

        let conflicts = ops.existingDestinationPaths(forUnpacking: archive,
                                                     to: dest,
                                                     createSubfolder: false)
        XCTAssertEqual(conflicts, [clash])
    }

    func test_existingDestinationPaths_subfolderModeLooksInsideTheSubfolder() throws {
        let src = path("payload.txt")
        try "hello".write(toFile: src, atomically: true, encoding: .utf8)
        let archive = path("bundle3.zip")
        try zip(files: [src], to: archive)

        // createSubfolder puts everything under <dest>/<archive base name>/ — a file with the
        // same name directly in <dest> must therefore NOT count as a conflict.
        let dest = path("subdir")
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        try "decoy".write(toFile: (dest as NSString).appendingPathComponent("payload.txt"),
                          atomically: true, encoding: .utf8)
        XCTAssertTrue(ops.existingDestinationPaths(forUnpacking: archive,
                                                   to: dest,
                                                   createSubfolder: true).isEmpty)
    }

    /// Build a zip with the system zip tool — independent of the code under test.
    private func zip(files: [String], to archivePath: String) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.arguments = ["-j", "-q", archivePath] + files
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "zip failed")
    }


    // MARK: - add-to-archive performance (zip inside zip)

    /// Adding an already-compressed 2MB file into a zip should take a moment, not a minute.
    func test_addZipIntoZip_completesQuickly() throws {
        // Destination archive with one small entry.
        let seed = path("seed.txt")
        try "seed".write(toFile: seed, atomically: true, encoding: .utf8)
        let dest = path("dest.zip")
        try zip(files: [seed], to: dest)

        // A ~2MB incompressible payload, zipped — same shape as the reported case.
        let payload = path("payload.bin")
        var bytes = Data(count: 0)
        for i in 0..<(2 * 1024 * 1024) { bytes.append(UInt8(truncatingIfNeeded: i &* 31)) }
        try bytes.write(to: URL(fileURLWithPath: payload))
        let inner = path("inner.zip")
        try zip(files: [payload], to: inner)

        let bridge = CoreBridgeService()

        // (a) no progress callback at all
        let t0 = Date()
        try bridge.addFilesToArchive(archivePath: dest, filePaths: [inner], basePath: "", progress: nil)
        let noCb = Date().timeIntervalSince(t0)

        // (b) with a callback — how often is it even called?
        let dest2 = path("dest2.zip")
        try zip(files: [seed], to: dest2)
        var calls = 0
        let t1 = Date()
        try bridge.addFilesToArchive(archivePath: dest2, filePaths: [inner], basePath: "") { _, _, _, _, _, _ in
            calls += 1
        }
        let withCb = Date().timeIntervalSince(t1)

        print("### no-callback: \(String(format: "%.2f", noCb))s | with-callback: \(String(format: "%.2f", withCb))s | calls=\(calls)")
        XCTAssertLessThan(withCb, 10, "adding a 2MB zip into a zip took \(withCb)s")
    }


    /// The archive must survive a failed add. Before this, appending wrote straight into the
    /// user's zip: minizip drops the central directory as soon as the first entry lands, so an
    /// interrupted add left the file unopenable and everything inside it gone.
    func test_failedAdd_leavesOriginalArchiveIntact() throws {
        let seed = path("keep.txt")
        try "precious".write(toFile: seed, atomically: true, encoding: .utf8)
        let archive = path("safe.zip")
        try zip(files: [seed], to: archive)
        let before = try Data(contentsOf: URL(fileURLWithPath: archive))

        // Adding a file that does not exist fails somewhere inside the append.
        let bridge = CoreBridgeService()
        XCTAssertThrowsError(
            try bridge.addFilesToArchive(archivePath: archive,
                                         filePaths: [path("does-not-exist.bin")],
                                         basePath: "",
                                         progress: nil)
        )

        // Byte-identical, still listable, entry still there.
        let after = try Data(contentsOf: URL(fileURLWithPath: archive))
        XCTAssertEqual(after, before, "a failed add must not modify the archive at all")
        let entries = try bridge.listArchiveEntries(archivePath: archive)
        XCTAssertTrue(entries.contains { $0.path.hasSuffix("keep.txt") })
    }

    /// And no .tmp staging file is left lying next to the archive.
    func test_successfulAdd_leavesNoTempFile() throws {
        let seed = path("a.txt")
        try "a".write(toFile: seed, atomically: true, encoding: .utf8)
        let archive = path("clean.zip")
        try zip(files: [seed], to: archive)

        let extra = path("b.txt")
        try "b".write(toFile: extra, atomically: true, encoding: .utf8)
        let bridge = CoreBridgeService()
        try bridge.addFilesToArchive(archivePath: archive, filePaths: [extra],
                                     basePath: "", progress: nil)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "staging files left behind: \(leftovers)")
        let entries = try bridge.listArchiveEntries(archivePath: archive)
        XCTAssertEqual(entries.count, 2)
    }


    /// A cancelled operation must not poison the ones after it. The cancel flag is
    /// process-wide and nothing ever reset it, so the first cancel made every later archive
    /// call — including listing — return "cancelled": the archive could not be opened again
    /// for the rest of the session, and looked corrupted when it was perfectly fine.
    func test_cancel_doesNotBreakLaterArchiveOperations() throws {

        let seed = path("inside.txt")
        try "data".write(toFile: seed, atomically: true, encoding: .utf8)
        let archive = path("after-cancel.zip")
        try zip(files: [seed], to: archive)

        let bridge = CoreBridgeService()
        // Listing works before any cancel.
        XCTAssertEqual(try bridge.listArchiveEntries(archivePath: archive).count, 1)

        // Someone cancels an operation.
        bridge.cancelArchiveOperations()

        // Entering the archive must still work afterwards.
        let entries = try bridge.listArchiveEntries(archivePath: archive)
        XCTAssertEqual(entries.count, 1, "listing must survive an earlier cancel")

        // ...and so must a fresh add.
        let extra = path("added.txt")
        try "more".write(toFile: extra, atomically: true, encoding: .utf8)
        try bridge.addFilesToArchive(archivePath: archive, filePaths: [extra],
                                     basePath: "", progress: nil)
        XCTAssertEqual(try bridge.listArchiveEntries(archivePath: archive).count, 2,
                       "a new add must not inherit the previous cancel")
    }



    /// THE reported scenario: cancel while a file is being added — it must not end up in the
    /// archive. Cancellation inside a single file is only detected from the progress callback,
    /// so this passes a real one, exactly like the app does.
    func test_cancelDuringAdd_fileDoesNotAppear() throws {
        // OPEN BUG, reproduced by this test. The cancel is now reported correctly (the add
        // throws) and the staged copy is discarded, yet the file still lands in the archive —
        // so it arrives through a path not yet identified. Skipped so "green" stays honest;
        // remove the skip to reproduce in seconds.

        let seed = path("keep2.txt")
        try "keep".write(toFile: seed, atomically: true, encoding: .utf8)
        let archive = path("live-cancel.zip")
        try zip(files: [seed], to: archive)

        // Big and incompressible, so the add lasts long enough to cancel mid-file.
        let big = path("big.bin")
        // Build it fast: the byte-by-byte loop took ~15s and was itself most of the test.
        var block = Data(count: 1 << 20)
        block.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        }
        // Big enough to matter: cancellation is only sampled every 120ms, so a payload that
        // writes faster than that can never show an abort. This is the user's 800MB case in
        // miniature.
        var bytes = Data(); bytes.reserveCapacity(500 << 20)
        for _ in 0..<500 { bytes.append(block) }
        try bytes.write(to: URL(fileURLWithPath: big))

        let bridge = CoreBridgeService()

        // Baseline: how long does the SAME add take when left alone? The cancel must come back
        // in a fraction of that — otherwise it merely waited for the write to end, which is
        // exactly the 15-20s stall an 800MB file used to produce.
        let baselineArchive = path("baseline.zip")
        try zip(files: [seed], to: baselineArchive)
        let baseStart = Date()
        try bridge.addFilesToArchive(archivePath: baselineArchive, filePaths: [big],
                                     basePath: "", progress: nil)
        let fullWrite = Date().timeIntervalSince(baseStart)

        let finished = expectation(description: "add returned")
        var addError: Error?
        var sawProgress = false

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try bridge.addFilesToArchive(archivePath: archive, filePaths: [big], basePath: "") { _, _, _, _, _, _ in
                    sawProgress = true
                }
            } catch {
                addError = error
            }
            finished.fulfill()
        }

        // The add is FAST (60MB in a fraction of a second), so the cancel has to land almost
        // immediately or there is nothing left to cancel — which is precisely why a cancel that
        // came "too late" always looked like it was ignored.
        Thread.sleep(forTimeInterval: 0.03)
        let cancelledAt = Date()
        bridge.cancelArchiveOperations()
        wait(for: [finished], timeout: 120)
        let stoppedAfter = Date().timeIntervalSince(cancelledAt)
        // Cancelling must ABORT the write, not wait for it to finish. minizip discards its
        // progress callback's return value upstream, so a cancel used to sit through the whole
        // file — ~20s for an 800MB video — before the staged copy could be thrown away.
        print("### full write=\(String(format: "%.2f", fullWrite))s | cancel took effect in \(String(format: "%.2f", stoppedAfter))s")
        XCTAssertLessThan(stoppedAfter, fullWrite * 0.5,
                          "cancel took \(stoppedAfter)s vs a \(fullWrite)s full write — it waited instead of aborting")

        XCTAssertTrue(sawProgress, "no progress callback fired — cancellation could never be seen")
        XCTAssertNotNil(addError, "a cancelled add must report an error, not report success")
        let names = try bridge.listArchiveEntries(archivePath: archive).map(\.path)
        XCTAssertFalse(names.contains { $0.hasSuffix("big.bin") },
                       "CANCELLED FILE ENDED UP IN THE ARCHIVE: \(names)")
        XCTAssertTrue(names.contains { $0.hasSuffix("keep2.txt") }, "original entry must survive")
    }


    /// The FULL app path — FileOperationsService.addItemsToArchive, i.e. progress dialog,
    /// reporter chain and bridge together, not just the bridge. This is the flow the user
    /// reported stuck at 3% for minutes; the bridge alone finishes 60MB in under a second.
    @MainActor
    func test_addItemsToArchive_fullPath_completesQuickly() async throws {
        let seed = path("s.txt")
        try "s".write(toFile: seed, atomically: true, encoding: .utf8)
        let archive = path("fullpath.zip")
        try zip(files: [seed], to: archive)

        let payload = path("payload2.bin")
        var block = Data(count: 1 << 20)
        block.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 17 &+ 3) }
        }
        var bytes = Data(); bytes.reserveCapacity(4 << 20)
        for _ in 0..<4 { bytes.append(block) }
        try bytes.write(to: URL(fileURLWithPath: payload))

        let item = try XCTUnwrap(FileItem.fromPath(payload))
        let ops = FileOperationsService(bridgeService: CoreBridgeService())

        let started = Date()
        try await ops.addItemsToArchive([item], archivePath: archive, destinationRelativePath: "")
        let elapsed = Date().timeIntervalSince(started)
        print("### addItemsToArchive (full path) took \(String(format: "%.2f", elapsed))s")

        XCTAssertLessThan(elapsed, 15, "the full add path took \(elapsed)s for 4MB")
        let names = try CoreBridgeService().listArchiveEntries(archivePath: archive).map(\.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: archive)[.size] as? Int) ?? -1
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: tmp))?.filter { $0.contains(".tmp") } ?? []
        XCTAssertTrue(names.contains { $0.hasSuffix("payload2.bin") })
    }


    /// Isolates the one difference between a bridge add that works and the full app path that
    /// does not: whether a progress callback is installed.
    func test_addWithProgressCallback_actuallyAddsTheFile() throws {
        let seed = path("z.txt")
        try "z".write(toFile: seed, atomically: true, encoding: .utf8)
        let extra = path("payload3.bin")
        try Data(repeating: 7, count: 2 << 20).write(to: URL(fileURLWithPath: extra))
        let bridge = CoreBridgeService()

        // (a) WITHOUT a progress callback
        let a1 = path("nocb.zip"); try zip(files: [seed], to: a1)
        try bridge.addFilesToArchive(archivePath: a1, filePaths: [extra], basePath: "", progress: nil)
        let namesA = try bridge.listArchiveEntries(archivePath: a1).map(\.path)

        // (b) WITH one
        let a2 = path("withcb.zip"); try zip(files: [seed], to: a2)
        var calls = 0
        try bridge.addFilesToArchive(archivePath: a2, filePaths: [extra], basePath: "") { _, _, _, _, _, _ in
            calls += 1
        }
        let namesB = try bridge.listArchiveEntries(archivePath: a2).map(\.path)

        print("### no-callback entries=\(namesA) | with-callback entries=\(namesB) calls=\(calls)")
        XCTAssertTrue(namesA.contains { $0.hasSuffix("payload3.bin") }, "add without a callback lost the file")
        XCTAssertTrue(namesB.contains { $0.hasSuffix("payload3.bin") }, "add WITH a progress callback lost the file")
    }


    /// Does READING the archive first break the add that follows?
    func test_listBeforeAdd_breaksTheAdd() throws {
        let seed = path("q.txt")
        try "q".write(toFile: seed, atomically: true, encoding: .utf8)
        let extra = path("payload4.bin")
        try Data(repeating: 9, count: 2 << 20).write(to: URL(fileURLWithPath: extra))
        let bridge = CoreBridgeService()

        let arch = path("listfirst.zip"); try zip(files: [seed], to: arch)
        _ = try bridge.listArchiveEntries(archivePath: arch)      // ← the only difference
        try bridge.addFilesToArchive(archivePath: arch, filePaths: [extra], basePath: "", progress: nil)
        let names = try bridge.listArchiveEntries(archivePath: arch).map(\.path)
        print("### after list-then-add: \(names)")
        XCTAssertTrue(names.contains { $0.hasSuffix("payload4.bin") },
                      "listing the archive before adding made the add invisible")
    }


    /// The progress dialog's pause must actually FREEZE the worker. It used to be hardcoded
    /// to "never paused", so the confirmation dialog could not hold the operation: the add ran
    /// on while the question was on screen and usually finished before it was answered.
    @MainActor
    func test_progressControllerPause_freezesTheWorker() {
        let controller = DialogService.shared.showProgress(title: "t", message: "m", cancelHandler: nil)
        defer { controller.close() }

        let reporter: OperationProgressReporter = controller
        XCTAssertFalse(reporter.isPaused)
        XCTAssertFalse(reporter.waitWhilePaused(), "must not block when running")

        controller.setPaused(true)
        XCTAssertTrue(reporter.isPaused)

        // A worker entering waitWhilePaused must stay there until resumed.
        let released = expectation(description: "worker resumed")
        let releasedFlag = NSLock()
        var didRelease = false
        DispatchQueue.global().async {
            _ = reporter.waitWhilePaused()
            releasedFlag.lock(); didRelease = true; releasedFlag.unlock()
            released.fulfill()
        }

        Thread.sleep(forTimeInterval: 0.4)
        releasedFlag.lock()
        let escapedWhilePaused = didRelease
        releasedFlag.unlock()
        XCTAssertFalse(escapedWhilePaused, "the worker did NOT stop while paused")

        controller.setPaused(false)              // resume
        wait(for: [released], timeout: 3)        // must come back promptly
        XCTAssertFalse(reporter.isPaused)
    }


    /// A hard link is a SECOND NAME for the same data — not a copy. Both names are equal and
    /// the data survives until the last one goes.
    func test_hardlink_isASecondNameForTheSameData() throws {
        let original = path("data.bin")
        try "payload".write(toFile: original, atomically: true, encoding: .utf8)
        let link = path("second-name.bin")

        try ops.createHardlink(at: link, pointingTo: original)

        // Same inode → genuinely the same data, not a copy.
        var a = stat(), b = stat()
        XCTAssertEqual(lstat(original, &a), 0)
        XCTAssertEqual(lstat(link, &b), 0)
        XCTAssertEqual(a.st_ino, b.st_ino, "a hard link must point at the same inode")
        XCTAssertEqual(a.st_nlink, 2, "both names must be counted")

        // Removing the original leaves the data reachable through the other name.
        try FileManager.default.removeItem(atPath: original)
        XCTAssertEqual(try String(contentsOfFile: link, encoding: .utf8), "payload",
                       "data must survive as long as one name remains")
    }

    /// macOS forbids hard links to directories — the menu hides the command for folders, and
    /// the core must refuse it regardless.
    func test_hardlink_toDirectoryFails() throws {
        let dir = path("some-folder")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ops.createHardlink(at: path("folder-link"), pointingTo: dir))
    }

    // MARK: - Editing attributes (properties window)

    func test_properties_readsPermissionModeAndHiddenFlag() throws {
        let p = makeFile("perm.txt")
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o640)], ofItemAtPath: p)
        let props = try ops.properties(path: p)
        XCTAssertEqual(props.posixMode, 0o640)
        XCTAssertFalse(props.isHidden, "a normal file is not hidden")
    }

    func test_setPermissions_changesTheMode() throws {
        let p = makeFile("chmod.txt")
        try ops.setPermissions(mode: 0o600, atPath: p, recursive: false)
        XCTAssertEqual(try ops.properties(path: p).posixMode, 0o600)
    }

    /// Hiding moved to the ONE road every attribute edit takes — changeAttributes; the
    /// promises stay the same: set, clear, and never rename.
    func test_hiddenViaChangeAttributes_setsAndClearsTheFlag() throws {
        let p = makeFile("secret.txt")
        let item = FileItem(path: p, name: "secret.txt", fileExtension: "txt", size: 1,
                            isDirectory: false, isHidden: false, isSymlink: false,
                            permissions: "644", dateModified: Date())
        XCTAssertTrue(ops.changeAttributes(.init(hidden: true), items: [item]).isEmpty)
        XCTAssertTrue(try ops.properties(path: p).isHidden, "the hidden flag must be set")
        XCTAssertTrue(ops.changeAttributes(.init(hidden: false), items: [item]).isEmpty)
        XCTAssertFalse(try ops.properties(path: p).isHidden, "and cleared again — it's reversible")
        XCTAssertTrue(exists(p), "the file keeps its original name and path")
    }

    func test_setPermissions_recursiveAppliesToEnclosedItems() throws {
        let dir = path("tree")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let inner = (dir as NSString).appendingPathComponent("inner.txt")
        FileManager.default.createFile(atPath: inner, contents: Data("x".utf8))
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o777)], ofItemAtPath: inner)

        let failures = try ops.setPermissions(mode: 0o700, atPath: dir, recursive: true)
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(try ops.properties(path: inner).posixMode, 0o700,
                       "the enclosed file must pick up the recursive change")
    }

    /// Non-recursive on a folder changes only the folder itself, not its contents.
    func test_setPermissions_nonRecursiveLeavesContentsAlone() throws {
        let dir = path("tree2")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let inner = (dir as NSString).appendingPathComponent("inner.txt")
        FileManager.default.createFile(atPath: inner, contents: Data("x".utf8))
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: inner)

        try ops.setPermissions(mode: 0o700, atPath: dir, recursive: false)
        XCTAssertEqual(try ops.properties(path: inner).posixMode, 0o644,
                       "the enclosed file must be untouched without recursion")
    }

}

// MARK: - Extracting out of an archive

extension FileOperationsServiceTests {
    private func zipTree(_ names: [String], in directory: String, to archivePath: String) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.currentDirectoryURL = URL(fileURLWithPath: directory)
        task.arguments = ["-r", "-q", archivePath] + names
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "zip -r failed")
    }

    private func makeTree() throws -> String {
        let src = path("src")
        try FileManager.default.createDirectory(atPath: src + "/docs/sub", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: src + "/sub/inner", withIntermediateDirectories: true)
        try "A".write(toFile: src + "/docs/a.txt", atomically: true, encoding: .utf8)
        try "B".write(toFile: src + "/docs/sub/b.txt", atomically: true, encoding: .utf8)
        try "C".write(toFile: src + "/sub/inner/c.txt", atomically: true, encoding: .utf8)
        try "O".write(toFile: src + "/other.txt", atomically: true, encoding: .utf8)
        let archive = path("tree.zip")
        try zipTree(["docs", "sub", "other.txt"], in: src, to: archive)
        try FileManager.default.createDirectory(atPath: path("out"), withIntermediateDirectories: true)
        return archive
    }

    /// Папка выходит из архива с содержимым: панель просит «docs», а не каждую запись.
    /// Архив собран `zip -r`, с записями-каталогами — как делают Finder и большинство утилит.
    @MainActor
    func test_extractEntries_folderComesOutWithItsFiles() throws {
        let archive = try makeTree()
        let out = path("out")

        try ops.extractEntries(["docs"], fromArchive: archive, to: out)

        XCTAssertEqual(read(out + "/docs/a.txt"), "A")
        XCTAssertEqual(read(out + "/docs/sub/b.txt"), "B")
        XCTAssertFalse(exists(out + "/other.txt"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: out).filter { $0.hasPrefix(".fcxl_") }
        XCTAssertTrue(leftovers.isEmpty, "staging folder left behind: \(leftovers)")
    }

    /// Запись из глубины архива ложится по имени, а не по полному пути — как при F5.
    @MainActor
    func test_extractEntries_nestedEntryLandsByName() throws {
        let archive = try makeTree()
        let out = path("out")

        try ops.extractEntries(["sub/inner"], fromArchive: archive, to: out)

        XCTAssertEqual(read(out + "/inner/c.txt"), "C")
        XCTAssertFalse(exists(out + "/sub"))
    }

    /// «Заменить» — это заменить: старая папка с тем же именем уходит целиком.
    @MainActor
    func test_extractEntries_replacesFolderAlreadyThere() throws {
        let archive = try makeTree()
        let out = path("out")
        try FileManager.default.createDirectory(atPath: out + "/docs", withIntermediateDirectories: true)
        try "old".write(toFile: out + "/docs/old.txt", atomically: true, encoding: .utf8)

        try ops.extractEntries(["docs"], fromArchive: archive, to: out)

        XCTAssertEqual(read(out + "/docs/a.txt"), "A")
        XCTAssertFalse(exists(out + "/docs/old.txt"))
    }

    func test_plannedArchiveBytes_weighsFolderByItsFiles() {
        let files: [(path: String, size: Int64)] = [
            ("docs/a.txt", 10), ("docs/sub/b.txt", 5), ("./docs/d.txt", 1),
            ("docs2/c.txt", 100), ("docs.txt", 7)
        ]
        let planned = FileOperationsService.plannedArchiveBytes(
            for: ["docs", "docs/", "docs.txt", "missing"], files: files)
        XCTAssertEqual(planned["docs"], 16)
        XCTAssertEqual(planned["docs/"], 16)
        XCTAssertEqual(planned["docs.txt"], 7)
        XCTAssertEqual(planned["missing"], 0)
    }
}
