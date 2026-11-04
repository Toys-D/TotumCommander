import Foundation
import XCTest

@testable import TotumComXLApp

/// The branch-view walk (Ctrl+B): every file of the subtree as one flat list, each row
/// carrying its subpath; directories are not rows, symlinked folders are not entered.
final class BranchViewTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func make(_ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func build(showHidden: Bool = false, limit: Int = 100_000) -> [FileItem] {
        PanelViewModel.buildBranchItems(root: root.path, showHidden: showHidden, limit: limit)
    }

    func test_flattens_theWholeSubtree_withSubpaths() throws {
        try make("верхний.txt")
        try make("глубже/внутренний.txt")
        try make("глубже/ещё/самый глубокий.txt")

        let items = build()

        XCTAssertEqual(Set(items.compactMap(\.branchPath)),
                       ["верхний.txt", "глубже/внутренний.txt",
                        "глубже/ещё/самый глубокий.txt"])
        // Operations keep working with the REAL name — the subpath is display only.
        XCTAssertEqual(items.first { $0.branchPath!.hasSuffix("внутренний.txt") }?.name,
                       "внутренний.txt")
    }

    /// Directories are not rows: their contents are the point of the flattening.
    func test_directories_areNotRows() throws {
        try make("папка/файл.txt")
        let items = build()
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items.contains(where: \.isDirectory))
    }

    func test_hiddenFiles_followTheSetting() throws {
        try make("обычный.txt")
        try make(".тайный.txt")

        XCTAssertEqual(build(showHidden: false).count, 1)
        XCTAssertEqual(Set(build(showHidden: true).compactMap(\.branchPath)),
                       ["обычный.txt", ".тайный.txt"])
    }

    /// A symlinked folder is not entered — that is how a cycle would get in.
    func test_symlinkedFolders_areNotDescendedInto() throws {
        try make("настоящая/внутри.txt")
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("ссылка").path,
            withDestinationPath: root.appendingPathComponent("настоящая").path)

        let subpaths = build().compactMap(\.branchPath)

        XCTAssertTrue(subpaths.contains("настоящая/внутри.txt"))
        XCTAssertFalse(subpaths.contains("ссылка/внутри.txt"),
                       "the walk must not follow the symlink into the folder")
    }

    /// The cap is a ceiling, not an error: what was gathered is still returned.
    func test_limit_stopsTheWalk_keepingWhatItHas() throws {
        try make("а.txt"); try make("б.txt"); try make("в.txt")
        XCTAssertEqual(build(limit: 2).count, 2)
    }
}
