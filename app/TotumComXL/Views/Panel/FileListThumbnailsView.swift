import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct FileListThumbnailsView: NSViewRepresentable {
    @ObservedObject var viewModel: PanelViewModel
    let isActive: Bool
    let cellSize: CGFloat
    let previewSize: CGFloat
    let useQuickLookPreviews: Bool
    let folderIconStyle: FolderIconStyle
    let folderIconTintColor: NSColor?
    let upIconScale: CGFloat
    let upIconWeight: Double
    let upIconSymbol: String
    let folderNameColor: NSColor
    let fileNameColor: NSColor
    /// Счётчик перекрасок правил: меняется на каждом шаге угасания и заставляет ячейки
    /// пересчитать цвет, которого иначе они не тронут — содержимое-то прежнее.
    let colorGeneration: Int
    let cursorNameColor: NSColor
    let cursorBackgroundColor: NSColor?
    // Icon/thumbnail cells are square and the cursor highlights the WHOLE cell, so only the
    // feather (blur) + corner apply here — the brief/detailed size, offset and anchor tweaks
    // are intentionally NOT wired into this view.
    let cursorBeauty: Bool
    let cursorBlur: CGFloat
    let cursorCorner: CGFloat

    let renamingPath: String?
    let renameText: String
    let onRenameTextChanged: (String) -> Void
    let onCommitRename: (FileItem) -> Void
    let onCancelRename: () -> Void

    let onColumnsPerRowChanged: (Int) -> Void
    let onItemPrimaryClick: (Int, NSEvent.ModifierFlags) -> Void
    let onItemDoubleClick: (FileItem) -> Void
    /// A press past the second detent, by ROW — the panel decides what it means.
    /// Defaulted: a view put up on its own (a test, a preview) has no use for it.
    var onDeepPress: (Int) -> Void = { _ in }
    let onItemRightClick: (FileItem, NSPoint) -> Void
    let menuForItem: (FileItem) -> NSMenu
    let backgroundMenu: () -> NSMenu
    let onBackgroundPrimaryClick: () -> Void
    let onBeginDrag: (FileItem) -> NSItemProvider
    let onDropPaths: ([String], FileItem?, Bool) -> Void
    /// Entries dropped out of an ARCHIVE — they carry no file URL, so they cannot travel
    /// through onDropPaths above.
    let onDropArchiveEntries: ([String], FileItem?) -> Void
    let keyHandler: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        layout.itemSize = NSSize(width: cellSize, height: cellSize)

        let collectionView = ThumbnailsCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.isSelectable = false
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.focusRingType = .none
        collectionView.backgroundColors = [.clear]
        collectionView.keyHandler = keyHandler
        collectionView.onItemClick = { [weak coordinator = context.coordinator] index, flags in
            coordinator?.handlePrimaryClick(at: index, modifierFlags: flags)
        }
        collectionView.onItemDoubleClick = { [weak coordinator = context.coordinator] index in
            coordinator?.handleDoubleClick(at: index)
        }
        collectionView.onDeepPress = { [weak coordinator = context.coordinator] index in
            coordinator?.parent.onDeepPress(index)
        }
        collectionView.onItemRightClick = { [weak coordinator = context.coordinator] index, point in
            coordinator?.handleRightClick(at: index, point: point)
        }
        collectionView.onBackgroundClick = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onBackgroundPrimaryClick()
        }
        collectionView.onVisibleWidthChanged = { [weak coordinator = context.coordinator] visibleWidth in
            coordinator?.updateColumnsPerRow(forVisibleWidth: visibleWidth)
        }
        collectionView.onDragExited = { [weak coordinator = context.coordinator, weak collectionView] in
            guard let coordinator, let collectionView else { return }
            coordinator.updateDropHighlight(to: nil, in: collectionView)
        }
        collectionView.selectedIndicesForDrag = { [weak coordinator = context.coordinator] in
            guard let parent = coordinator?.parent else { return [] }
            let items = parent.viewModel.items
            let selectedPaths = parent.viewModel.selectedPaths
            guard !selectedPaths.isEmpty else { return [] }
            return items.enumerated().compactMap { index, item in
                selectedPaths.contains(item.path) ? index : nil
            }
        }

        collectionView.register(
            ThumbnailItem.self,
            forItemWithIdentifier: ThumbnailItem.id
        )

        let menu = NSMenu(title: L("context.menu.title"))
        menu.delegate = context.coordinator
        collectionView.menu = menu

        collectionView.registerForDraggedTypes([.fileURL, .init("com.fcxl.remotePaths"),
                                                .init("com.fcxl.archivePaths")])
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

        scrollView.documentView = collectionView
        context.coordinator.collectionView = collectionView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let collectionView = scrollView.documentView as? ThumbnailsCollectionView,
              let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout
        else {
            return
        }

        context.coordinator.parent = self
        let pictureToken = ThumbnailAppearance.pictureToken(
            previewSize: previewSize,
            quickLook: useQuickLookPreviews,
            folderTint: folderTintCacheToken(),
            upIconScale: upIconScale,
            upIconWeight: upIconWeight,
            upIconSymbol: upIconSymbol)
        let paintToken = ThumbnailAppearance.paintToken(
            folderName: folderNameColor,
            fileName: fileNameColor,
            cursorName: cursorNameColor,
            cursorBackground: cursorBackgroundColor,
            generation: colorGeneration)
        if context.coordinator.lastPictureToken != pictureToken {
            context.coordinator.lastPictureToken = pictureToken
            context.coordinator.resetThumbnailCache()
            collectionView.reloadData()
        }
        // Только раскраска — ячейки перенастроить, эскизы не трогать (см. ThumbnailAppearance).
        let paintChanged = context.coordinator.lastPaintToken != paintToken
        if paintChanged { context.coordinator.lastPaintToken = paintToken }
        collectionView.keyHandler = keyHandler
        collectionView.onItemClick = { [weak coordinator = context.coordinator] index, flags in
            coordinator?.handlePrimaryClick(at: index, modifierFlags: flags)
        }
        collectionView.onItemDoubleClick = { [weak coordinator = context.coordinator] index in
            coordinator?.handleDoubleClick(at: index)
        }
        collectionView.onDeepPress = { [weak coordinator = context.coordinator] index in
            coordinator?.parent.onDeepPress(index)
        }
        collectionView.onItemRightClick = { [weak coordinator = context.coordinator] index, point in
            coordinator?.handleRightClick(at: index, point: point)
        }
        collectionView.onBackgroundClick = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onBackgroundPrimaryClick()
        }
        collectionView.onVisibleWidthChanged = { [weak coordinator = context.coordinator] visibleWidth in
            coordinator?.updateColumnsPerRow(forVisibleWidth: visibleWidth)
        }

        let desiredSize = NSSize(width: cellSize, height: cellSize)
        if layout.itemSize != desiredSize {
            layout.itemSize = desiredSize
            layout.invalidateLayout()
        }

        context.coordinator.updateColumnsPerRow(forVisibleWidth: scrollView.contentView.bounds.width)

        // The tag scan finishes after the cells are already on screen, so a tag-only change has to
        // count as a reason to redraw — otherwise the dots appear only on the next folder change.
        let pathChanged = context.coordinator.lastPath != viewModel.currentPath
        if context.coordinator.lastItemCount != viewModel.items.count ||
            pathChanged ||
            context.coordinator.lastSortToken != viewModel.sortToken ||
            context.coordinator.lastTags != viewModel.tagsByPath ||
            context.coordinator.lastGit != viewModel.gitByPath
        {
            collectionView.reloadData()
            context.coordinator.lastItemCount = viewModel.items.count
            context.coordinator.lastPath = viewModel.currentPath
            context.coordinator.lastSortToken = viewModel.sortToken
            context.coordinator.lastTags = viewModel.tagsByPath
            context.coordinator.lastGit = viewModel.gitByPath
        }

        if context.coordinator.lastScrollResetToken != viewModel.scrollResetToken {
            context.coordinator.lastScrollResetToken = viewModel.scrollResetToken
            if viewModel.items.indices.contains(0) {
                collectionView.scrollToItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: .top)
            }
        }

        var needsVisibleRefresh = paintChanged

        let previousCursor = context.coordinator.lastCursorIndex
        let cursorChanged = previousCursor != viewModel.cursorIndex
        var cursorOnly = false
        if cursorChanged {
            context.coordinator.lastCursorIndex = viewModel.cursorIndex
            // Only a few cells change when the cursor steps; the rest of the screenful is
            // untouched. Same shape as the detailed list and the brief one.
            cursorOnly = true
        }

        // За курсором — только когда он переехал или сменилась папка. На прочих
        // обновлениях (а перекраска приходит сама, раз в пятнадцать секунд) прокрутку не
        // трогать: человек листает список, и его бросало обратно к курсору. CursorFollow.
        let follow = context.coordinator.follow.step(
            wanted: cursorChanged || pathChanged,
            canScroll: viewModel.items.indices.contains(viewModel.cursorIndex))
        if follow, viewModel.scrollOnCursorChange {
            context.coordinator.scrollCursorToVisible(
                in: collectionView,
                cursorIndex: viewModel.cursorIndex,
                force: true
            )
        }

        if context.coordinator.lastSelectedPaths != viewModel.selectedPaths {
            context.coordinator.lastSelectedPaths = viewModel.selectedPaths
            needsVisibleRefresh = true
            cursorOnly = false
        }

        if context.coordinator.lastIsActive != isActive {
            context.coordinator.lastIsActive = isActive
            needsVisibleRefresh = true
            cursorOnly = false
        }

        if context.coordinator.lastRenamingPath != renamingPath {
            let indexes = context.coordinator.affectedRenameIndexes(
                oldPath: context.coordinator.lastRenamingPath,
                newPath: renamingPath
            )
            context.coordinator.lastRenamingPath = renamingPath
            context.coordinator.lastRenameText = renameText

            if indexes.isEmpty {
                collectionView.reloadData()
            } else {
                collectionView.reloadItemsSafely(at: indexes,
                                                 expectedCount: viewModel.items.count)
            }
            needsVisibleRefresh = true
            cursorOnly = false
        } else if context.coordinator.lastRenameText != renameText {
            // Во время ввода rename текста не трогаем NSCollectionView/ячейку,
            // иначе field editor может сбрасывать выделение и курсор.
            context.coordinator.lastRenameText = renameText
            return
        }

        if needsVisibleRefresh {
            context.coordinator.refreshVisibleItems(in: collectionView)
        } else if cursorOnly {
            context.coordinator.refreshCursorBand(in: collectionView,
                                                  from: previousCursor,
                                                  to: viewModel.cursorIndex)
        }

        // Feathered cursor (beauty mode). Second pass on the next runloop tick catches the
        // case where the layout attributes aren't ready yet right after a reload/mode switch.
        context.coordinator.updateCursorGlow()
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.updateCursorGlow()
        }
    }

    private func folderTintCacheToken() -> String {
        guard let folderIconTintColor else { return "none" }
        return PanelAppearanceSettings.hexString(from: folderIconTintColor)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSMenuDelegate {
        var parent: FileListThumbnailsView
        weak var collectionView: ThumbnailsCollectionView?

        var lastItemCount: Int
        var lastPath: String
        var lastCursorIndex: Int
        /// Идти ли за курсором — и просьба, которую не смогли исполнить сразу.
        var follow = CursorFollow()
        var lastSelectedPaths: Set<String>
        var lastIsActive: Bool
        var lastScrollResetToken: UInt64
        var lastSortToken: UInt64 = 0
        var lastTags: [String: [FinderTag]] = [:]
        var lastGit: [String: GitBadge] = [:]
        var lastRenamingPath: String?
        var lastRenameText: String
        var lastColumnsPerRow: Int = 1
        var lastPictureToken: String
        var lastPaintToken: String

        private let thumbnailProvider = ThumbnailProvider()

        /// The cell (a folder) currently showing the drop-target ring, if any. Managed by hand
        /// instead of via NSCollectionView's `.on` highlightState, because the drop operation is
        /// ALWAYS `.on` (to avoid the `.before` insertion line) — so the framework would ring
        /// files and clamped cells too. We ring only a genuine folder under the pointer.
        private var dropFolderIP: IndexPath?

        func updateDropHighlight(to ip: IndexPath?, in cv: NSCollectionView) {
            guard ip != dropFolderIP else { return }
            if let old = dropFolderIP, let v = cv.item(at: old)?.view as? ThumbnailItemView {
                v.isDropTarget = false
            }
            dropFolderIP = ip
            if let new = ip, let v = cv.item(at: new)?.view as? ThumbnailItemView {
                v.isDropTarget = true
            }
        }

        init(_ parent: FileListThumbnailsView) {
            self.parent = parent
            lastItemCount = parent.viewModel.items.count
            lastPath = parent.viewModel.currentPath
            lastCursorIndex = parent.viewModel.cursorIndex
            lastSelectedPaths = parent.viewModel.selectedPaths
            lastIsActive = parent.isActive
            lastScrollResetToken = parent.viewModel.scrollResetToken
            lastRenamingPath = parent.renamingPath
            lastRenameText = parent.renameText
            lastPictureToken = ""
            lastPaintToken = ""
            super.init()
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            1
        }

        func collectionView(_ collectionView: NSCollectionView,
                            numberOfItemsInSection section: Int) -> Int {
            parent.viewModel.items.count
        }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: ThumbnailItem.id,
                for: indexPath
            )

            guard let cell = item as? ThumbnailItem,
                  parent.viewModel.items.indices.contains(indexPath.item)
            else {
                return item
            }

            let model = parent.viewModel.items[indexPath.item]
            configureCell(cell, with: model, index: indexPath.item)
            return cell
        }

        private static let remotePathsType = NSPasteboard.PasteboardType("com.fcxl.remotePaths")
        /// Items inside an archive have no file on disk — item.path points INSIDE the
        /// archive. Handing that over as an NSURL is why dragging out of an archive did
        /// nothing at all: macOS will not drag a file that does not exist.
        private static let archivePathsType = NSPasteboard.PasteboardType("com.fcxl.archivePaths")

        func collectionView(_ collectionView: NSCollectionView,
                            pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
            guard parent.viewModel.items.indices.contains(indexPath.item) else { return nil }
            let item = parent.viewModel.items[indexPath.item]
            guard item.name != ".." else { return nil }
            _ = parent.onBeginDrag(item)
            if parent.viewModel.insideRemote {
                let pbItem = NSPasteboardItem()
                pbItem.setString(item.path, forType: Self.remotePathsType)
                return pbItem
            }
            if parent.viewModel.insideArchive {
                let pbItem = NSPasteboardItem()
                pbItem.setString(item.path, forType: Self.archivePathsType)
                return pbItem
            }
            return NSURL(fileURLWithPath: item.path)
        }

        private func droppedArchivePaths(from info: NSDraggingInfo) -> [String] {
            guard let items = info.draggingPasteboard.pasteboardItems else { return [] }
            return items.compactMap { $0.string(forType: Self.archivePathsType) }
        }

        private func droppedRemotePaths(from info: NSDraggingInfo) -> [String] {
            guard let items = info.draggingPasteboard.pasteboardItems else { return [] }
            return items.compactMap { $0.string(forType: Self.remotePathsType) }
        }

        func collectionView(_ collectionView: NSCollectionView,
                            validateDrop draggingInfo: NSDraggingInfo,
                            proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            let archivePaths = droppedArchivePaths(from: draggingInfo)
            let isArchive = !archivePaths.isEmpty
            if isArchive && parent.viewModel.insideArchive {
                // One exception to "archive → archive is not a thing": this panel's own entry
                // dropped onto ".." extracts it OUT, next to the archive — Total Commander's
                // gesture. The closure routes it, same as the detailed table.
                let hit = collectionView.indexPathForItem(
                    at: collectionView.convert(draggingInfo.draggingLocation, from: nil))
                guard (draggingInfo.draggingSource as AnyObject?) === collectionView,
                      let ip = hit, parent.viewModel.items.indices.contains(ip.item),
                      parent.viewModel.items[ip.item].name == ".." else {
                    updateDropHighlight(to: nil, in: collectionView)
                    return []
                }
                updateDropHighlight(to: ip, in: collectionView)
                proposedDropIndexPath.pointee = ip as NSIndexPath
                proposedDropOperation.pointee = .on
                return .copy
            }
            let remotePaths = isArchive ? [] : droppedRemotePaths(from: draggingInfo)
            let filePaths = (isArchive || !remotePaths.isEmpty) ? [] : droppedFilePaths(from: draggingInfo)
            guard isArchive || !remotePaths.isEmpty || !filePaths.isEmpty else { return [] }

            let count = collectionView.numberOfItems(inSection: 0)
            let loc = collectionView.convert(draggingInfo.draggingLocation, from: nil)
            let hitIP = collectionView.indexPathForItem(at: loc)
            let folderIP: IndexPath? = {
                guard let ip = hitIP, parent.viewModel.items.indices.contains(ip.item) else { return nil }
                let it = parent.viewModel.items[ip.item]
                return (it.isDirectory && it.name != "..") ? ip : nil
            }()
            updateDropHighlight(to: folderIP, in: collectionView)

            // ALWAYS `.on` a valid cell so NO `.before` insertion line is drawn (that line — as if
            // the file would slot in between items — is exactly what the user didn't want; the
            // detailed list, dropping onto its whole table, never shows one). The folder target,
            // if any, is tracked above and read in acceptDrop; WE draw the ring, not the framework.
            if count > 0 {
                let onIP = folderIP ?? hitIP ?? IndexPath(item: count - 1, section: 0)
                proposedDropIndexPath.pointee = onIP as NSIndexPath
                proposedDropOperation.pointee = .on
            } else {
                // Empty folder: no cell to target, and with no items a `.before` line has nothing
                // to sit between, so it's invisible anyway.
                proposedDropIndexPath.pointee = IndexPath(item: 0, section: 0) as NSIndexPath
                proposedDropOperation.pointee = .before
            }
            // Extracting is the only outcome for archive entries — you cannot MOVE one out by
            // dragging (that would delete the entry behind the user's back).
            return isArchive ? .copy : (dropShouldMove(draggingInfo) ? .move : .copy)
        }

        func collectionView(_ collectionView: NSCollectionView,
                            acceptDrop draggingInfo: NSDraggingInfo,
                            indexPath: IndexPath,
                            dropOperation: NSCollectionView.DropOperation) -> Bool {
            let archiveEntries = droppedArchivePaths(from: draggingInfo)
            let remotePaths = archiveEntries.isEmpty ? droppedRemotePaths(from: draggingInfo) : []
            let isRemoteDrop = !remotePaths.isEmpty
            let filePaths = (isRemoteDrop || !archiveEntries.isEmpty) ? [] : droppedFilePaths(from: draggingInfo)
            guard !archiveEntries.isEmpty || isRemoteDrop || !filePaths.isEmpty else { return false }

            // The folder target is the one we tracked while hovering (dropFolderIP) — the passed
            // indexPath is now always `.on` some cell (to suppress the insertion line) and can't
            // be trusted to mean "into this folder". nil → drop into the current directory.
            var targetFolder: FileItem?
            if let ip = dropFolderIP, parent.viewModel.items.indices.contains(ip.item) {
                let item = parent.viewModel.items[ip.item]
                if item.isDirectory, item.name != ".." {
                    targetFolder = item
                }
            }
            updateDropHighlight(to: nil, in: collectionView)

            if !archiveEntries.isEmpty {
                parent.onDropArchiveEntries(archiveEntries, targetFolder)
            } else if isRemoteDrop {
                parent.onDropPaths(remotePaths, targetFolder, dropShouldMove(draggingInfo))
            } else {
                parent.onDropPaths(filePaths, targetFolder, dropShouldMove(draggingInfo))
            }
            return true
        }

        func collectionView(_ collectionView: NSCollectionView,
                            layout collectionViewLayout: NSCollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> NSSize {
            NSSize(width: parent.cellSize, height: parent.cellSize)
        }

        func collectionView(_ collectionView: NSCollectionView,
                            layout collectionViewLayout: NSCollectionViewLayout,
                            minimumLineSpacingForSectionAt section: Int) -> CGFloat {
            4
        }

        func collectionView(_ collectionView: NSCollectionView,
                            layout collectionViewLayout: NSCollectionViewLayout,
                            minimumInteritemSpacingForSectionAt section: Int) -> CGFloat {
            4
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let collectionView else { return }

            if let indexPath = collectionView.lastContextMenuIndexPath,
               parent.viewModel.items.indices.contains(indexPath.item)
            {
                let item = parent.viewModel.items[indexPath.item]
                parent.onItemRightClick(item, collectionView.lastContextMenuPoint)
                let fileMenu = ContextMenuBuilder.fileMenu(for: item, provider: parent.menuForItem)
                ContextMenuBuilder.moveItems(from: fileMenu, to: menu)
            } else {
                let bgMenu = ContextMenuBuilder.backgroundMenu(provider: parent.backgroundMenu)
                ContextMenuBuilder.moveItems(from: bgMenu, to: menu)
            }
        }

        func handlePrimaryClick(at index: Int, modifierFlags: NSEvent.ModifierFlags) {
            guard parent.viewModel.items.indices.contains(index) else { return }
            parent.onItemPrimaryClick(index, modifierFlags)
        }

        func handleDoubleClick(at index: Int) {
            guard parent.viewModel.items.indices.contains(index) else { return }
            parent.onItemDoubleClick(parent.viewModel.items[index])
        }

        func handleRightClick(at index: Int, point: NSPoint) {
            guard parent.viewModel.items.indices.contains(index) else { return }
            let item = parent.viewModel.items[index]
            parent.onItemRightClick(item, point)
        }

        func updateColumnsPerRow(forVisibleWidth visibleWidth: CGFloat,
                                 sectionInset: NSEdgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4),
                                 spacing: CGFloat = 4) {
            let usableWidth = max(1, visibleWidth - sectionInset.left - sectionInset.right + spacing)
            let columns = max(1, Int(floor(usableWidth / max(parent.cellSize + spacing, 1))))
            if columns != lastColumnsPerRow {
                lastColumnsPerRow = columns
                parent.onColumnsPerRowChanged(columns)
            }
        }

        /// Positions the feathered cursor over the cursor cell (beauty mode), or hides it.
        func updateCursorGlow() {
            guard let cv = collectionView else { return }
            // Unconditional: a mask edit re-bakes the cursor IMAGE behind unchanged property
            // values, so the didSet-based repaints never fire. This is what keeps the live
            // preview alive — it was removed once as "pointless" and the preview died with it.
            cv.needsDisplay = true
            cv.cursorGlowBlur = parent.cursorBlur
            cv.cursorGlowCorner = parent.cursorCorner
            // Full cell, centred, no offset — size/offset/anchor are deliberately fixed here
            // (they only make sense for the row-shaped brief/detailed cursors).
            cv.cursorGlowHeightFraction = 1
            cv.cursorGlowWidthFraction = 1
            cv.cursorGlowOffsetX = 0
            cv.cursorGlowOffsetY = 0
            cv.cursorGlowAnchorX = 0.5
            cv.cursorGlowAnchorY = 0.5
            cv.cursorGlowColor = parent.cursorBackgroundColor ?? .selectedContentBackgroundColor
            let idx = parent.viewModel.cursorIndex
            if parent.cursorBeauty, parent.isActive,
               // Check the COLLECTION VIEW's own count, not the view model's: during a
               // directory change the model already holds the new list while the collection
               // view still has the old one, and layoutAttributesForItem(at:) does not
               // return nil for an out-of-range path — it raises an AppKit assertion and
               // kills the app.
               idx >= 0, cv.numberOfSections > 0, idx < cv.numberOfItems(inSection: 0),
               let attr = cv.layoutAttributesForItem(at: IndexPath(item: idx, section: 0)) {
                cv.cursorGlowFrame = attr.frame
            } else {
                cv.cursorGlowFrame = nil
            }
        }

        func affectedRenameIndexes(oldPath: String?, newPath: String?) -> Set<IndexPath> {
            var indexes: Set<IndexPath> = []
            if let oldPath,
               let oldIndex = parent.viewModel.items.firstIndex(where: { $0.path == oldPath }) {
                indexes.insert(IndexPath(item: oldIndex, section: 0))
            }
            if let newPath,
               let newIndex = parent.viewModel.items.firstIndex(where: { $0.path == newPath }) {
                indexes.insert(IndexPath(item: newIndex, section: 0))
            }
            return indexes
        }

        func refreshVisibleItems(in collectionView: NSCollectionView) {
            for item in collectionView.visibleItems() {
                guard let cell = item as? ThumbnailItem,
                      let indexPath = collectionView.indexPath(for: cell),
                      parent.viewModel.items.indices.contains(indexPath.item)
                else {
                    continue
                }
                let model = parent.viewModel.items[indexPath.item]
                configureCell(cell, with: model, index: indexPath.item)
            }
        }

        /// Only the cells a cursor step can change: the one it left, the one it arrived at,
        /// and the zoom band on either side.
        func refreshCursorBand(in collectionView: NSCollectionView, from old: Int, to new: Int) {
            let spread = PanelAppearanceSettings.resolvedCursorIconZoomSpread + 1
            let lower = min(old, new) - spread
            let upper = max(old, new) + spread
            for item in collectionView.visibleItems() {
                guard let cell = item as? ThumbnailItem,
                      let indexPath = collectionView.indexPath(for: cell),
                      parent.viewModel.items.indices.contains(indexPath.item),
                      indexPath.item >= lower, indexPath.item <= upper
                else { continue }
                configureCell(cell, with: parent.viewModel.items[indexPath.item],
                              index: indexPath.item)
            }
        }

        func scrollCursorToVisible(in collectionView: NSCollectionView, cursorIndex: Int, force: Bool) {
            let indexPath = IndexPath(item: cursorIndex, section: 0)
            collectionView.layoutSubtreeIfNeeded()
            if !force, isIndexPathVisible(indexPath, in: collectionView) {
                return
            }
            collectionView.scrollToItems(at: [indexPath], scrollPosition: [.nearestVerticalEdge, .nearestHorizontalEdge])
        }

        private func configureCell(_ cell: ThumbnailItem,
                                   with model: FileItem,
                                   index: Int) {
            let isCursor = index == parent.viewModel.cursorIndex && parent.isActive
            let isSelected = parent.viewModel.selectedPaths.contains(model.path)
            let isRenaming = parent.renamingPath == model.path
            // ".." chevron (template) tint = EXACTLY the ".." text colour.
            let iconTint: NSColor? = model.name == ".."
                ? (isCursor ? parent.cursorNameColor
                            : (isSelected ? PanelAppearanceSettings.selectedNameNSColor : parent.folderNameColor))
                : nil

            let previewImage = thumbnailProvider.image(
                for: model,
                previewSize: parent.previewSize,
                useQuickLookPreviews: parent.useQuickLookPreviews,
                folderIconStyle: parent.folderIconStyle,
                folderIconTintColor: parent.folderIconTintColor,
                upIconScale: parent.upIconScale,
                upIconSymbol: parent.upIconSymbol
            ) { [weak self, weak collectionView] _ in
                guard let self,
                      let collectionView,
                      let currentIndex = self.parent.viewModel.items.firstIndex(where: { $0.path == model.path })
                else {
                    return
                }
                collectionView.reloadItemsSafely(
                    at: [IndexPath(item: currentIndex, section: 0)],
                    expectedCount: self.parent.viewModel.items.count)
            }

            cell.configure(
                item: model,
                git: parent.viewModel.gitByPath[model.path],
                tags: parent.viewModel.tagsByPath[model.path] ?? [],
                image: previewImage,
                previewSize: parent.previewSize,
                iconTint: iconTint,
                folderNameColor: parent.folderNameColor,
                fileNameColor: parent.fileNameColor,
                cursorNameColor: parent.cursorNameColor,
                cursorBackgroundColor: parent.cursorBackgroundColor,
                isCursor: isCursor,
                cursorDistance: parent.isActive
                    ? abs(index - parent.viewModel.cursorIndex) : Int.max,
                isSelected: isSelected,
                isRenaming: isRenaming,
                renameText: parent.renameText,
                onRenameTextChanged: { [weak self] text in
                    self?.parent.onRenameTextChanged(text)
                },
                onCommitRename: { [weak self] in
                    self?.parent.onCommitRename(model)
                },
                onCancelRename: { [weak self] in
                    self?.parent.onCancelRename()
                }
            )
        }

        private func droppedFilePaths(from info: NSDraggingInfo) -> [String] {
            let pasteboard = info.draggingPasteboard
            let classes: [AnyClass] = [NSURL.self]
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            guard let urls = pasteboard.readObjects(forClasses: classes, options: options) as? [URL] else {
                return []
            }
            return Array(Set(urls.map(\.path)))
        }

        private func dropShouldMove(_ info: NSDraggingInfo) -> Bool {
            let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            if flags.contains(.command) || flags.contains(.shift) {
                return true
            }
            return info.draggingSourceOperationMask.contains(.move) &&
                !info.draggingSourceOperationMask.contains(.copy)
        }

        private func isIndexPathVisible(_ indexPath: IndexPath, in collectionView: NSCollectionView) -> Bool {
            if let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
                return collectionView.visibleRect.intersects(attributes.frame)
            }

            for item in collectionView.visibleItems() {
                guard let visibleIndexPath = collectionView.indexPath(for: item) else { continue }
                if visibleIndexPath == indexPath {
                    return true
                }
            }
            return false
        }

        func resetThumbnailCache() {
            thumbnailProvider.resetCache()
        }
    }
}

@MainActor
private final class ThumbnailProvider {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "avif"
    ]

    private static var iconCache: [String: NSImage] = [:]
    private static let iconCacheLock = NSLock()
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private static let fileIcon = NSWorkspace.shared.icon(for: .data)

    private var cache: [String: NSImage] = [:]
    private var inFlight: [String: [(NSImage) -> Void]] = [:]

    func image(for item: FileItem,
               previewSize: CGFloat,
               useQuickLookPreviews: Bool,
               folderIconStyle: FolderIconStyle,
               folderIconTintColor: NSColor?,
               upIconScale: CGFloat,
               upIconSymbol: String,
               onUpdate: @escaping (NSImage) -> Void) -> NSImage {
        // The ".." entry's path IS its parent folder's path, so keying on the path alone made
        // it collide with the real folder of that name: after going up out of TEMP, the cached
        // up-arrow was served to the actual TEMP folder sitting in the parent listing. The
        // isParent flag keeps the two apart.
        let isParent = item.name == ".."
        let cacheKey = "\(item.path)|parent\(isParent ? 1 : 0)|\(Int(previewSize.rounded()))|\(useQuickLookPreviews)|\(folderIconStyle.rawValue)|\(folderIconCacheToken(folderIconTintColor))|custom\(CustomFolderIconService.isEnabled)|us\(Int((upIconScale * 100).rounded()))|sym\(upIconSymbol)"
        if let cached = cache[cacheKey] {
            return cached
        }

        let targetSize = CGSize(width: previewSize, height: previewSize)
        let fallback = fallbackIcon(for: item, targetSize: targetSize, folderIconStyle: folderIconStyle, folderIconTintColor: folderIconTintColor, upIconScale: upIconScale)

        if item.isDirectory || item.name == ".." {
            cache[cacheKey] = fallback
            return fallback
        }

        guard useQuickLookPreviews else {
            cache[cacheKey] = fallback
            return fallback
        }

        var ext = item.fileExtension.lowercased()
        if ext.hasPrefix(".") { ext = String(ext.dropFirst()) }
        guard Self.imageExtensions.contains(ext) else {
            cache[cacheKey] = fallback
            return fallback
        }

        if inFlight[cacheKey] != nil {
            inFlight[cacheKey, default: []].append(onUpdate)
            return fallback
        }

        inFlight[cacheKey] = [onUpdate]
        let path = item.path

        Task.detached(priority: .utility) {
            let loaded = await Self.loadImageThumbnail(path: path, targetSize: targetSize) ?? fallback
            await MainActor.run {
                self.cache[cacheKey] = loaded
                let callbacks = self.inFlight.removeValue(forKey: cacheKey) ?? []
                for callback in callbacks {
                    callback(loaded)
                }
            }
        }

        return fallback
    }

    private static func loadImageThumbnail(path: String, targetSize: CGSize) async -> NSImage? {
        if let quickLookImage = await generateQuickLookThumbnail(path: path, targetSize: targetSize) {
            return scaled(image: quickLookImage, targetSize: targetSize)
        }
        if let image = NSImage(contentsOfFile: path) {
            return scaled(image: image, targetSize: targetSize)
        }
        return nil
    }

    private static func generateQuickLookThumbnail(path: String, targetSize: CGSize) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: targetSize,
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let representation else {
                    continuation.resume(returning: nil)
                    return
                }
                let cgImage = representation.cgImage
                let image = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
                continuation.resume(returning: image)
            }
        }
    }

    private static func scaled(image: NSImage, targetSize: CGSize) -> NSImage {
        let result = NSImage(size: targetSize)
        result.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        result.unlockFocus()
        return result
    }

    private static func icon(for item: FileItem, folderIconStyle: FolderIconStyle, folderIconTintColor: NSColor?) -> NSImage {
        if item.name == ".." {
            return PanelAppearanceSettings.upArrowIcon(size: 64)
        }
        if item.isAppBundle, FileManager.default.fileExists(atPath: item.path) {
            return AppIconCache.icon(path: item.path, size: 64)
        }
        if item.isDirectory {
            if let custom = CustomFolderIconService.icon(for: item, size: 64) { return custom }
            return FolderIconRenderer.image(
                style: folderIconStyle,
                size: 64,
                tintColor: folderIconTintColor
            )
        }

        var ext = item.fileExtension.lowercased()
        if ext.hasPrefix(".") { ext = String(ext.dropFirst()) }
        if ext.isEmpty {
            return fileIcon
        }

        iconCacheLock.lock()
        if let cached = iconCache[ext] {
            iconCacheLock.unlock()
            return cached
        }
        iconCacheLock.unlock()

        let resolved: NSImage
        if let contentType = UTType(filenameExtension: ext) {
            resolved = NSWorkspace.shared.icon(for: contentType)
        } else {
            resolved = fileIcon
        }

        iconCacheLock.lock()
        iconCache[ext] = resolved
        iconCacheLock.unlock()
        return resolved
    }

    private static func scaledImage(_ image: NSImage, targetSize: NSSize) -> NSImage {
        PanelAppearanceSettings.scaledImage(image, size: targetSize)
    }

    private func fallbackIcon(for item: FileItem,
                              targetSize: CGSize,
                              folderIconStyle: FolderIconStyle,
                              folderIconTintColor: NSColor?,
                              upIconScale: CGFloat) -> NSImage {
        if item.name == ".." {
            // Thin chevron drawn centred in the preview box → aligned with folders.
            return PanelAppearanceSettings.upArrowIcon(size: max(targetSize.width, targetSize.height), scale: upIconScale)
        }
        let source = Self.icon(for: item, folderIconStyle: folderIconStyle, folderIconTintColor: folderIconTintColor)
        return Self.scaledImage(
            source,
            targetSize: NSSize(width: targetSize.width, height: targetSize.height)
        )
    }

    private func folderIconCacheToken(_ folderIconTintColor: NSColor?) -> String {
        guard let folderIconTintColor else { return "none" }
        return PanelAppearanceSettings.hexString(from: folderIconTintColor)
    }

    func resetCache() {
        cache.removeAll(keepingCapacity: true)
        inFlight.removeAll(keepingCapacity: true)
    }
}

final class ThumbnailsCollectionView: NSCollectionView {

    /// Same reason as the detailed list: NSCollectionView's own selectAll: works on a selection
    /// model this panel does not use, so ⌘A must reach the panel controller instead.
    override func selectAll(_ sender: Any?) {
        _ = nextResponder?.tryToPerform(#selector(NSResponder.selectAll(_:)), with: sender)
    }

    var onItemClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    var onItemDoubleClick: ((Int) -> Void)?
    var onItemRightClick: ((Int, NSPoint) -> Void)?
    var onBackgroundClick: (() -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?
    var onVisibleWidthChanged: ((CGFloat) -> Void)?
    var selectedIndicesForDrag: (() -> [Int])?
    /// Called when a drag leaves or ends, so the coordinator can clear any drop-target ring.
    var onDragExited: (() -> Void)?

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragExited?()
        super.draggingEnded(sender)
    }

    // Feathered cursor glow (beauty mode), drawn behind the transparent cells so the soft
    // edges spill onto neighbours. Mirrors BriefCollectionView; shares FeatheredCursor.draw.
    var cursorGlowFrame: NSRect? { didSet { needsDisplay = true } }
    var cursorGlowColor: NSColor = .selectedContentBackgroundColor { didSet { needsDisplay = true } }
    var cursorGlowBlur: CGFloat = 0 { didSet { needsDisplay = true } }
    var cursorGlowHeightFraction: CGFloat = 0.8 { didSet { needsDisplay = true } }
    var cursorGlowWidthFraction: CGFloat = 1 { didSet { needsDisplay = true } }
    var cursorGlowCorner: CGFloat = 8 { didSet { needsDisplay = true } }
    var cursorGlowOffsetX: CGFloat = 0 { didSet { needsDisplay = true } }
    var cursorGlowOffsetY: CGFloat = 0 { didSet { needsDisplay = true } }
    var cursorGlowAnchorX: CGFloat = 0.5 { didSet { needsDisplay = true } }
    var cursorGlowAnchorY: CGFloat = 0.5 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let f = cursorGlowFrame else { return }
        FeatheredCursor.draw(cellFrame: f, color: cursorGlowColor,
                             blur: cursorGlowBlur, corner: cursorGlowCorner,
                             widthFraction: cursorGlowWidthFraction,
                             heightFraction: cursorGlowHeightFraction,
                             anchorX: cursorGlowAnchorX, anchorY: cursorGlowAnchorY,
                             offsetX: cursorGlowOffsetX, offsetY: cursorGlowOffsetY)
    }

    var lastContextMenuPoint: NSPoint = .zero
    var lastContextMenuIndexPath: IndexPath?

    // Drag tracking state
    private var mouseDownEvent: NSEvent?
    private var mouseDownIndexPath: IndexPath?
    private var dragInitiated = false
    private var deferredClickHandled = false

    // Custom double-click detection (uses DoubleClickSettings.currentInterval)
    private var lastClickItem: Int = -1
    private var lastClickTime: Date = .distantPast

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if let handler = keyHandler, handler(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func layout() {
        super.layout()
        let visibleWidth = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        onVisibleWidthChanged?(visibleWidth)
    }

    /// A press past the second detent, on the item under the finger.
    var onDeepPress: ((Int) -> Void)?
    private var deepPress = DeepPressDetector()

    override func pressureChange(with event: NSEvent) {
        super.pressureChange(with: event)
        guard deepPress.crossedIntoDeepPress(event) else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return }
        onDeepPress?(indexPath.item)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)

        mouseDownEvent = event
        mouseDownIndexPath = indexPath
        dragInitiated = false
        deferredClickHandled = false

        if let indexPath {
            let now = Date()
            let interval = DoubleClickSettings.currentInterval
            let isDoubleClick = (indexPath.item == lastClickItem
                                 && now.timeIntervalSince(lastClickTime) < interval)

            if isDoubleClick {
                onItemClick?(indexPath.item, event.modifierFlags)
                onItemDoubleClick?(indexPath.item)
                deferredClickHandled = true
                lastClickItem = -1
                lastClickTime = .distantPast
                mouseDownEvent = nil
                mouseDownIndexPath = nil
            } else {
                lastClickItem = indexPath.item
                lastClickTime = now
                // If clicked item is already in selection, defer the click handling
                // to mouseUp so drag can start with full multi-selection intact
                let isAlreadySelected: Bool
                if let indices = selectedIndicesForDrag?() {
                    isAlreadySelected = indices.contains(indexPath.item)
                } else {
                    isAlreadySelected = false
                }

                if isAlreadySelected && !event.modifierFlags.contains(.shift)
                    && !event.modifierFlags.contains(.command) {
                    deferredClickHandled = false
                } else {
                    onItemClick?(indexPath.item, event.modifierFlags)
                    deferredClickHandled = true
                }
            }
        } else {
            onBackgroundClick?()
            mouseDownEvent = nil
            mouseDownIndexPath = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragInitiated,
              let downEvent = mouseDownEvent,
              let downIndexPath = mouseDownIndexPath else { return }

        let downPoint = convert(downEvent.locationInWindow, from: nil)
        let currentPoint = convert(event.locationInWindow, from: nil)
        let dx = currentPoint.x - downPoint.x
        let dy = currentPoint.y - downPoint.y
        guard (dx * dx + dy * dy) >= 25 else { return }

        dragInitiated = true

        // Collect dragging items for ALL selected indices (multi-selection drag)
        var draggingItems: [NSDraggingItem] = []

        // Get selected indices from ViewModel; if none or clicked item not selected, use clicked item only
        var dragIndexPaths: [IndexPath]
        if let selectedIndices = selectedIndicesForDrag?(), !selectedIndices.isEmpty,
           selectedIndices.contains(downIndexPath.item) {
            dragIndexPaths = selectedIndices.sorted().map { IndexPath(item: $0, section: 0) }
        } else {
            dragIndexPaths = [downIndexPath]
        }

        for indexPath in dragIndexPaths {
            guard let writer = delegate?.collectionView?(self, pasteboardWriterForItemAt: indexPath) else {
                continue
            }
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            if let cellItem = item(at: indexPath) {
                let frame = convert(cellItem.view.bounds, from: cellItem.view)
                let image = NSImage(size: cellItem.view.bounds.size)
                if let rep = cellItem.view.bitmapImageRepForCachingDisplay(in: cellItem.view.bounds) {
                    cellItem.view.cacheDisplay(in: cellItem.view.bounds, to: rep)
                    image.addRepresentation(rep)
                }
                draggingItem.setDraggingFrame(frame, contents: image)
            }
            draggingItems.append(draggingItem)
        }

        guard !draggingItems.isEmpty else { return }
        beginDraggingSession(with: draggingItems, event: downEvent, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragInitiated && !deferredClickHandled, let indexPath = mouseDownIndexPath {
            onItemClick?(indexPath.item, event.modifierFlags)
        }
        mouseDownEvent = nil
        mouseDownIndexPath = nil
        dragInitiated = false
        deferredClickHandled = false
    }

    // MARK: – NSDraggingSource

    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy, .move]
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastContextMenuPoint = point
        lastContextMenuIndexPath = indexPathForItem(at: point)
        if let indexPath = lastContextMenuIndexPath {
            onItemRightClick?(indexPath.item, point)
        }
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        lastContextMenuPoint = convert(event.locationInWindow, from: nil)
        lastContextMenuIndexPath = indexPathForItem(at: lastContextMenuPoint)
        guard let menu = self.menu else { return super.menu(for: event) }
        menu.delegate?.menuNeedsUpdate?(menu)
        let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        ContextPopupMenuController.shared.show(menu, at: screenPoint)
        return nil
    }

    override func selectItems(at indexPaths: Set<IndexPath>, scrollPosition: NSCollectionView.ScrollPosition) {}

    override func deselectItems(at indexPaths: Set<IndexPath>) {}

    override var selectionIndexPaths: Set<IndexPath> {
        get { [] }
        set {}
    }
}

/// Из чего складывается вид ячейки — двумя частями, и это не мелочь.
///
/// Раньше цвет имени и готовая картинка жили в одном признаке: любое изменение выбрасывало
/// ВСЕ готовые эскизы, а выброшенный эскиз на миг становится обычным значком, пока читается
/// заново. Правило «гаснущая свежесть» просит перекраску каждые пятнадцать секунд — и
/// картинки в панели мигали раз в пятнадцать секунд, будто папка открывается заново.
enum ThumbnailAppearance {

    /// Признак самой картинки: её размер, предпросмотр, вид папок, стрелка «наверх».
    /// Изменился — готовые эскизы больше не годятся.
    static func pictureToken(previewSize: CGFloat, quickLook: Bool, folderTint: String,
                             upIconScale: CGFloat, upIconWeight: CGFloat,
                             upIconSymbol: String) -> String {
        "\(Int(previewSize.rounded()))-\(quickLook)-\(folderTint)"
            + "-us\(Int((upIconScale * 100).rounded()))"
            + "-uw\(Int(upIconWeight.rounded()))-sym\(upIconSymbol)"
    }

    /// Признак раскраски: цвета имён и курсора, красота, наплыв значка, шрифт списка и
    /// счётчик перекрасок. Изменился — ячейки перенастраиваются, эскизы остаются.
    static func paintToken(folderName: NSColor, fileName: NSColor, cursorName: NSColor,
                           cursorBackground: NSColor?, generation: Int) -> String {
        let cursorBg = cursorBackground.map { PanelAppearanceSettings.hexString(from: $0) } ?? "sys"
        let beauty = UserDefaults.standard.bool(forKey: PanelAppearanceSettings.beautyModeEnabledKey)
        return PanelAppearanceSettings.hexString(from: folderName)
            + "-" + PanelAppearanceSettings.hexString(from: fileName)
            + "-" + PanelAppearanceSettings.hexString(from: cursorName)
            + "-\(cursorBg)-beauty\(beauty ? 1 : 0)"
            + "-zoom\(Int(CursorIconZoom.effectiveScale * 100))"
            + "s\(PanelAppearanceSettings.resolvedCursorIconZoomSpread)"
            + "-\(PanelAppearanceSettings.listFontToken)-cg\(generation)"
    }
}

/// Где внутри квадратной ячейки стоят картинка и имя.
///
/// Курсор закрашивает ВСЮ ячейку, а картинка с именем занимают только её верх: при размере
/// 210 это 6 + 134 + 4 + строка имени — на пятьдесят точек меньше ячейки. Пустой остаток
/// оставался снизу, и подсветка выглядела сдвинутой вниз. Поэтому пустое место делится
/// пополам — сверху и снизу, и содержимое стоит в середине.
enum ThumbnailCellLayout {
    /// Наименьший отступ сверху: при мелком размере ячейки содержимое выше её самой, и
    /// тогда лучше прижать к верху, чем срезать картинке шапку.
    static let minimumTopInset: CGFloat = 6
    /// Зазор между картинкой и именем.
    static let iconToName: CGFloat = 4

    /// Высота под имя. По умолчанию одна строка: имя здесь именно в одну строку и
    /// обрезается многоточием (стиль абзаца — .byTruncatingTail), поэтому запас на вторую
    /// строку просто поднял бы содержимое выше середины на полстроки.
    static func nameHeight(font: NSFont, lines: Int = 1) -> CGFloat {
        let line = (font.ascender - font.descender + font.leading).rounded(.up)
        return max(line, 1) * CGFloat(max(lines, 1))
    }

    /// Отступ сверху, при котором картинка с именем стоят в середине ячейки.
    static func topInset(cellSize: CGFloat, previewSize: CGFloat, nameHeight: CGFloat,
                         gap: CGFloat = iconToName,
                         minimum: CGFloat = minimumTopInset) -> CGFloat {
        let content = previewSize + gap + nameHeight
        return max(minimum, ((cellSize - content) / 2).rounded())
    }
}

final class ThumbnailItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("thumbnail-item")

    override func loadView() {
        view = ThumbnailItemView()
    }

    private var thumbnailView: ThumbnailItemView {
        guard let view = view as? ThumbnailItemView else {
            fatalError("ThumbnailItemView is required")
        }
        return view
    }

    func configure(item: FileItem,
                   git: GitBadge?,
                   tags: [FinderTag],
                   image: NSImage,
                   previewSize: CGFloat,
                   iconTint: NSColor?,
                   folderNameColor: NSColor,
                   fileNameColor: NSColor,
                   cursorNameColor: NSColor,
                   cursorBackgroundColor: NSColor?,
                   isCursor: Bool,
                   cursorDistance: Int,
                   isSelected: Bool,
                   isRenaming: Bool,
                   renameText: String,
                   onRenameTextChanged: @escaping (String) -> Void,
                   onCommitRename: @escaping () -> Void,
                   onCancelRename: @escaping () -> Void) {
        thumbnailView.configure(
            item: item,
            git: git,
            tags: tags,
            image: image,
            previewSize: previewSize,
            iconTint: iconTint,
            folderNameColor: folderNameColor,
            fileNameColor: fileNameColor,
            cursorNameColor: cursorNameColor,
            cursorBackgroundColor: cursorBackgroundColor,
            isCursor: isCursor,
            cursorDistance: cursorDistance,
            isSelected: isSelected,
            isRenaming: isRenaming,
            renameText: renameText,
            onRenameTextChanged: onRenameTextChanged,
            onCommitRename: onCommitRename,
            onCancelRename: onCancelRename
        )
    }
}

final class ThumbnailItemView: NSView {

    /// The cell is one surface as far as the mouse is concerned.
    ///
    /// Its labels are NSTextFields, and a text field swallows the mouse sequence after the
    /// first click: the click itself still reached the list (selection worked), but the DRAG
    /// that followed never did — so a file could not be dragged out of this mode at all, while
    /// the same file dragged fine from the detailed list. Handing every point to the cell puts
    /// the whole sequence where the drag is started.
    ///
    /// The rename field is the one exception: while it is editing, it must have the mouse to
    /// place a text cursor.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let inside = super.hitTest(point)
        if let inside, inside === renameField || inside.isDescendant(of: renameField) {
            return inside
        }
        return inside == nil ? nil : self
    }
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let dotsView = NSImageView()
    /// Git's mark. The tag dots hold the icon's bottom-right corner, so this takes the top-left
    /// one — the two never meet, and both stay on the picture they belong to.
    private let gitView = NSImageView()
    private let renameField = InlineRenameThumbnailsField(frame: .zero)

    private var previewWidthConstraint: NSLayoutConstraint?
    private var previewHeightConstraint: NSLayoutConstraint?
    /// Отступ сверху — не постоянная величина: он держит содержимое в середине ячейки.
    private var iconTopConstraint: NSLayoutConstraint?
    private var displayedName = ""
    private var displayedIsDirectory = false
    private var displayedExtension = ""
    /// Цвет по правилам раскраски, посчитанный когда файл был ещё под рукой.
    private var displayedRuleColor: NSColor?
    // updateTextColor rebuilds the whole name: a link's marker and the tag dots are per-run
    // colours, and assigning .textColor would flatten both into one colour.
    private var displayedCleanName = ""
    private var displayedIsSymlink = false
    private var displayedVaultUnlocked: Bool?
    private var displayedIsHardlink = false
    private var displayedIsAlias = false
    private var displayedTags: [FinderTag] = []
    private var displayedGit = GitBadge()
    /// Width the plaque was last drawn for. The cell is wider than the picture it holds, and a
    /// branch name needs that width — "main" does not fit across a 64-point icon.
    private var plaqueWidth: CGFloat = 0
    private var folderNameColor: NSColor = .systemYellow
    private var fileNameColor: NSColor = .labelColor
    private var cursorBackgroundColor: NSColor?
    private var cursorNameColor: NSColor = .systemOrange

    private var cursorDistance: Int = .max
    var isCursor = false {
        didSet { needsDisplay = true }
    }
    var isItemSelected = false {
        didSet {
            updateTextColor()
            needsDisplay = true
        }
    }
    /// Set by the item while a drag hovers over this (folder) cell — draws the drop-target ring.
    var isDropTarget = false {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        // A cell subview must NOT be a drop destination. NSImageView (and NSTextField) register
        // for dragged types by default, and in icons/thumbnails the big icon covers the whole
        // cell — so a file dropped "on the folder" lands on the icon and is swallowed there, and
        // the collection view's acceptDrop never fires. (Brief's tiny 16pt icon rarely gets hit,
        // which is exactly why only the icon modes were broken.) Let drops fall through to the
        // collection view.
        iconView.unregisterDraggedTypes()

        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 2
        nameLabel.drawsBackground = false
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.unregisterDraggedTypes()

        renameField.font = .systemFont(ofSize: 11)
        renameField.translatesAutoresizingMaskIntoConstraints = false
        renameField.isHidden = true

        // Badged onto the thumbnail's corner rather than appended to the name: the name here wraps
        // to two lines and truncates, so anything at its end is exactly what gets cut.
        dotsView.translatesAutoresizingMaskIntoConstraints = false
        dotsView.imageScaling = .scaleNone

        addSubview(iconView)
        addSubview(nameLabel)
        gitView.translatesAutoresizingMaskIntoConstraints = false
        gitView.imageScaling = .scaleNone
        addSubview(dotsView)
        addSubview(gitView)
        addSubview(renameField)

        previewWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 64)
        previewHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 64)
        iconTopConstraint = iconView.topAnchor.constraint(equalTo: topAnchor,
                                                          constant: ThumbnailCellLayout.minimumTopInset)

        NSLayoutConstraint.activate([
            iconTopConstraint,
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),

            dotsView.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 3),
            dotsView.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 2),

            // ON the picture, not beside it: at the bottom-left corner of the icon, where the
            // tag dots (bottom-right) cannot reach it.
            gitView.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            gitView.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: -4),

            previewWidthConstraint,
            previewHeightConstraint,

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

            renameField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            renameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            renameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ].compactMap { $0 })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        centreContent()
        if abs(bounds.width - plaqueWidth) > 0.5 { refreshGitPlaque() }
    }

    /// Ставит картинку с именем в середину ячейки. Вызывается из layout() и после
    /// настройки: размер ячейки знает только layout, размер картинки — только configure.
    private func centreContent() {
        guard let iconTopConstraint, bounds.height > 0 else { return }
        let preview = previewHeightConstraint?.constant ?? 64
        let inset = ThumbnailCellLayout.topInset(
            cellSize: bounds.height,
            previewSize: preview,
            nameHeight: ThumbnailCellLayout.nameHeight(font: PanelAppearanceSettings.resolvedListFont()))
        // Ставим только при настоящем изменении: присваивание запускает новый проход
        // разметки, а он опять придёт сюда.
        guard abs(iconTopConstraint.constant - inset) > 0.5 else { return }
        iconTopConstraint.constant = inset
    }

    /// The Git plaque: drawn to lie ON the picture, and never wider than the cell holding it.
    private func refreshGitPlaque() {
        plaqueWidth = bounds.width
        let room = max(40, (plaqueWidth > 0 ? plaqueWidth : 64) - 8)
        gitView.image = GitBadgeChip.plaqueImage(displayedGit, font: .systemFont(ofSize: 11),
                                                 maxWidth: room)
        gitView.toolTip = displayedGit.isEmpty ? nil : GitBadgeChip.help(displayedGit)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Cursor bar FIRST, then the selection tint OVER it, so a marked file that is also the
        // cursor cell still shows its mark (Cmd-click / Space mark the file AND move the cursor
        // onto it — the old order hid the mark under the opaque cursor bar).
        //
        // Beauty mode draws a feathered cursor in the collection view (behind the cells),
        // so skip the flat fill here; otherwise paint the solid cursor bar as before.
        if isCursor && !UserDefaults.standard.bool(forKey: PanelAppearanceSettings.beautyModeEnabledKey) {
            (cursorBackgroundColor ?? .selectedContentBackgroundColor).setFill()
            bounds.fill()
        }

        if isItemSelected {
            let alpha: CGFloat = isCursor ? 0.42 : 0.25
            PanelAppearanceSettings.accentNSColor.withAlphaComponent(alpha).setFill()
            bounds.fill()
        }

        // Drop-target ring: a filled accent tint plus a bold accent border, so the folder the
        // drag will land in reads at a glance (drawn last, over everything else).
        if isDropTarget {
            let accent = PanelAppearanceSettings.accentNSColor
            let inset = bounds.insetBy(dx: 2, dy: 2)
            let ring = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
            accent.withAlphaComponent(0.20).setFill()
            ring.fill()
            accent.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    func configure(item: FileItem,
                   git: GitBadge?,
                   tags: [FinderTag],
                   image: NSImage,
                   previewSize: CGFloat,
                   iconTint: NSColor?,
                   folderNameColor: NSColor,
                   fileNameColor: NSColor,
                   cursorNameColor: NSColor,
                   cursorBackgroundColor: NSColor?,
                   isCursor: Bool,
                   cursorDistance: Int,
                   isSelected: Bool,
                   isRenaming: Bool,
                   renameText: String,
                   onRenameTextChanged: @escaping (String) -> Void,
                   onCommitRename: @escaping () -> Void,
                   onCancelRename: @escaping () -> Void) {
        self.isCursor = isCursor && !isRenaming
        self.cursorDistance = cursorDistance
        isItemSelected = isSelected
        displayedName = item.name
        displayedIsDirectory = item.isDirectory
        displayedExtension = item.fileExtension
        displayedRuleColor = FileTypeColorPalette.color(for: item,
                                                       folderColor: folderNameColor,
                                                       fileColor: fileNameColor)
        self.folderNameColor = folderNameColor
        self.fileNameColor = fileNameColor
        self.cursorNameColor = cursorNameColor
        self.cursorBackgroundColor = cursorBackgroundColor
        // Symlinks get the Finder-style arrow badge, same as the detailed list — the icon
        // must say "symlink" in every view mode, not just where the name is readable.
        if item.isSymlink, item.name != ".." {
            iconView.image = PanelViewController.symlinkBadgedIcon(image, size: image.size.width)
            iconView.contentTintColor = nil
        } else {
            iconView.image = image
            // The ".." chevron is a template; its colour comes from the tint (cursor
            // contrast on the cursor row, accent otherwise). nil for normal (baked) icons.
            iconView.contentTintColor = iconTint
        }
        // "Lift" the icon on the cursor cell (settings-gated); grows from its centre.
        CursorIconZoom.apply(to: iconView, scale: CursorIconZoom.scale(atDistance: cursorDistance))

        if previewWidthConstraint?.constant != previewSize {
            previewWidthConstraint?.constant = previewSize
        }
        if previewHeightConstraint?.constant != previewSize {
            previewHeightConstraint?.constant = previewSize
        }
        centreContent()

        if isRenaming {
            nameLabel.isHidden = true
            renameField.isHidden = false
            InlineRenameLook.apply(to: renameField, font: InlineRenameLook.font(matching: nameLabel.font))
            if renameField.stringValue != renameText {
                renameField.stringValue = renameText
            }
            renameField.onTextChanged = onRenameTextChanged
            renameField.onCommit = onCommitRename
            renameField.onCancel = onCancelRename

            DispatchQueue.main.async { [weak self, weak field = renameField] in
                // Уже правится — не трогать: первый ответчик здесь редактор поля, а не само
                // поле, и прежнее сравнение с полем было истинно всегда. Каждая перенастройка
                // ячейки заново выделяла всё имя, и каретку было не поставить щелчком.
                guard let self,
                      let field,
                      self.renameField.isHidden == false,
                      field.currentEditor() == nil
                else {
                    return
                }
                self.window?.makeFirstResponder(field)
                field.selectNamePart(originalName: self.displayedName, isDirectory: self.displayedIsDirectory)
                InlineRenameLook.styleEditor(of: field)
            }
        } else {
            renameField.isHidden = true
            nameLabel.isHidden = false
            displayedCleanName = item.name
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            displayedIsSymlink = item.isSymlink
            displayedIsHardlink = item.isHardlink
        displayedIsAlias = item.isAlias
            displayedVaultUnlocked = (item.name != ".." && VaultService.isVault(item.path))
                ? VaultService.isMountedFast(item.path) : nil
            displayedTags = tags
            displayedGit = git ?? GitBadge()
            updateTextColor()
        }
    }

    private func updateTextColor() {
        // Тот же приём, что в кратком виде: цвет по правилам приходит из configure, где
        // файл ещё цел.
        let normalColor = displayedRuleColor
            ?? (displayedIsDirectory ? folderNameColor : fileNameColor)
        // Selection wins over the cursor, so a marked file under the cursor still shows its mark.
        let resolvedColor = PanelAppearanceSettings.fileNameColor(
            isCursor: isCursor, isSelected: isItemSelected,
            cursor: cursorNameColor, selected: PanelAppearanceSettings.selectedNameNSColor, normal: normalColor)
        guard !displayedCleanName.isEmpty else {
            nameLabel.textColor = resolvedColor
            return
        }
        // Configured list font, enlarged by the cursor wave — full under the cursor,
        // easing down over the neighbours within reach.
        let font = PanelAppearanceSettings.resolvedListFont(atDistance: cursorDistance)
        let text: NSMutableAttributedString
        if let unlocked = displayedVaultUnlocked {
            text = NSMutableAttributedString(attributedString: PanelViewController.vaultAttributedName(
                displayedCleanName, font: font, color: resolvedColor, unlocked: unlocked))
        } else if displayedIsSymlink {
            let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            text = NSMutableAttributedString(attributedString: PanelViewController.symlinkAttributedName(
                displayedCleanName, font: italic, color: resolvedColor))
        } else if displayedIsAlias {
            text = NSMutableAttributedString(attributedString: PanelViewController.aliasAttributedName(
                displayedCleanName, font: font, color: resolvedColor))
        } else if displayedIsHardlink {
            text = NSMutableAttributedString(attributedString: PanelViewController.hardlinkAttributedName(
                displayedCleanName, font: font, color: resolvedColor))
        } else {
            text = NSMutableAttributedString(string: displayedCleanName,
                                             attributes: [.font: font, .foregroundColor: resolvedColor])
        }
        // The label is centred over the thumbnail; keep that when handing it an attributed string.
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        nameLabel.attributedStringValue = text
        // A touch larger than in the lists: the thumbnail cell is big, and the badge sits on
        // artwork rather than beside text.
        dotsView.image = FinderTagDots.image(displayedTags, font: .systemFont(ofSize: 15))
        refreshGitPlaque()
    }
}

private final class InlineRenameThumbnailsField: NSTextField, NSTextFieldDelegate {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTextChanged: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = true
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        alignment = .center
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func controlTextDidChange(_ obj: Notification) {
        onTextChanged?(stringValue)
    }

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onCommit?()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }

    func selectNamePart(originalName: String, isDirectory: Bool) {
        let range: NSRange
        if isDirectory {
            range = NSRange(location: 0, length: originalName.utf16.count)
        } else if let dotIndex = originalName.lastIndex(of: "."), dotIndex != originalName.startIndex {
            let baseName = originalName[..<dotIndex]
            range = NSRange(location: 0, length: baseName.utf16.count)
        } else {
            range = NSRange(location: 0, length: originalName.utf16.count)
        }

        guard let editor = currentEditor() else { return }
        editor.selectedRange = range
    }
}

// MARK: - Safe batch reload

extension NSCollectionView {
    /// `reloadItems(at:)` is a BATCH UPDATE: AppKit compares the count the data
    /// source reports now against the count it cached at the last reload, and
    /// raises NSInternalInconsistencyException when they disagree. That happens
    /// whenever the model changed size since the last reload — e.g. the user
    /// navigated into another folder while a rename or appearance update was
    /// still in flight.
    ///
    /// That exception is not survivable here, and the failure is invisible.
    /// It is raised inside a block being drained on the MAIN QUEUE; AppKit's
    /// top-level handler catches it so the process keeps running, but the drain
    /// never completes and the main queue is dead from that moment on. Every
    /// later DispatchQueue.main.async and every MainActor job silently never
    /// runs — so the panel keeps handling clicks (those are delivered
    /// synchronously) while directory loads never start, which reads to the
    /// user as "clicking a folder does nothing".
    ///
    /// Measured in the wild before this guard existed:
    ///   "Invalid update: invalid number of items in section 0. The number of
    ///    items contained in an existing section after the update (56) must be
    ///    equal to the number of items contained in that section before the
    ///    update (63), plus or minus the number inserted or deleted"
    /// followed by the main queue never being drained again.
    ///
    /// Reloading everything when the count moved is cheap and always correct.
    func reloadItemsSafely(at indexPaths: Set<IndexPath>, expectedCount: Int) {
        guard numberOfSections > 0,
              numberOfItems(inSection: 0) == expectedCount,
              indexPaths.allSatisfy({ $0.section == 0 && $0.item < expectedCount })
        else {
            reloadData()
            return
        }
        reloadItems(at: indexPaths)
    }
}
