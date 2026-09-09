import Foundation
import XCTest

@testable import TotumComXLApp

/// Copying a folder that holds the same file under two names.
///
/// Measured before this was handled: a 20 MB file with two names came out as 40 MB and two
/// independent files — the space doubled silently, and editing one name no longer showed
/// through the other. clonefile and copyfile both do that; only ditto keeps them one file.
final class HardlinkCopyTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-hardlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        try super.tearDownWithError()
    }

    private func inode(_ path: String) -> UInt64 {
        var s = stat()
        return stat(path, &s) == 0 ? s.st_ino : 0
    }

    private func linkCount(_ path: String) -> Int {
        var s = stat()
        return stat(path, &s) == 0 ? Int(s.st_nlink) : 0
    }

    /// On ONE volume the fast path stays: clonefile is instant and its clones share their
    /// blocks, so the split link costs no space — only the "one file, two names" meaning.
    /// Measured on Xcode.app: 3.1 s and 45 MB against ditto's 41.5 s and 4839 MB.
    func testOnTheSameVolumeTheFastPathIsKept() throws {
        let source = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let first = source.appendingPathComponent("a.bin").path
        let second = source.appendingPathComponent("b.bin").path
        try Data(repeating: 7, count: 64 * 1024).write(to: URL(fileURLWithPath: first))
        try FileManager.default.linkItem(atPath: first, toPath: second)

        let destination = tmp.appendingPathComponent("dst").path
        try DarwinFileOperations.copy(from: source.path, to: destination,
                                      progress: nil, shouldCancel: nil)

        // Both names are there and readable — that is what the copy owes the user here.
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination + "/a.bin")).count,
                       64 * 1024)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination + "/b.bin")).count,
                       64 * 1024)
    }

    /// The detection is what routes a tree to the slower, correct path — it must not fire on
    /// ordinary folders, or every copy would lose its progress bar.
    func testAnOrdinaryFolderIsNotTakenForALinkedOne() throws {
        let plain = tmp.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: plain.appendingPathComponent("one.txt"))
        try Data("two".utf8).write(to: plain.appendingPathComponent("two.txt"))

        XCTAssertFalse(DarwinFileOperations.treeHasInternalHardlinks(plain.path))
    }

    /// A file whose other name lives OUTSIDE the copied folder (a pnpm store, a Homebrew cellar)
    /// can only be copied as a full file — that is correct, and must keep the fast path.
    func testALinkPointingOutsideTheFolderIsNotOurCase() throws {
        let outside = tmp.appendingPathComponent("outside.bin").path
        try Data(repeating: 3, count: 1024).write(to: URL(fileURLWithPath: outside))
        let folder = tmp.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: outside,
                                         toPath: folder.appendingPathComponent("inside.bin").path)

        XCTAssertEqual(linkCount(outside), 2, "the fixture is a hard link across the boundary")
        XCTAssertFalse(DarwinFileOperations.treeHasInternalHardlinks(folder.path),
                       "only one of the two names is inside — nothing to keep linked")
    }

    /// A single file is never a hard-link group, and must not pay for a tree walk.
    func testASingleFileIsNeverALinkGroup() throws {
        let file = tmp.appendingPathComponent("alone.txt").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        XCTAssertFalse(DarwinFileOperations.treeHasInternalHardlinks(file))
    }

    /// The ordinary copy still works — the new branch must not have swallowed the common case.
    func testAPlainFolderStillCopies() throws {
        let plain = tmp.appendingPathComponent("plain2")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: plain.appendingPathComponent("f.txt"))

        let destination = tmp.appendingPathComponent("plain2-copy").path
        try DarwinFileOperations.copy(from: plain.path, to: destination,
                                      progress: nil, shouldCancel: nil)

        XCTAssertEqual(try String(contentsOfFile: destination + "/f.txt", encoding: .utf8), "hello")
    }
}

/// The hard-link badge in the panel: when it shows, and — the part that was broken — when it
/// stops showing.
@MainActor
final class HardlinkBadgeTests: XCTestCase {

    private func item(name: String, links: UInt) -> FileItem {
        FileItem(path: "/test/\(name)", name: name, fileExtension: "txt", size: 1,
                 isDirectory: false, isHidden: false, isSymlink: false,
                 hardlinkCount: links, permissions: "rw-r--r--", dateModified: Date())
    }

    /// Both names wear the badge — there is no "original" and no "copy" in a hard link, only one
    /// file answering to two names.
    func testEveryNameOfTheFileIsBadged() {
        XCTAssertTrue(item(name: "a.txt", links: 2).isHardlink)
        XCTAssertTrue(item(name: "b.txt", links: 2).isHardlink)
    }

    func testOneNameIsNotAHardLink() {
        XCTAssertFalse(item(name: "alone.txt", links: 1).isHardlink)
    }

    /// A count nobody measured is not a hard link either — a names-only pass, a remote listing.
    func testAnUnmeasuredCountIsNotABadge() {
        XCTAssertFalse(item(name: "unknown.txt", links: 0).isHardlink)
    }

    /// The bug this pins down: the merge with the previous listing took the LARGER count, so a
    /// file that lost its second name kept the badge for ever.
    func testLosingTheSecondNameTakesTheBadgeAway() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-badge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let first = tmp.appendingPathComponent("a.txt").path
        let second = tmp.appendingPathComponent("b.txt").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: first))
        try FileManager.default.linkItem(atPath: first, toPath: second)
        XCTAssertTrue(try XCTUnwrap(FileItem.fromPath(first)).isHardlink, "two names — badged")

        try FileManager.default.removeItem(atPath: second)

        XCTAssertFalse(try XCTUnwrap(FileItem.fromPath(first)).isHardlink,
                       "one name left — the badge must go")
    }
}
