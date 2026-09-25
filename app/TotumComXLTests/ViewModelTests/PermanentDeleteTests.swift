import XCTest

@testable import TotumComXLApp

/// Shift+Del — the one operation the app cannot undo. These pin down that it really bypasses the
/// Trash (a delete that quietly trashed instead would be a lie, and one that trashed while
/// claiming to erase would be worse), and that it takes whole trees with it.
@MainActor
final class PermanentDeleteTests: XCTestCase {

    private var ops: FileOperationsService!
    private var tmp: String!

    override func setUp() {
        super.setUp()
        ops = FileOperationsService(bridgeService: CoreBridgeService())
        tmp = (FileManager.default.temporaryDirectory.path as NSString)
            .appendingPathComponent("fcxl-erase-test-\(UUID().uuidString)")
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

    private func item(_ p: String) -> FileItem {
        FileItem.fromPath(p)!
    }

    private func exists(_ p: String) -> Bool {
        FileManager.default.fileExists(atPath: p)
    }

    /// Names currently sitting in the user's Trash. Read-only — nothing here ever writes there.
    private func trashNames() -> Set<String> {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []
        return Set(names)
    }

    // MARK: - The file is gone

    func testFileIsRemovedFromDisk() async throws {
        let file = makeFile("doomed.txt")
        try await ops.deleteItemsPermanently([item(file)])
        XCTAssertFalse(exists(file))
    }

    /// The whole point: it must NOT end up in the Trash, or "permanently" is a lie.
    func testTheFileDoesNotLandInTheTrash() async throws {
        let name = "erase-me-\(UUID().uuidString).txt"
        let file = makeFile(name)
        let before = trashNames()

        try await ops.deleteItemsPermanently([item(file)])

        XCTAssertFalse(exists(file))
        XCTAssertFalse(trashNames().contains(name))
        XCTAssertEqual(trashNames().subtracting(before), [],
                       "erasing must add nothing at all to the Trash")
    }

    func testAFolderGoesWithEverythingInsideIt() async throws {
        let folder = path("tree")
        let nested = (folder as NSString).appendingPathComponent("deep/deeper")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let buried = (nested as NSString).appendingPathComponent("leaf.txt")
        FileManager.default.createFile(atPath: buried, contents: Data("x".utf8))

        try await ops.deleteItemsPermanently([item(folder)])

        XCTAssertFalse(exists(folder))
        XCTAssertFalse(exists(buried))
    }

    func testEveryItemInTheListIsErased() async throws {
        let files = (1...5).map { makeFile("file\($0).txt") }
        try await ops.deleteItemsPermanently(files.map(item))
        for file in files { XCTAssertFalse(exists(file), file) }
    }

    func testCyrillicNamesAreErasedToo() async throws {
        let file = makeFile("Снимок экрана.png")
        try await ops.deleteItemsPermanently([item(file)])
        XCTAssertFalse(exists(file))
    }

    // MARK: - Edges

    func testAnEmptyListIsAQuietNoOp() async throws {
        let survivor = makeFile("keep.txt")
        try await ops.deleteItemsPermanently([])
        XCTAssertTrue(exists(survivor))
    }

    /// A symlink must be unlinked, never followed — erasing the link cannot take its target.
    func testASymlinkIsRemovedButItsTargetSurvives() async throws {
        let target = makeFile("target.txt")
        let link = path("link.txt")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        try await ops.deleteItemsPermanently([item(link)])

        XCTAssertFalse(exists(link))
        XCTAssertTrue(exists(target), "erasing a link must never reach through it")
    }
}

/// A symlink whose target is gone: the one thing the file manager could not delete.
///
/// The preflight asked fileExists, which FOLLOWS the link — the target was gone, so the answer
/// was "file not found" and the delete refused, even though the link itself sat right there.
/// Deleting from the Trash hit it constantly: trash a link, move its target, and the trash
/// entry became immortal.
@MainActor
final class BrokenSymlinkDeleteTests: XCTestCase {

    func testABrokenSymlinkCanBeDeleted() async throws {
        let ops = FileOperationsService(bridgeService: CoreBridgeService())
        let tmp = (FileManager.default.temporaryDirectory.path as NSString)
            .appendingPathComponent("fcxl-broken-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let link = (tmp as NSString).appendingPathComponent("битая-ссылка.png")
        try FileManager.default.createSymbolicLink(atPath: link,
                                                   withDestinationPath: "/нигде/нет/такого.png")
        let item = FileItem(path: link, name: "битая-ссылка.png", fileExtension: "png",
                            size: 0, isDirectory: false, isHidden: false, isSymlink: true,
                            permissions: "lrwxr-xr-x", dateModified: Date())

        try await ops.deleteItemsPermanently([item])

        XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: link),
                     "the link itself must be gone")
    }
}
