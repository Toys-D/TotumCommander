import Foundation
import XCTest

@testable import TotumComXLApp

/// The Finder alias — the third kind of link.
///
/// Its whole point is the one thing a symbolic link cannot do: keep pointing at the file after
/// it is renamed or moved. That is what these tests pin down.
@MainActor
final class AliasCreationTests: XCTestCase {

    private var tmp: URL!
    private var ops: FileOperationsService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        ops = FileOperationsService(bridgeService: CoreBridgeService())
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        try super.tearDownWithError()
    }

    /// Where the alias leads right now.
    private func resolve(_ aliasPath: String) throws -> String {
        let data = try URL.bookmarkData(withContentsOf: URL(fileURLWithPath: aliasPath))
        var stale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [.withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return url.resolvingSymlinksInPath().path
    }

    /// The same form the resolver returns: /var is itself a symlink to /private/var, so the
    /// fixture's own path has to be canonicalised before the two can be compared.
    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func testAnAliasLeadsToItsTarget() throws {
        let target = tmp.appendingPathComponent("target.txt").path
        try Data("payload".utf8).write(to: URL(fileURLWithPath: target))
        let alias = tmp.appendingPathComponent("alias").path

        try ops.createAlias(at: alias, pointingTo: target)

        XCTAssertTrue(FileManager.default.fileExists(atPath: alias))
        XCTAssertEqual(try resolve(alias), canonical(target))
    }

    /// The reason to offer an alias at all: rename the target and it still resolves — where a
    /// symbolic link would now point at nothing.
    func testAnAliasSurvivesTheTargetBeingRenamed() throws {
        let target = tmp.appendingPathComponent("before.txt").path
        try Data("payload".utf8).write(to: URL(fileURLWithPath: target))
        let alias = tmp.appendingPathComponent("alias").path
        let symlink = tmp.appendingPathComponent("symlink").path
        try ops.createAlias(at: alias, pointingTo: target)
        try ops.createSymlink(at: symlink, pointingTo: target)

        let renamed = tmp.appendingPathComponent("after.txt").path
        try FileManager.default.moveItem(atPath: target, toPath: renamed)

        XCTAssertEqual(try resolve(alias), canonical(renamed), "the alias followed the rename")
        XCTAssertFalse(FileManager.default.fileExists(atPath: symlink),
                       "…while the symlink now points at nothing (fileExists follows it)")
    }

    /// And a move into another folder, which is the same story one level up.
    func testAnAliasSurvivesTheTargetBeingMoved() throws {
        let target = tmp.appendingPathComponent("doc.txt").path
        try Data("payload".utf8).write(to: URL(fileURLWithPath: target))
        let alias = tmp.appendingPathComponent("alias").path
        try ops.createAlias(at: alias, pointingTo: target)

        let sub = tmp.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let moved = sub.appendingPathComponent("doc.txt").path
        try FileManager.default.moveItem(atPath: target, toPath: moved)

        XCTAssertEqual(try resolve(alias), canonical(moved))
    }

    func testAFolderCanHaveAnAliasToo() throws {
        let folder = tmp.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let alias = tmp.appendingPathComponent("folder-alias").path

        try ops.createAlias(at: alias, pointingTo: folder.path)

        XCTAssertEqual(try resolve(alias), canonical(folder.path))
    }

    /// An alias must never quietly overwrite something — the same rule the other two links keep.
    func testAnExistingNameIsRefused() throws {
        let target = tmp.appendingPathComponent("t.txt").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: target))
        let taken = tmp.appendingPathComponent("taken").path
        try Data("do not touch".utf8).write(to: URL(fileURLWithPath: taken))

        XCTAssertThrowsError(try ops.createAlias(at: taken, pointingTo: target)) { error in
            XCTAssertEqual((error as NSError).code, NSFileWriteFileExistsError)
        }
        XCTAssertEqual(try String(contentsOfFile: taken, encoding: .utf8), "do not touch")
    }
}

/// Marking an alias in the panel.
///
/// macOS badges an alias's ICON with a curved arrow, but the panel resolves icons from the
/// file's EXTENSION — one lookup per type rather than per file — so that badge never reaches a
/// row. The name carries the mark instead, the way a symlink carries its chain link.
@MainActor
final class AliasMarkerTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-alias-mark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        try super.tearDownWithError()
    }

    /// The listing must recognise an alias — that is what the mark hangs on.
    func testAnAliasIsRecognisedInTheListing() throws {
        let target = tmp.appendingPathComponent("target.txt").path
        try Data("payload".utf8).write(to: URL(fileURLWithPath: target))
        let aliasPath = tmp.appendingPathComponent("alias").path
        let ops = FileOperationsService(bridgeService: CoreBridgeService())
        try ops.createAlias(at: aliasPath, pointingTo: target)

        let alias = try XCTUnwrap(FileItem.fromPath(aliasPath))
        let plain = try XCTUnwrap(FileItem.fromPath(target))

        XCTAssertTrue(alias.isAlias, "the alias must be marked as one")
        XCTAssertFalse(alias.isSymlink, "and it is not a symbolic link")
        XCTAssertFalse(plain.isAlias, "an ordinary file must not be")
    }

    /// A symbolic link also answers "yes" to the system's isAliasFile question — it must not be
    /// marked as an alias, or every symlink would wear the wrong badge.
    func testASymlinkIsNotTakenForAnAlias() throws {
        let target = tmp.appendingPathComponent("t.txt").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: target))
        let link = tmp.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let item = try XCTUnwrap(FileItem.fromPath(link))
        XCTAssertTrue(item.isSymlink)
        XCTAssertFalse(item.isAlias)
    }

    /// The mark itself: the name, then the badge as an attachment.
    func testTheMarkedNameCarriesTheBadge() {
        let font = NSFont.systemFont(ofSize: 13)
        let marked = PanelViewController.aliasAttributedName("photo", font: font, color: .labelColor)

        XCTAssertTrue(marked.string.hasPrefix("photo"), "the name comes first")
        var foundAttachment = false
        marked.enumerateAttribute(.attachment, in: NSRange(location: 0, length: marked.length)) { value, _, _ in
            if value != nil { foundAttachment = true }
        }
        XCTAssertTrue(foundAttachment, "the badge must be there")
    }
}
