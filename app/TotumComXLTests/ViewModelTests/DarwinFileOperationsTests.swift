import XCTest

@testable import TotumComXLApp

/// Tests for `DarwinFileOperations` — the low-level POSIX/APFS file primitives behind copy (F5),
/// move (F6) and delete (F8): rawStat, the SMB Unicode-normalization path resolver, clone/copyfile
/// copy, same-volume rename move, recursive remove, same-volume detection, clone support and the
/// atomic swap. Every test runs against real files in a per-test temporary directory (no mocks, no
/// UI); `trash` is intentionally not exercised because it would litter the user's Trash.
final class DarwinFileOperationsTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl_darwin_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    @discardableResult
    private func makeFile(_ name: String, _ contents: String = "x") throws -> String {
        let path = dir.appendingPathComponent(name).path
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func makeDir(_ name: String) throws -> String {
        let path = dir.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func missing(_ name: String) -> String { dir.appendingPathComponent(name).path }

    // MARK: - rawStat

    func test_rawStat_file() throws {
        let r = DarwinFileOperations.rawStat(try makeFile("a.txt"))
        XCTAssertTrue(r.exists)
        XCTAssertFalse(r.isDir)
    }

    func test_rawStat_directory() throws {
        let r = DarwinFileOperations.rawStat(try makeDir("sub"))
        XCTAssertTrue(r.exists)
        XCTAssertTrue(r.isDir)
    }

    func test_rawStat_missing() {
        let r = DarwinFileOperations.rawStat(missing("ghost"))
        XCTAssertFalse(r.exists)
        XCTAssertFalse(r.isDir)
    }

    // MARK: - existingPathForm (SMB NFC/NFD resolution)

    func test_existingPathForm_exactMatch() throws {
        let p = try makeFile("plain.txt")
        let r = DarwinFileOperations.existingPathForm(p)
        XCTAssertTrue(r.exists)
        XCTAssertEqual(r.path, p)
        XCTAssertFalse(r.isDir)
    }

    func test_existingPathForm_directory() throws {
        let r = DarwinFileOperations.existingPathForm(try makeDir("somedir"))
        XCTAssertTrue(r.exists)
        XCTAssertTrue(r.isDir)
    }

    func test_existingPathForm_missing() {
        let p = missing("ghost")
        let r = DarwinFileOperations.existingPathForm(p)
        XCTAssertFalse(r.exists)
        XCTAssertEqual(r.path, p)
    }

    func test_existingPathForm_resolvesCyrillicNormalization() throws {
        // Store the file under the precomposed (NFC) "й"; query with the decomposed (NFD) form.
        // The resolver must still find it (the crux of the Windows/SMB Cyrillic-name fix).
        let nfc = "тест_й.txt".precomposedStringWithCanonicalMapping
        try makeFile(nfc, "smb")
        let nfdPath = dir.appendingPathComponent(
            "тест_й.txt".decomposedStringWithCanonicalMapping).path
        let r = DarwinFileOperations.existingPathForm(nfdPath)
        XCTAssertTrue(r.exists, "file must resolve across NFC/NFD normalization")
        XCTAssertFalse(r.isDir)
    }

    // MARK: - move

    func test_move_sameVolume_returnsTrueAndRelocates() throws {
        let src = try makeFile("m1.txt", "data")
        let dst = missing("m2.txt")
        let wasInstantRename = try DarwinFileOperations.move(from: src, to: dst)
        XCTAssertTrue(wasInstantRename, "same-volume move should be an O(1) rename")
        XCTAssertFalse(DarwinFileOperations.rawStat(src).exists)
        XCTAssertTrue(DarwinFileOperations.rawStat(dst).exists)
    }

    func test_move_directoryTree() throws {
        let src = try makeDir("src_dir")
        try Data("hi".utf8).write(to: URL(fileURLWithPath: src + "/inner.txt"))
        let dst = missing("dst_dir")
        try DarwinFileOperations.move(from: src, to: dst)
        XCTAssertFalse(DarwinFileOperations.rawStat(src).exists)
        XCTAssertTrue(DarwinFileOperations.rawStat(dst + "/inner.txt").exists)
    }

    // MARK: - copy

    func test_copy_fileContentsPreserved() throws {
        let src = try makeFile("c1.txt", "hello copy")
        let dst = missing("c2.txt")
        try DarwinFileOperations.copy(from: src, to: dst, progress: nil, shouldCancel: nil)
        XCTAssertTrue(DarwinFileOperations.rawStat(src).exists, "source must remain")
        XCTAssertEqual(try String(contentsOfFile: dst, encoding: .utf8), "hello copy")
    }

    func test_copy_directoryTree() throws {
        let src = try makeDir("cdir")
        try Data("x".utf8).write(to: URL(fileURLWithPath: src + "/f.txt"))
        let dst = missing("cdir_copy")
        try DarwinFileOperations.copy(from: src, to: dst, progress: nil, shouldCancel: nil)
        XCTAssertTrue(DarwinFileOperations.rawStat(dst + "/f.txt").exists)
    }

    // MARK: - remove

    func test_remove_file() throws {
        let p = try makeFile("r.txt")
        try DarwinFileOperations.remove(path: p)
        XCTAssertFalse(DarwinFileOperations.rawStat(p).exists)
    }

    func test_remove_directoryTree() throws {
        let d = try makeDir("rmdir")
        try Data("x".utf8).write(to: URL(fileURLWithPath: d + "/f.txt"))
        try DarwinFileOperations.remove(path: d)
        XCTAssertFalse(DarwinFileOperations.rawStat(d).exists)
    }

    func test_remove_missingThrows() {
        XCTAssertThrowsError(try DarwinFileOperations.remove(path: missing("nope")))
    }

    // MARK: - sameVolume

    func test_sameVolume_trueWithinTempDir() throws {
        let src = try makeFile("sv.txt")
        XCTAssertTrue(DarwinFileOperations.sameVolume(source: src, destination: missing("sv2.txt")))
    }

    func test_sameVolume_falseAcrossVolumes() throws {
        let src = try makeFile("sv3.txt")
        // /dev is a separate devfs volume from the Data volume that backs NSTemporaryDirectory.
        XCTAssertFalse(DarwinFileOperations.sameVolume(source: src, destination: "/dev/null"))
    }

    // MARK: - supportsClone

    func test_supportsClone_apfsTempIsTrue() {
        // NSTemporaryDirectory lives on the APFS Data volume on modern macOS → clonefile supported.
        XCTAssertTrue(DarwinFileOperations.supportsClone(at: dir.path))
    }

    // MARK: - atomicSwap

    func test_atomicSwap_exchangesContents() throws {
        let a = try makeFile("swapA.txt", "AAA")
        let b = try makeFile("swapB.txt", "BBB")
        try DarwinFileOperations.atomicSwap(a, b)
        XCTAssertEqual(try String(contentsOfFile: a, encoding: .utf8), "BBB")
        XCTAssertEqual(try String(contentsOfFile: b, encoding: .utf8), "AAA")
    }
}
