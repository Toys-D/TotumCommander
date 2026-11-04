import XCTest

@testable import TotumComXLApp

/// Tests for two small-but-everywhere pieces of logic:
/// • `FileItem.fromPath` — the parser that turns a filesystem path into the model used by
///   every panel, search result and drag payload (name/ext/size/dir/symlink/hidden/.app/hardlink).
/// • `DialogService.generateCopyName` — the "(копия)" duplicate-naming used by copy-to-same-folder.
/// All deterministic against a throwaway temp directory.
final class FileItemAndCopyNameTests: XCTestCase {

    private var tmp: String!

    override func setUp() {
        super.setUp()
        tmp = (FileManager.default.temporaryDirectory.path as NSString)
            .appendingPathComponent("fcxl-fileitem-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        tmp = nil
        super.tearDown()
    }

    private func path(_ name: String) -> String { (tmp as NSString).appendingPathComponent(name) }

    @discardableResult
    private func makeFile(_ name: String, bytes: Int = 3) -> String {
        let p = path(name)
        FileManager.default.createFile(atPath: p, contents: Data(count: bytes))
        return p
    }

    // MARK: - FileItem.fromPath

    func test_fromPath_regularFile() throws {
        let p = makeFile("report.pdf", bytes: 42)
        let item = try XCTUnwrap(FileItem.fromPath(p))
        XCTAssertEqual(item.name, "report.pdf")
        XCTAssertEqual(item.fileExtension, "pdf")
        XCTAssertEqual(item.size, 42)
        XCTAssertFalse(item.isDirectory)
        XCTAssertFalse(item.isSymlink)
        XCTAssertFalse(item.isHidden)
    }

    func test_fromPath_directoryHasEmptyExtension() throws {
        try FileManager.default.createDirectory(atPath: path("My.Folder"), withIntermediateDirectories: true)
        let item = try XCTUnwrap(FileItem.fromPath(path("My.Folder")))
        XCTAssertTrue(item.isDirectory)
        XCTAssertEqual(item.fileExtension, "", "directories must not expose a file extension")
    }

    func test_fromPath_cyrillicName() throws {
        let p = makeFile("Отчёт й.txt")
        let item = try XCTUnwrap(FileItem.fromPath(p))
        XCTAssertEqual(item.name, "Отчёт й.txt")
        XCTAssertEqual(item.fileExtension, "txt")
    }

    func test_fromPath_hiddenFile() throws {
        let p = makeFile(".secret")
        let item = try XCTUnwrap(FileItem.fromPath(p))
        XCTAssertTrue(item.isHidden)
    }

    func test_fromPath_symlink() throws {
        let target = makeFile("target.txt")
        let link = path("alias.txt")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let item = try XCTUnwrap(FileItem.fromPath(link))
        XCTAssertTrue(item.isSymlink)
        XCTAssertEqual(item.symlinkTarget, target)
    }

    func test_fromPath_appBundleIsDetected() throws {
        try FileManager.default.createDirectory(atPath: path("Cool.app"), withIntermediateDirectories: true)
        let item = try XCTUnwrap(FileItem.fromPath(path("Cool.app")))
        XCTAssertTrue(item.isAppBundle)
    }

    func test_fromPath_hardlinkIsDetected() throws {
        let target = makeFile("orig.bin")
        let link = path("hard.bin")
        try FileManager.default.linkItem(atPath: target, toPath: link)  // real hard link
        let item = try XCTUnwrap(FileItem.fromPath(link))
        XCTAssertTrue(item.hardlinkCount >= 2)
        XCTAssertTrue(item.isHardlink)
    }

    func test_fromPath_missingReturnsNil() {
        XCTAssertNil(FileItem.fromPath(path("does-not-exist")))
    }

    // MARK: - DialogService.generateCopyName

    @MainActor
    func test_generateCopyName_firstCopyKeepsExtension() {
        let name = DialogService.generateCopyName(for: "photo.jpg", in: tmp)
        XCTAssertEqual(name, "photo (копия).jpg")
    }

    @MainActor
    func test_generateCopyName_incrementsWhenTaken() {
        makeFile("photo (копия).jpg")
        XCTAssertEqual(DialogService.generateCopyName(for: "photo.jpg", in: tmp), "photo (копия 2).jpg")

        makeFile("photo (копия 2).jpg")
        XCTAssertEqual(DialogService.generateCopyName(for: "photo.jpg", in: tmp), "photo (копия 3).jpg")
    }

    @MainActor
    func test_generateCopyName_noExtension() {
        XCTAssertEqual(DialogService.generateCopyName(for: "Notes", in: tmp), "Notes (копия)")
    }

    @MainActor
    func test_generateCopyName_cyrillic() {
        XCTAssertEqual(DialogService.generateCopyName(for: "Документ.txt", in: tmp), "Документ (копия).txt")
    }
}
