import Foundation
import XCTest

@testable import TotumComXLApp

/// The batch attribute engine: permissions and dates over a selection, folders walked when
/// asked, symlinks left alone, refusals reported instead of hidden.
final class ChangeAttributesTests: XCTestCase {

    private var dir: URL!
    private var ops: FileOperationsService!

    override func setUp() async throws {
        try await super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-attrs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ops = await MainActor.run { FileOperationsService(bridgeService: CoreBridgeService()) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    private func makeFile(_ name: String, in folder: URL? = nil) throws -> String {
        let url = (folder ?? dir).appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url.path
    }

    private func item(at path: String) -> FileItem {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        let name = (path as NSString).lastPathComponent
        return FileItem(path: path, name: name,
                        fileExtension: (name as NSString).pathExtension,
                        size: 0, isDirectory: isDir, isHidden: false, isSymlink: false,
                        permissions: String(format: "%o", (attrs[.posixPermissions] as? Int) ?? 0),
                        dateModified: Date())
    }

    private func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions]
            as? NSNumber)?.intValue ?? -1
    }

    private func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: - The essentials

    func test_permissionsAndDate_landOnEveryItem() throws {
        let a = try makeFile("a.txt")
        let b = try makeFile("b.txt")
        let date = Date(timeIntervalSince1970: 1_000_000_000)   // 2001, unmistakable

        let failures = ops.changeAttributes(
            .init(permissionsMode: 0o600, modificationDate: date),
            items: [item(at: a), item(at: b)])

        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(mode(a), 0o600)
        XCTAssertEqual(mode(b), 0o600)
        XCTAssertEqual(modified(a)?.timeIntervalSince1970 ?? 0, 1_000_000_000, accuracy: 2)
    }

    /// A nil field means "leave that alone" — dates survive a permissions-only pass.
    func test_nilFields_areLeftAlone() throws {
        let a = try makeFile("a.txt")
        let before = modified(a)

        _ = ops.changeAttributes(.init(permissionsMode: 0o640), items: [item(at: a)])

        XCTAssertEqual(mode(a), 0o640)
        XCTAssertEqual(modified(a)?.timeIntervalSince1970 ?? 0,
                       before?.timeIntervalSince1970 ?? -1, accuracy: 2)
    }

    func test_recursive_walksIntoTheFolder_andOffStaysOut() throws {
        let sub = dir.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let child = try makeFile("child.txt", in: sub)

        _ = ops.changeAttributes(.init(permissionsMode: 0o600, recursive: false),
                                 items: [item(at: sub.path)])
        XCTAssertNotEqual(mode(child), 0o600, "recursive=false must not touch children")

        _ = ops.changeAttributes(.init(permissionsMode: 0o755, recursive: true),
                                 items: [item(at: sub.path)])
        XCTAssertEqual(mode(sub.path), 0o755)
        XCTAssertEqual(mode(child), 0o755)
    }

    /// chmod and dates go THROUGH a symlink to its target; the person pointed at the link.
    func test_symlinks_areLeftEntirelyAlone() throws {
        let target = try makeFile("target.txt")
        let link = dir.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let targetModeBefore = mode(target)

        let failures = ops.changeAttributes(.init(permissionsMode: 0o600),
                                            items: [item(at: link)])

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(mode(target), targetModeBefore, "the link's target must stay untouched")
    }

    func test_missingFile_isReportedNotSwallowed() throws {
        let ghost = dir.appendingPathComponent("нет-такого.txt").path
        let real = try makeFile("real.txt")

        let failures = ops.changeAttributes(.init(permissionsMode: 0o600),
                                            items: [item(at: ghost), item(at: real)])

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.name, "нет-такого.txt")
        XCTAssertEqual(mode(real), 0o600, "the rest of the batch still goes through")
    }

    func test_hiddenFlag_setAndCleared() throws {
        let a = try makeFile("a.txt")

        _ = ops.changeAttributes(.init(hidden: true), items: [item(at: a)])
        var hidden = try URL(fileURLWithPath: a).resourceValues(forKeys: [.isHiddenKey]).isHidden
        XCTAssertEqual(hidden, true)

        _ = ops.changeAttributes(.init(hidden: false), items: [item(at: a)])
        hidden = try URL(fileURLWithPath: a).resourceValues(forKeys: [.isHiddenKey]).isHidden
        XCTAssertEqual(hidden, false)
    }

    func test_quarantine_isStripped_andItsAbsenceIsNotAFailure() throws {
        let marked = try makeFile("скачанный.bin")
        let clean = try makeFile("чистый.bin")
        // The same mark Safari writes, planted by hand.
        let payload = "0083;00000000;Test;"
        XCTAssertEqual(setxattr(marked, "com.apple.quarantine",
                                payload, payload.utf8.count, 0, 0), 0)

        let failures = ops.changeAttributes(.init(quarantine: false),
                                            items: [item(at: marked), item(at: clean)])

        XCTAssertTrue(failures.isEmpty, "a file that never had the mark is not a failure")
        XCTAssertEqual(getxattr(marked, "com.apple.quarantine", nil, 0, 0, 0), -1,
                       "the mark must be gone")
    }

    /// The switch is a STATE and works both ways: on puts the mark back, and a file that
    /// already carries one keeps ITS mark — the original "who downloaded this" note.
    func test_quarantine_canBePutBack_withoutOverwritingAnExistingMark() throws {
        let plain = try makeFile("обычный.bin")
        let marked = try makeFile("свой.bin")
        let original = "0083;11111111;Safari;"
        XCTAssertEqual(setxattr(marked, "com.apple.quarantine",
                                original, original.utf8.count, 0, 0), 0)

        let failures = ops.changeAttributes(.init(quarantine: true),
                                            items: [item(at: plain), item(at: marked)])
        XCTAssertTrue(failures.isEmpty)

        XCTAssertGreaterThan(getxattr(plain, "com.apple.quarantine", nil, 0, 0, 0), 0,
                             "the mark must appear on the plain file")
        var buf = [CChar](repeating: 0, count: 256)
        let n = getxattr(marked, "com.apple.quarantine", &buf, 255, 0, 0)
        let kept = String(bytes: buf.prefix(max(n, 0)).map { UInt8(bitPattern: $0) },
                          encoding: .utf8)
        XCTAssertEqual(kept, original, "an existing mark is not overwritten")
    }

    /// isEmpty must know about EVERY field — a forgotten one silently drops that change
    /// at the "nothing to do" gate.
    func test_isEmpty_knowsEveryField() {
        XCTAssertTrue(FileOperationsService.AttributeChanges().isEmpty)
        XCTAssertFalse(FileOperationsService.AttributeChanges(permissionsMode: 0o644).isEmpty)
        XCTAssertFalse(FileOperationsService.AttributeChanges(hidden: true).isEmpty)
        XCTAssertFalse(FileOperationsService.AttributeChanges(quarantine: false).isEmpty)
        XCTAssertFalse(FileOperationsService.AttributeChanges(quarantine: true).isEmpty)
    }

    func test_emptyChanges_touchNothing() throws {
        let a = try makeFile("a.txt")
        let before = mode(a)
        let failures = ops.changeAttributes(.init(), items: [item(at: a)])
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(mode(a), before)
        XCTAssertTrue(FileOperationsService.AttributeChanges().isEmpty)
    }
}
