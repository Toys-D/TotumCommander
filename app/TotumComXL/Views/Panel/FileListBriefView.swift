import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Custom Flow Layout (eliminates progressive spacing between items)

/// NSCollectionViewFlowLayout distributes leftover vertical pixels as extra
/// inter-item spacing when the collection height isn't an exact multiple of
/// itemSize.height.  This causes items to drift progressively from their
/// expected positions, creating visual gaps and click "dead zones."
///
/// BriefFlowLayout bypasses the default algorithm entirely and calculates
/// every item's frame from scratch:  column = index / rowsPerColumn,
/// row = index % rowsPerColumn,  y = row * itemHeight.
final class BriefFlowLayout: NSCollectionViewFlowLayout {

    private var cache: [NSCollectionViewLayoutAttributes] = []
    private var computedContentSize: NSSize = .zero

    /// True when the last prepare() bailed because the collection was still 0-height
    /// (mode-switch transient).  A zero content size suppresses the automatic
    /// bounds-change re-layout, so BriefCollectionView.layout() watches this flag and
    /// forces a re-prepare the moment a real height arrives.
    private(set) var lastLayoutWasDeferred = false

    override var collectionViewContentSize: NSSize { computedContentSize }

    override func prepare() {
        cache.removeAll(keepingCapacity: true)
        lastLayoutWasDeferred = false
        guard let cv = collectionView else {
            computedContentSize = .zero
            return
        }

        let sections = cv.numberOfSections
        guard sections > 0 else { computedContentSize = .zero; return }

        let totalItems = cv.numberOfItems(inSection: 0)
        guard totalItems > 0 else { computedContentSize = .zero; return }

        let h = itemSize.height
        let w = itemSize.width
        guard h > 0, w > 0 else { computedContentSize = .zero; return }

        let availableHeight = cv.bounds.height

        // During a view-mode switch the freshly-created collection is momentarily
        // 0-height (SwiftUI reconciles the new NSScrollView a frame later).  Laying out
        // now would divide by a ~0 height and pack every item into a single row — the
        // "folders in a row" flash.  Bail with an empty layout instead; when the real
        // height arrives the bounds change re-invokes prepare() and it lays out properly.
        guard availableHeight >= h else {
            lastLayoutWasDeferred = true
            computedContentSize = .zero
            return
        }

        let rowsPerColumn = max(1, Int(floor(availableHeight / h)))

        cache.reserveCapacity(totalItems)
        for i in 0..<totalItems {
            let col = i / rowsPerColumn
            let row = i % rowsPerColumn
            let attr = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: i, section: 0))
            attr.frame = NSRect(x: CGFloat(col) * w,
                                y: CGFloat(row) * h,
                                width: w,
                                height: h)
            cache.append(attr)
        }

        let totalColumns = (totalItems + rowsPerColumn - 1) / rowsPerColumn
        computedContentSize = NSSize(width: CGFloat(totalColumns) * w,
                                     height: availableHeight)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        cache.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item >= 0, indexPath.item < cache.count else { return nil }
        return cache[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let cv = collectionView else { return true }
        return cv.bounds.size != newBounds.size
    }
}

struct BriefNameParts {
    let baseName: String
    let extensionName: String
}

enum BriefNameLayout {
    static func parts(for name: String, isDirectory: Bool) -> BriefNameParts {
        let sanitizedName = sanitize(name)
        guard !isDirectory, sanitizedName != ".." else {
            return BriefNameParts(baseName: sanitizedName, extensionName: "")
        }

        guard let dotIndex = sanitizedName.lastIndex(of: "."),
              dotIndex != sanitizedName.startIndex,
              dotIndex < sanitizedName.index(before: sanitizedName.endIndex)
        else {
            return BriefNameParts(baseName: sanitizedName, extensionName: "")
        }

        let baseName = String(sanitizedName[..<dotIndex])
        let extensionName = String(sanitizedName[sanitizedName.index(after: dotIndex)...])
        return BriefNameParts(baseName: baseName, extensionName: extensionName)
    }

    static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}

@MainActor
struct FileListBriefView: NSViewRepresentable {
    @ObservedObject var viewModel: PanelViewModel
    let isActive: Bool
    let itemWidth: CGFloat
    let itemHeight: CGFloat
    let iconSize: CGFloat
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
    let cursorBeauty: Bool
    let cursorBlur: CGFloat
    let cursorHeightFraction: CGFloat
    let cursorWidthFraction: CGFloat
    let cursorCorner: CGFloat
    let cursorOffsetX: CGFloat
    let cursorOffsetY: CGFloat
    let cursorAnchorX: CGFloat
    let cursorAnchorY: CGFloat

    let renamingPath: String?
    let renameText: String
    let onRenameTextChanged: (String) -> Void
    let onCommitRename: (FileItem) -> Void
    let onCancelRename: () -> Void

    let onRowsPerColumnChanged: (Int) -> Void
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
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let layout = BriefFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        layout.itemSize = NSSize(width: itemWidth, height: itemHeight)

        let collectionView = BriefCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.isSelectable = false
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
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
        collectionView.onVisibleHeightChanged = { [weak coordinator = context.coordinator] visibleHeight in
            coordinator?.updateRowsPerColumn(forVisibleHeight: visibleHeight)
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
            BriefItem.self,
            forItemWithIdentifier: BriefItem.identifier
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
        guard let collectionView = scrollView.documentView as? BriefCollectionView,
              let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout
        else {
            return
        }

        context.coordinator.parent = self
        let appearanceToken = self.appearanceToken()
        if context.coordinator.lastAppearanceToken != appearanceToken {
            context.coordinator.lastAppearanceToken = appearanceToken
            context.coordinator.resetAppearanceCache()
            collectionView.reloadData()
        }
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
        collectionView.onVisibleHeightChanged = { [weak coordinator = context.coordinator] visibleHeight in
            coordinator?.updateRowsPerColumn(forVisibleHeight: visibleHeight)
        }

        if layout.itemSize.width != itemWidth || layout.itemSize.height != itemHeight {
            layout.itemSize = NSSize(width: itemWidth, height: itemHeight)
            layout.invalidateLayout()
        }

        context.coordinator.updateRowsPerColumn(forVisibleHeight: scrollView.contentView.bounds.height)

        // The tag scan finishes after the cells are already on screen, so a tag-only change has to
        // count as a reason to redraw — otherwise the dots appear only on the next folder change.
        if context.coordinator.lastItemCount != viewModel.items.count ||
            context.coordinator.lastPath != viewModel.currentPath ||
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
                collectionView.scrollToItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: .left)
            }
        }

        var needsVisibleRefresh = false

        let previousCursor = context.coordinator.lastCursorIndex
        let cursorChanged = previousCursor != viewModel.cursorIndex
        var cursorOnly = false
        if cursorChanged {
            context.coordinator.lastCursorIndex = viewModel.cursorIndex
            // A cursor step changes how a HANDFUL of cells look — the one it left, the one it
            // came to, and the zoom band around them. Everything else on screen is unchanged,
            // and in this mode "everything else" is most of a screenful.
            cursorOnly = true
        }

        if viewModel.scrollOnCursorChange,
           viewModel.items.indices.contains(viewModel.cursorIndex) {
            context.coordinator.scrollCursorToVisible(
                in: collectionView,
                cursorIndex: viewModel.cursorIndex,
                force: cursorChanged
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
        context.coordinator.updateCursorGlow()
        // Re-run after layout settles so the cursor frame is final.
        DispatchQueue.main.async { [weak c = context.coordinator] in c?.updateCursorGlow() }
    }

    private func folderTintCacheToken() -> String {
        guard let folderIconTintColor else { return "none" }
        return PanelAppearanceSettings.hexString(from: folderIconTintColor)
    }

    private func appearanceToken() -> String {
        let gap = Int(BriefItemView.currentIconNameGap())
        let cursorBg = cursorBackgroundColor.map { PanelAppearanceSettings.hexString(from: $0) } ?? "sys"
        // Only "beauty on/off" belongs here (the cell draws a solid cursor when off,
        // nothing when on). Blur/height are NOT in the token — they only affect the
        // collection's cursor drawing, so dragging them never triggers a cell reload.
        let beauty = UserDefaults.standard.bool(forKey: PanelAppearanceSettings.beautyModeEnabledKey) ? 1 : 0
        let stripes = PanelAppearanceSettings.resolvedAlternateRowColor()
            .map { PanelAppearanceSettings.hexString(from: $0) } ?? "off"
        return "\(Int(iconSize.rounded()))-\(folderIconStyle.rawValue)-\(folderTintCacheToken())-us\(Int((upIconScale * 100).rounded()))-uw\(Int(upIconWeight.rounded()))-sym\(upIconSymbol)-\(PanelAppearanceSettings.hexString(from: folderNameColor))-\(PanelAppearanceSettings.hexString(from: fileNameColor))-\(PanelAppearanceSettings.hexString(from: cursorNameColor))-\(cursorBg)-gap\(gap)-beauty\(beauty)-zoom\(Int(CursorIconZoom.effectiveScale * 100))s\(PanelAppearanceSettings.resolvedCursorIconZoomSpread)-\(PanelAppearanceSettings.listFontToken)-in\(Int(PanelAppearanceSettings.resolvedIconEdgeInset))-custom\(CustomFolderIconService.isEnabled)-alt\(stripes)-cg\(colorGeneration)"
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSMenuDelegate {
        var parent: FileListBriefView
        weak var collectionView: BriefCollectionView?

        var lastItemCount: Int
        var lastPath: String
        var lastCursorIndex: Int
        var lastSelectedPaths: Set<String>
        var lastIsActive: Bool
        var lastScrollResetToken: UInt64
        var lastSortToken: UInt64 = 0
        var lastTags: [String: [FinderTag]] = [:]
        var lastGit: [String: GitBadge] = [:]
        var lastRenamingPath: String?
        var lastRenameText: String
        var lastRowsPerColumn: Int = 1
        var lastAppearanceToken: String

        static var iconCache: [String: NSImage] = [:]
        static let iconCacheLock = NSLock()
        static var folderTintCache: [String: NSImage] = [:]
        static let folderTintCacheLock = NSLock()
        static let folderIcon = NSWorkspace.shared.icon(for: .folder)
        static let fileIcon = NSWorkspace.shared.icon(for: .data)

        /// The folder cell currently showing the drop-target ring, managed by hand (see the
        /// thumbnails view for the full why): the drop operation is always `.on` to avoid the
        /// `.before` insertion line, so we ring only a genuine folder under the pointer ourselves.
        private var dropFolderIP: IndexPath?

        func updateDropHighlight(to ip: IndexPath?, in cv: NSCollectionView) {
            guard ip != dropFolderIP else { return }
            if let old = dropFolderIP, let v = cv.item(at: old)?.view as? BriefItemView {
                v.isDropTarget = false
            }
            dropFolderIP = ip
            if let new = ip, let v = cv.item(at: new)?.view as? BriefItemView {
                v.isDropTarget = true
            }
        }

        init(_ parent: FileListBriefView) {
            self.parent = parent
            lastItemCount = parent.viewModel.items.count
            lastPath = parent.viewModel.currentPath
            lastCursorIndex = parent.viewModel.cursorIndex
            lastSelectedPaths = parent.viewModel.selectedPaths
            lastIsActive = parent.isActive
            lastScrollResetToken = parent.viewModel.scrollResetToken
            lastRenamingPath = parent.renamingPath
            lastRenameText = parent.renameText
            lastAppearanceToken = parent.appearanceToken()
            super.init()
        }

        /// Positions the feathered cursor at the cursor item (beauty mode), or hides it.
        func updateCursorGlow() {
            guard let cv = collectionView else { return }
            // Unconditional: a mask edit re-bakes the cursor IMAGE behind unchanged property
            // values, so the didSet-based repaints never fire. This is what keeps the live
            // preview alive — it was removed once as "pointless" and the preview died with it.
            cv.needsDisplay = true
            cv.alternateRowColor = PanelAppearanceSettings.resolvedAlternateRowColor()
            cv.alternateRowHeight = parent.itemHeight
            cv.alternateRowCount = lastRowsPerColumn
            cv.cursorGlowBlur = parent.cursorBlur   // may be 0 → sharp-edged bar
            cv.cursorGlowHeightFraction = parent.cursorHeightFraction
            cv.cursorGlowWidthFraction = parent.cursorWidthFraction
            cv.cursorGlowCorner = parent.cursorCorner
            cv.cursorGlowOffsetX = parent.cursorOffsetX
            cv.cursorGlowOffsetY = parent.cursorOffsetY
            cv.cursorGlowAnchorX = parent.cursorAnchorX
            cv.cursorGlowAnchorY = parent.cursorAnchorY
            cv.cursorGlowColor = parent.cursorBackgroundColor ?? .selectedContentBackgroundColor
            let idx = parent.viewModel.cursorIndex
            // Beauty mode owns the cursor (sized by height, feathered by blur) regardless
            // of the blur value; the frame is set whenever beauty is on.
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
                withIdentifier: BriefItem.identifier,
                for: indexPath
            )

            guard let briefItem = item as? BriefItem,
                  parent.viewModel.items.indices.contains(indexPath.item)
            else {
                return item
            }

            let model = parent.viewModel.items[indexPath.item]
            configureCell(briefItem, with: model, index: indexPath.item)
            return briefItem
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

            // ALWAYS `.on` a valid cell so NO `.before` insertion line is drawn (the user didn't
            // want that "insert between files" line — the detailed list never shows one). The
            // folder target, if any, is tracked above and read in acceptDrop; WE draw the ring.
            if count > 0 {
                let onIP = folderIP ?? hitIP ?? IndexPath(item: count - 1, section: 0)
                proposedDropIndexPath.pointee = onIP as NSIndexPath
                proposedDropOperation.pointee = .on
            } else {
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
            // indexPath is now always `.on` some cell (to suppress the insertion line). nil →
            // drop into the current directory.
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
            NSSize(width: parent.itemWidth, height: parent.itemHeight)
        }

        func collectionView(_ collectionView: NSCollectionView,
                            layout collectionViewLayout: NSCollectionViewLayout,
                            minimumLineSpacingForSectionAt section: Int) -> CGFloat {
            0
        }

        func collectionView(_ collectionView: NSCollectionView,
                            layout collectionViewLayout: NSCollectionViewLayout,
                            minimumInteritemSpacingForSectionAt section: Int) -> CGFloat {
            0
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

        func updateRowsPerColumn(forVisibleHeight visibleHeight: CGFloat) {
            let rows = max(1, Int(floor(visibleHeight / max(parent.itemHeight, 1))))
            if rows != lastRowsPerColumn {
                lastRowsPerColumn = rows
                collectionView?.alternateRowCount = rows
                parent.onRowsPerColumnChanged(rows)
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
                guard let briefItem = item as? BriefItem,
                      let indexPath = collectionView.indexPath(for: briefItem),
                      parent.viewModel.items.indices.contains(indexPath.item)
                else {
                    continue
                }
                configureCell(briefItem, with: parent.viewModel.items[indexPath.item], index: indexPath.item)
            }
        }

        /// Only the cells a cursor step can change: the one it left, the one it arrived at,
        /// and the zoom band on either side. The same shape the detailed list uses — this mode
        /// simply never got it, which is why a folder of programs felt heavy here and fine
        /// there.
        func refreshCursorBand(in collectionView: NSCollectionView, from old: Int, to new: Int) {
            let spread = PanelAppearanceSettings.resolvedCursorIconZoomSpread + 1
            let lower = min(old, new) - spread
            let upper = max(old, new) + spread
            for item in collectionView.visibleItems() {
                guard let briefItem = item as? BriefItem,
                      let indexPath = collectionView.indexPath(for: briefItem),
                      parent.viewModel.items.indices.contains(indexPath.item),
                      indexPath.item >= lower, indexPath.item <= upper
                else { continue }
                configureCell(briefItem, with: parent.viewModel.items[indexPath.item],
                              index: indexPath.item)
            }
        }

        func scrollCursorToVisible(in collectionView: NSCollectionView, cursorIndex: Int, force: Bool) {
            let indexPath = IndexPath(item: cursorIndex, section: 0)
            collectionView.layoutSubtreeIfNeeded()
            if !force, isIndexPathVisible(indexPath, in: collectionView) {
                return
            }
            collectionView.scrollToItems(
                at: [indexPath],
                scrollPosition: [.nearestVerticalEdge, .nearestHorizontalEdge]
            )
        }

        /// As wide as the widest mark in the folder, so the marks form a column.
        private var gitGutter: CGFloat {
            GitBadgeChip.gutterWidth(parent.viewModel.gitByPath.values,
                                     font: PanelAppearanceSettings.resolvedListFont(atDistance: .max))
        }

        private func configureCell(_ cell: BriefItem, with model: FileItem, index: Int) {
            let isCursor = index == parent.viewModel.cursorIndex && parent.isActive
            let isSelected = parent.viewModel.selectedPaths.contains(model.path)
            let isRenaming = parent.renamingPath == model.path
            // ".." chevron (template) tint = EXACTLY the ".." text colour.
            let iconTint: NSColor? = model.name == ".."
                ? (isCursor ? parent.cursorNameColor
                            : (isSelected ? PanelAppearanceSettings.selectedNameNSColor : parent.folderNameColor))
                : nil
            let cursorDistance = parent.isActive
                ? abs(index - parent.viewModel.cursorIndex) : Int.max
            cell.configure(
                item: model,
                tags: parent.viewModel.tagsByPath[model.path] ?? [],
                git: parent.viewModel.gitByPath[model.path],
                gitGutter: gitGutter,
                icon: icon(for: model),
                iconSize: parent.iconSize,
                iconTint: iconTint,
                folderNameColor: parent.folderNameColor,
                fileNameColor: parent.fileNameColor,
                cursorNameColor: parent.cursorNameColor,
                cursorBackgroundColor: parent.cursorBackgroundColor,
                isCursor: isCursor,
                cursorDistance: cursorDistance,
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

        private func icon(for item: FileItem) -> NSImage {
            if item.name == ".." {
                // Thin chevron centred in the regular icon box → aligned with folders.
                return PanelAppearanceSettings.upArrowIcon(size: parent.iconSize, scale: parent.upIconScale)
            }
            if item.isAppBundle, FileManager.default.fileExists(atPath: item.path) {
                // Remembered: this mode shows three times the rows the detailed one does, so
                // an uncached LaunchServices lookup per row is felt on every cursor move.
                return AppIconCache.icon(path: item.path, size: parent.iconSize)
            }
            if item.isDirectory {
                if let custom = CustomFolderIconService.icon(for: item, size: parent.iconSize) {
                    return custom
                }
                return FolderIconRenderer.image(
                    style: parent.folderIconStyle,
                    size: parent.iconSize,
                    tintColor: parent.folderIconTintColor
                )
            }

            var ext = item.fileExtension.lowercased()
            if ext.hasPrefix(".") { ext = String(ext.dropFirst()) }
            if ext.isEmpty {
                return Self.fileIcon
            }

            Self.iconCacheLock.lock()
            if let cached = Self.iconCache[ext] {
                Self.iconCacheLock.unlock()
                return cached
            }
            Self.iconCacheLock.unlock()

            let resolved: NSImage
            if let contentType = UTType(filenameExtension: ext) {
                resolved = NSWorkspace.shared.icon(for: contentType)
            } else {
                resolved = Self.fileIcon
            }

            Self.iconCacheLock.lock()
            Self.iconCache[ext] = resolved
            Self.iconCacheLock.unlock()
            return resolved
        }

        func resetAppearanceCache() {
            Self.folderTintCacheLock.lock()
            Self.folderTintCache.removeAll(keepingCapacity: true)
            Self.folderTintCacheLock.unlock()
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
    }
}

final class BriefCollectionView: NSCollectionView {

    /// Same reason as the detailed list: NSCollectionView's own selectAll: works on a selection
    /// model this panel does not use, so ⌘A must reach the panel controller instead.
    override func selectAll(_ sender: Any?) {
        _ = nextResponder?.tryToPerform(#selector(NSResponder.selectAll(_:)), with: sender)
    }

    var onItemClick: ((Int, NSEvent.ModifierFlags) -> Void)?

    // Feathered cursor glow, drawn behind the item cells (which are transparent) so it
    // spills onto neighbours while text stays readable. Drawn here — not via a
    // backgroundView — so the collection stays transparent and the panel background
    // shows through. Blits a cached baked image (FeatheredCursor); no per-frame blur.
    // Alternating-row bands. Every column shares the same row grid (y = row * itemHeight), so
    // the stripes are full-width horizontal bands — they run straight across the panel and line
    // up in every column by construction. Drawn below, before the cursor glow, in the same
    // background the transparent cells sit on.
    var alternateRowColor: NSColor? { didSet { needsDisplay = true } }
    var alternateRowHeight: CGFloat = 0 { didSet { needsDisplay = true } }
    var alternateRowCount: Int = 0 { didSet { needsDisplay = true } }

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

        if let alternateRowColor, alternateRowHeight > 1 {
            alternateRowColor.setFill()
            for row in stride(from: 1, to: alternateRowCount, by: 2) {
                let band = NSRect(x: bounds.minX, y: CGFloat(row) * alternateRowHeight,
                                  width: bounds.width, height: alternateRowHeight)
                guard band.intersects(dirtyRect) else { continue }
                band.fill()
            }
        }

        guard let f = cursorGlowFrame else { return }
        FeatheredCursor.draw(cellFrame: f, color: cursorGlowColor,
                             blur: cursorGlowBlur, corner: cursorGlowCorner,
                             widthFraction: cursorGlowWidthFraction,
                             heightFraction: cursorGlowHeightFraction,
                             anchorX: cursorGlowAnchorX, anchorY: cursorGlowAnchorY,
                             offsetX: cursorGlowOffsetX, offsetY: cursorGlowOffsetY)
    }
    var onItemDoubleClick: ((Int) -> Void)?
    var onItemRightClick: ((Int, NSPoint) -> Void)?
    var onBackgroundClick: (() -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?
    var onVisibleHeightChanged: ((CGFloat) -> Void)?
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
        // The layout deferred while the collection was 0-height (mode switch); now that a
        // real height is in, force it to re-lay-out immediately instead of waiting for an
        // automatic invalidation that a zero content size never delivers.
        if let flow = collectionViewLayout as? BriefFlowLayout,
           flow.lastLayoutWasDeferred,
           bounds.height >= flow.itemSize.height {
            flow.invalidateLayout()
        }
        let visibleHeight = enclosingScrollView?.contentView.bounds.height ?? bounds.height
        onVisibleHeightChanged?(visibleHeight)
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
                // Don't start drag tracking on double-click
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
                    // Defer click — keep selection for potential drag
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
        // NOTE: Do NOT call super.mouseDown — NSCollectionView enters a
        // blocking mouse-tracking loop that consumes all subsequent events
        // (breaks double-click, single-click responsiveness, etc.).
        // Drag is initiated manually in mouseDragged via beginDraggingSession.
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragInitiated,
              let downEvent = mouseDownEvent,
              let downIndexPath = mouseDownIndexPath else { return }

        let downPoint = convert(downEvent.locationInWindow, from: nil)
        let currentPoint = convert(event.locationInWindow, from: nil)
        let dx = currentPoint.x - downPoint.x
        let dy = currentPoint.y - downPoint.y
        guard (dx * dx + dy * dy) >= 25 else { return } // 5pt threshold

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
        // If click was deferred (selected item clicked without modifiers) and no drag happened,
        // process the click now to clear selection and set cursor
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

final class BriefItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("brief-item")

    override func loadView() {
        view = BriefItemView()
    }

    private var briefView: BriefItemView {
        guard let view = view as? BriefItemView else {
            fatalError("BriefItemView is required")
        }
        return view
    }

    func configure(item: FileItem,
                   tags: [FinderTag],
                   git: GitBadge?,
                   gitGutter: CGFloat,
                   icon: NSImage,
                   iconSize: CGFloat,
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
        briefView.configure(
            item: item,
            tags: tags,
            git: git,
            gitGutter: gitGutter,
            icon: icon,
            iconSize: iconSize,
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

final class BriefItemView: NSView {

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
    private let nameLabel = MarqueeTextField(labelWithString: "")
    private let extensionLabel = NSTextField(labelWithString: "")
    /// Tag dots live in their own view: at the tail of the extension label they were eaten by its
    /// truncation, and reserving room for them inside it starved the name.
    private let dotsView = NSImageView()
    /// Git's mark, in a gutter before the icon — the same column in every panel mode.
    private let gitView = NSImageView()
    private var gitWidthConstraint: NSLayoutConstraint!
    /// The branch of a repository folder, kept out of the gutter: a name is a dozen characters
    /// and would push every row of the folder aside for the sake of one.
    private let branchView = NSImageView()
    private var branchWidthConstraint: NSLayoutConstraint!
    /// The vault's lock, in the marks column beside the branch — the detailed list keeps it
    /// there too, so the two modes read the same way.
    private let lockView = NSImageView()
    private var lockWidthConstraint: NSLayoutConstraint!
    /// The icon-to-name gap now belongs to the gutter, which stands between them.
    private var gitLeadingConstraint: NSLayoutConstraint?
    private var dotsWidthConstraint: NSLayoutConstraint?
    private let renameField = InlineRenameBriefField(frame: .zero)
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?
    private var extensionWidthConstraint: NSLayoutConstraint?
    private var nameLeadingConstraint: NSLayoutConstraint?
    private var renameLeadingConstraint: NSLayoutConstraint?
    private var iconLeadingConstraint: NSLayoutConstraint?

    private var displayedName = ""
    private var displayedIsDirectory = false
    private var displayedExtension = ""
    /// Цвет по правилам раскраски, посчитанный когда файл был ещё под рукой.
    private var displayedRuleColor: NSColor?
    // Needed by updateTextColor: a link's name is an attributed string, and assigning
    // .textColor would throw it away (losing the italics and the 🔗).
    private var displayedIsSymlink = false
    private var displayedIsHardlink = false
    private var displayedIsAlias = false
    private var displayedBaseName = ""
    private var displayedExtensionText = ""
    private var displayedTags: [FinderTag] = []
    private var displayedGit = GitBadge()
    private var displayedGitGutter: CGFloat = 0
    private var folderNameColor: NSColor = .systemYellow
    private var fileNameColor: NSColor = .labelColor
    private var cursorNameColor: NSColor = .systemOrange
    private var cursorBackgroundColor: NSColor?
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

    static func currentIconNameGap() -> CGFloat {
        let raw = UserDefaults.standard.object(forKey: "iconNameGap") as? Double ?? 6
        return CGFloat(max(0, min(20, raw)))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        extensionLabel.font = .systemFont(ofSize: 12)
        extensionLabel.lineBreakMode = .byTruncatingTail
        extensionLabel.maximumNumberOfLines = 1
        extensionLabel.drawsBackground = false
        extensionLabel.isBezeled = false
        extensionLabel.isEditable = false
        extensionLabel.alignment = .left
        extensionLabel.cell?.wraps = false
        extensionLabel.cell?.usesSingleLineMode = true
        extensionLabel.cell?.truncatesLastVisibleLine = true
        extensionLabel.translatesAutoresizingMaskIntoConstraints = false
        extensionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        extensionLabel.setContentHuggingPriority(.required, for: .horizontal)

        renameField.font = .systemFont(ofSize: 12)
        renameField.translatesAutoresizingMaskIntoConstraints = false
        renameField.isHidden = true

        dotsView.translatesAutoresizingMaskIntoConstraints = false
        dotsView.imageScaling = .scaleNone
        dotsView.setContentHuggingPriority(.required, for: .horizontal)
        dotsView.setContentCompressionResistancePriority(.required, for: .horizontal)

        gitView.translatesAutoresizingMaskIntoConstraints = false
        gitView.imageScaling = .scaleNone
        gitView.imageAlignment = .alignLeft
        gitView.setContentHuggingPriority(.required, for: .horizontal)
        gitView.setContentCompressionResistancePriority(.required, for: .horizontal)
        branchView.translatesAutoresizingMaskIntoConstraints = false
        branchView.imageScaling = .scaleNone
        branchView.imageAlignment = .alignRight
        branchView.setContentHuggingPriority(.required, for: .horizontal)
        branchView.setContentCompressionResistancePriority(.required, for: .horizontal)
        lockView.translatesAutoresizingMaskIntoConstraints = false
        lockView.imageScaling = .scaleNone
        lockView.imageAlignment = .alignRight
        lockView.setContentHuggingPriority(.required, for: .horizontal)
        lockView.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(gitView)
        addSubview(branchView)
        addSubview(lockView)
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(extensionLabel)
        addSubview(dotsView)
        addSubview(renameField)

        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 14)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 14)
        extensionWidthConstraint = extensionLabel.widthAnchor.constraint(equalToConstant: 56)
        // Below required, so a narrow column shrinks the extension instead of breaking layout.
        extensionWidthConstraint?.priority = .defaultHigh
        dotsWidthConstraint = dotsView.widthAnchor.constraint(equalToConstant: 0)

        let gap = Self.currentIconNameGap()
        gitLeadingConstraint = gitView.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                                                constant: gap)
        nameLeadingConstraint = nameLabel.leadingAnchor.constraint(equalTo: gitView.trailingAnchor, constant: 0)
        renameLeadingConstraint = renameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: gap)
        gitWidthConstraint = gitView.widthAnchor.constraint(equalToConstant: 0)
        branchWidthConstraint = branchView.widthAnchor.constraint(equalToConstant: 0)
        lockWidthConstraint = lockView.widthAnchor.constraint(equalToConstant: 0)
        iconLeadingConstraint = iconView.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                                  constant: PanelAppearanceSettings.resolvedIconEdgeInset)

        NSLayoutConstraint.activate([
            // After the icon, exactly where the detailed mode puts it: the marks then stand in
            // one column beside the names instead of hanging off the panel's edge.
            gitLeadingConstraint,
            gitView.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitWidthConstraint,

            iconLeadingConstraint,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint,
            iconHeightConstraint,

            nameLeadingConstraint,
            nameLabel.trailingAnchor.constraint(equalTo: lockView.leadingAnchor, constant: -6),

            lockView.trailingAnchor.constraint(equalTo: branchView.leadingAnchor),
            lockView.centerYAnchor.constraint(equalTo: centerYAnchor),
            lockWidthConstraint,

            branchView.trailingAnchor.constraint(equalTo: dotsView.leadingAnchor),
            branchView.centerYAnchor.constraint(equalTo: centerYAnchor),
            branchWidthConstraint,
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // The EXTENSION owns the right edge — that is what makes extensions line up down
            // the column. Colour tags sit before it, where they push the name aside instead of
            // shoving the extension out of line: a marked file used to break the alignment of
            // its whole column.
            extensionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            extensionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            extensionWidthConstraint,

            dotsView.trailingAnchor.constraint(equalTo: extensionLabel.leadingAnchor, constant: -2),
            dotsView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotsWidthConstraint,

            // The name never collapses to nothing, however many tags a file carries.
            nameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),

            renameLeadingConstraint,
            renameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            renameField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ].compactMap { $0 })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        // Cursor bar FIRST, then the selection tint OVER it, so a marked file that is also the
        // cursor cell still shows its mark (Cmd-click / Space mark the file AND move the cursor
        // onto it — the old order hid the mark under the opaque cursor bar).
        //
        // Beauty mode draws the cursor on the collection (sized + feathered), so the cell
        // paints a plain solid cursor only when beauty is OFF.
        if isCursor && !UserDefaults.standard.bool(forKey: PanelAppearanceSettings.beautyModeEnabledKey) {
            (cursorBackgroundColor ?? .selectedContentBackgroundColor).setFill()
            bounds.fill()
        }

        if isItemSelected {
            let alpha: CGFloat = isCursor ? 0.42 : 0.25
            PanelAppearanceSettings.accentNSColor.withAlphaComponent(alpha).setFill()
            bounds.fill()
        }

        // Drop-target ring: accent tint + bold accent border on the folder a drag will land in.
        if isDropTarget {
            let accent = PanelAppearanceSettings.accentNSColor
            let inset = bounds.insetBy(dx: 2, dy: 1)
            let ring = NSBezierPath(roundedRect: inset, xRadius: 5, yRadius: 5)
            accent.withAlphaComponent(0.20).setFill()
            ring.fill()
            accent.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    func configure(item: FileItem,
                   tags: [FinderTag],
                   git: GitBadge?,
                   gitGutter: CGFloat,
                   icon: NSImage,
                   iconSize: CGFloat,
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
        displayedIsSymlink = item.isSymlink
        displayedIsHardlink = item.isHardlink
        displayedIsAlias = item.isAlias
        displayedExtension = item.fileExtension
        displayedRuleColor = FileTypeColorPalette.color(for: item,
                                                       folderColor: folderNameColor,
                                                       fileColor: fileNameColor)
        displayedTags = tags
        displayedGit = git ?? GitBadge()
        displayedGitGutter = gitGutter
        self.folderNameColor = folderNameColor
        self.fileNameColor = fileNameColor
        self.cursorNameColor = cursorNameColor
        self.cursorBackgroundColor = cursorBackgroundColor
        // Symlinks get the Finder-style arrow badge, same as the detailed list — the icon
        // must say "symlink" in every view mode, not just where the name is readable.
        if item.isSymlink, item.name != ".." {
            iconView.image = PanelViewController.symlinkBadgedIcon(icon, size: icon.size.width)
            iconView.contentTintColor = nil
        } else {
            iconView.image = icon
            // The ".." chevron is a template; its colour comes from the tint (cursor
            // contrast on the cursor row, accent otherwise). nil for normal (baked) icons.
            iconView.contentTintColor = iconTint
        }
        if iconWidthConstraint?.constant != iconSize {
            iconWidthConstraint?.constant = iconSize
        }
        if iconHeightConstraint?.constant != iconSize {
            iconHeightConstraint?.constant = iconSize
        }
        // "Lift" the icon on the cursor row (settings-gated); grows from centre, no reflow.
        CursorIconZoom.apply(to: iconView, scale: CursorIconZoom.scale(atDistance: cursorDistance))
        // Update icon-to-name gap from settings
        let gap = Self.currentIconNameGap()
        if gitLeadingConstraint?.constant != gap {
            gitLeadingConstraint?.constant = gap
            renameLeadingConstraint?.constant = gap
        }
        // Left inset of the icon from the panel edge (settings).
        let edgeInset = PanelAppearanceSettings.resolvedIconEdgeInset
        if iconLeadingConstraint?.constant != edgeInset {
            iconLeadingConstraint?.constant = edgeInset
        }

        if isRenaming {
            nameLabel.isHidden = true
            lockView.isHidden = true
            extensionLabel.isHidden = true
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
            lockView.isHidden = false
            let parts = BriefNameLayout.parts(for: item.name, isDirectory: item.isDirectory)
            displayedBaseName = parts.baseName
            displayedVaultUnlocked = (item.name != ".." && VaultService.isVault(item.path))
                ? VaultService.isMountedFast(item.path) : nil
            // Configured list font, enlarged by the cursor wave — full under the cursor,
            // easing down over the neighbours within reach.
            let baseFont = PanelAppearanceSettings.resolvedListFont(atDistance: self.cursorDistance)
            extensionLabel.font = baseFont
            if item.isSymlink {
                let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                nameLabel.attributedStringValue = PanelViewController.symlinkAttributedName(parts.baseName, font: italicFont, color: nameLabel.textColor)
            } else if item.isAlias {
                nameLabel.attributedStringValue = PanelViewController.aliasAttributedName(parts.baseName, font: baseFont, color: nameLabel.textColor)
            } else if item.isHardlink {
                nameLabel.attributedStringValue = PanelViewController.hardlinkAttributedName(parts.baseName, font: baseFont, color: nameLabel.textColor)
            } else {
                nameLabel.font = baseFont
                nameLabel.stringValue = parts.baseName
            }
            displayedExtensionText = parts.extensionName.isEmpty ? "" : ".\(parts.extensionName)"
            extensionLabel.isHidden = displayedExtensionText.isEmpty
            updateTextColor()
        }
    }

    private var displayedVaultUnlocked: Bool?

    private func updateTextColor() {
        // Цвет по правилам считается там, где ещё виден сам файл (configure), и хранится
        // здесь: у ячейки от него остаются только разложенные поля, а правилам нужны имя
        // и возраст целиком.
        let normalColor = displayedRuleColor
            ?? (displayedIsDirectory ? folderNameColor : fileNameColor)
        // Selection wins over the cursor, so a marked file under the cursor still shows its mark.
        let resolvedColor = PanelAppearanceSettings.fileNameColor(
            isCursor: isCursor, isSelected: isItemSelected,
            cursor: cursorNameColor, selected: PanelAppearanceSettings.selectedNameNSColor, normal: normalColor)
        // Same trap as the detailed list: for a link the name is an ATTRIBUTED string
        // (italic + a 🔗 attachment), and assigning .textColor replaces it with a plain
        // one — the marker would silently vanish on every colour refresh. Rebuild it.
        if displayedIsSymlink || displayedIsHardlink || displayedIsAlias,
           !displayedBaseName.isEmpty {
            let baseFont = PanelAppearanceSettings.resolvedListFont(atDistance: cursorDistance)
            if displayedIsSymlink {
                let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                nameLabel.attributedStringValue = PanelViewController.symlinkAttributedName(
                    displayedBaseName, font: italic, color: resolvedColor)
            } else if displayedIsAlias {
                nameLabel.attributedStringValue = PanelViewController.aliasAttributedName(
                    displayedBaseName, font: baseFont, color: resolvedColor)
            } else {
                nameLabel.attributedStringValue = PanelViewController.hardlinkAttributedName(
                    displayedBaseName, font: baseFont, color: resolvedColor)
            }
        } else {
            nameLabel.textColor = resolvedColor
        }
        extensionLabel.stringValue = displayedExtensionText
        extensionLabel.textColor = resolvedColor
        // The Git mark keeps the LIST's font: a gutter that widened under the cursor would
        // shift every name as the cursor went past.
        let gitFont = PanelAppearanceSettings.resolvedListFont(atDistance: .max)
        let gitTint: NSColor? = isCursor ? GitBadgeChip.cursorInk : nil
        gitView.image = displayedGit.mark.flatMap {
            GitBadgeChip.markImage($0, font: gitFont, tint: gitTint)
        }
        gitView.toolTip = displayedGit.mark?.localizedName
        if gitWidthConstraint?.constant != displayedGitGutter {
            gitWidthConstraint?.constant = displayedGitGutter
        }
        // The vault's lock stands in the marks column, the branch's size and ink, as in the
        // detailed list: it used to hang off the name and shrink with the row's font.
        let lockImage = displayedVaultUnlocked.flatMap {
            GitBadgeChip.vaultLockImage(unlocked: $0, font: gitFont, ink: gitTint ?? resolvedColor)
        }
        lockView.image = lockImage
        let lockWidth = lockImage.map { $0.size.width + 6 } ?? 0
        if lockWidthConstraint?.constant != lockWidth { lockWidthConstraint?.constant = lockWidth }
        branchView.image = GitBadgeChip.branchImage(displayedGit, font: gitFont, tint: gitTint)
        branchView.toolTip = displayedGit.branch == nil ? nil : GitBadgeChip.help(displayedGit)
        let branchWidth = GitBadgeChip.branchWidth(displayedGit, font: gitFont)
        if branchWidthConstraint?.constant != branchWidth {
            branchWidthConstraint?.constant = branchWidth
        }
        // Sized for the row's own font, so the dots grow with the text.
        let dotsFont = PanelAppearanceSettings.resolvedListFont(atDistance: cursorDistance)
        dotsView.image = FinderTagDots.image(displayedTags, font: dotsFont)
        let dotsWidth = FinderTagDots.width(displayedTags, font: dotsFont)
        if dotsWidthConstraint?.constant != dotsWidth { dotsWidthConstraint?.constant = dotsWidth }
        // Marquee scroll only on the cursor row when the name is truncated.
        if isCursor {
            nameLabel.startMarqueeIfOverflowing(delay: 1.5)
        } else {
            nameLabel.stopMarquee()
        }
    }
}

private final class InlineRenameBriefField: NSTextField, NSTextFieldDelegate {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTextChanged: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = true
        isBordered = false
        drawsBackground = false
        focusRingType = .none
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

