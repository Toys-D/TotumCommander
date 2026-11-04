import XCTest

@testable import TotumComXLApp

/// An empty folder used to read `<DIR>` forever, indistinguishable from a folder whose size the
/// walker had not reached yet — both carry `size == 0`. The child count the listing now brings
/// along is what separates "holds nothing" from "nobody has counted yet".
final class EmptyFolderSizeTests: XCTestCase {

    private var tmp: String!
    private var bridge: CoreBridgeService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        bridge = CoreBridgeService()
        tmp = (FileManager.default.temporaryDirectory.path as NSString)
            .appendingPathComponent("fcxl-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(atPath: tmp) }
        bridge = nil
        tmp = nil
        try super.tearDownWithError()
    }

    private func path(_ name: String) -> String { (tmp as NSString).appendingPathComponent(name) }

    private func item(_ name: String, size: UInt64 = 0, isDirectory: Bool = true,
                      entryCount: Int = -1) -> FileItem {
        FileItem(path: "/tmp/\(name)", name: name, fileExtension: "", size: size,
                 isDirectory: isDirectory, isHidden: false, isSymlink: false,
                 permissions: "755", dateModified: Date(), entryCount: entryCount)
    }

    // MARK: - The count survives the trip from the C++ listing to Swift

    func testTheBulkListingCountsChildrenAllTheWayToSwift() throws {
        try FileManager.default.createDirectory(atPath: path("пусто"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path("занято"), withIntermediateDirectories: true)
        try "x".write(toFile: (path("занято") as NSString).appendingPathComponent("файл.txt"),
                      atomically: true, encoding: .utf8)
        try "содержимое".write(toFile: path("обычный.txt"), atomically: true, encoding: .utf8)

        let listed = try bridge.listDirectoryFast(path: tmp, showHidden: true)
        let byName = Dictionary(uniqueKeysWithValues: listed.map { ($0.name, $0) })

        XCTAssertEqual(byName["пусто"]?.entryCount, 0)
        XCTAssertEqual(byName["занято"]?.entryCount, 1)
        XCTAssertEqual(byName["обычный.txt"]?.entryCount, -1,
                       "a file has no child count — only directories carry one")

        XCTAssertEqual(byName["пусто"]?.isEmptyDirectory, true)
        XCTAssertEqual(byName["занято"]?.isEmptyDirectory, false)
        XCTAssertEqual(byName["обычный.txt"]?.isEmptyDirectory, false)
    }

    /// A hidden child is still a child: the folder is not empty, whatever the panel chooses to show.
    func testADotFileMakesAFolderNonEmpty() throws {
        try FileManager.default.createDirectory(atPath: path("сдотфайлом"), withIntermediateDirectories: true)
        try "".write(toFile: (path("сдотфайлом") as NSString).appendingPathComponent(".DS_Store"),
                     atomically: true, encoding: .utf8)

        let listed = try bridge.listDirectoryFast(path: tmp, showHidden: false)
        let folder = try XCTUnwrap(listed.first { $0.name == "сдотфайлом" })
        XCTAssertEqual(folder.entryCount, 1)
        XCTAssertFalse(folder.isEmptyDirectory, "it holds a file, hidden or not")
    }

    /// The old readdir-only path never asks, and must say so rather than claim emptiness.
    func testAListingThatNeverAsksLeavesTheCountUnknown() throws {
        try FileManager.default.createDirectory(atPath: path("пусто"), withIntermediateDirectories: true)
        let listed = try bridge.listDirectoryNamesOnly(path: tmp, showHidden: true)
        let folder = try XCTUnwrap(listed.first { $0.name == "пусто" })
        XCTAssertEqual(folder.entryCount, -1)
        XCTAssertFalse(folder.isEmptyDirectory, "unknown is not empty")
    }

    func testCarryingASizeKeepsTheChildCount() {
        XCTAssertEqual(item("папка", entryCount: 4).withSize(9_000).entryCount, 4)
    }

    // MARK: - What the size column prints

    func testAnEmptyFolderPrintsZeroBytes() {
        XCTAssertEqual(PanelViewController.sizeCellText(for: item("пусто", entryCount: 0)),
                       L("size.zero"))
    }

    /// The regression this whole change guards: a folder nobody has measured must keep saying
    /// <DIR>, or every folder would flash "0 байт" until the walker reached it.
    func testAnUncountedFolderStillSaysDIR() {
        XCTAssertEqual(PanelViewController.sizeCellText(for: item("неизвестно", entryCount: -1)),
                       "<DIR>")
    }

    /// Non-empty but not yet added up — same rule.
    func testAFolderWithChildrenAndNoSizeYetSaysDIR() {
        XCTAssertEqual(PanelViewController.sizeCellText(for: item("занято", entryCount: 3)), "<DIR>")
    }

    func testAMeasuredFolderPrintsItsSize() {
        let text = PanelViewController.sizeCellText(for: item("посчитано", size: 5_000, entryCount: 3))
        XCTAssertEqual(text, ByteCountFormatter.string(fromByteCount: 5_000, countStyle: .file))
        XCTAssertFalse(text.contains("DIR"))
    }

    /// A measured folder that really does add up to nothing — say so rather than <DIR>.
    func testAFolderHoldingOnlyEmptyFilesPrintsZeroBytes() {
        XCTAssertEqual(PanelViewController.sizeCellText(for: item("нулевые", size: 0, entryCount: 2)),
                       "<DIR>", "children but no measurement yet — still unknown")
        XCTAssertEqual(PanelViewController.sizeCellText(for: item("пусто", size: 0, entryCount: 0)),
                       L("size.zero"))
    }

    /// Empty files shared the column with the old hardcoded "0 KB"; one wording for one column.
    func testAnEmptyFilePrintsZeroBytesToo() {
        XCTAssertEqual(
            PanelViewController.sizeCellText(for: item("пустой.txt", isDirectory: false)),
            L("size.zero"))
    }

    func testTheParentRowShowsNothing() {
        XCTAssertEqual(PanelViewController.sizeCellText(for: item("..", entryCount: 0)), "")
    }

    /// ByteCountFormatter is exactly why the zero case is spelled out by hand.
    func testTheFormatterWouldHaveSaidZeroKB() {
        XCTAssertNotEqual(ByteCountFormatter.string(fromByteCount: 0, countStyle: .file),
                          L("size.zero"))
    }
}
