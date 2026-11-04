import AppKit
import XCTest

@testable import TotumComXLApp

/// The journal behind Cmd+Z: what it remembers and in which order it hands it back.
@MainActor
final class UndoJournalTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UndoJournal.shared.reset()
    }

    override func tearDown() {
        UndoJournal.shared.reset()
        super.tearDown()
    }

    func testTheNewestOperationIsTheFirstUndone() async throws {
        UndoJournal.shared.record(.renamed(from: "/a/один", to: "/a/два"))
        UndoJournal.shared.record(.created(path: "/a/папка", isDirectory: true))

        var replayed: [UndoJournal.Record] = []
        try await UndoJournal.shared.undo { replayed.append($0) }
        try await UndoJournal.shared.undo { replayed.append($0) }

        guard case .created = replayed.first, case .renamed = replayed.last else {
            return XCTFail("expected created, then renamed — got \(replayed)")
        }
        XCTAssertFalse(UndoJournal.shared.canUndo)
        XCTAssertTrue(UndoJournal.shared.canRedo)
    }

    /// A failed replay keeps the record: the obstacle gets cleared, Cmd+Z gets pressed again.
    func testAFailedUndoKeepsTheRecord() async {
        UndoJournal.shared.record(.created(path: "/a/папка", isDirectory: true))

        struct Obstacle: Error {}
        try? await UndoJournal.shared.undo { _ in throw Obstacle() }

        XCTAssertTrue(UndoJournal.shared.canUndo, "the record must survive a failed replay")
        XCTAssertFalse(UndoJournal.shared.canRedo)
    }

    /// A new operation forks history: what was undone before it cannot be redone after it.
    func testANewOperationClearsTheRedoStack() async throws {
        UndoJournal.shared.record(.created(path: "/a/x", isDirectory: true))
        try await UndoJournal.shared.undo { _ in }
        XCTAssertTrue(UndoJournal.shared.canRedo)

        UndoJournal.shared.record(.renamed(from: "/a/б", to: "/a/в"))

        XCTAssertFalse(UndoJournal.shared.canRedo)
    }

    /// The journal must never record its own footsteps: undoing a copy trashes the copies, and
    /// that trash goes through the same recorded road.
    func testReplayLeavesNoFootprints() async throws {
        UndoJournal.shared.record(.created(path: "/a/x", isDirectory: true))

        try await UndoJournal.shared.undo { _ in
            UndoJournal.shared.record(.trashed(pairs: []))   // what a replayed trash would do
        }

        XCTAssertFalse(UndoJournal.shared.canUndo, "the replay's own operation was recorded")
    }

    func testTheStackIsBounded() {
        for i in 0..<40 {
            UndoJournal.shared.record(.created(path: "/a/\(i)", isDirectory: true))
        }
        XCTAssertEqual(UndoJournal.shared.undoStack.count, 20)
        guard case .created(let path, _) = UndoJournal.shared.undoStack.first else {
            return XCTFail()
        }
        XCTAssertEqual(path, "/a/20", "the oldest records go first")
    }

    func testMenuTitlesNameTheOperation() {
        UndoJournal.shared.record(.moved(pairs: [("/a/1", "/b/1"), ("/a/2", "/b/2")]))
        XCTAssertEqual(UndoJournal.shared.undoDescription, L("undo.op.move", 2))
    }
}

/// The full circle on real files: do, undo, redo — through the same service as always.
@MainActor
final class UndoReplayTests: XCTestCase {

    private var ops: FileOperationsService!
    private var tmp: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        UndoJournal.shared.reset()
        ops = FileOperationsService(bridgeService: CoreBridgeService())
        tmp = (FileManager.default.temporaryDirectory.path as NSString)
            .appendingPathComponent("fcxl-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: (tmp as NSString).appendingPathComponent("a"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (tmp as NSString).appendingPathComponent("b"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UndoJournal.shared.reset()
        if let tmp { try? FileManager.default.removeItem(atPath: tmp) }
        ops = nil
        tmp = nil
        try super.tearDownWithError()
    }

    private func path(_ parts: String...) -> String {
        parts.reduce(tmp) { ($0 as NSString).appendingPathComponent($1) }
    }

    private func write(_ relative: String..., text: String = "содержимое") throws -> String {
        let p = relative.reduce(tmp!) { ($0 as NSString).appendingPathComponent($1) }
        try text.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    private func exists(_ p: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: p)) != nil
    }

    private func undoLast() async throws {
        try await UndoJournal.shared.undo { try await self.ops.performUndo(of: $0) }
    }

    private func redoLast() async throws {
        var replacement: UndoJournal.Record?
        try await UndoJournal.shared.redo { replacement = try await self.ops.performRedo(of: $0) }
        if let replacement { UndoJournal.shared.replaceNewestUndo(with: replacement) }
    }

    // MARK: - Rename

    func testARenameWalksBackAndForwardAgain() async throws {
        let old = try write("a", "старое-имя.txt")
        try ops.renameItem(item(at: old), to: "новое-имя.txt")
        XCTAssertTrue(UndoJournal.shared.canUndo, "the rename was not recorded")

        try await undoLast()
        XCTAssertTrue(exists(path("a", "старое-имя.txt")))
        XCTAssertFalse(exists(path("a", "новое-имя.txt")))

        try await redoLast()
        XCTAssertTrue(exists(path("a", "новое-имя.txt")))
        XCTAssertFalse(exists(path("a", "старое-имя.txt")))
    }

    // MARK: - Move

    func testAMoveComesBack() async throws {
        let file = try write("a", "письмо.txt")
        try await ops.moveItems([item(at: file)], to: path("b"),
                                onConflict: { _ in .replace })
        XCTAssertTrue(exists(path("b", "письмо.txt")))
        XCTAssertTrue(UndoJournal.shared.canUndo, "the move was not recorded")

        try await undoLast()
        XCTAssertTrue(exists(path("a", "письмо.txt")), "the file must be back where it was")
        XCTAssertFalse(exists(path("b", "письмо.txt")))

        try await redoLast()
        XCTAssertTrue(exists(path("b", "письмо.txt")))
    }

    /// A move that met a conflict is not honestly reversible — and must not be recorded.
    func testAMoveThroughAConflictIsNotRecorded() async throws {
        let file = try write("a", "занятое.txt", text: "новое")
        _ = try write("b", "занятое.txt", text: "старое")

        try await ops.moveItems([item(at: file)], to: path("b"),
                                onConflict: { _ in .replace })

        XCTAssertFalse(UndoJournal.shared.canUndo,
                       "a replace destroyed a file — walking that back would lie")
    }

    /// Undo blocked by an occupied name keeps the record; freeing the name lets it finish.
    func testABlockedUndoRetriesAfterTheObstacleGoes() async throws {
        let file = try write("a", "дом.txt", text: "переезжает")
        try await ops.moveItems([item(at: file)], to: path("b"),
                                onConflict: { _ in .replace })
        // Somebody new took the old spot.
        let squatter = try write("a", "дом.txt", text: "занял место")

        await XCTAssertThrowsErrorAsync(try await self.undoLast())
        XCTAssertTrue(UndoJournal.shared.canUndo, "the record must survive")

        try FileManager.default.removeItem(atPath: squatter)
        try await undoLast()
        XCTAssertEqual(try String(contentsOfFile: path("a", "дом.txt"), encoding: .utf8),
                       "переезжает")
    }

    // MARK: - Copy

    func testUndoOfACopyRemovesOnlyTheCopies() async throws {
        let source = try write("a", "оригинал.txt")
        try await ops.copyItems([item(at: source)], to: path("b"))
        XCTAssertTrue(exists(path("b", "оригинал.txt")))

        try await undoLast()
        XCTAssertTrue(exists(source), "the original must never be touched")
        XCTAssertFalse(exists(path("b", "оригинал.txt")))

        try await redoLast()
        XCTAssertTrue(exists(path("b", "оригинал.txt")))
    }

    // MARK: - New folder

    func testUndoOfANewFolderTakesItAwayWhileEmpty() async throws {
        try ops.createDirectory(at: path("a"), name: "новая")
        XCTAssertTrue(exists(path("a", "новая")))

        try await undoLast()
        XCTAssertFalse(exists(path("a", "новая")))

        try await redoLast()
        XCTAssertTrue(exists(path("a", "новая")))
    }

    /// A folder the user has already filled must not ride into the bin on an undo of CREATING it.
    func testUndoOfANewFolderRefusesOnceItHoldsAnything() async throws {
        try ops.createDirectory(at: path("a"), name: "полная")
        _ = try write("a", "полная", "труд.txt", text: "не потерять")

        await XCTAssertThrowsErrorAsync(try await self.undoLast())
        XCTAssertTrue(exists(path("a", "полная", "труд.txt")))
        XCTAssertTrue(UndoJournal.shared.canUndo)
    }

    // MARK: - Trash

    func testAFileComesBackOutOfTheBin() async throws {
        let file = try write("a", "выброшенное.txt", text: "вернусь")
        try await ops.trashItems([item(at: file)])
        XCTAssertFalse(exists(file))
        XCTAssertTrue(UndoJournal.shared.canUndo, "the trash was not recorded")

        try await undoLast()
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "вернусь")

        // And forward again — into the bin under a fresh URL, which the next undo must know.
        try await redoLast()
        XCTAssertFalse(exists(file))
        try await undoLast()
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "вернусь")
        // Leave nothing behind in the user's bin.
    }

    // MARK: - What the failure says

    /// The refusal must EXPLAIN: name the file, name the place that is in the way, and say why
    /// the undo will not push through it. "имя занято" alone answers none of that.
    func testABlockedUndoNamesTheFileAndThePlace() async throws {
        let file = try write("a", "дом.txt", text: "переезжает")
        try await ops.moveItems([item(at: file)], to: path("b"),
                                onConflict: { _ in .replace })
        _ = try write("a", "дом.txt", text: "занял место")

        do {
            try await undoLast()
            XCTFail("expected the occupied name to block the undo")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("дом.txt"), "the file is not named: \(message)")
            XCTAssertTrue(message.contains((path("a") as NSString).lastPathComponent),
                          "the place in the way is not named: \(message)")
        }
    }

    /// A folder that has gained content refuses with the REASON, not a shrug.
    func testARefusedFolderUndoExplainsWhy() async throws {
        try ops.createDirectory(at: path("a"), name: "полная")
        _ = try write("a", "полная", "труд.txt", text: "не потерять")

        do {
            try await undoLast()
            XCTFail("expected the filled folder to refuse")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(L("undo.reason.folderNotEmpty",
                                                                1).prefix(20)),
                          "the reason does not explain itself: \(error.localizedDescription)")
        }
    }

    private func item(at p: String) -> FileItem {
        let attrs = try? FileManager.default.attributesOfItem(atPath: p)
        let isDir = (attrs?[.type] as? FileAttributeType) == .typeDirectory
        let name = (p as NSString).lastPathComponent
        return FileItem(path: p, name: name, fileExtension: (name as NSString).pathExtension,
                        size: (attrs?[.size] as? UInt64) ?? 0, isDirectory: isDir,
                        isHidden: false, isSymlink: false, permissions: "-rw-r--r--",
                        dateModified: Date())
    }
}

/// XCTAssertThrowsError has no async form of its own.
func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
