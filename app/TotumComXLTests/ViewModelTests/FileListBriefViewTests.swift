import AppKit
import Foundation
import XCTest

@testable import TotumComXLApp

@MainActor
final class FileListBriefViewTests: XCTestCase {
    func test_whenFileHasExtension_shouldSplitIntoBaseAndExtension() {
        let parts = BriefNameLayout.parts(for: "archive.tar.gz", isDirectory: false)
        XCTAssertEqual(parts.baseName, "archive.tar")
        XCTAssertEqual(parts.extensionName, "gz")
    }

    func test_whenDirectory_shouldKeepWholeNameAndNoExtension() {
        let parts = BriefNameLayout.parts(for: "Documents", isDirectory: true)
        XCTAssertEqual(parts.baseName, "Documents")
        XCTAssertEqual(parts.extensionName, "")
    }

    func test_whenDotFileWithoutRealExtension_shouldNotSplit() {
        let parts = BriefNameLayout.parts(for: ".gitignore", isDirectory: false)
        XCTAssertEqual(parts.baseName, ".gitignore")
        XCTAssertEqual(parts.extensionName, "")
    }

    func test_whenNameEndsWithDot_shouldNotSplit() {
        let parts = BriefNameLayout.parts(for: "config.", isDirectory: false)
        XCTAssertEqual(parts.baseName, "config.")
        XCTAssertEqual(parts.extensionName, "")
    }

    func test_whenCursorItemIsVisible_shouldNotScrollIfNotForced() throws {
        let fixture = try BriefPanelFixture()
        defer { fixture.cleanup() }

        let view = makeBriefView(viewModel: fixture.viewModel)
        let coordinator = view.makeCoordinator()
        let spy = ScrollSpyCollectionView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let indexPath = IndexPath(item: 0, section: 0)
        spy.layoutAttributes[indexPath] = {
            let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            attributes.frame = NSRect(x: 0, y: 0, width: 100, height: 20)
            return attributes
        }()

        coordinator.scrollCursorToVisible(in: spy, cursorIndex: 0, force: false)

        XCTAssertEqual(spy.scrollCallCount, 0)
    }

    func test_whenForced_shouldScrollToCursorItem() throws {
        let fixture = try BriefPanelFixture()
        defer { fixture.cleanup() }

        let view = makeBriefView(viewModel: fixture.viewModel)
        let coordinator = view.makeCoordinator()
        let spy = ScrollSpyCollectionView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let indexPath = IndexPath(item: 1, section: 0)
        spy.layoutAttributes[indexPath] = {
            let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            attributes.frame = NSRect(x: 420, y: 0, width: 100, height: 20)
            return attributes
        }()

        coordinator.scrollCursorToVisible(in: spy, cursorIndex: 1, force: true)

        XCTAssertEqual(spy.scrollCallCount, 1)
        XCTAssertEqual(spy.lastScrolledIndexPaths, [indexPath])
    }

    private func makeBriefView(viewModel: PanelViewModel) -> FileListBriefView {
        FileListBriefView(
            viewModel: viewModel,
            isActive: true,
            itemWidth: 190,
            itemHeight: 20,
            iconSize: 14,
            folderIconStyle: .macos,
            folderIconTintColor: nil,
            upIconScale: 1.0,
            upIconWeight: PanelAppearanceSettings.defaultUpIconWeight,
            upIconSymbol: PanelAppearanceSettings.defaultUpIconSymbol,
            folderNameColor: .labelColor,
            fileNameColor: .labelColor,
            colorGeneration: 0,
            cursorNameColor: .systemBlue,
            cursorBackgroundColor: nil,
            cursorBeauty: false,
            cursorBlur: 0,
            cursorHeightFraction: 0.8,
            cursorWidthFraction: 1.0,
            cursorCorner: 8,
            cursorOffsetX: 0,
            cursorOffsetY: 0,
            cursorAnchorX: 0.5,
            cursorAnchorY: 0.5,
            renamingPath: nil,
            renameText: "",
            onRenameTextChanged: { _ in },
            onCommitRename: { _ in },
            onCancelRename: {},
            onRowsPerColumnChanged: { _ in },
            onItemPrimaryClick: { _, _ in },
            onItemDoubleClick: { _ in },
            onItemRightClick: { _, _ in },
            menuForItem: { _ in NSMenu() },
            backgroundMenu: { NSMenu() },
            onBackgroundPrimaryClick: {},
            onBeginDrag: { _ in NSItemProvider() },
            onDropPaths: { _, _, _ in },
            onDropArchiveEntries: { _, _ in },
            keyHandler: { _ in false }
        )
    }
}

@MainActor
private final class BriefPanelFixture {
    let rootURL: URL
    let viewModel: PanelViewModel

    init() throws {
        let fileManager = FileManager.default
        rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("fcxl-brief-view-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        try "alpha".write(
            to: rootURL.appendingPathComponent("alpha.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "beta".write(
            to: rootURL.appendingPathComponent("beta.txt"),
            atomically: true,
            encoding: .utf8
        )

        viewModel = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: rootURL.path,
            pathDefaultsKey: "panel.path.brief.view.test.\(UUID().uuidString)",
            viewModeDefaultsKey: "panel.mode.brief.view.test.\(UUID().uuidString)",
            showHiddenFiles: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class ScrollSpyCollectionView: NSCollectionView {
    var scrollCallCount = 0
    var lastScrolledIndexPaths: Set<IndexPath> = []
    var layoutAttributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]

    override func scrollToItems(at indexPaths: Set<IndexPath>, scrollPosition: NSCollectionView.ScrollPosition) {
        scrollCallCount += 1
        lastScrolledIndexPaths = indexPaths
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        layoutAttributes[indexPath]
    }
}
