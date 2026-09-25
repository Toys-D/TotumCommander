import XCTest

@testable import TotumComXLApp

/// Tests for `FileItem`'s pure computed properties — the type/category/sort classification used by
/// the list columns, colouring and sorting, plus the hardlink/app-bundle flags and `withSize`.
/// Built directly via the memberwise initialiser, so no filesystem access is involved.
final class FileItemComputedTests: XCTestCase {

    private func make(name: String, ext: String = "", isDir: Bool = false,
                      isSymlink: Bool = false, hardlinks: UInt = 1, size: UInt64 = 0) -> FileItem {
        FileItem(path: "/tmp/\(name)", name: name, fileExtension: ext, size: size,
                 isDirectory: isDir, isHidden: name.hasPrefix("."), isSymlink: isSymlink,
                 hardlinkCount: hardlinks, permissions: "rw-r--r--",
                 dateModified: Date(timeIntervalSince1970: 0))
    }

    // MARK: - id

    func test_id_isPath() {
        XCTAssertEqual(make(name: "a.txt").id, "/tmp/a.txt")
    }

    // MARK: - isHardlink

    func test_isHardlink_trueWhenCountAboveOne() {
        XCTAssertTrue(make(name: "a", hardlinks: 2).isHardlink)
    }

    func test_isHardlink_falseForSingleLinkDirOrSymlink() {
        XCTAssertFalse(make(name: "a", hardlinks: 1).isHardlink)
        XCTAssertFalse(make(name: "d", isDir: true, hardlinks: 5).isHardlink)
        XCTAssertFalse(make(name: "s", isSymlink: true, hardlinks: 5).isHardlink)
    }

    // MARK: - isAppBundle

    func test_isAppBundle_trueForDotAppDirectory() {
        XCTAssertTrue(make(name: "Safari.app", ext: "app", isDir: true).isAppBundle)
    }

    func test_isAppBundle_falseForNonDirOrOtherExtension() {
        XCTAssertFalse(make(name: "Safari.app", ext: "app", isDir: false).isAppBundle)
        XCTAssertFalse(make(name: "folder", isDir: true).isAppBundle)
    }

    // MARK: - typeDisplayName

    func test_typeDisplayName_parentFolderFileAndExtension() {
        XCTAssertEqual(make(name: "..").typeDisplayName, L("type.parent"))
        XCTAssertEqual(make(name: "docs", isDir: true).typeDisplayName, L("type.folder"))
        XCTAssertEqual(make(name: "README").typeDisplayName, L("type.file"))
        XCTAssertNotEqual(L("type.folder"), "type.folder", "слово переведено")
        XCTAssertEqual(make(name: "photo.jpg", ext: "jpg").typeDisplayName, "JPG")
    }

    func test_typeDisplayName_trimsAndUppercases() {
        XCTAssertEqual(make(name: "a.txt", ext: "  Txt ").typeDisplayName, "TXT")
    }

    // MARK: - typeSortKey (folders first, then extensionless files, then by extension)

    func test_typeSortKey_ordersFoldersBeforeFiles() {
        let folder = make(name: "d", isDir: true).typeSortKey
        let noext = make(name: "f").typeSortKey
        let txt = make(name: "f.txt", ext: "txt").typeSortKey
        XCTAssertEqual(folder, "0_folder")
        XCTAssertEqual(noext, "1_file")
        XCTAssertEqual(txt, "2_txt")
        XCTAssertTrue(folder < noext && noext < txt)
    }

    // MARK: - colorCategoryKey

    func test_colorCategoryKey_directoryFileAndExtension() {
        XCTAssertEqual(make(name: "d", isDir: true).colorCategoryKey, "directory")
        XCTAssertEqual(make(name: "f").colorCategoryKey, "file")
        XCTAssertEqual(make(name: "a.PNG", ext: "PNG").colorCategoryKey, "png")
    }

    // MARK: - withSize

    func test_withSize_replacesSizeAndKeepsEverythingElse() {
        let original = make(name: "big.bin", ext: "bin", size: 10)
        let resized = original.withSize(4096)
        XCTAssertEqual(resized.size, 4096)
        XCTAssertEqual(resized.name, "big.bin")
        XCTAssertEqual(resized.fileExtension, "bin")
        XCTAssertEqual(resized.path, original.path)
        XCTAssertEqual(original.size, 10, "original must stay unchanged (value semantics)")
    }

    /// Entering a folder lists it in two passes: names-only first (fast), full metadata
    /// second. The fast pass must already know a symlink is a symlink — readdir hands the
    /// type over for free — or the 🔗 marker only appears once the slow pass lands.
    func test_namesOnlyListing_knowsSymlinks() throws {
        let dir = NSTemporaryDirectory() + "/fcxl-sym-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let target = (dir as NSString).appendingPathComponent("target.txt")
        try "x".write(toFile: target, atomically: true, encoding: .utf8)
        let link = (dir as NSString).appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let bridge = CoreBridgeService()

        let full = try bridge.listDirectory(path: dir, showHidden: true)
        let fullLink = try XCTUnwrap(full.first { $0.name == "link.txt" })
        XCTAssertTrue(fullLink.isSymlink, "full listing must flag the symlink")

        let fast = try bridge.listDirectoryNamesOnly(path: dir, showHidden: true)
        let fastLink = try XCTUnwrap(fast.first { $0.name == "link.txt" })
        XCTAssertTrue(fastLink.isSymlink, "names-only listing lost the symlink flag")
    }

}
