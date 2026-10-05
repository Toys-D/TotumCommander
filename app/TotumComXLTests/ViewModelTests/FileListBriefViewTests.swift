import AppKit
import Foundation
import XCTest
import SwiftUI

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

    /// Рамка переноса не застревает на файлах. Список перезагружается посреди переноса
    /// (перекраска по свежести раз в 15 с, изменения в папке) — раньше вид ячейки с рамкой
    /// уезжал на другой файл, снималась рамка по номеру позиции с ДРУГОГО вида, и она
    /// оставалась навсегда, перескакивая при каждом удалении.
    func test_dropRingNeverSticksToFilesAcrossReloads() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fcxl-ring-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for i in 1...40 { try Data().write(to: root.appendingPathComponent(String(format: "img_%02d.png", i))) }
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: root.path,
                                pathDefaultsKey: "ring.\(UUID().uuidString)",
                                viewModeDefaultsKey: "ringm.\(UUID().uuidString)", showHiddenFiles: true)
        let host = NSHostingView(rootView: makeBriefView(viewModel: vm))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        let probe = try DropRingProbe(host: host, viewModel: vm, expectedCount: 42)
        let folder = try XCTUnwrap(vm.items.firstIndex { $0.name == "folder" })
        let coordinator = try XCTUnwrap(probe.collectionView.delegate as? FileListBriefView.Coordinator)

        coordinator.updateDropHighlight(to: IndexPath(item: folder, section: 0), in: probe.collectionView)
        XCTAssertEqual(probe.ringed(), ["folder"])

        probe.collectionView.reloadData(); probe.settle()
        XCTAssertEqual(probe.ringed(), ["folder"], "перезагрузка посреди переноса — рамка там же, на папке")
        XCTAssertEqual(probe.ringViewCount(), 1)

        coordinator.updateDropHighlight(to: nil, in: probe.collectionView)
        XCTAssertEqual(probe.ringViewCount(), 0, "перенос кончился — рамки нет нигде")

        for name in ["img_01.png", "img_02.png", "img_03.png"] {
            try probe.delete(root.appendingPathComponent(name))
            XCTAssertEqual(probe.ringViewCount(), 0, "удалили \(name) — рамка не всплыла")
        }
        withExtendedLifetime(window) {}
    }

    /// Ответ Spotlight о новом внутри приходит, когда список уже на экране, и меняет только
    /// знак у папки. Счётчик обязан появиться сразу, а не после щелчка по панели.
    func test_счётчикНовогоВнутриПоявляетсяБезСменыСписка() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fcxl-news-brief-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("Проект"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: root.path,
                                pathDefaultsKey: "newsb.\(UUID().uuidString)",
                                viewModeDefaultsKey: "newsbm.\(UUID().uuidString)", showHiddenFiles: true)
        let host = NSHostingView(rootView: makeBriefView(viewModel: vm))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        let probe = try DropRingProbe(host: host, viewModel: vm, expectedCount: 2)

        /// Подсказка у плашки — «Новых файлов внутри: N»; плашки нет — и подсказки нет.
        func chipTooltip() throws -> String? {
            let index = try XCTUnwrap(vm.items.firstIndex { $0.name == "Проект" })
            let cell = try XCTUnwrap(probe.collectionView.item(at: IndexPath(item: index, section: 0))?.view)
            return cell.subviews.compactMap { ($0 as? NSImageView)?.image != nil ? $0.toolTip : nil }
                .first { $0.contains("12") }
        }

        XCTAssertNil(try chipTooltip(), "пока нового нет — счётчика нет")
        vm.applyFolderNews([root.appendingPathComponent("Проект").path: FolderNews.Inside(count: 12, newest: Date())],
                           in: vm.currentPath)
        probe.settle()
        XCTAssertEqual(try chipTooltip(), String(format: L("folderNews.tooltip"), 12), "«+12» — без смены списка")
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

/// Список в окне без рамки: где сейчас рамка переноса и сколько видов её несут.
@MainActor
final class DropRingProbe {
    let collectionView: NSCollectionView
    private let host: NSView
    private let viewModel: PanelViewModel

    init(host: NSView, viewModel: PanelViewModel, expectedCount: Int) throws {
        self.host = host
        self.viewModel = viewModel
        let deadline = Date().addingTimeInterval(5)
        while viewModel.items.count < expectedCount, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        func find(_ v: NSView) -> NSCollectionView? {
            if let c = v as? NSCollectionView { return c }
            for s in v.subviews { if let c = find(s) { return c } }
            return nil
        }
        collectionView = try XCTUnwrap(find(host))
    }

    func settle() {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        collectionView.layoutSubtreeIfNeeded()
    }

    /// Имена видимых файлов с рамкой.
    func ringed() -> [String] {
        collectionView.visibleItems().compactMap { item -> String? in
            guard (item.view as? DropRingCell)?.isDropTarget == true,
                  let ip = collectionView.indexPath(for: item),
                  viewModel.items.indices.contains(ip.item) else { return nil }
            return viewModel.items[ip.item].name
        }
    }

    /// Все виды ячеек с рамкой — и видимые, и те, что ждут переиспользования внутри списка.
    func ringViewCount() -> Int {
        func walk(_ v: NSView) -> Int {
            (((v as? DropRingCell)?.isDropTarget ?? false) ? 1 : 0) + v.subviews.reduce(0) { $0 + walk($1) }
        }
        return walk(collectionView)
    }

    /// Удалить файл и дождаться, пока список его уберёт.
    func delete(_ url: URL) throws {
        let before = viewModel.items.count
        try FileManager.default.removeItem(at: url)
        viewModel.loadDirectory(at: url.deletingLastPathComponent().path)
        let deadline = Date().addingTimeInterval(3)
        while viewModel.items.count >= before, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        settle()
    }
}

