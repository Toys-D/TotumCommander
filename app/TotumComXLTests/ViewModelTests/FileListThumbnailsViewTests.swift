import AppKit
import Foundation
import XCTest

@testable import TotumComXLApp

@MainActor
final class FileListThumbnailsViewTests: XCTestCase {
    func test_whenCoordinatorRequestsItems_shouldReturnItemsCount() throws {
        let fixture = try ThumbnailsPanelFixture()
        defer { fixture.cleanup() }

        let thumbnailsView = makeThumbnailsView(viewModel: fixture.viewModel)
        let coordinator = thumbnailsView.makeCoordinator()

        XCTAssertEqual(
            coordinator.collectionView(NSCollectionView(), numberOfItemsInSection: 0),
            fixture.viewModel.items.count
        )
    }

    func test_whenVisibleWidthChanges_shouldUpdateColumnsPerRowCallback() throws {
        let fixture = try ThumbnailsPanelFixture()
        defer { fixture.cleanup() }

        var capturedColumns: Int?
        var view = makeThumbnailsView(viewModel: fixture.viewModel)
        view = FileListThumbnailsView(
            viewModel: view.viewModel,
            isActive: view.isActive,
            cellSize: view.cellSize,
            previewSize: view.previewSize,
            useQuickLookPreviews: true,
            folderIconStyle: view.folderIconStyle,
            folderIconTintColor: view.folderIconTintColor,
            upIconScale: view.upIconScale,
            upIconWeight: view.upIconWeight,
            upIconSymbol: view.upIconSymbol,
            folderNameColor: view.folderNameColor,
            fileNameColor: view.fileNameColor,
            colorGeneration: view.colorGeneration,
            cursorNameColor: view.cursorNameColor,
            cursorBackgroundColor: view.cursorBackgroundColor,
            cursorBeauty: view.cursorBeauty,
            cursorBlur: view.cursorBlur,
            cursorCorner: view.cursorCorner,
            renamingPath: view.renamingPath,
            renameText: view.renameText,
            onRenameTextChanged: view.onRenameTextChanged,
            onCommitRename: view.onCommitRename,
            onCancelRename: view.onCancelRename,
            onColumnsPerRowChanged: { capturedColumns = $0 },
            onItemPrimaryClick: view.onItemPrimaryClick,
            onItemDoubleClick: view.onItemDoubleClick,
            onItemRightClick: view.onItemRightClick,
            menuForItem: view.menuForItem,
            backgroundMenu: view.backgroundMenu,
            onBackgroundPrimaryClick: view.onBackgroundPrimaryClick,
            onBeginDrag: view.onBeginDrag,
            onDropPaths: view.onDropPaths,
            onDropArchiveEntries: view.onDropArchiveEntries,
            keyHandler: view.keyHandler
        )

        let coordinator = view.makeCoordinator()
        coordinator.updateColumnsPerRow(forVisibleWidth: 340)

        XCTAssertEqual(capturedColumns, 3)
    }

    private func makeThumbnailsView(viewModel: PanelViewModel) -> FileListThumbnailsView {
        FileListThumbnailsView(
            viewModel: viewModel,
            isActive: true,
            cellSize: 100,
            previewSize: 64,
            useQuickLookPreviews: true,
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
            cursorCorner: 8,
            renamingPath: nil,
            renameText: "",
            onRenameTextChanged: { _ in },
            onCommitRename: { _ in },
            onCancelRename: {},
            onColumnsPerRowChanged: { _ in },
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
private final class ThumbnailsPanelFixture {
    let rootURL: URL
    let viewModel: PanelViewModel

    init() throws {
        let fileManager = FileManager.default
        rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("fcxl-thumbnails-view-tests-\(UUID().uuidString)")
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
            pathDefaultsKey: "panel.path.thumbnails.test.\(UUID().uuidString)",
            viewModeDefaultsKey: "panel.mode.thumbnails.test.\(UUID().uuidString)",
            showHiddenFiles: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
