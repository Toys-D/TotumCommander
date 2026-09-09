import AppKit
import OSLog
import Combine
import SwiftUI
import UniformTypeIdentifiers

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

// MARK: - Custom NSTableView with key forwarding

/// NSTableView subclass that forwards key events and intercepts mouse clicks.
/// mouseDown override ensures click handling runs for ALL clicks, including
/// clickCount > 2 (which NSTableView normally swallows, preventing shouldSelectRow).
/// This fixes the "frozen cursor" bug after rapid double-click navigation.
final class PanelNSTableView: NSTableView {

    /// NSTableView implements selectAll: against its OWN selection model, which this panel does not
    /// use (shouldSelectRow returns false) — so it would swallow ⌘A and appear to do nothing.
    /// Passed up the chain to the panel controller, which selects the panel's marked files.
    override func selectAll(_ sender: Any?) {
        _ = nextResponder?.tryToPerform(#selector(NSResponder.selectAll(_:)), with: sender)
    }

    var keyHandler: ((NSEvent) -> Bool)?

    /// Поле переименования, пока оно открыто. Таблица по умолчанию не пускает щелчок в поле
    /// невыделенной строки (первый щелчок — выбрать строку, второй — править) и забирает
    /// его себе, а обработчик щелчка по строке закрывает правку. Щелчок по буквам должен
    /// ставить каретку, и ничего больше.
    weak var inlineRenameField: NSTextField?

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let field = inlineRenameField, let view = responder as? NSView,
           view === field || view.isDescendant(of: field) {
            return true
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }
    /// Returns true if the click caused navigation (double-click) — super.mouseDown is skipped.
    var clickHandler: ((_ row: Int, _ modifierFlags: NSEvent.ModifierFlags) -> Bool)?
    /// Called after mouseDown if user clicked a selected item without dragging (deferred deselect).
    var pendingDeselectHandler: (() -> Void)?
    /// Set to true by PanelViewController when a drag session begins.
    var dragDidStart = false
    /// Called when clicking empty area below the file list (no row hit).
    var emptyAreaClickHandler: (() -> Void)?
    /// A press past the second detent on this row — the trackpad's own "do it".
    var deepPressHandler: ((Int) -> Void)?
    private var deepPress = DeepPressDetector()

    override func pressureChange(with event: NSEvent) {
        super.pressureChange(with: event)
        guard deepPress.crossedIntoDeepPress(event) else { return }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return }
        deepPressHandler?(row)
    }

    // Feathered cursor glow (beauty mode). Painted into the table BACKGROUND — behind the
    // (transparent) rows — so its soft edges spill onto the neighbouring rows while the row
    // text stays on top and readable. Mirrors the collection-view cursor; shares
    // FeatheredCursor.draw so every view mode reacts to the settings identically.
    var cursorGlowRow: Int? { didSet { if oldValue != cursorGlowRow { needsDisplay = true } } }
    var cursorGlowColor: NSColor = .selectedContentBackgroundColor { didSet { needsDisplay = true } }
    var cursorGlowBlur: CGFloat = 0 { didSet { needsDisplay = true } }
    var cursorGlowHeightFraction: CGFloat = 0.8 { didSet { needsDisplay = true } }
    var cursorGlowWidthFraction: CGFloat = 1 { didSet { needsDisplay = true } }
    var cursorGlowCorner: CGFloat = 8 { didSet { needsDisplay = true } }
    var cursorGlowOffsetX: CGFloat = 0 { didSet { needsDisplay = true } }
    var cursorGlowOffsetY: CGFloat = 0 { didSet { needsDisplay = true } }
    var cursorGlowAnchorX: CGFloat = 0.5 { didSet { needsDisplay = true } }
    var cursorGlowAnchorY: CGFloat = 0.5 { didSet { needsDisplay = true } }

    /// Stripe colour for every other row; nil = striping off. Drawn HERE, in the background the
    /// transparent rows sit on, and strictly BEFORE the cursor glow below, so the glow composites
    /// over the stripes. Rows themselves never paint stripes: a row is a subview, and anything a
    /// row paints sits above this background and would cut the glow off.
    var alternateRowColor: NSColor? { didSet { needsDisplay = true } }

    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)

        if let alternateRowColor {
            alternateRowColor.setFill()
            for row in stride(from: 1, to: numberOfRows, by: 2) {
                let rowRect = rect(ofRow: row)
                guard rowRect.intersects(clipRect) else { continue }
                rowRect.fill()
            }
        }

        guard let row = cursorGlowRow, row >= 0, row < numberOfRows else { return }
        let rowRect = rect(ofRow: row)
        guard rowRect.width > 1, rowRect.height > 1 else { return }
        FeatheredCursor.draw(cellFrame: rowRect, color: cursorGlowColor,
                             blur: cursorGlowBlur, corner: cursorGlowCorner,
                             widthFraction: cursorGlowWidthFraction,
                             heightFraction: cursorGlowHeightFraction,
                             anchorX: cursorGlowAnchorX, anchorY: cursorGlowAnchorY,
                             offsetX: cursorGlowOffsetX, offsetY: cursorGlowOffsetY)
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Show the context menu as our CUSTOM popover (submenus open on click, accent)
    /// instead of the native NSMenu. The delegate still builds the items.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = self.menu else { return super.menu(for: event) }
        // Tell the delegate which row was right-clicked, then let it build the same
        // items it would for the native menu.
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        let pvc = menu.delegate as? PanelViewController
        pvc?.contextMenuRowOverride = row >= 0 ? row : nil
        menu.delegate?.menuNeedsUpdate?(menu)
        pvc?.contextMenuRowOverride = nil
        let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        ContextPopupMenuController.shared.show(menu, at: screenPoint)
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        dragDidStart = false
        let point = convert(event.locationInWindow, from: nil)
        var row = self.row(at: point)

        // Fallback: macOS 11+ can return -1 for pixels between rows even with
        // intercellSpacing = 0 (known AppKit issue with .plain style).
        // Calculate row from ACTUAL row geometry (rect(ofRow:)) instead of
        // self.rowHeight, which may not match macOS internal layout.
        if row < 0 && numberOfRows > 0 {
            let firstRect = self.rect(ofRow: 0)
            let actualRowPitch: CGFloat
            if numberOfRows > 1 {
                actualRowPitch = self.rect(ofRow: 1).minY - firstRect.minY
            } else {
                actualRowPitch = firstRect.height
            }
            if actualRowPitch > 0 && point.y >= firstRect.minY {
                let calculated = Int((point.y - firstRect.minY) / actualRowPitch)
                if calculated >= 0 && calculated < numberOfRows {
                    row = calculated
                }
            }
        }

        if row >= 0, let handler = clickHandler {
            if handler(row, event.modifierFlags) {
                // Double-click caused navigation — skip super to avoid stale data
                return
            }
        } else if row < 0 {
            // Click on empty area below file list — activate panel
            emptyAreaClickHandler?()
        }
        super.mouseDown(with: event)

        // super.mouseDown returns when the drag session starts OR on mouse-up. The drag's
        // draggingSession(willBeginAt:) — which sets dragDidStart — can fire on the runloop
        // turn AFTER super.mouseDown returns, so checking dragDidStart synchronously here
        // would clear the selection a moment BEFORE the drag begins (dragging the whole
        // multi-selection then breaks — only the clicked item survives). Defer the check one
        // runloop turn: by then a real drag has set the flag and we keep the selection; a
        // plain click (no drag) leaves it false and the deselect runs as intended.
        let deselect = pendingDeselectHandler
        pendingDeselectHandler = nil
        if let deselect {
            RunLoop.main.perform { [weak self] in
                guard let self, !self.dragDidStart else { return }
                deselect()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if let keyHandler, keyHandler(event) {
            return  // Handled by PanelViewController
        }
        super.keyDown(with: event)
    }
}


/// AppKit-native panel with NSTableView, connected directly to PanelViewModel.
/// Layout (top to bottom): VolumeBar → Breadcrumb → TabBar → SortBar → FileList → StatusBar
final class PanelViewController: NSViewController,
                                  NSTableViewDelegate,
                                  NSTableViewDataSource,
                                  NSMenuDelegate,
                                  NSMenuItemValidation,
                                  NSTextFieldDelegate {

    let viewModel: PanelViewModel
    let tabsVM: PanelTabsViewModel
    let side: MainSplitViewController.PanelSide

    weak var actionDelegate: PanelActionDelegate?

    var isActivePanel: Bool = false {
        didSet {
            guard oldValue != isActivePanel else { return }
            if !isActivePanel { cancelInlineRename() }
            refreshVisibleRowStates()
            updateTabBarActiveState()
            updateAlternateHosting()
            if isActivePanel {
                claimFirstResponder()
            }
        }
    }
    var onBecameActive: (() -> Void)?

    private var scrollView: NSScrollView!
    /// Подписки на ход обхода сети — снимаются вместе с контроллером.
    private var networkBannerObservers: [NSObjectProtocol] = []
    /// Полоса «ищем компьютеры» / «никого не нашли» поверх пустого списка.
    private var networkBannerHost: NSHostingView<NetworkBrowseBanner>?
    /// Надпись поверх пустого списка: почему он пуст.
    ///
    /// Раньше причина уходила в журнал, а человек видел пустую панель и гадал, куда делись
    /// его файлы. Пустая папка и оборванная связь выглядели одинаково.
    private var troubleLabel: NSTextField!
    private(set) var tableView: PanelNSTableView!
    private var alternateHosting: NSHostingView<AnyView>?
    private var alternateTopConstraint: NSLayoutConstraint?
    private var alternateBottomConstraint: NSLayoutConstraint?
    private var terminalContainers: [UUID: SwiftTermContainerView] = [:]
    private var activeTerminalID: UUID?
    private var monitorHosting: NSHostingView<AnyView>?
    private(set) var isMonitorMode = false
    private lazy var monitorService = SystemMonitorService()
    private var statusBarToScrollViewConstraint: NSLayoutConstraint!
    private var eventMonitor: Any?
    /// Shift + two-finger swipe over this panel — see SwipeNavigator.
    private var swipeMonitor: Any?
    private var swipe = SwipeNavigator()

    /// Rows per column in brief mode (updated by FileListBriefView callback)
    private var briefRowsPerColumn: Int = 1
    /// Columns per row in thumbnails/icons mode (updated by FileListThumbnailsView callback)
    private var thumbnailColumnsPerRow: Int = 1
    private var cancellables = Set<AnyCancellable>()

    // Custom double-click detection (uses DoubleClickSettings.currentInterval)
    private var lastClickRow: Int = -1
    private var lastClickTime: Date = .distantPast
    /// Guards against double-firing of activateItem from multiple detection layers
    private var lastActivationTime: Date = .distantPast
    private var lastActivationPath: String = ""
    /// A brief/icons/thumbnails click is delivered to us TWICE: first by the window's
    /// event monitor (the guaranteed path), then again by the collection view's own
    /// mouseDown. Both used to call handleRowClick, so Cmd — a TOGGLE — fired twice and
    /// cancelled itself out (mark on, mark off) while Shift, an idempotent range insert,
    /// survived. The monitor stamps the click here; the collection view's handler skips a
    /// click the monitor already processed, and still runs as a fallback if it didn't.
    private var monitorHandledClickRow: Int = -1
    private var monitorHandledClickTime: Date = .distantPast

    // Launch spinner (small floating window following cursor)
    private var launchSpinnerWindow: NSWindow?
    private var launchSpinnerMouseMonitor: Any?
    private var launchSpinnerLocalMonitor: Any?

    // SwiftUI hosted bars
    private var tabBarHosting: NSHostingView<PanelTabsBarView>!
    private var volumeBarHosting: NSHostingView<PanelVolumeBar>!
    private var breadcrumbHosting: NSHostingView<PanelBreadcrumbBar>!
    private var sortBarHosting: NSHostingView<SortBarView>!
    private var statusBarHosting: NSHostingView<PanelStatusBar>!

    // MARK: - Appearance Settings (resolved from UserDefaults)
    private var resolvedFolderNameColor: NSColor = .systemYellow
    private var resolvedFileNameColor: NSColor = .labelColor
    private var resolvedCursorNameColor: NSColor = .systemOrange
    /// nil = use the system selection color (default look).
    /// Finder tags for the rows on screen, keyed by path.
    ///
    /// Filled in the background after a listing loads and read straight from memory while drawing:
    /// a tag lives in an extended attribute, and reading one per visible row on every scroll frame
    /// would put file I/O in the draw path.

    private var resolvedCursorBackgroundColor: NSColor?
    private var resolvedFolderIconTintColor: NSColor?
    private var resolvedFolderIconStyle: FolderIconStyle = .macos
    private var resolvedIconScale: CGFloat = 1.0
    private var resolvedUpIconScale: CGFloat = 1.0
    private var resolvedRowHeight: CGFloat = 26
    private var resolvedIconNameGap: CGFloat = 6
    private var resolvedPanelBackgroundColor: NSColor = .controlBackgroundColor
    /// nil when striping is off.
    private var resolvedAlternateRowColor: NSColor?
    private var isDistributingColumns = false
    /// Current horizontal scroll offset of the detailed table — mirrored to the
    /// SortBar so column headers scroll in sync with the data.
    private var detailedHScroll: CGFloat = 0

    // MARK: - Inline Rename State
    private var renamingItem: FileItem?
    private var renameText: String = ""
    private var inlineRenameField: NSTextField?
    private var inlineRenameOKButton: NSButton?

    // Icon cache
    private static var iconCache: [String: NSImage] = [:]

    /// Extensions whose icon lookup is already running — keeps duplicate rows
    /// from each starting their own identical load. Main-thread only, like the
    /// cache itself.
    private static var iconLoadsInFlight: Set<String> = []
    private static let fileIcon = NSWorkspace.shared.icon(for: .data)

    // Date formatter
    private lazy var dateFormatter: DateFormatter = {
        let df = DateFormatter.fcxlDisplay(date: .short, time: .short)
        return df
    }()

    // MARK: - Init

    init(viewModel: PanelViewModel, tabsVM: PanelTabsViewModel, side: MainSplitViewController.PanelSide) {
        self.viewModel = viewModel
        self.tabsVM = tabsVM
        self.side = side
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - Lifecycle

    override func loadView() {
        // Load appearance settings BEFORE creating columns/table
        reloadAppearanceFromDefaults()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
        container.wantsLayer = true
        container.layer?.backgroundColor = resolvedPanelBackgroundColor.cgColor
        container.layer?.masksToBounds = true

        // Volume bar (top)
        let volumeBar = PanelVolumeBar(
            viewModel: viewModel,
            onNetwork: { [weak self] in
                self?.actionDelegate?.panelDidRequestNetwork(self!)
            },
            onConnectNetworkDrive: { [weak self] in self?.connectNetworkDrive() },
            onLocalNetwork: { [weak self] in self?.openLocalNetwork() },
            onSwitchToRemoteTab: { [weak self] in
                guard let self else { return }
                // Find the remote tab and switch to it
                if let idx = self.tabsVM.tabs.firstIndex(where: { $0.isRemote }) {
                    self.handleSelectTab(idx)
                }
            },
            onDisconnectRemote: { [weak self] in
                guard let self else { return }
                self.viewModel.exitRemote()
                self.tabsVM.closeRemoteTabs()
                // Refresh the new active tab's content
                let newTab = self.tabsVM.activeTab
                self.viewModel.loadDirectory(at: newTab.path)
            },
            onOpenNetworkVolume: { [weak self] in self?.openNetworkMount(at: $0) },
            onOpenForeignRemote: { [weak self] connection in
                guard let self else { return }
                self.actionDelegate?.panelDidRequestOpenRemote(self, connection: connection)
            },
            onDisconnectForeignRemote: { [weak self] session in
                guard let self else { return }
                self.actionDelegate?.panelDidRequestDisconnectRemote(self, session: session)
            }
        )
        volumeBarHosting = NSHostingView(rootView: volumeBar)
        volumeBarHosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(volumeBarHosting)

        // Breadcrumb bar
        let breadcrumb = PanelBreadcrumbBar(
            state: viewModel.state,
            viewModel: viewModel,
            onDismiss: { [weak self] in self?.claimFirstResponder() }
        )
        breadcrumbHosting = NSHostingView(rootView: breadcrumb)
        breadcrumbHosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(breadcrumbHosting)

        // Tab bar (after breadcrumbs)
        let tabBar = PanelTabsBarView(
            tabsVM: tabsVM,
            isPanelActive: isActivePanel,
            onNewTab: { [weak self] in self?.handleNewTab() },
            onSelectTab: { [weak self] in self?.handleSelectTab($0) },
            onCloseTab: { [weak self] in self?.handleCloseTab($0) },
            onShowFavorites: { [weak self] in
                self?.showFavoriteFoldersMenu(at: NSEvent.mouseLocation)
            },
            currentViewModeRaw: viewModel.viewMode.rawValue
        )
        tabBarHosting = NSHostingView(rootView: tabBar)
        tabBarHosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabBarHosting)

        // Sort bar
        sortBarHosting = NSHostingView(rootView: makeSortBarView())
        sortBarHosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sortBarHosting)

        // Table (detailed mode) — always in the constraint chain for height
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = resolvedPanelBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView = PanelNSTableView()
        tableView.style = .plain
        tableView.rowSizeStyle = .custom   // Force exact rowHeight (prevent macOS auto-sizing with gaps)
        tableView.rowHeight = effectiveRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = resolvedPanelBackgroundColor
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.headerView = nil

        // Drag & drop support (local file URLs + remote custom type)
        tableView.registerForDraggedTypes([.fileURL, Self.remotePathsType, Self.archivePathsType])
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

        // Forward key events from table to our handler
        tableView.keyHandler = { [weak self] event -> Bool in
            guard let self else { return false }
            return self.handleKeyEvent(event)
        }
        // Note: panel activation on mouse click is handled by eventMonitor in viewDidLoad
        // (covers clicks on any part of the panel, not just the table)

        setupColumns()

        troubleLabel = NSTextField(labelWithString: "")
        troubleLabel.translatesAutoresizingMaskIntoConstraints = false
        troubleLabel.alignment = .center
        troubleLabel.font = .systemFont(ofSize: 12)
        troubleLabel.textColor = .secondaryLabelColor
        troubleLabel.lineBreakMode = .byWordWrapping
        troubleLabel.maximumNumberOfLines = 4
        troubleLabel.isHidden = true

        tableView.delegate = self
        tableView.dataSource = self

        // Empty area click — clear the marked selection and activate the panel.
        // The deep press is a command, and the command it gives is the one the user chose.
        // Straight into activateItem — the single activation path double-click and Enter take,
        // with everything it knows about archives, the viewer and the launch spinner.
        tableView.deepPressHandler = { [weak self] row in
            self?.handleDeepPress(row: row)
        }

        tableView.emptyAreaClickHandler = { [weak self] in
            self?.handleEmptyAreaClick()
        }

        // Click/double-click handling via mouseDown override (always fires, even for clickCount > 2).
        // Returns true if double-click caused navigation (skip super.mouseDown).
        tableView.clickHandler = { [weak self] row, flags -> Bool in
            guard let self, self.viewModel.items.indices.contains(row) else { return false }

            let now = Date()
            let interval = DoubleClickSettings.currentInterval
            if row == self.lastClickRow && now.timeIntervalSince(self.lastClickTime) < interval {
                // Double-click → navigate
                self.lastClickRow = -1
                self.lastClickTime = .distantPast
                self.activateItem(self.viewModel.items[row])
                return true
            }

            self.lastClickRow = row
            self.lastClickTime = now
            self.handleRowClick(row: row, flags: flags)
            self.onBecameActive?()
            return false
        }

        // Accessibility
        tableView.setAccessibilityLabel(L("accessibility.file_list"))
        tableView.setAccessibilityIdentifier("panel-\(side == .left ? "left" : "right")-file-list")

        // Context menu
        let contextMenu = NSMenu(title: "")
        contextMenu.delegate = self
        tableView.menu = contextMenu

        scrollView.documentView = tableView
        container.addSubview(scrollView)
        container.addSubview(troubleLabel)

        // alternateHosting created lazily in applyViewMode() for non-detailed modes

        // Status bar
        let statusBar = PanelStatusBar(viewModel: viewModel)
        statusBarHosting = NSHostingView(rootView: statusBar)
        statusBarHosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusBarHosting)

        NSLayoutConstraint.activate([
            // Top bars: Volume → Breadcrumb → Tabs → Sort
            volumeBarHosting.topAnchor.constraint(equalTo: container.topAnchor),
            volumeBarHosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            volumeBarHosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            breadcrumbHosting.topAnchor.constraint(equalTo: volumeBarHosting.bottomAnchor),
            breadcrumbHosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            breadcrumbHosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            tabBarHosting.topAnchor.constraint(equalTo: breadcrumbHosting.bottomAnchor),
            tabBarHosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBarHosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            sortBarHosting.topAnchor.constraint(equalTo: tabBarHosting.bottomAnchor),
            sortBarHosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sortBarHosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            // ScrollView — sole vertical filler between sortBar and statusBar
            scrollView.topAnchor.constraint(equalTo: sortBarHosting.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            // Надпись о беде — посреди пустого списка, где человек и ищет свои файлы.
            troubleLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            troubleLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            troubleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor,
                                                  constant: 24),
            troubleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                                   constant: -24),

            // Status bar (leading, trailing, bottom are permanent; top switches between scrollView/alternateHosting)
            statusBarHosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBarHosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBarHosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Status bar top constraint — attached to scrollView by default, switches when alternateHosting is shown
        statusBarToScrollViewConstraint = statusBarHosting.topAnchor.constraint(equalTo: scrollView.bottomAnchor)
        statusBarToScrollViewConstraint.isActive = true

        self.view = container
    }

    // MARK: - Edit menu (file semantics)


    /// Cut/Copy/Paste/Select All when the FILE LIST holds the keyboard.
    ///
    /// These are the standard first-responder selectors, so the Edit menu can dispatch them to nil
    /// and let whoever has focus answer: a text field's editor gives text semantics, this gives
    /// file semantics. That is how macOS wires the Edit menu everywhere, and it is what keeps the
    /// two from ever being confused — pointing the menu items at file-only handlers hijacked ⌘C
    /// and ⌘V inside every text field in the app, including inline rename.
    ///
    /// They call exactly what the panel's own key handling calls, so menu, shortcut and command
    /// palette cannot drift apart.
    @objc func copy(_ sender: Any?) {
        guard !viewModel.insideArchive else { return }
        copySelectedFilesToClipboard()
    }

    @objc func cut(_ sender: Any?) {
        guard !viewModel.insideArchive else { return }
        cutSelectedFilesToClipboard()
    }

    @objc func paste(_ sender: Any?) {
        guard !viewModel.insideArchive else { return }
        actionDelegate?.panelDidRequestPasteFromClipboard(self)
    }

    @objc override func selectAll(_ sender: Any?) {
        viewModel.selectAll()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return !viewModel.insideArchive && !viewModel.operationTargets.isEmpty
        case #selector(paste(_:)):
            return !viewModel.insideArchive && clipboardHasFiles
        case #selector(selectAll(_:)):
            return !viewModel.items.isEmpty
        default:
            return true
        }
    }

    /// Is there anything for the clipboard paste to work with? The same two sources the paste path
    /// itself reads: a payload copied from a remote panel, or file URLs on the system pasteboard
    /// (which may have been put there by Finder).
    private var clipboardHasFiles: Bool {
        if FileClipboard.remotePayload != nil { return true }
        return NSPasteboard.general.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    // MARK: - Quick filter

    private var quickFilterBubble: QuickFilterBubble?
    /// The "reading the tree… N" pill while the branch-view walk is out. Created on first
    /// use, hidden the rest of the time.
    private var branchScanBadge: NSTextField?
    private var quickFilterActions: QuickFilterActionsPanel?
    private var quickFilterListArea: NSLayoutGuide?
    var isQuickFilterActive: Bool { quickFilterBubble != nil }

    /// Is the QuickLook preview panel up? It forwards printable keys down to the panel, so the
    /// bubble would open behind it with no way to dismiss it from there.
    private enum QuickLookBridge {
        static var isPreviewPanelOpen: Bool {
            NSApp.windows.contains { $0.isVisible && $0.className.contains("QLPreviewPanel") }
        }
    }

    /// A printable character with no command-like modifier. `characters` rather than
    /// `charactersIgnoringModifiers`, so a Russian keyboard types Russian letters into the filter.
    private static func printableCharacter(from event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.function),
              let characters = event.characters, !characters.isEmpty else { return nil }
        // Arrows and F-keys arrive as private-use scalars; control characters are Tab, Return, Esc.
        guard characters.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }) else { return nil }
        return characters
    }

    /// Can typing start the filter right now? Every state that hides or borrows the file list says
    /// no, or the panel would narrow a list the user cannot see — or steal keys from a terminal.
    private var canBeginQuickFilter: Bool {
        !isMonitorMode && activeTerminalID == nil && renamingItem == nil
            && !viewModel.items.isEmpty
            && !QuickLookBridge.isPreviewPanelOpen
    }

    /// The favourites, drawn as the app's own popup. One builder for every way in — Cmd+D, the
    /// menu bar, the star on the tab bar — so they cannot drift apart.
    func showFavoriteFoldersMenu(at screenPoint: NSPoint) {
        let current = viewModel.currentPath
        let menu = NSMenu()

        for path in FavoriteFolders.paths {
            let exists = FileManager.default.fileExists(atPath: path)
            let title = ((path as NSString).lastPathComponent.isEmpty ? path
                : (path as NSString).lastPathComponent)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if exists {
                let target = MenuItemActionTarget { [weak self] in
                    self?.viewModel.navigateToBookmark(path)
                }
                item.target = target
                item.action = #selector(MenuItemActionTarget.invoke(_:))
                item.representedObject = target
            } else {
                // The folder is gone — an unmounted disk, a deleted project. Shown greyed, not
                // hidden: a row that vanishes looks like the list lost it.
                item.isEnabled = false
            }
            item.image = NSImage(systemSymbolName: exists ? "folder" : "folder.badge.questionmark",
                                 accessibilityDescription: nil)
            item.toolTip = (path as NSString).abbreviatingWithTildeInPath
            menu.addItem(item)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }

        // The current folder joins or leaves the list — one item, whichever way round applies.
        // Only for a REAL local folder: an FTP path, an archive interior or /TRASH saved into a
        // list of local places would come back later as a favourite that leads nowhere.
        let currentIsBookmarkable = !viewModel.insideRemote && !viewModel.insideArchive
            && FileManager.default.fileExists(atPath: current)
        if !currentIsBookmarkable {
            // No add/remove row at all — the navigation list above still works from anywhere.
        } else if FavoriteFolders.contains(current) {
            menu.addStyledItem(title: L("favorites.removeCurrent"), symbolName: "star.slash", id: "favorites.removeCurrent") {
                FavoriteFolders.remove(current)
            }
        } else {
            menu.addStyledItem(title: L("favorites.addCurrent"), symbolName: "star", id: "favorites.addCurrent") {
                FavoriteFolders.add(current)
            }
        }

        // Anywhere else in the list is pruned through a submenu — a right-click cannot land on
        // a row of a popup that closes on any click.
        let others = FavoriteFolders.paths.filter { $0 != current }
        if !others.isEmpty {
            let removeItem = NSMenuItem(title: L("favorites.remove"), action: nil, keyEquivalent: "")
            removeItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            let removeMenu = NSMenu()
            for path in others {
                removeMenu.addStyledItem(title: (path as NSString).abbreviatingWithTildeInPath,
                                         symbolName: "folder") {
                    FavoriteFolders.remove(path)
                }
            }
            removeItem.submenu = removeMenu
            menu.addItem(removeItem)
        }

        ContextPopupMenuController.shared.show(menu, at: screenPoint)
    }

    /// Raise, update or drop the "reading the tree…" pill. One label, panel's own style:
    /// accent-tinted rounded plate under the sort bar, never taking the keyboard.
    private func updateBranchScanBadge() {
        guard let count = viewModel.branchScanCount else {
            branchScanBadge?.isHidden = true
            return
        }
        let badge: NSTextField
        if let existing = branchScanBadge {
            badge = existing
        } else {
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.alignment = .center
            label.wantsLayer = true
            label.layer?.cornerRadius = 6
            label.layer?.backgroundColor = NSColor(
                PanelAppearanceSettings.swiftUIColor(
                    from: UserDefaults.standard.string(
                        forKey: PanelAppearanceSettings.accentColorHexKey) ?? "",
                    fallback: .purple)).withAlphaComponent(0.85).cgColor
            label.textColor = .white
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: sortBarHosting.bottomAnchor, constant: 8),
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.heightAnchor.constraint(equalToConstant: 22),
            ])
            branchScanBadge = label
            badge = label
        }
        badge.stringValue = "  " + L("branch.scanning", count) + "  "
        badge.isHidden = false
    }

    private func beginQuickFilter(with characters: String) {
        guard quickFilterBubble == nil else { return }
        let bubble = QuickFilterBubble(frame: .zero)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bubble)
        // A guide over exactly the slot the file list occupies — between the sort bar and the
        // status bar, the same span the monitor and the embedded terminal use. Created once and
        // reused: a fresh guide per filter session would pile up guides and live constraints the
        // layout engine keeps solving forever, since removing the bubble detaches only the
        // constraints that mention the bubble.
        let listArea: NSLayoutGuide
        if let existing = quickFilterListArea {
            listArea = existing
        } else {
            listArea = NSLayoutGuide()
            view.addLayoutGuide(listArea)
            NSLayoutConstraint.activate([
                listArea.topAnchor.constraint(equalTo: sortBarHosting.bottomAnchor),
                listArea.bottomAnchor.constraint(equalTo: statusBarHosting.topAnchor),
                listArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                listArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            quickFilterListArea = listArea
        }
        // The buttons live on their own plate to the RIGHT of the bubble: the bubble is a
        // read-out of what is being typed, and buttons under the text made the two read as one
        // control. The pair is centred together, so the bubble sits a little left of centre.
        let actions = QuickFilterActionsPanel(frame: .zero)
        actions.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actions)

        NSLayoutConstraint.activate([
            bubble.centerYAnchor.constraint(equalTo: listArea.centerYAnchor),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: listArea.widthAnchor, multiplier: 0.6),

            actions.leadingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: 10),
            actions.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            // Both together are what gets centred.
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: listArea.leadingAnchor,
                                            constant: 8),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: listArea.trailingAnchor,
                                              constant: -8),
            bubble.centerXAnchor.constraint(equalTo: listArea.centerXAnchor,
                                            constant: -46).withPriority(.defaultHigh),
        ])
        // The pattern is already typed, so these need no dialog. The bubble STAYS afterwards:
        // one press is rarely the whole job — mark by one mask, then another, then invert — and
        // a bubble that closed on the first press made the next one start from scratch. Esc ends
        // it, and the selection outlives the filter.
        actions.onSelect = { [weak self] in
            guard let self else { return }
            viewModel.selectVisible()
            refreshQuickFilterBubble()
        }
        actions.onDeselect = { [weak self] in
            guard let self else { return }
            viewModel.deselectVisible()
            refreshQuickFilterBubble()
        }
        // Inverting SHOWS the other files and nothing more — marking them is what the button
        // next door is for. Press it again to come back.
        // Straight into the delete every other road takes — F8, Backspace, the context menu —
        // so the confirmation, the Trash-versus-erase rule and the progress are the ones the
        // app already has, and there is no second copy of any of it here.
        actions.onDelete = { [weak self] in
            guard let self else { return }
            actionDelegate?.panelDidRequestDelete(self, items: selectedOrCursorItems())
        }
        // Inverting swaps the MARKS over: what was marked lets go, what was not is marked — and
        // the list turns over with them, so what is now marked is what is on screen. Pressed
        // with nothing marked, the filter's own catch stands in as the thing being turned over.
        actions.onInvert = { [weak self] in
            guard let self else { return }
            if viewModel.selectedPaths.isEmpty { viewModel.selectVisible() }
            viewModel.invertSelectionInFolder()
            viewModel.toggleQuickFilterInversion()
            refreshAfterPlateAction()
            scrollToCursorIfNeeded()
        }

        // A pressed preset takes the same road the typing does, inversion reset included.
        bubble.onPresetChosen = { [weak self] mask in
            self?.setQuickFilterText(mask)
        }

        quickFilterBubble = bubble
        quickFilterActions = actions
        // The list can recompute without the panel asking — the background tag scan lands and
        // "#красная" suddenly has matches. The read-out follows the list, not the keystrokes.
        viewModel.onQuickFilterRecomputed = { [weak self] in self?.refreshQuickFilterBubble() }
        setQuickFilterText(characters)
        // The plate arrives the way a shop-window sign does — a flicker, then steady.
        actions.lightUp()
    }

    /// Close the bubble and put the whole folder back. Called from Esc and from every path that
    /// takes the file list away — a bubble outliving its list would describe something else.
    func endQuickFilter() {
        guard quickFilterBubble != nil else { return }
        quickFilterBubble?.removeFromSuperview()
        quickFilterBubble = nil
        quickFilterActions?.removeFromSuperview()
        quickFilterActions = nil
        viewModel.onQuickFilterRecomputed = nil
        viewModel.clearQuickFilter()
        scrollToCursorIfNeeded()
    }

    private func setQuickFilterText(_ text: String) {
        viewModel.setQuickFilter(text)
        refreshQuickFilterBubble()
        scrollToCursorIfNeeded()
    }

    /// After a button on the plate: the marks have moved, and every mode has to show it.
    ///
    /// The detailed table repaints from the selection subject on its own, but the brief and
    /// thumbnails views re-render only when their token moves — which is why marks made from
    /// here could appear in one mode and not in the others.
    private func refreshAfterPlateAction() {
        viewModel.data.sortToken &+= 1
        refreshVisibleRowStates()
        refreshQuickFilterBubble()
    }

    /// Re-read what the bubble shows: the counts, and which of its buttons have work to do.
    /// Called after every keystroke AND after every button press, since marking files changes
    /// what the other two buttons can do.
    private func refreshQuickFilterBubble() {
        let matches = viewModel.items.filter { $0.name != ".." }.count
        quickFilterBubble?.update(text: viewModel.quickFilterText,
                                  matches: matches,
                                  total: viewModel.unfilteredItemCount,
                                  inverted: viewModel.quickFilterInverted)
        // All three act on what is SHOWN, so none needs a mask; only "clear" needs something
        // to clear.
        quickFilterActions?.update(canSelect: matches > 0,
                                   canDeselect: viewModel.hasSelectionAmongVisible,
                                   // "|| inverted" or the button goes dark in exactly the state
                                   // it created: an inversion that emptied the list could never
                                   // be pressed again to come back.
                                   canInvert: matches > 0 || viewModel.quickFilterInverted,
                                   // Only a selection the delete can actually REACH lights it.
                                   // It used to light for the whole folder's selection while
                                   // the action saw only the visible part — with everything
                                   // selected hidden by the filter, the button fell through to
                                   // the file under the cursor, which nobody had chosen.
                                   canDelete: viewModel.hasSelectionAmongVisible,
                                   inverted: viewModel.quickFilterInverted)
    }

    /// Keys while the bubble is up. Returns nil for anything it does not claim, so cursor movement,
    /// Enter and the F-keys keep working on the narrowed list.
    private func handleQuickFilterKey(_ event: NSEvent) -> Bool? {
        switch event.keyCode {
        case 53:                                  // Esc — cancel, restore the folder
            endQuickFilter()
            return true
        case 51:                                  // Backspace — MUST be claimed before the panel's
            // own case 51, which either goes up a folder or asks to DELETE the selection.
            let text = String(viewModel.quickFilterText.dropLast())
            if text.isEmpty { endQuickFilter() } else { setQuickFilterText(text) }
            return true
        default:
            if let characters = Self.printableCharacter(from: event) {
                setQuickFilterText(viewModel.quickFilterText + characters)
                return true
            }
            return nil
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        viewModel.onNetworkShareMounted = { [weak self] mountPoint in
            self?.openNetworkMount(at: mountPoint)
        }
        reloadAppearanceSettings()
        bindViewModel()
        viewModel.loadDirectory()

        // Observe appearance-related UserDefaults keys via KVO
        for key in Self.appearanceKeys {
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: .new, context: nil)
        }
        // Cursor "beauty" keys drive only the detailed-mode glow — observed separately so a
        // slider drag repaints the glow without a full table reloadData.
        for key in Self.cursorBeautyKeys {
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: .new, context: nil)
        }
        for key in Self.iconZoomKeys {
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: .new, context: nil)
        }
        // Turning Git marks on or off has to reach a panel that is already standing in a folder.
        UserDefaults.standard.addObserver(self,
                                          forKeyPath: PanelAppearanceSettings.gitStatusEnabledKey,
                                          options: .new, context: nil)

        // The drawn cursor changed — mask edited, preview pushed, toggle flipped. Repaint every
        // surface the cursor is drawn on; the baked image changed behind unchanged properties,
        // so no didSet will do it for us.
        maskNoteObserver = NotificationCenter.default.addObserver(
            forName: .fcxlCursorMaskChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.updateDetailedCursorGlow()
            self.tableView?.needsDisplay = true
            self.tableView?.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
            if self.alternateHosting != nil { self.updateAlternateHosting() }
        }

        // Re-read the per-theme panel background when the app switches light/dark.
        appearanceNoteObserver = NotificationCenter.default.addObserver(
            forName: .fcxlAppearanceChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadAppearanceSettings()
        }

        // Правила раскраски изменились в настройках — список перекрашивается сразу.
        //
        // Без `queue:` намеренно: окно настроек открыто модально, а блоки, поставленные в
        // OperationQueue.main, в модальном цикле ждут его окончания. Цвет из-за этого
        // появлялся только после закрытия настроек, да и то после щелчка по панели.
        // Уведомление посылается с главного потока, поэтому обработчик и так выполняется
        // на нём — просто немедленно.
        fileColorsObserver = NotificationCenter.default.addObserver(
            forName: .fcxlFileColorsChanged, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadAppearanceSettings()
                // Сроки могли поменяться — значит и шаг перекраски другой.
                self?.restartFreshnessTimer()
            }
        }

        // Ошибка панели меняется и без смены списка: чтение упало, а список как был
        // пустым, так и остался — надпись обязана появиться и в этом случае.
        viewModel.state.$errorMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] (_: String?) in self?.updateTroubleLabel() }
            .store(in: &cancellables)

        // Правки из копии отправлены в облако — папка, которую показывает панель,
        // перечитывается: человек должен увидеть свежую дату, а не вчерашнюю.
        remoteUploadObserver = NotificationCenter.default.addObserver(
            forName: .fcxlRemoteFileUploaded, object: nil, queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.viewModel.insideRemote,
                      let id = note.userInfo?["connectionID"] as? UUID,
                      self.viewModel.remoteSession?.connection.id == id,
                      let folder = note.userInfo?["folder"] as? String,
                      self.viewModel.currentPath == folder else { return }
                self.viewModel.startRemoteLoad(at: folder)
            }
        }

        // Цвет свежести зависит от времени, а не от событий: без этого файл, покрашенный
        // как «только что появившийся», оставался бы ярким до самого закрытия программы.
        // Раз в десять минут — незаметно для глаза на суточной шкале и даром по расходу.
        restartFreshnessTimer()

        // Mirror the table's horizontal scroll onto the SortBar header so the
        // column titles scroll together with the data when columns overflow.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let x = self.scrollView.contentView.bounds.origin.x
            guard abs(x - self.detailedHScroll) > 0.5 else { return }
            self.detailedHScroll = x
            self.sortBarHosting?.rootView = self.makeSortBarView()
        }

        // Monitor all mouse clicks to activate this panel when any part is clicked.
        // IMPORTANT: Skip activation if click lands on the file list area (scrollView
        // for detailed mode, alternateHosting for brief/thumbnails) — the item click
        // handler will set cursor FIRST, then activate, preventing old cursor flash.
        // Shift + a two-finger swipe: fingers left go up a folder, fingers right go back in.
        // Only trackpad gestures (they carry phases); a wheel under Shift keeps scrolling.
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self, event.modifierFlags.contains(.shift),
                  event.phase != [] || event.momentumPhase != [],
                  let window = self.view.window, event.window === window, !self.view.isHidden,
                  self.view.bounds.contains(self.view.convert(event.locationInWindow, from: nil))
            else { return event }
            // Momentum after the fingers have left: never a second swipe, never a scroll.
            guard event.momentumPhase == [] else { return nil }
            let inverted = event.isDirectionInvertedFromDevice
            let direction = self.swipe.feed(
                phase: event.phase,
                fingerX: SwipeNavigator.fingerMotion(deltaX: event.scrollingDeltaX, invertedFromDevice: inverted),
                fingerY: SwipeNavigator.fingerMotion(deltaX: event.scrollingDeltaY, invertedFromDevice: inverted))
            if let direction { self.performSwipe(direction) }
            return nil   // the list must not scroll sideways under a navigation gesture
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.view.window, event.window === window else { return event }
            // A hidden panel is the one the embedded viewer/editor is standing on: it keeps its
            // frame, so every click on the viewer's own chrome — page strip, fast/slow toggle,
            // Close — still lands inside these bounds. Answering them handed the keyboard to a
            // panel nobody can see, and the cursor jumped away from the file being viewed.
            guard !self.view.isHidden else { return event }
            let locationInView = self.view.convert(event.locationInWindow, from: nil)
            guard self.view.bounds.contains(locationInView) else { return event }

            // The terminal must not hold the keyboard hostage over a FILE panel. While a
            // terminal tab is up anywhere, it owns the first responder — and a click into this
            // panel's list moved the cursor with the mouse while every ARROW still went into
            // the shell (the ^[[A litter in the terminal was the arrows arriving there). The
            // activation path could not fix it: it holds its tongue when this panel is already
            // the active one. Claimed SYNCHRONOUSLY, before the click is dispatched, so a
            // click on a text field still lands the caret in that field afterwards.
            if self.activeTerminalID == nil,
               let responder = window.firstResponder as? NSView,
               responder.className.contains("TerminalView") {
                self.claimFirstResponder()
            }

            // Щелчок по буквам в поле переименования — дело поля: поставить каретку. Монитор
            // видит щелчок первым и раньше отдавал его обработчику строки, а тот закрывал
            // правку — так в имя нельзя было ткнуть мышью.
            if self.renamingItem != nil,
               InlineRenameLook.isInsideActiveEditor(window.contentView?.hitTest(event.locationInWindow)) {
                return event
            }

            // Check if click is inside the file list area (detailed OR brief/thumbnails)
            let locInScroll = self.scrollView.convert(event.locationInWindow, from: nil)
            let clickIsOnDetailedList = self.scrollView.bounds.contains(locInScroll)

            var clickIsOnAlternateList = false
            if let alt = self.alternateHosting {
                let locInAlt = alt.convert(event.locationInWindow, from: nil)
                clickIsOnAlternateList = alt.bounds.contains(locInAlt)
            }

            if !clickIsOnDetailedList && !clickIsOnAlternateList {
                // Click on breadcrumb, volume bar, tab bar, status bar — activate immediately
                self.onBecameActive?()
            }

            // Handle clicks on brief/thumbnails via event monitor — guaranteed to fire
            // regardless of AppKit clickCount or SwiftUI event swallowing. Only while one of
            // them is what the panel shows: the hosting view stays alive under the detailed
            // table, and answering for it there handled every table click twice.
            if clickIsOnAlternateList && self.viewModel.viewMode != .detailed && event.type == .leftMouseDown {
                if let cv = self.findCollectionView() {
                    let locInCV = cv.convert(event.locationInWindow, from: nil)
                    if let ip = cv.indexPathForItem(at: locInCV),
                       self.viewModel.items.indices.contains(ip.item) {
                        let now = Date()
                        let interval = DoubleClickSettings.currentInterval
                        if ip.item == self.lastClickRow
                            && now.timeIntervalSince(self.lastClickTime) < interval {
                            // Double-click → navigate. Consume event so collection view
                            // doesn't start stale drag tracking.
                            self.lastClickRow = -1
                            self.lastClickTime = .distantPast
                            self.activateItem(self.viewModel.items[ip.item])
                            return nil
                        }
                        self.lastClickRow = ip.item
                        self.lastClickTime = now
                        self.handleRowClick(row: ip.item, flags: event.modifierFlags)
                        // Stamp this click so the collection view's own mouseDown (which fires
                        // for the SAME event a moment later) doesn't re-run handleRowClick.
                        self.monitorHandledClickRow = ip.item
                        self.monitorHandledClickTime = Date()
                        self.onBecameActive?()
                    }
                }
            }

            return event
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if isActivePanel {
            claimFirstResponder()
        }
        // Distribute columns to fill panel, then sync to SortBarView
        distributeColumnWidths()
        syncColumnWidthsToViewModel()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        distributeColumnWidths()
        syncColumnWidthsToViewModel()
    }

    deinit {
        if let swipeMonitor {
            NSEvent.removeMonitor(swipeMonitor)
        }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        for key in Self.appearanceKeys {
            UserDefaults.standard.removeObserver(self, forKeyPath: key)
        }
        for key in Self.cursorBeautyKeys {
            UserDefaults.standard.removeObserver(self, forKeyPath: key)
        }
        for key in Self.iconZoomKeys {
            UserDefaults.standard.removeObserver(self, forKeyPath: key)
        }
        UserDefaults.standard.removeObserver(self,
                                             forKeyPath: PanelAppearanceSettings.gitStatusEnabledKey)
        if let appearanceNoteObserver {
            NotificationCenter.default.removeObserver(appearanceNoteObserver)
        }
        if let maskNoteObserver {
            NotificationCenter.default.removeObserver(maskNoteObserver)
        }
        if let remoteUploadObserver {
            NotificationCenter.default.removeObserver(remoteUploadObserver)
        }
        if let fileColorsObserver {
            NotificationCenter.default.removeObserver(fileColorsObserver)
        }
        freshnessTimer?.invalidate()
    }

    private static let appearanceKeys: [String] = [
        PanelAppearanceSettings.thumbnailSizeKey,
        PanelAppearanceSettings.folderNameColorHexKey,
        PanelAppearanceSettings.fileNameColorHexKey,
        PanelAppearanceSettings.selectedNameColorHexKey,
        PanelAppearanceSettings.cursorNameColorHexKey,
        PanelAppearanceSettings.cursorBackgroundColorHexKey,
        PanelAppearanceSettings.cursorUnderNameColorHexKey,
        PanelAppearanceSettings.folderIconColorHexKey,
        PanelAppearanceSettings.panelBackgroundColorHexLightKey,
        PanelAppearanceSettings.panelBackgroundColorHexDarkKey,
        PanelAppearanceSettings.alternateRowsEnabledKey,
        PanelAppearanceSettings.alternateRowColorHexLightKey,
        PanelAppearanceSettings.alternateRowColorHexDarkKey,
        PanelAppearanceSettings.accentColorHexKey,
        PanelAppearanceSettings.cursorUsesCustomColorKey,
        PanelAppearanceSettings.upIconScaleKey,
        PanelAppearanceSettings.upIconWeightKey,
        PanelAppearanceSettings.upIconSymbolKey,
        PanelAppearanceSettings.iconScaleKey,
        FolderIconStyle.storageKey,
        CustomFolderIconService.enabledKey,
        "briefRowHeight",
        "iconNameGap",
        PanelAppearanceSettings.listFontFamilyKey,
        PanelAppearanceSettings.listFontSizeKey,
        PanelAppearanceSettings.listFontBoldKey,
        PanelAppearanceSettings.listLetterSpacingKey,
        PanelAppearanceSettings.cursorFontZoomEnabledKey,
        PanelAppearanceSettings.cursorFontZoomAmountKey,
        PanelAppearanceSettings.iconEdgeInsetKey,
    ]

    /// Keys that only affect the detailed-mode feathered cursor glow (the SwiftUI modes
    /// react to these via their own @AppStorage). Observed separately for a lightweight
    /// glow-only repaint instead of a full appearance reload.
    private static let cursorBeautyKeys: [String] = [
        PanelAppearanceSettings.beautyModeEnabledKey,
        PanelAppearanceSettings.cursorBlurKey,
        // NB: the mask keys are NOT here — they are dotted, and defaults KVO silently never
        // fires for dotted keys. The mask speaks through .fcxlCursorMaskChanged instead.
        PanelAppearanceSettings.cursorHeightKey,
        PanelAppearanceSettings.cursorWidthKey,
        PanelAppearanceSettings.cursorCornerKey,
        PanelAppearanceSettings.cursorOffsetXKey,
        PanelAppearanceSettings.cursorOffsetYKey,
        PanelAppearanceSettings.cursorAnchorXKey,
        PanelAppearanceSettings.cursorAnchorYKey,
        PanelAppearanceSettings.cursorOutlineEnabledKey,
        PanelAppearanceSettings.cursorOutlineWidthKey,
        PanelAppearanceSettings.cursorOutlineColorHexKey,
    ]

    /// Keys for the icon "lift" under the cursor. On change we re-apply it in the detailed
    /// rows and refresh the brief/thumbnails hosting so every mode picks up the new scale.
    private static let iconZoomKeys: [String] = [
        PanelAppearanceSettings.cursorIconZoomSpreadKey,
        PanelAppearanceSettings.cursorIconZoomEnabledKey,
        PanelAppearanceSettings.cursorIconZoomAmountKey,
    ]

    private var appearanceDebounceWork: DispatchWorkItem?
    private var appearanceNoteObserver: NSObjectProtocol?
    private var fileColorsObserver: NSObjectProtocol?
    private var remoteUploadObserver: NSObjectProtocol?
    private var freshnessTimer: Timer?
    private var maskNoteObserver: NSObjectProtocol?
    private var stackNoteObserver: NSObjectProtocol?

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == PanelAppearanceSettings.gitStatusEnabledKey {
            // `force`, because the listing has not changed — only whether we look at it.
            viewModel.refreshGit(force: true)
        } else if keyPath == PanelAppearanceSettings.thumbnailSizeKey {
            // A new cell size is a new layout, not a new colour: rebuild the thumbnails view.
            updateAlternateHosting()
        } else if let keyPath, Self.appearanceKeys.contains(keyPath) {
            reloadAppearanceSettings()
        } else if let keyPath, Self.cursorBeautyKeys.contains(keyPath) {
            // Live cursor-beauty tweak: repaint just the detailed-mode glow (+ mark rows so
            // the solid-fill suppression re-evaluates when the master toggle flips). No reload.
            updateDetailedCursorGlow()
            // The glow lives in the table's BACKGROUND, and updateDetailedCursorGlow only marks
            // it when a property CHANGES value. A mask edit changes the baked image behind the
            // same property values — the row/colour/blur are all identical — so nothing here
            // repainted and the live preview looked dead. The background must be told directly.
            tableView?.needsDisplay = true
            tableView?.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
            // Brief/thumbnails draw the same feather — refresh their hosting so a slider drag
            // is visible there too, the same way the icon-zoom keys already do.
            if alternateHosting != nil { updateAlternateHosting() }
        } else if let keyPath, Self.iconZoomKeys.contains(keyPath) {
            // Icon-lift setting changed: re-apply in the detailed rows + refresh the brief/
            // thumbnails hosting so their cells pick up the new scale.
            refreshVisibleRowStates()
            if alternateHosting != nil { updateAlternateHosting() }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    // MARK: - Appearance Settings Reload

    /// Каким цветом писать имя: по правилу раскраски, если оно есть, иначе обычным.
    ///
    /// Правила смотрят на ИМЯ и на возраст, поэтому папке они тоже могут достаться — но
    /// только если человек написал маску, которая её ловит; готовый набор состоит из
    /// расширений и папок не трогает.
    private func colorForName(of item: FileItem) -> NSColor {
        let base: NSColor = item.isDirectory ? resolvedFolderNameColor : resolvedFileNameColor
        guard item.name != "..",
              let ruled = FileColorRulesStore.shared.color(for: item, base: base)
        else { return base }
        return ruled
    }

    /// Перекрашивать список сам по себе, пока в нём есть гаснущие правила.
    ///
    /// Шаг берётся от самого короткого срока: при пятиминутном сроке десятиминутный таймер
    /// не успевал сработать ни разу, и «постепенно гаснуть» оказывалось «пропасть разом».
    private func restartFreshnessTimer() {
        freshnessTimer?.invalidate()
        freshnessTimer = nil
        guard let interval = FileColorRulesStore.shared.repaintInterval else { return }
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Время идёт — значит цвет гаснущего правила уже другой. Ячейки кратких
                // видов узнают об этом только по счётчику: их содержимое не менялось.
                FileColorRulesStore.shared.markRepaint()
                self.refreshVisibleRowStates()
                self.updateAlternateHosting()
            }
        }
    }

    /// Read all appearance values from UserDefaults into resolved properties.
    /// Safe to call before views exist (used in loadView before setupColumns).
    private func reloadAppearanceFromDefaults() {
        let defaults = UserDefaults.standard

        let folderNameHex = defaults.string(forKey: PanelAppearanceSettings.folderNameColorHexKey) ?? ""
        let fileNameHex = defaults.string(forKey: PanelAppearanceSettings.fileNameColorHexKey) ?? ""
        let cursorNameHex = defaults.string(forKey: PanelAppearanceSettings.cursorNameColorHexKey) ?? ""
        let cursorBgHex = defaults.string(forKey: PanelAppearanceSettings.cursorBackgroundColorHexKey) ?? ""
        let folderIconHex = defaults.string(forKey: PanelAppearanceSettings.folderIconColorHexKey) ?? ""
        // Panel background is per-theme — read the key for the current light/dark state.
        // NSApp is nil in the SwiftPM test bundle (no NSApplication), so fall back to the
        // current drawing appearance instead of force-unwrapping it and crashing the suite.
        let appAppearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let dark = appAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let bgHex = defaults.string(forKey: PanelAppearanceSettings.panelBackgroundKey(dark: dark)) ?? ""
        let iconStyleRaw = defaults.string(forKey: FolderIconStyle.storageKey) ?? FolderIconStyle.macos.rawValue

        resolvedFolderNameColor = PanelAppearanceSettings.nsColor(from: folderNameHex, fallback: .systemYellow)
        resolvedFileNameColor = PanelAppearanceSettings.nsColor(from: fileNameHex, fallback: .labelColor)
        resolvedCursorBackgroundColor = PanelAppearanceSettings.resolvedCursorBackground()
        resolvedCursorNameColor = PanelAppearanceSettings.resolvedCursorNameColor()
        resolvedFolderIconTintColor = PanelAppearanceSettings.optionalNSColor(from: folderIconHex)
        resolvedFolderIconStyle = FolderIconStyle(rawValue: iconStyleRaw) ?? .macos
        resolvedIconScale = max(PanelAppearanceSettings.minimumIconScale,
                                min(PanelAppearanceSettings.maximumIconScale,
                                    defaults.double(forKey: PanelAppearanceSettings.iconScaleKey).nonZero ?? 1.0))
        resolvedUpIconScale = max(0.3, min(2.0, defaults.double(forKey: PanelAppearanceSettings.upIconScaleKey).nonZero ?? 1.0))
        resolvedRowHeight = max(18, defaults.double(forKey: "briefRowHeight").nonZero ?? 26)
        let rawGap = defaults.object(forKey: "iconNameGap") as? Double ?? 6
        resolvedIconNameGap = CGFloat(max(0, min(20, rawGap)))
        resolvedPanelBackgroundColor = PanelAppearanceSettings.nsColor(from: bgHex, fallback: .controlBackgroundColor)
        resolvedAlternateRowColor = PanelAppearanceSettings.resolvedAlternateRowColor()
        tableView?.alternateRowColor = resolvedAlternateRowColor

        // The cursor-style investigation: every input the cursor is drawn from, in one line,
        // each time this panel re-reads its appearance. A "did not survive the restart" report
        // is answered by diffing the line before quit against the line after launch.
        let d = defaults
        Self.keyLog.notice("""
            cursor-inputs dark=\(dark, privacy: .public) \
            maskOn=\(CursorMaskStore.isEnabled, privacy: .public) \
            rev=\(CursorMaskStore.revision, privacy: .public) \
            usesCustom=\(d.bool(forKey: PanelAppearanceSettings.cursorUsesCustomColorKey), privacy: .public) \
            bg=\(cursorBgHex, privacy: .public) name=\(cursorNameHex, privacy: .public) \
            blur=\(d.double(forKey: PanelAppearanceSettings.cursorBlurKey), privacy: .public) \
            h=\(d.double(forKey: PanelAppearanceSettings.cursorHeightKey), privacy: .public) \
            w=\(d.double(forKey: PanelAppearanceSettings.cursorWidthKey), privacy: .public) \
            corner=\(d.double(forKey: PanelAppearanceSettings.cursorCornerKey), privacy: .public) \
            outline=\(d.bool(forKey: PanelAppearanceSettings.cursorOutlineEnabledKey), privacy: .public) \
            beauty=\(d.bool(forKey: PanelAppearanceSettings.beautyModeEnabledKey), privacy: .public) \
            gradH=\(d.bool(forKey: "fcxl.cursorMaskGradHOn"), privacy: .public) \
            gradV=\(d.bool(forKey: "fcxl.cursorMaskGradVOn"), privacy: .public)
            """)
    }

    private func reloadAppearanceSettings() {
        reloadAppearanceFromDefaults()

        // Apply row height and icon column width to detailed-mode table
        if let tableView {
            // Whichever is taller: the row height the person set, or what the icon needs.
            let newRowHeight = max(PanelAppearanceSettings.resolvedListRowHeight,
                                   resolvedDetailedIconSize() + 4)
            if abs(tableView.rowHeight - newRowHeight) > 0.5 {
                tableView.rowHeight = newRowHeight
            }
            // Update icon column width for current scale + gap
            let iconColWidth = resolvedDetailedIconSize() + resolvedIconNameGap + PanelAppearanceSettings.resolvedIconEdgeInset
            if let iconCol = tableView.tableColumn(withIdentifier: .init("icon")) {
                iconCol.width = iconColWidth
                iconCol.minWidth = iconColWidth
                iconCol.maxWidth = iconColWidth
            } else {
                // icon column not found — should not happen
            }
            tableView.backgroundColor = resolvedPanelBackgroundColor
            scrollView?.backgroundColor = resolvedPanelBackgroundColor
            view.layer?.backgroundColor = resolvedPanelBackgroundColor.cgColor
            distributeColumnWidths()
            syncColumnWidthsToViewModel()
            tableView.tile()
            tableView.reloadData()
            // Guarantee the visible cursor row repaints with the new cursor
            // background color even if NSTableView reused the row view.
            tableView.enumerateAvailableRowViews { rowView, _ in
                (rowView as? FileListRowView)?.cursorBackgroundColor = self.resolvedCursorBackgroundColor
            }
            // Keep the feathered cursor colour in step with the accent/cursor colour.
            updateDetailedCursorGlow()
        }

        // Refresh alternate hosting for brief/thumbnails
        if alternateHosting != nil {
            updateAlternateHosting()
        }

        // Update sort bar background
        updateSortBarBackground()
    }

    private func updateSortBarBackground() {
        sortBarHosting?.rootView = makeSortBarView()
    }

    /// Single construction point for the sort bar — wires the resize-handle
    /// callbacks straight into this controller (no publisher round-trip).
    private func makeSortBarView() -> SortBarView {
        SortBarView(
            viewModel: viewModel,
            backgroundColor: Color(nsColor: resolvedPanelBackgroundColor),
            horizontalScrollOffset: detailedHScroll,
            onColumnResize: { [weak self] column, width in
                self?.handleSortBarColumnResize(column: column, requestedWidth: width)
            },
            onColumnResizeCommit: { [weak self] in
                self?.handleSortBarColumnResizeCommit()
            },
            onAutoFitColumn: { [weak self] column in
                self?.handleAutoFitColumn(column)
            }
        )
    }

    // MARK: - First Responder

    /// Claim keyboard focus for this panel based on current view mode.
    /// For alternate modes, attempts to find the internal NSCollectionView;
    /// if not yet available (SwiftUI layout pending), retries once after layout pass.
    func claimFirstResponder() {
        guard let window = view.window else { return }
        if viewModel.viewMode == .detailed {
            window.makeFirstResponder(tableView)
            return
        }
        guard let hosting = alternateHosting else { return }
        if let collectionView = findFirstResponderCandidate(in: hosting) {
            window.makeFirstResponder(collectionView)
        } else {
            // NSCollectionView not yet created — fallback to hosting view.
            // The override of keyDown on PanelViewController catches events via responder chain.
            window.makeFirstResponder(hosting)
        }
    }

    /// Hand the list the keyboard back, but only when focus has drifted OUT of this panel —
    /// into the embedded viewer, the editor or the bottom terminal.
    ///
    /// A no-op while focus is anywhere inside the panel, which is what keeps an inline rename
    /// field, the quick filter and the monitor's own controls from having it snatched away.
    func reclaimListFocusIfLost() {
        guard !view.isHidden, let window = view.window else { return }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) {
            return
        }
        claimFirstResponder()
    }

    /// Walk the subview tree to find the first NSCollectionView (brief/thumbnails internal view).
    private func findFirstResponderCandidate(in root: NSView) -> NSView? {
        for subview in root.subviews {
            if subview is NSCollectionView && subview.acceptsFirstResponder {
                return subview
            }
            if let found = findFirstResponderCandidate(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Responder Chain Fallback

    /// Catch key events that bubble up from NSHostingView / alternate views
    /// when their internal collection view didn't become first responder.
    override func keyDown(with event: NSEvent) {
        if handleKeyEvent(event) { return }
        super.keyDown(with: event)
    }

    /// Esc arrives as `cancelOperation:` down the responder chain. The monitor is SwiftUI, and
    /// SwiftUI's hosting view swallows the raw Esc key-down (it uses it to dismiss its own menus and
    /// popovers), so keyDown alone stops working as soon as the user has touched a control in the
    /// monitor. Handling the action here catches Esc regardless of which subview has focus.
    override func cancelOperation(_ sender: Any?) {
        if isMonitorMode { toggleMonitor(); return }
        super.cancelOperation(sender)
    }

    // MARK: - Columns

    private func setupColumns() {
        let iconColWidth = resolvedDetailedIconSize() + resolvedIconNameGap + PanelAppearanceSettings.resolvedIconEdgeInset
        let iconCol = NSTableColumn(identifier: .init("icon"))
        iconCol.title = ""
        iconCol.width = iconColWidth
        iconCol.minWidth = iconColWidth
        iconCol.maxWidth = iconColWidth
        iconCol.resizingMask = []
        tableView.addTableColumn(iconCol)

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = L("column.name")
        nameCol.minWidth = 120
        nameCol.resizingMask = .userResizingMask
        tableView.addTableColumn(nameCol)

        let typeCol = NSTableColumn(identifier: .init("type"))
        typeCol.title = L("properties.type")
        typeCol.width = 90
        typeCol.minWidth = 70
        typeCol.resizingMask = .userResizingMask
        tableView.addTableColumn(typeCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = L("column.size")
        sizeCol.width = 90
        sizeCol.minWidth = 60
        sizeCol.resizingMask = .userResizingMask
        tableView.addTableColumn(sizeCol)

        let createdCol = NSTableColumn(identifier: .init("created"))
        createdCol.title = L("properties.createdDate")
        createdCol.width = 130
        createdCol.minWidth = 90
        createdCol.resizingMask = .userResizingMask
        tableView.addTableColumn(createdCol)

        let modifiedCol = NSTableColumn(identifier: .init("modified"))
        modifiedCol.title = L("column.date")
        modifiedCol.width = 130
        modifiedCol.minWidth = 90
        modifiedCol.resizingMask = .userResizingMask
        tableView.addTableColumn(modifiedCol)

        let addedCol = NSTableColumn(identifier: .init("added"))
        addedCol.title = L("column.dateAdded")
        addedCol.width = 130
        addedCol.minWidth = 90
        addedCol.resizingMask = .userResizingMask
        tableView.addTableColumn(addedCol)

        let permCol = NSTableColumn(identifier: .init("permissions"))
        permCol.title = L("properties.permissions")
        permCol.width = 72
        permCol.minWidth = 60
        permCol.resizingMask = .userResizingMask
        tableView.addTableColumn(permCol)

        let ownerCol = NSTableColumn(identifier: .init("owner"))
        ownerCol.title = L("properties.owner")
        ownerCol.width = 110
        ownerCol.minWidth = 80
        ownerCol.resizingMask = .userResizingMask
        tableView.addTableColumn(ownerCol)

        // Trash only. Created unconditionally so its width and order are stable, then hidden by
        // applyColumnVisibility everywhere except the Trash.
        let originCol = NSTableColumn(identifier: .init("origin"))
        originCol.title = L("column.origin")
        originCol.width = 220
        originCol.minWidth = 100
        originCol.resizingMask = .userResizingMask
        tableView.addTableColumn(originCol)

        // The saved order, applied once the columns exist.
        applyColumnOrder()

        // Apply column visibility from ViewModel
        applyColumnVisibility()
    }

    /// The set the table was last built for — so re-checking on every reload costs one comparison.
    private var appliedColumnSet: Set<PanelColumn>?

    /// Put the columns right BEFORE the rows are drawn. The headers are SwiftUI and swap the
    /// instant the panel enters the Trash; the columns are AppKit and used to be swapped a
    /// runloop later, so a frame went out with "date deleted" written over the created column —
    /// which is empty for everything in the Trash, hence a column of dashes.
    /// Line the AppKit columns up with the user's order. Hidden columns move too — the
    /// order array covers EVERY column, so indexes stay honest whatever is visible. Widths
    /// live in a per-column dictionary and follow their column wherever it goes.
    private func applyColumnOrder() {
        let desired = ["icon", "name"] + viewModel.columnOrder.map(\.tableID)
        for (target, id) in desired.enumerated() {
            let current = tableView.column(withIdentifier: .init(id))
            guard current >= 0, current != target else { continue }
            tableView.moveColumn(current, toColumn: target)
        }
    }

    private func applyColumnVisibilityIfSetChanged() {
        guard viewModel.effectiveVisibleColumns != appliedColumnSet else { return }
        applyColumnVisibility()
    }

    private func applyColumnVisibility() {
        let visible = viewModel.effectiveVisibleColumns
        appliedColumnSet = visible
        for col in tableView.tableColumns {
            let id = col.identifier.rawValue
            switch id {
            case "icon", "name": break // always visible
            case "type": col.isHidden = !visible.contains(.type)
            case "size": col.isHidden = !visible.contains(.size)
            case "created": col.isHidden = !visible.contains(.dateCreated)
            case "modified": col.isHidden = !visible.contains(.dateModified)
            case "added": col.isHidden = !visible.contains(.dateAdded)
            case "permissions": col.isHidden = !visible.contains(.permissions)
            case "owner": col.isHidden = !visible.contains(.owner)
            case "origin": col.isHidden = !visible.contains(.origin)
            default: break
            }
        }
        distributeColumnWidths()
        syncColumnWidthsToViewModel()
    }

    /// Preferred (base) width for proportional distribution.
    private func preferredWidth(for columnID: String) -> CGFloat {
        switch columnID {
        case "name":        return 250
        case "type":        return 90
        case "size":        return 90
        case "created":     return 130
        case "modified":    return 130
        case "added":       return 130
        case "permissions": return 72
        case "owner":       return 110
        default:            return 100
        }
    }

    /// Proportionally distribute column widths to fill the available panel width.
    /// If total minWidths exceed available space, columns stay at preferred widths
    /// and horizontal scrollbar handles the overflow.
    private func distributeColumnWidths() {
        guard !isDistributingColumns else { return }
        isDistributingColumns = true
        defer { isDistributingColumns = false }

        let availableWidth = scrollView.contentSize.width
        guard availableWidth > 0 else { return }

        // Collect visible data columns (skip icon — fixed width)
        var visibleDataCols: [NSTableColumn] = []
        var iconWidth: CGFloat = 0

        for col in tableView.tableColumns where !col.isHidden {
            if col.identifier.rawValue == "icon" {
                iconWidth = col.width
            } else {
                visibleDataCols.append(col)
            }
        }

        guard !visibleDataCols.isEmpty else { return }

        // If the user has manually resized columns, restore their widths
        // instead of redistributing. Like Finder: user widths are absolute,
        // and the LAST visible column absorbs any leftover space so columns
        // always fill the panel (no dead gap when the window grows). On
        // overflow the last column keeps its width and the horizontal
        // scrollbar appears. Columns the user never sized (e.g. newly shown)
        // fall back to their preferred default.
        let userWidths = viewModel.userColumnWidths
        if !userWidths.isEmpty {
            let spaceForUserData = availableWidth - iconWidth
            var consumed: CGFloat = 0
            for col in visibleDataCols.dropLast() {
                let stored = userWidths[col.identifier.rawValue]
                    ?? preferredWidth(for: col.identifier.rawValue)
                let w = max(col.minWidth, stored)
                col.width = w
                consumed += w
            }
            if let last = visibleDataCols.last {
                let stored = userWidths[last.identifier.rawValue]
                    ?? preferredWidth(for: last.identifier.rawValue)
                let desired = max(last.minWidth, stored)
                // Grow to fill leftover, never shrink below the user's choice.
                last.width = max(desired, spaceForUserData - consumed)
            }
            return
        }

        let spaceForData = availableWidth - iconWidth

        // Sum of minimum widths — if panel is too narrow, just let scrollbar handle it
        let totalMin = visibleDataCols.reduce(CGFloat(0)) { $0 + $1.minWidth }
        if spaceForData <= totalMin {
            for col in visibleDataCols {
                col.width = col.minWidth
            }
            return
        }

        // Proportional distribution based on preferred widths.
        // Use floor() to avoid sub-pixel overflow that triggers the horizontal scrollbar.
        // The last column absorbs any remaining pixels.
        let preferred = visibleDataCols.map { preferredWidth(for: $0.identifier.rawValue) }
        let totalPreferred = preferred.reduce(CGFloat(0), +)

        var usedWidth: CGFloat = 0
        for (i, col) in visibleDataCols.enumerated() {
            if i == visibleDataCols.count - 1 {
                // Last column gets the remaining space (avoids rounding gaps)
                col.width = max(col.minWidth, spaceForData - usedWidth)
            } else {
                let ratio = preferred[i] / totalPreferred
                let w = floor(max(col.minWidth, spaceForData * ratio))
                col.width = w
                usedWidth += w
            }
        }
    }

    /// Map NSTableColumn identifier → PanelColumn (canonical mapping lives
    /// on PanelColumn.tableColumnIdentifier).
    private static func panelColumn(for identifier: String) -> PanelColumn? {
        PanelColumn.from(tableColumnIdentifier: identifier)
    }

    /// Push actual NSTableView column widths into ViewModel so SortBarView can align.
    private func syncColumnWidthsToViewModel() {
        var widths: [PanelColumn: CGFloat] = [:]
        var iconWidth: CGFloat = 24
        for col in tableView.tableColumns where !col.isHidden {
            let id = col.identifier.rawValue
            if id == "icon" {
                iconWidth = col.width
            } else if let pc = Self.panelColumn(for: id) {
                widths[pc] = col.width
            }
        }
        viewModel.detailedIconColumnWidth = iconWidth
        viewModel.detailedColumnWidths = widths
    }

    // MARK: - SortBar-driven column resize

    /// Live handler for a SortBar resize-handle drag. The handle is the ONLY
    /// source of user column resizes (headerView is nil, so AppKit never
    /// generates native ones). Direct call — no publisher round-trip, no
    /// echo-suppression caches.
    private func handleSortBarColumnResize(column: PanelColumn, requestedWidth: CGFloat) {
        let id = column.tableColumnIdentifier
        guard let col = tableView.tableColumn(withIdentifier: .init(id)) else { return }
        // Clamp at the single authoritative place: the real column minimum.
        // Recording the CLAMPED value keeps the stored layout identical to
        // what's on screen (no sub-minimum junk in UserDefaults).
        let clamped = max(col.minWidth, requestedWidth)
        // Merge (not replace): widths of currently hidden columns survive.
        viewModel.userColumnWidths[id] = clamped
        guard abs(col.width - clamped) > 0.5 else { return }
        isDistributingColumns = true
        col.width = clamped
        isDistributingColumns = false
        syncColumnWidthsToViewModel()
    }

    /// Drag ended — persist the layout once.
    private func handleSortBarColumnResizeCommit() {
        viewModel.saveUserColumnWidthsIfEnabled()
    }

    // MARK: - Smart auto-fit (content-based column width)

    /// The size column, for one item. A folder carries `size == 0` both when it holds nothing and
    /// when nobody has added it up yet, so the two must be told apart by the child count the
    /// listing brought along — otherwise every folder would claim to be empty for a moment.
    nonisolated static func sizeCellText(for item: FileItem) -> String {
        if item.name == ".." { return "" }
        if item.size == 0 {
            if item.isDirectory { return item.isEmptyDirectory ? L("size.zero") : "<DIR>" }
            return L("size.zero")   // ByteCountFormatter renders zero as "Zero KB"
        }
        return ByteText.file(Int64(item.size))
    }

    /// The text the detailed cell shows for a given item + column — must match
    /// makeTextCell/makeNameCell so measurement reflects what's on screen.
    private func cellText(for item: FileItem, column: PanelColumn) -> String {
        if item.name == ".." { return "" }
        switch column {
        case .name: return item.name
        case .type: return item.typeDisplayName
        case .size:
            return Self.sizeCellText(for: item)
        case .dateCreated:  return formatDate(item.dateCreated)
        case .dateModified: return formatDate(item.dateModified)
        case .dateAdded:    return formatDate(item.dateAdded)
        case .permissions:  return item.permissions
        case .owner:        return item.owner
        case .origin:       return viewModel.trashOrigins[item.path] ?? ""
        }
    }

    private func localizedColumnTitle(_ column: PanelColumn) -> String {
        column.localizedTitle(insideTrash: viewModel.state.insideTrash)
    }

    /// Width needed to show the column's longest value (and its header) in full,
    /// clamped to the column minimum and capped so one huge name can't dominate.
    private func idealWidth(for column: PanelColumn) -> CGFloat {
        let cellFont = NSFont.systemFont(ofSize: 12)
        let cellAttrs: [NSAttributedString.Key: Any] = [.font: cellFont]

        // Header (sort-bar font is ~10pt) plus room for the sort arrow.
        let headerFont = NSFont.systemFont(ofSize: 10)
        var maxWidth = (localizedColumnTitle(column) as NSString)
            .size(withAttributes: [.font: headerFont]).width + 18

        // Measure content. Cap the sample for very large folders — the widest
        // of the first few thousand rows is representative enough.
        let sampleLimit = 4000
        for item in viewModel.items.prefix(sampleLimit) {
            let text = cellText(for: item, column: column)
            guard !text.isEmpty else { continue }
            var w = (text as NSString).size(withAttributes: cellAttrs).width
            // The Name cell also carries the tag dots. Measuring the bare name would make the
            // auto-fit gesture — whose whole point is "show it all" — the thing that truncates them.
            if column == .name, let tags = viewModel.tagsByPath[item.path] {
                w += FinderTagDots.width(tags, font: cellFont)
            }
            if w > maxWidth { maxWidth = w }
        }

        let padding: CGFloat = 16   // cell insets + breathing room
        let panelWidth = scrollView.contentSize.width
        let cap = max(160, panelWidth * 0.6)
        let id = column.tableColumnIdentifier
        let minW = tableView.tableColumn(withIdentifier: .init(id))?.minWidth ?? 60
        return min(max(minW, ceil(maxWidth) + padding), cap)
    }

    /// Double-click on a divider → fit that one column to its content.
    private func handleAutoFitColumn(_ column: PanelColumn) {
        let id = column.tableColumnIdentifier
        guard let col = tableView.tableColumn(withIdentifier: .init(id)) else { return }
        let ideal = idealWidth(for: column)
        viewModel.userColumnWidths[id] = ideal
        isDistributingColumns = true
        col.width = ideal
        isDistributingColumns = false
        syncColumnWidthsToViewModel()
        viewModel.saveUserColumnWidthsIfEnabled()
    }

    /// Menu "Auto-fit all columns" → fit every visible column to its content,
    /// then expand the Name column to fill any leftover so the panel stays full.
    private func handleAutoFitAllColumns() {
        let dataCols = tableView.tableColumns.filter {
            !$0.isHidden && $0.identifier.rawValue != "icon"
        }
        var widths: [String: CGFloat] = [:]
        var total: CGFloat = 0
        for col in dataCols {
            guard let pc = Self.panelColumn(for: col.identifier.rawValue) else { continue }
            let ideal = idealWidth(for: pc)
            widths[col.identifier.rawValue] = ideal
            total += ideal
        }
        // Fill the panel: give any slack to Name (falls back to the last column).
        let available = scrollView.contentSize.width - viewModel.detailedIconColumnWidth
        if total < available {
            let slack = available - total
            if widths["name"] != nil {
                widths["name"]! += slack
            } else if let last = dataCols.last {
                widths[last.identifier.rawValue, default: 0] += slack
            }
        }
        isDistributingColumns = true
        for col in dataCols {
            if let w = widths[col.identifier.rawValue] { col.width = max(col.minWidth, w) }
        }
        isDistributingColumns = false
        viewModel.userColumnWidths = widths
        syncColumnWidthsToViewModel()
        viewModel.saveUserColumnWidthsIfEnabled()
    }

    // MARK: - Binding

    /// The font every Git mark is drawn at — the plain list font, untouched by the cursor wave.
    private var gitGutterFont: NSFont { PanelAppearanceSettings.resolvedListFont(atDistance: .max) }

    /// Width of the Git gutter for the folder on screen: as wide as its widest mark, zero when
    /// there is nothing to show. Recomputed when the readings change, not per row.
    private var gitGutterWidth: CGFloat = 0

    private func bindViewModel() {
        // Git answers from a background reading, after the rows are already on screen.
        viewModel.$gitByPath
            .receive(on: RunLoop.main)
            .sink { [weak self] badges in
                guard let self else { return }
                let width = GitBadgeChip.gutterWidth(badges.values, font: self.gitGutterFont)
                self.gitGutterWidth = width
                self.tableView.reloadData()
            }
            .store(in: &cancellables)

        // Tags arrive from a background scan; the rows are already on screen by then.
        viewModel.$tagsByPath
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.tableView.reloadData() }
            .store(in: &cancellables)

        // Observe items changes (PanelData subject)
        viewModel.data.dataDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                // Before reloadData, not after: the rows about to be built must land in the
                // columns this content belongs to.
                self?.applyColumnVisibilityIfSetChanged()
                self?.tableView.reloadData()
                self?.updateTroubleLabel()
                self?.scrollToCursorIfNeeded()
                self?.viewModel.refreshTags()
                self?.viewModel.refreshGit()
                // Re-apply the beauty-mode cursor glow after a (re)load. On launch isActivePanel
                // is set true while items are still empty, so the glow row was cleared; the reload
                // that follows the async directory load must restore it, otherwise there is no
                // visible cursor until the user clicks (which triggers cursorDidChange).
                self?.updateDetailedCursorGlow()
            }
            .store(in: &cancellables)

        // Branch-view walk progress: its own quiet channel, so a counter ticking a few
        // times a second never rebuilds the table.
        viewModel.data.branchScanDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateBranchScanBadge() }
            .store(in: &cancellables)

        // Observe cursor changes (PanelData subject)
        viewModel.data.cursorDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                // Only the wave's band: a plain cursor move cannot restyle rows the wave
                // does not reach, and repainting every visible row per keystroke was the
                // second half of the Big Stutter.
                self?.refreshVisibleRowStates(cursorBandOnly: true)
                self?.scrollToCursorIfNeeded()
            }
            .store(in: &cancellables)

        // Observe selection changes (PanelData subject)
        viewModel.data.selectionDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.refreshVisibleRowStates()
            }
            .store(in: &cancellables)

        // Observe scroll reset (PanelData subject)
        viewModel.data.scrollResetRequested
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.tableView.scrollRowToVisible(0)
            }
            .store(in: &cancellables)

        // Sync current path to tabs (PanelState @Published)
        viewModel.state.$currentPath
            .receive(on: RunLoop.main)
            // Only a real CHANGE of folder. The loader re-assigns the same path on every
            // refresh, and the file watcher refreshes 300 ms after any activity on disk — a
            // .DS_Store twitch was enough to fire this sink and take the filter bubble down
            // in the middle of typing.
            .removeDuplicates()
            .sink { [weak self] newPath in
                self?.tabsVM.panelNavigated(to: newPath)
                // Ушли из обзора сети — полосе «ищем компьютеры» там больше не место.
                self?.updateNetworkBanner()
                // Navigation clears the filter TEXT (the path setter does that), but the bubble is
                // this controller's view — left alone it keeps describing the previous folder's
                // filter, and while it is up Esc and Backspace are claimed by it instead of doing
                // their normal panel work. Re-entry is safe: clearQuickFilter guards on equality.
                self?.endQuickFilter()
            }
            .store(in: &cancellables)

        // Обход сети идёт секунды: пока он идёт, панель должна говорить «ищем», а когда
        // кончился и никого нет — «не нашли». Оба события приходят сюда.
        for name in [Notification.Name.networkBrowserDidUpdate, .networkBrowserScanDidFinish] {
            networkBannerObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                // Через тик: на то же уведомление список обновляет модель, и полосе надо
                // увидеть уже обновлённый список, а не вчерашний.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.updateNetworkBanner() }
                }
            })
        }

        // The shelf changed somewhere else — another panel, another tab. A panel showing it
        // must not keep yesterday's list.
        stackNoteObserver = NotificationCenter.default.addObserver(
            forName: .fcxlDropStackChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, viewModel.state.insideStack else { return }
            viewModel.loadStackDirectory()
        }

        // A disk image mounted into the panel takes seconds on a big image — hdiutil verifies
        // the checksum first. The spinner that already follows the cursor for a system launch
        // covers that wait too; without it Enter looks like it did nothing at all.
        viewModel.state.$launchingFilePath
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] path in
                if path == nil { self?.hideLaunchSpinner() } else { self?.showLaunchSpinner() }
            }
            .store(in: &cancellables)

        // Observe view mode changes (PanelState @Published)
        viewModel.state.$viewMode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.applyViewMode(mode)
            }
            .store(in: &cancellables)

        // Sync column widths to SortBarView when columns are resized
        NotificationCenter.default.publisher(for: NSTableView.columnDidResizeNotification, object: tableView)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isDistributingColumns else { return }
                self.syncColumnWidthsToViewModel()
            }
            .store(in: &cancellables)

        // "Reset column widths" from the SortBar context menu — return to
        // proportional auto-distribution.
        viewModel.data.columnWidthsDidReset
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.distributeColumnWidths()
                self.syncColumnWidthsToViewModel()
            }
            .store(in: &cancellables)

        // "Auto-fit all columns" from the SortBar context menu.
        viewModel.data.autoFitAllColumnsRequested
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.handleAutoFitAllColumns()
            }
            .store(in: &cancellables)

        // Re-apply column visibility AND order when changed from the header bar
        viewModel.data.columnVisibilityDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.applyColumnOrder()
                self?.applyColumnVisibility()
            }
            .store(in: &cancellables)

        // Entering or leaving the Trash swaps the whole column set. The headers are drawn by
        // SwiftUI and follow on their own; the table's columns are AppKit and have to be told,
        // or the headers end up standing over a different set of columns than the data.
        viewModel.state.$insideTrash
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyColumnVisibilityIfSetChanged()
            }
            .store(in: &cancellables)

        // Show the floating cursor spinner while a network computer's shares are being
        // listed (smbutil view + possible auth) — so the click doesn't feel dead.
        viewModel.state.$isListingNetworkShares
            .receive(on: RunLoop.main)
            .sink { [weak self] listing in
                if listing { self?.showLaunchSpinner() } else { self?.hideLaunchSpinner() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Tab Bar Actions

    func handleNewTab() {
        tabsVM.newTab(path: viewModel.currentPath)
    }

    func handleSelectTab(_ index: Int) {
        // One controller serves every tab, so nothing else takes the bubble down on a switch.
        endQuickFilter()
        let wasRemote = viewModel.insideRemote
        let savePerTab = UserDefaults.standard.bool(forKey: "fcxl.saveViewModePerTab")

        // Save current viewMode into the tab we're leaving
        let oldIndex = tabsVM.activeIndex
        let oldTab = tabsVM.tabs[oldIndex]
        if savePerTab || oldTab.viewModePinned {
            tabsVM.saveViewMode(at: oldIndex, mode: viewModel.viewMode.rawValue)
        }
        // When global setting is OFF and leaving a non-pinned tab,
        // save current viewMode as the "common mode" for all unpinned tabs.
        if !savePerTab && !oldTab.viewModePinned {
            UserDefaults.standard.set(viewModel.viewMode.rawValue, forKey: "fcxl.commonViewMode")
        }

        // Save current remote path before switching away
        if wasRemote {
            viewModel.suspendRemote()
        }

        tabsVM.selectTab(at: index)
        let tab = tabsVM.activeTab
        viewModel.scrollOnCursorChange = true

        // Restore viewMode from the tab AFTER directory loads (avoids header scroll flash)
        let pendingViewMode: ViewMode?
        if savePerTab {
            // Global setting ON: every tab stores its own mode
            if let savedMode = tab.savedViewMode, let mode = ViewMode(rawValue: savedMode), mode != viewModel.viewMode {
                pendingViewMode = mode
            } else {
                pendingViewMode = nil
            }
        } else if tab.viewModePinned, let savedMode = tab.savedViewMode, let mode = ViewMode(rawValue: savedMode), mode != viewModel.viewMode {
            // Global setting OFF, but this tab is pinned — restore its pinned mode
            pendingViewMode = mode
        } else if !tab.viewModePinned,
                  let commonRaw = UserDefaults.standard.string(forKey: "fcxl.commonViewMode"),
                  let commonMode = ViewMode(rawValue: commonRaw), commonMode != viewModel.viewMode {
            // Global setting OFF, non-pinned tab — restore the common mode
            pendingViewMode = commonMode
        } else {
            pendingViewMode = nil
        }

        if tab.isTerminal {
            // Switching TO a terminal tab — show embedded terminal
            showEmbeddedTerminal(tabID: tab.id, directory: tab.path)
            return
        }

        // Hide terminal if switching away from it. The terminal view held the
        // first responder, so we must reclaim keyboard focus for the file list
        // below — otherwise keys stop working until the user clicks another panel.
        let wasShowingTerminal = (activeTerminalID != nil)
        hideEmbeddedTerminal()

        if tab.isRemote {
            // Switching TO a remote tab — resume or re-enter remote
            let tabID = tab.id
            tabsVM.beginLoading(tabID, tag: "remote-tab-switch")
            if viewModel.remoteSession != nil {
                viewModel.resumeRemote()
            } else if let connID = tab.remoteConnectionID,
                      let conn = ConnectionManagerService.shared.connections.first(where: { $0.id == connID }) {
                let session = ConnectionManagerService.shared.createSession(for: conn)
                viewModel.enterRemote(session: session)
                Task {
                    try? await session.connect()
                    viewModel.loadDirectory()
                }
            }
            // Clear loading flag when remote task finishes
            Task { [weak self] in
                await self?.viewModel.remoteLoadTask?.value
                self?.tabsVM.endLoading(tabID, tag: "remote-tab-switch")
            }
        } else {
            // Switching TO a local tab — exit remote mode if still active
            if viewModel.insideRemote {
                viewModel.suspendRemote()
            }
            viewModel.loadDirectory(at: tab.path)
        }

        // Apply saved viewMode after layout settles
        if let mode = pendingViewMode {
            DispatchQueue.main.async { [weak self] in
                self?.viewModel.viewMode = mode
            }
        }

        // Reclaim keyboard focus after the layout (and any viewMode change) settles.
        if wasShowingTerminal {
            DispatchQueue.main.async { [weak self] in self?.claimFirstResponder() }
        }
    }

    /// Called from MainWindowController when a terminal tab is created externally.
    func activateCurrentTab() {
        handleSelectTab(tabsVM.activeIndex)
    }

    /// Close a terminal tab: kill process, remove view, switch to file tab.
    func closeTerminalTab(at index: Int) {
        handleCloseTab(index)
    }

    // MARK: - Embedded Terminal

    /// Hand the keyboard to the terminal inside `container` — the mirror of what switching to
    /// a folder tab does for the file list. Choosing the terminal TAB is choosing to type into
    /// it; making the person click into the window first was an extra step with no meaning.
    /// Async because the view may have just been added and not yet be in the window.
    private func focusTerminal(in container: NSView) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.view.window,
                  let terminal = Self.findTerminalView(in: container) else { return }
            window.makeFirstResponder(terminal)
        }
    }

    /// The SwiftTerm view buried inside the container's hosting hierarchy.
    private static func findTerminalView(in root: NSView) -> NSView? {
        if root.className.contains("TerminalView") { return root }
        for subview in root.subviews {
            if let found = findTerminalView(in: subview) { return found }
        }
        return nil
    }

    private func showEmbeddedTerminal(tabID: UUID, directory: String) {
        endQuickFilter()
        // The terminal and the monitor share this slot; whichever is added last would otherwise sit
        // on top while isMonitorMode still claimed the monitor was showing.
        if isMonitorMode { hideMonitor() }
        // Hide only the file list — all bars (tabs, volume, breadcrumb, sort) stay visible
        scrollView.isHidden = true
        alternateHosting?.isHidden = true

        // Hide all other terminals first
        for (id, container) in terminalContainers {
            container.isHidden = (id != tabID)
        }

        if let existing = terminalContainers[tabID] {
            existing.isHidden = false
            activeTerminalID = tabID
            focusTerminal(in: existing)
            return
        }

        // Create new terminal — same position as scrollView (between sortBar and statusBar)
        let term = SwiftTermContainerView(frame: .zero)
        term.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(term)

        NSLayoutConstraint.activate([
            term.topAnchor.constraint(equalTo: sortBarHosting.bottomAnchor),
            term.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            term.bottomAnchor.constraint(equalTo: statusBarHosting.topAnchor)
        ])

        term.startTerminal(directory: directory)
        TerminalProcessRegistry.shared.register(term, for: tabID)
        terminalContainers[tabID] = term
        activeTerminalID = tabID
        // The fresh terminal focuses itself when its process starts; this covers the window
        // where the tab was chosen again before that async focus had fired.
        focusTerminal(in: term)
    }

    private func hideEmbeddedTerminal() {
        for (_, container) in terminalContainers {
            container.isHidden = true
        }
        activeTerminalID = nil
        // Restore visibility based on current view mode:
        // scrollView only in detailed mode, alternateHosting in others.
        let isDetailed = (viewModel.viewMode == .detailed)
        scrollView.isHidden = !isDetailed
        alternateHosting?.isHidden = false
    }

    // MARK: - System Monitor (in-panel)

    /// Toggle the live system monitor in place of this panel's file list. The bars (tabs, volume,
    /// breadcrumb, sort, status) stay visible — same slot the embedded terminal uses.
    func toggleMonitor() {
        isMonitorMode ? hideMonitor() : showMonitor()
    }

    private func showMonitor() {
        endQuickFilter()
        scrollView.isHidden = true
        alternateHosting?.isHidden = true
        monitorService.start()
        // Esc inside the monitor closes it via the same toggle the toolbar button uses.
        let host = NSHostingView(rootView: AnyView(
            SystemMonitorView(service: monitorService,
                              onClose: { [weak self] in self?.toggleMonitor() },
                              onRestoreFocus: { [weak self] in self?.focusMonitorHost() })))
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: sortBarHosting.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: statusBarHosting.topAnchor)
        ])
        monitorHosting = host
        isMonitorMode = true
        // Take keyboard focus away from the now-hidden file list, so its key handling (F-keys,
        // Return, Space) cannot act on files the user can no longer see, and so the monitor's own
        // search field and controls receive typing.
        view.window?.makeFirstResponder(host)
    }

    /// Put keyboard focus back on the monitor after an action that opened a menu or popover.
    /// Without this the first responder is left wherever the menu dropped it, and Esc — which the
    /// responder chain delivers as cancelOperation: — no longer reaches the panel.
    private func focusMonitorHost() {
        guard isMonitorMode, let host = monitorHosting else { return }
        view.window?.makeFirstResponder(host)
    }

    private func hideMonitor() {
        monitorHosting?.removeFromSuperview()
        monitorHosting = nil
        monitorService.stop()
        let isDetailed = (viewModel.viewMode == .detailed)
        scrollView.isHidden = !isDetailed
        alternateHosting?.isHidden = false
        isMonitorMode = false
        // The monitor hosted SwiftUI controls (search field, action buttons) that took the
        // window's first responder; after removing it the file list no longer receives keys or
        // F-shortcuts. Return keyboard focus to this panel's list. Retry async so alternate
        // (brief/thumbnail) modes, whose NSCollectionView is re-created on layout, also reclaim it.
        guard isActivePanel else { return }
        claimFirstResponder()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActivePanel, !self.isMonitorMode else { return }
            self.claimFirstResponder()
        }
    }

    func handleCloseTab(_ index: Int) {
        // The index comes from a chip closure and can be stale: remote tabs auto-close on a lost
        // connection, network-mount tabs vanish on unmount, and a double-fired close on the last
        // chip arrives after the array already shrank. The model guards its own closeTab(at:), but
        // this method dereferences — and runs terminal-kill side effects — before reaching it.
        guard tabsVM.tabs.indices.contains(index) else { return }
        let closingTab = tabsVM.tabs[index]
        let isClosingActiveTab = (index == tabsVM.activeIndex)

        if closingTab.isTerminal {
            TerminalProcessRegistry.shared.terminate(tabID: closingTab.id)
            terminalContainers[closingTab.id]?.removeFromSuperview()
            terminalContainers.removeValue(forKey: closingTab.id)
            if isClosingActiveTab { activeTerminalID = nil }
        }
        // Only disconnect if closing the ACTIVE remote tab
        if closingTab.isRemote && isClosingActiveTab {
            viewModel.exitRemote()
        }

        // Unmount network volume when closing a network mount tab
        if closingTab.isNetworkMount {
            let tabPath = closingTab.path
            // Find the volume root from the tab's path
            // Имени тома может не быть: путь усох до «/Volumes/», когда том исчез, — тогда
            // и отключать нечего.
            if tabPath.hasPrefix("/Volumes/"),
               let volumeName = tabPath.dropFirst("/Volumes/".count).split(separator: "/").first {
                let volumePath = "/Volumes/" + String(volumeName)
                DispatchQueue.global(qos: .userInitiated).async {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                    proc.arguments = ["unmount", volumePath]
                    proc.standardOutput = Pipe()
                    proc.standardError = Pipe()
                    try? proc.run()
                    proc.waitUntilExit()
                    NSLog("[NetworkMount] Unmounted %@ (exit %d)", volumePath, proc.terminationStatus)
                }
            }
            if isClosingActiveTab {
                viewModel.state.insideNetworkBrowser = false
            }
        }

        tabsVM.closeTab(at: index)
        let newTab = tabsVM.activeTab
        viewModel.scrollOnCursorChange = true

        if newTab.isTerminal {
            showEmbeddedTerminal(tabID: newTab.id, directory: newTab.path)
        } else if newTab.isRemote {
            hideEmbeddedTerminal()
            if viewModel.remoteSession != nil {
                viewModel.resumeRemote()
            }
        } else {
            hideEmbeddedTerminal()
            if viewModel.insideRemote {
                viewModel.exitRemote()
            } else {
                viewModel.loadDirectory(at: newTab.path)
            }
        }

        // Closing a terminal tab and landing on a file tab: the terminal view was
        // the first responder, so reclaim keyboard focus for the panel — otherwise
        // keys stop working until the user clicks another panel and back.
        if closingTab.isTerminal && !newTab.isTerminal {
            DispatchQueue.main.async { [weak self] in self?.claimFirstResponder() }
        }
    }

    private func updateTabBarActiveState() {
        // Rebuild tab bar to update isPanelActive and currentViewModeRaw
        let tabBar = PanelTabsBarView(
            tabsVM: tabsVM,
            isPanelActive: isActivePanel,
            onNewTab: { [weak self] in self?.handleNewTab() },
            onSelectTab: { [weak self] in self?.handleSelectTab($0) },
            onCloseTab: { [weak self] in self?.handleCloseTab($0) },
            onShowFavorites: { [weak self] in
                self?.showFavoriteFoldersMenu(at: NSEvent.mouseLocation)
            },
            currentViewModeRaw: viewModel.viewMode.rawValue
        )
        tabBarHosting.rootView = tabBar
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        viewModel.items.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard viewModel.items.indices.contains(row) else { return nil }
        let item = viewModel.items[row]
        let columnID = tableColumn?.identifier.rawValue ?? ""
        // Курсор рисуется и в неактивной панели (приглушённо) — он говорит, какой файл
        // сейчас смотрят, и это не перестаёт быть правдой, когда фокус ушёл в просмотрщик.
        let isCursor = (row == viewModel.cursorIndex)

        switch columnID {
        case "icon":
            let isSelected = viewModel.selectedPaths.contains(item.path)
            return makeIconCell(for: item, isCursor: isCursor, isSelected: isSelected,
                                cursorDistance: isActivePanel ? abs(row - viewModel.cursorIndex) : Int.max,
                                in: tableView)
        case "name":
            return makeNameCell(for: item, row: row, in: tableView)
        case "type":
            return makeTextCell(
                text: item.name == ".." ? "" : item.typeDisplayName,
                id: "type", alignment: .center, isCursor: isCursor, in: tableView)
        case "size":
            return makeTextCell(text: Self.sizeCellText(for: item),
                                id: "size", alignment: .center, isCursor: isCursor, in: tableView)
        case "created":
            return makeTextCell(
                text: item.name == ".." ? "" : formatDate(item.dateCreated),
                id: "created", alignment: .center, isCursor: isCursor, in: tableView)
        case "modified":
            return makeTextCell(
                text: item.name == ".." ? "" : formatDate(item.dateModified),
                id: "modified", alignment: .center, isCursor: isCursor, in: tableView)
        case "added":
            return makeTextCell(
                text: item.name == ".." ? "" : formatDate(item.dateAdded),
                id: "added", alignment: .center, isCursor: isCursor, in: tableView)
        case "permissions":
            return makeTextCell(
                text: item.name == ".." ? "" : item.permissions,
                id: "permissions", alignment: .center, isCursor: isCursor, in: tableView)
        case "owner":
            return makeTextCell(
                text: item.name == ".." ? "" : item.owner,
                id: "owner", alignment: .center, isCursor: isCursor, in: tableView)
        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("panel-row")
        let rowView: FileListRowView
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? FileListRowView {
            rowView = existing
        } else {
            rowView = FileListRowView()
            rowView.identifier = identifier
        }

        rowView.cursorBackgroundColor = resolvedCursorBackgroundColor
        if viewModel.items.indices.contains(row) {
            let item = viewModel.items[row]
            let isRenamingRow = renamingItem?.path == item.path
            rowView.isCursor = (row == viewModel.cursorIndex) && !isRenamingRow
        rowView.isPanelActive = isActivePanel
            rowView.isItemSelected = viewModel.selectedPaths.contains(item.path)
        } else {
            rowView.isCursor = false
            rowView.isItemSelected = false
        }
        return rowView
    }

    /// Explicitly return row height — the most authoritative way to control row sizes.
    /// Prevents macOS 11+ from adding invisible gaps between rows.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        max(18, resolvedRowHeight)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // All click/double-click logic is handled in PanelNSTableView.mouseDown via clickHandler.
        // shouldSelectRow still fires for clickCount 1-2 from super.mouseDown, but we
        // already handled the click — just return false to prevent NSTableView row selection.
        return false
    }

    // MARK: - Item Activation

    /// Single entry point for opening/activating any item (Enter, double-click, brief/thumbnails click).
    /// Handles: directories, archives, remote items, regular files.
    /// Uses viewModel.open() which knows about all item types.
    /// Do NOT bypass this method — always call activateItem() for item activation.
    /// What a deep press does, in one place for every view mode.
    func handleDeepPress(row: Int) {
        guard viewModel.items.indices.contains(row) else { return }
        let item = viewModel.items[row]
        // The cursor follows the finger first, so whatever opens is what was pressed.
        viewModel.setCursor(index: row)
        switch ForceTouchSupport.action {
        case .off:
            return
        case .open:
            activateItem(item)
        case .view:
            guard item.name != ".." else { return }
            actionDelegate?.panelDidRequestView(self, item: item)
        }
    }

    func activateItem(_ item: FileItem, diskImageRoad: DiskImageOpenMode? = nil) {
        // Guard against double-firing the SAME item from multiple detection layers
        // (event monitor + collection view / tableView clickHandler).
        // Different items are allowed immediately for rapid folder navigation.
        let now = Date()
        if item.path == lastActivationPath,
           now.timeIntervalSince(lastActivationTime) < 0.3 {
            return
        }
        lastActivationTime = now
        lastActivationPath = item.path

        // A .app bundle launches as an application (Finder-style) instead of being
        // entered as a folder. "Enter as folder" is offered in the context menu.
        if viewModel.isAppBundle(item) {
            launchApplication(at: item.path)
            return
        }

        // Push navigation history for directories and archives (but not ".." — goUp handles its own history)
        if item.name != ".." && viewModel.shouldOpenAsContainer(item) {
            viewModel.pushHistory(from: viewModel.currentPath, to: item.path)
        }
        if !viewModel.open(item, diskImageRoad: diskImageRoad) {
            // Regular file (not directory, not archive) — open with the default app
            // and bring THAT app to the front (not our window). Both open forms
            // request the foreground (`activates` defaults to true); what used to
            // be missing is the cooperative-activation yield macOS 14+ requires
            // from whoever is active at launch time. ExternalOpenService does it.
            // An age envelope has no default application, and the system's answer was a
            // blank "couldn't be opened". Enter says what the file IS and offers the way in.
            if AgeCrypt.isAgeFile(item.path) {
                let choice = FCXLMessageDialog.run(FCXLMessageConfig(
                    title: L("age.enter.title"),
                    message: String(format: L("age.enter.message"), item.name),
                    icon: "lock.doc",
                    iconColor: PanelAppearanceSettings.accentColor,
                    buttons: [
                        FCXLMessageButton(title: L("button.cancel"), kind: .normal),
                        FCXLMessageButton(title: L("age.enter.decrypt"), kind: .primary)
                    ]))
                if choice.buttonIndex == 1 {
                    (view.window?.windowController as? MainWindowController)?
                        .ageDecrypt(paths: [item.path])
                }
                return
            }
            // Файл в облаке или на сервере лежит не на диске, и системной программе его
            // путь не говорит ничего: Finder отвечает «не удаётся найти файл» на файл,
            // который человек прямо сейчас видит в панели. Сначала местная копия.
            if viewModel.insideRemote {
                openRemoteWithSystem(item)
                return
            }
            let fileURL = URL(fileURLWithPath: item.path)
            showLaunchSpinner()
            // macOS ships no DjVu handler at all, so a plain open would only raise the
            // "no application can open this document" panel. Hand .djvu to the standalone
            // reader we bundle ourselves — the user installs nothing.
            if fileCategory(extension: item.fileExtension) == .djvu,
               let viewer = Self.embeddedDjVuViewerURL {
                ExternalOpenService.open([fileURL], withApplicationAt: viewer)
            } else {
                // Through the service: a launch that fails now says so instead of nothing at all.
                viewModel.operationsService.openWithSystem(item.path)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.hideLaunchSpinner()
            }
        }
    }

    /// Launch a `.app` bundle as an application (Finder-style double-click).
    /// The standalone DjVu reader shipped inside our own bundle (Contents/Library).
    /// nil when running from a plain build product rather than the assembled .app.
    static var embeddedDjVuViewerURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/FCXL DjVu Viewer.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Open the LAN browser in this panel. Single entry point: the drive bar's "Local
    /// network" item AND the centre divider's Network button both come here, so the two can
    /// never drift apart.
    func openLocalNetwork() {
        // In the CURRENT tab, like every other place you can navigate to. Opening a tab of its
        // own made browsing the network a thing to clean up afterwards, and ".." leads back out
        // of /NETWORK by itself — the tab bought nothing.
        viewModel.loadDirectory(at: NetworkBrowserService.networkRoot)

        // Bonjour and the remembered hosts are already on screen by now; the subnet sweep only
        // ADDS to them, so the spinner marks "still looking", not "nothing yet". Per-tab state,
        // so the other panel stays fully usable — and the list fills in as answers arrive
        // instead of appearing all at once when the sweep ends.
        let tabID = tabsVM.activeTab.id
        tabsVM.beginLoading(tabID, tag: "lan-scan")
        updateNetworkBanner()
        Task { @MainActor [weak self] in
            await NetworkBrowserService.shared.refreshAndWaitForLANScan()
            self?.tabsVM.endLoading(tabID, tag: "lan-scan")
            self?.updateNetworkBanner()
        }
    }

    // MARK: - Полоса обзора сети

    /// Сказать словами, что происходит: обход идёт или кончился и никого не нашёл.
    ///
    /// Пока полосы не было, панель во время обхода выглядела ровно так же, как если бы в
    /// сети никого не оказалось, — пусто и молча несколько секунд.
    func updateNetworkBanner() {
        guard viewModel.currentPath == NetworkBrowserService.networkRoot else {
            hideNetworkBanner()
            return
        }
        let hosts = viewModel.items.filter { $0.name != ".." }.count
        let status = NetworkBrowseStatus.of(scanning: NetworkBrowserService.shared.isLANScanning,
                                            hostCount: hosts)
        guard status != .hosts else { hideNetworkBanner(); return }

        let banner = NetworkBrowseBanner(status: status) {
            NSWorkspace.shared.open(LocalNetworkPermission.settingsURL)
        }
        if let host = networkBannerHost {
            host.rootView = banner
            return
        }
        let host = NSHostingView(rootView: banner)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            host.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -24)
        ])
        networkBannerHost = host
    }

    private func hideNetworkBanner() {
        networkBannerHost?.removeFromSuperview()
        networkBannerHost = nil
    }

    /// Finder-style "Connect to Server": ask for an address, let macOS mount it (it handles
    /// credentials/Keychain and its own auth sheet), then open the mounted volume in this panel.
    func connectNetworkDrive() {
        // Runloop callout — a modal opened straight from a SwiftUI button action parks the
        // main queue and leaves the dialog's buttons dead (same rule as every modal here).
        fcxlPresentModal { [weak self] in
            guard let self,
                  let address = ConnectNetworkDriveController.show(),
                  let url = ConnectNetworkDriveController.normalize(address) else { return }
            ConnectNetworkDriveController.remember(address)
            self.showLaunchSpinner()
            Task { @MainActor in
                let result = await NetworkBrowserService.mountServerURL(url)
                self.hideLaunchSpinner()
                guard let mountPoint = result.path else {
                    DialogService.shared.showError(
                        title: L("network.connectDrive.failed.title"),
                        message: L("network.connectDrive.failed.message",
                                   url.absoluteString, Int(result.status)))
                    return
                }
                self.openNetworkMount(at: mountPoint)
            }
        }
    }

    /// Сетевой том — в своей вкладке, одной на том: уже открыта — переключаемся, нет —
    /// открываем. Папка, из которой пришли, остаётся на своей вкладке, а закрытие вкладки
    /// тома — это и есть «отключиться». Сюда сходятся все входы: обзор сети, «Подключиться
    /// к серверу» и чип тома на полосе дисков — иначе в одной панели том жил во вкладке,
    /// а в другой съедал текущую.
    func openNetworkMount(at mountPoint: String) {
        let info = NetworkMountInfo.info(forPath: mountPoint)
        let root = info?.mountRoot ?? mountPoint
        if let index = tabsVM.indexOfNetworkMountTab(onVolume: root) {
            handleSelectTab(index)
        } else {
            let title = info.map { "\($0.computer): \($0.share)" }
                ?? (mountPoint as NSString).lastPathComponent
            tabsVM.newNetworkMountTab(path: mountPoint, title: title)
        }
        viewModel.loadDirectory(at: mountPoint)
    }

    private func launchApplication(at path: String) {
        showLaunchSpinner()
        ExternalOpenService.openApplication(at: URL(fileURLWithPath: path)) { [weak self] error in
            self?.hideLaunchSpinner()
            if let error {
                NSLog("FCXL: failed to launch %@ — %@", path, String(describing: error))
            }
        }
    }

    // MARK: - Launch Spinner (floating near cursor)

    private func showLaunchSpinner() {
        guard launchSpinnerWindow == nil else { return }

        let size: CGFloat = 28
        let mouseLocation = NSEvent.mouseLocation

        let window = NSWindow(
            contentRect: NSRect(origin: Self.spinnerOrigin(mouse: mouseLocation, size: size),
                                size: NSSize(width: size, height: size)),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.isReleasedWhenClosed = false   // ARC owns it (see SearchWindow bug)
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.hasShadow = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        container.layer?.cornerRadius = size / 2

        let spinner = NSProgressIndicator(frame: NSRect(x: 4, y: 4, width: size - 8, height: size - 8))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.appearance = NSAppearance(named: .darkAqua)
        container.addSubview(spinner)

        window.contentView = container
        window.orderFront(nil)
        launchSpinnerWindow = window

        // Follow the cursor
        launchSpinnerMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            guard let win = self?.launchSpinnerWindow else { return }
            win.setFrameOrigin(Self.spinnerOrigin(mouse: NSEvent.mouseLocation, size: size))
        }
        // Also track inside our own app
        launchSpinnerLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            if let win = self?.launchSpinnerWindow {
                win.setFrameOrigin(Self.spinnerOrigin(mouse: NSEvent.mouseLocation, size: size))
            }
            return event
        }

        // Safety timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.hideLaunchSpinner()
        }
    }

    private static func spinnerOrigin(mouse: NSPoint, size: CGFloat) -> NSPoint {
        NSPoint(x: mouse.x + 16, y: mouse.y - size - 2)
    }

    private func hideLaunchSpinner() {
        if let monitor = launchSpinnerMouseMonitor {
            NSEvent.removeMonitor(monitor)
            launchSpinnerMouseMonitor = nil
        }
        if let local = launchSpinnerLocalMonitor {
            NSEvent.removeMonitor(local)
            launchSpinnerLocalMonitor = nil
        }
        launchSpinnerWindow?.orderOut(nil)
        launchSpinnerWindow = nil
    }

    // MARK: - Collection View Lookup

    /// Find the NSCollectionView inside alternateHosting (for brief/thumbnails click handling).
    private func findCollectionView() -> NSCollectionView? {
        guard let hosting = alternateHosting else { return nil }
        return findSubview(ofType: NSCollectionView.self, in: hosting)
    }

    private func findSubview<T: NSView>(ofType _: T.Type, in view: NSView) -> T? {
        for sub in view.subviews {
            if let match = sub as? T { return match }
            if let found = findSubview(ofType: T.self, in: sub) { return found }
        }
        return nil
    }

    // MARK: - Key Handling

    /// Called by PanelNSTableView.keyDown and alternateHosting keyHandler — returns true if the event was handled.
    /// The trail behind "the F-keys are acting strangely": every key the panel decides on goes
    /// to the log with the state that decided it, so a session of the user pressing things can
    /// be read back afterwards instead of reconstructed from memory.
    private static let keyLog = Logger(subsystem: "com.fcxl", category: "Keys")

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard isActivePanel else { return false }
        // Ctrl+B — branch view, the subtree as one flat list (TC's key). Checked before the
        // big switch so a plain "b" keeps feeding the type-ahead search untouched.
        if event.keyCode == 11, event.modifierFlags.contains(.control) {
            Self.keyLog.debug("Ctrl+B → branch view toggle")
            viewModel.toggleBranchView()
            return true
        }
        // Esc while the branch walk is reading: stop it and show what it gathered.
        if event.keyCode == 53, viewModel.isBranchScanning {
            viewModel.cancelBranchScan()
            return true
        }
        // While the monitor replaces the file list, keys must NOT drive the hidden list (F8 would
        // delete a file the user cannot see). Esc is the one exception: it closes the monitor via
        // the same toggle the toolbar button uses, and everything else is swallowed.
        if isMonitorMode {
            if event.keyCode == 53 { toggleMonitor(); return true }
            return false
        }
        // If inline renaming is active, only F2 key handler is relevant (handled above);
        // all other keys should not reach here because the rename field is first responder.
        // But if they do (e.g. Tab), cancel rename first.
        if renamingItem != nil && event.keyCode != 120 {
            cancelInlineRename()
        }
        // Before the switch on purpose: `case 51` treats Backspace as go-up or, with
        // fcxl.backspaceAsBack off, as DELETE — correcting a typo must never ask to delete files.
        // Anything the filter does not claim falls through, so arrows, Enter and the F-keys keep
        // working on the narrowed list.
        if isQuickFilterActive, let handled = handleQuickFilterKey(event) { return handled }
        let keyCode = event.keyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mode = viewModel.viewMode

        switch keyCode {
        case 125: // Down arrow
            viewModel.scrollOnCursorChange = true
            let delta: Int
            switch mode {
            case .thumbnails:
                delta = max(1, thumbnailColumnsPerRow)
            default:
                delta = 1
            }
            moveCursor(by: delta, flags: flags)
            return true
        case 126: // Up arrow
            viewModel.scrollOnCursorChange = true
            let delta: Int
            switch mode {
            case .thumbnails:
                delta = max(1, thumbnailColumnsPerRow)
            default:
                delta = 1
            }
            moveCursor(by: -delta, flags: flags)
            return true
        case 123: // Left arrow
            viewModel.scrollOnCursorChange = true
            switch mode {
            case .detailed:
                // Left = Home in detailed mode
                moveCursorTo(index: 0, flags: flags)
            case .brief:
                moveCursor(by: -max(1, briefRowsPerColumn), flags: flags)
            case .thumbnails:
                moveCursor(by: -1, flags: flags)
            }
            return true
        case 124: // Right arrow
            viewModel.scrollOnCursorChange = true
            switch mode {
            case .detailed:
                // Right = End in detailed mode
                moveCursorTo(index: viewModel.items.count - 1, flags: flags)
            case .brief:
                moveCursor(by: max(1, briefRowsPerColumn), flags: flags)
            case .thumbnails:
                moveCursor(by: 1, flags: flags)
            }
            return true
        case 36: // Return
            if flags.contains(.command) && flags.contains(.shift) {
                // Cmd+Shift+Enter — calculate all folder sizes in current directory
                viewModel.calculateAllFolderSizes()
            } else if let item = viewModel.cursorItem {
                // Shift+Enter on a disk image takes the road the setting did NOT choose: the
                // panel when Finder is the default, Finder when the panel is. It changes
                // nothing for anything else, so plain activation stays the fallback.
                let road: DiskImageOpenMode? =
                    flags.contains(.shift) && DiskImageOpenMode.isDiskImage(item.path)
                    ? DiskImageOpenMode.chosen.opposite : nil
                // Plain Return — activate item (enter directory, open archive, open file)
                activateItem(item, diskImageRoad: road)
            }
            return true
        case 49: // Space — quickView or toggle selection (based on settings)
            let spaceAction = UserDefaults.standard.string(forKey: "fcxl.spaceAction") ?? "quickView"
            if spaceAction == "quickView" {
                // Folders are allowed — viewer shows their contents.
                if let item = viewModel.cursorItem, item.name != ".." {
                    actionDelegate?.panelDidRequestView(self, item: item)
                }
            } else {
                viewModel.toggleSelectionAtCursor(
                    rowsPerColumn: briefRowsPerColumn,
                    columnsPerRow: thumbnailColumnsPerRow
                )
            }
            return true
        case 115: // Home
            viewModel.scrollOnCursorChange = true
            moveCursorTo(index: 0, flags: flags)
            return true
        case 119: // End
            viewModel.scrollOnCursorChange = true
            moveCursorTo(index: viewModel.items.count - 1, flags: flags)
            return true
        case 116: // PageUp
            viewModel.scrollOnCursorChange = true
            moveCursor(by: -visibleRowCount(), flags: flags)
            return true
        case 121: // PageDown
            viewModel.scrollOnCursorChange = true
            moveCursor(by: visibleRowCount(), flags: flags)
            return true
        case 51: // Backspace — go up OR delete (based on settings)
            let backspaceAsBack = UserDefaults.standard.object(forKey: "fcxl.backspaceAsBack") as? Bool ?? true
            if backspaceAsBack {
                // Ровно та же дорога, что у «..» и кнопки вверх: goUp знает про корзину,
                // полку, сеть, архив и хранилища. Свой расчёт родителя не знал ничего —
                // из Корзины он вёл в корень диска (родитель «/TRASH» — это «/»), а в
                // историю писал лишний раз: загрузка каталога пишет её и сама.
                viewModel.goUp()
            } else if flags.contains(.shift) {
                // Backspace acting as delete follows the same rule: Shift skips the Trash.
                actionDelegate?.panelDidRequestDeletePermanently(self, items: selectedOrCursorItems())
            } else {
                actionDelegate?.panelDidRequestDelete(self, items: selectedOrCursorItems())
            }
            return true
        case 117: // Forward Delete — delete files; with Shift — bypassing the Trash
            if flags.contains(.shift) {
                actionDelegate?.panelDidRequestDeletePermanently(self, items: selectedOrCursorItems())
            } else {
                actionDelegate?.panelDidRequestDelete(self, items: selectedOrCursorItems())
            }
            return true
        case 48: // Tab — switch panels
            if let splitVC = parent as? MainSplitViewController {
                let newSide: MainSplitViewController.PanelSide = (side == .left) ? .right : .left
                splitVC.setActivePanel(newSide)
            }
            return true

        case 53: // ESC — clear selection, and abandon a pending cut
            if !viewModel.selectedPaths.isEmpty {
                viewModel.clearSelection()
            }
            // Otherwise the only ways out of a cut are pasting it or copying something else.
            // Covers both a local cut (isCutPending) and a remote one (remotePayload isCut).
            if FileClipboard.isCutPending || FileClipboard.remotePayload?.isCut == true {
                FileClipboard.clearCutMark()
            }
            return true

        // MARK: Cmd+A — Select All
        case 0 where flags.contains(.command): // Cmd+A
            viewModel.selectAll()
            return true

        // MARK: Cmd+C — Copy files to clipboard
        case 8 where flags.contains(.command):
            if !viewModel.insideArchive {
                copySelectedFilesToClipboard()
            }
            return true

        // MARK: Cmd+X — Cut files to clipboard (pasted as a move)
        case 7 where flags.contains(.command):
            if !viewModel.insideArchive {
                cutSelectedFilesToClipboard()
            }
            return true

        // MARK: Cmd+V — Paste files from clipboard
        case 9 where flags.contains(.command):
            if !viewModel.insideArchive {
                actionDelegate?.panelDidRequestPasteFromClipboard(self)
            }
            return true

        // MARK: F-keys — delegate to actionDelegate (MainWindowController)
        case 69:                                   // keypad + — select by mask
            NSApp.sendAction(#selector(MainWindowController.handleSelectByMask(_:)), to: nil, from: self)
            return true

        case 78:                                   // keypad − — unselect by mask
            NSApp.sendAction(#selector(MainWindowController.handleDeselectByMask(_:)), to: nil, from: self)
            return true

        case 67:                                   // keypad * — invert the selection
            NSApp.sendAction(#selector(MainWindowController.handleInvertSelection(_:)), to: nil, from: self)
            return true

        case 120: // F2 — Inline Rename or Send to Queue
            if ProgressController.canSendToQueue {
                Self.keyLog.debug("F2 → send to queue")
                ProgressController.sendFirstToQueue()
            } else {
                Self.keyLog.debug("F2 → inline rename")
                startInlineRename()
            }
            return true
        case 99: // F3 — View (folders show their contents, ".." is excluded)
            if let item = viewModel.cursorItem, item.name != ".." {
                Self.keyLog.debug("F3 → view")
                actionDelegate?.panelDidRequestView(self, item: item)
            } else {
                Self.keyLog.debug("F3 → nothing under the cursor")
            }
            return true
        case 118: // F4 — Edit; with Shift — a new text file straight into the editor, as in TC
            if flags.contains(.shift) {
                // The same condition the menu item is enabled by.
                guard !viewModel.insideArchive else { return true }
                Self.keyLog.debug("Shift+F4 → new text file")
                actionDelegate?.panelDidRequestCreateTextFile(self)
                return true
            }
            if let item = viewModel.cursorItem, !item.isDirectory, item.name != ".." {
                Self.keyLog.debug("F4 → edit")
                actionDelegate?.panelDidRequestEdit(self, item: item)
            } else {
                Self.keyLog.debug("F4 → nothing editable under the cursor")
            }
            return true
        case 96: // F5 — Copy; with Cmd — Pack (Alt is taken by macOS text navigation habits)
            if flags.contains(.command) {
                // The same dialog and rules the context menu's "Упаковать" uses — one road.
                // Not inside an archive: packing entries of an archive into another is not a
                // thing the context menu offers either.
                guard !viewModel.insideArchive else { return true }
                Self.keyLog.debug("Cmd+F5 → pack \(self.selectedOrCursorItems().count, privacy: .public)")
                actionDelegate?.panelDidRequestPack(self, items: selectedOrCursorItems())
                return true
            }
            Self.keyLog.debug("F5 → copy \(self.selectedOrCursorItems().count, privacy: .public)")
            actionDelegate?.panelDidRequestCopy(self, items: selectedOrCursorItems())
            return true
        case 97: // F6 — Move
            Self.keyLog.debug("F6 → move \(self.selectedOrCursorItems().count, privacy: .public)")
            actionDelegate?.panelDidRequestMove(self, items: selectedOrCursorItems())
            return true
        case 98: // F7 — Mkdir
            Self.keyLog.debug("F7 → mkdir")
            actionDelegate?.panelDidRequestMkdir(self)
            return true
        case 100: // F8 — Delete; with Shift — bypassing the Trash, TC-style
            if flags.contains(.shift) {
                Self.keyLog.debug("F8+Shift → erase \(self.selectedOrCursorItems().count, privacy: .public)")
                actionDelegate?.panelDidRequestDeletePermanently(self, items: selectedOrCursorItems())
            } else {
                Self.keyLog.debug("F8 → trash \(self.selectedOrCursorItems().count, privacy: .public)")
                actionDelegate?.panelDidRequestDelete(self, items: selectedOrCursorItems())
            }
            return true
        case 101: // F9 — Search; with Cmd — Unpack, the pair to Cmd+F5's pack
            if flags.contains(.command) {
                // The same road and the same rule as the context menu's "Распаковать": every
                // selected archive, or the one under the cursor. Nothing archive-shaped in the
                // selection — the key stays quiet rather than guessing.
                let archives = selectedOrCursorItems().filter { viewModel.isArchiveFile($0) }
                guard !archives.isEmpty, !viewModel.insideArchive else { return true }
                Self.keyLog.debug("Cmd+F9 → unpack \(archives.count, privacy: .public)")
                actionDelegate?.panelDidRequestExtract(self, items: archives)
                return true
            }
            // Search is handled by MainWindowController
            Self.keyLog.debug("F9 → search")
            if let controller = view.window?.windowController as? MainWindowController {
                controller.triggerSearch()
            }
            return true

        default:
            // Nothing else claimed this key: a printable character opens the quick filter.
            if canBeginQuickFilter, let characters = Self.printableCharacter(from: event) {
                beginQuickFilter(with: characters)
                return true
            }
            return false
        }
    }

    /// Returns selected items, or the cursor item if nothing is selected.
    /// Excludes ".." entry. Used by F5/F6/F8 handlers.
    func selectedOrCursorItems() -> [FileItem] {
        // Одно правило на всех — в модели: там же учитывается настройка «файл под курсором
        // участвует в операции».
        return viewModel.operationTargets
    }

    // MARK: - Cursor & Selection

    private func handleRowClick(row: Int, flags: NSEvent.ModifierFlags) {
        cancelInlineRename()
        guard viewModel.items.indices.contains(row) else { return }
        let item = viewModel.items[row]

        if flags.contains(.command) {
            // Cmd+click: toggle the clicked file, seeding the cursor file on a fresh pick.
            viewModel.cmdClickToggle(at: row)
        } else if flags.contains(.shift) {
            // Shift+click: range selection
            let anchor = viewModel.anchorIndex ?? viewModel.cursorIndex
            let lo = max(0, min(anchor, row))
            let hi = min(max(anchor, row), viewModel.items.count - 1)
            for i in lo...hi {
                let it = viewModel.items[i]
                if it.name != ".." {
                    viewModel.selectedPaths.insert(it.path)
                }
            }
        } else {
            // Plain click: if clicking on an already-selected item, defer deselect
            // so that multi-file drag can start with full selection intact.
            // Deselect happens after mouseUp (if no drag occurred).
            if viewModel.selectedPaths.contains(item.path) && item.name != ".." {
                tableView.pendingDeselectHandler = { [weak self] in
                    self?.viewModel.selectedPaths.removeAll()
                }
            } else {
                viewModel.selectedPaths.removeAll()
            }
        }
        viewModel.setCursor(index: row)
        viewModel.anchorIndex = row

        // Clicking a file is a request for the list to own the keyboard, and until now nothing
        // granted it: onBecameActive reaches setActivePanel, which returns early for the panel
        // that is ALREADY active — and the viewer covers the INACTIVE panel, so the one being
        // clicked always is — so isActivePanel.didSet never fires. Nothing in the click path
        // asks for first responder either. With the embedded viewer open, focus is still inside
        // it from the click that started the video, and the next arrow key finds no owner: it
        // reaches noResponder:, which is the beep, with the cursor frozen.
        reclaimListFocusIfLost()
    }

    private func moveCursor(by delta: Int, flags: NSEvent.ModifierFlags) {
        let oldIndex = viewModel.cursorIndex
        let newIndex = max(0, min(viewModel.items.count - 1, oldIndex + delta))
        guard newIndex != oldIndex else { return }

        if flags.contains(.shift) {
            // Total Commander's rule, and now ours: Shift+arrow TOGGLES the rows the cursor
            // LEAVES and never touches the one it lands on. Marking the landing row too was
            // how "the file I'm merely standing on" quietly joined the selection — its own
            // highlight hidden under the cursor's — and rode into the next delete with it.
            // Toggle rather than insert, so walking back over a marked stretch unmarks it.
            var index = oldIndex
            let step = newIndex > oldIndex ? 1 : -1
            while index != newIndex {
                viewModel.toggleSelection(at: index)
                index += step
            }
        }
        viewModel.setCursor(index: newIndex)
    }

    /// Jump cursor to absolute index (Home/End) with optional Shift range selection.
    private func moveCursorTo(index targetIndex: Int, flags: NSEvent.ModifierFlags) {
        let oldIndex = viewModel.cursorIndex
        let newIndex = max(0, min(viewModel.items.count - 1, targetIndex))
        guard newIndex != oldIndex else { return }

        if flags.contains(.shift) {
            selectRange(from: oldIndex, to: newIndex)
        }
        viewModel.setCursor(index: newIndex)
    }

    /// Shift+Home/End only. Inclusive of BOTH ends on purpose — "select to the top/bottom"
    /// means the first/last file too, in Total Commander as here. The row-by-row walk
    /// (Shift+arrows) is different: it toggles the rows it leaves and spares the landing one.
    private func selectRange(from start: Int, to end: Int) {
        let lo = min(start, end)
        let hi = max(start, end)
        for i in lo...hi {
            let item = viewModel.items[i]
            if item.name != ".." {
                viewModel.selectedPaths.insert(item.path)
            }
        }
    }

    private func visibleRowCount() -> Int {
        let rowHeight = tableView.rowHeight + tableView.intercellSpacing.height
        guard rowHeight > 0 else { return 20 }
        return max(1, Int(scrollView.contentView.bounds.height / rowHeight) - 1)
    }

    // MARK: - Scroll

    private func scrollToCursorIfNeeded() {
        guard viewModel.scrollOnCursorChange else { return }
        // Only the detailed mode owns this table. In brief/thumbnails the table is hidden and
        // the collection view scrolls its own cursor — scrolling the hidden table anyway parked
        // its clip offset (against a stale, un-tiled height) on the last row, and applyViewMode
        // then revealed that stale offset, showing only the last row until a manual scroll.
        guard viewModel.viewMode == .detailed else { return }
        let idx = viewModel.cursorIndex
        guard viewModel.items.indices.contains(idx) else { return }
        tableView.scrollRowToVisible(idx)
    }

    // MARK: - Inline Rename (single entry point for ALL view modes)

    /// Start inline rename for the cursor item. Called from F2, footer button, context menu.

    /// Every application macOS says can open this file, deduplicated by bundle — the same list
    /// the "Open With" submenu offers.
    private static func applicationsThatOpen(_ path: String) -> [URL] {
        let fileURL = URL(fileURLWithPath: path) as CFURL
        guard let urls = LSCopyApplicationURLsForURL(fileURL, .all)?
            .takeRetainedValue() as? [URL] else { return [] }
        var seen = Set<String>()
        return urls.filter { url in
            guard let id = Bundle(url: url)?.bundleIdentifier else { return false }
            return seen.insert(id).inserted
        }
    }

    /// Make this application the system's answer for this kind of file, and say what happened:
    /// LaunchServices can refuse (a sandboxed or unsigned app, a type nobody may claim), and a
    /// refusal that looked like success would only be discovered on the next double-click.
    private func bindDefaultApplication(_ appURL: URL, forFileAt path: String, kind: String) {
        DefaultApplication.makeDefault(appURL: appURL, forFileAt: path) { error in
            guard let error else { return }
            DialogService.shared.showOperationError(
                title: String(format: L("context.openWith.always"), kind), error: error)
        }
    }

    func startInlineRename() {
        // Cancel any previous rename first
        if renamingItem != nil { cancelInlineRename() }

        guard let item = viewModel.cursorItem, item.name != ".." else { return }
        if renameForbidden(item) {
            DialogService.shared.showError(title: L("rename.error"),
                                           message: L("trash.rename.blocked"))
            return
        }
        renamingItem = item
        renameText = item.name

        if viewModel.viewMode == .detailed {
            startDetailedInlineRename(for: item)
        } else {
            updateAlternateHosting()
        }
    }

    /// Переименовывать в корзине нельзя — ни F2, ни из меню, ни двойным щелчком по имени.
    ///
    /// Путь возврата macOS помнит по имени файла в самой корзине (записи `ptbL` и `ptbN` в её
    /// `.DS_Store`). Переименовали — записи больше не находятся, и «восстановить» становится
    /// невозможным ни у нас, ни в Finder: файл остаётся в корзине навсегда. В корзине меню
    /// переименовывать и не предлагает; здесь тот же запрет для всех остальных дверей,
    /// включая папку, ЛЕЖАЩУЮ в корзине, — она глубже, и признак там снят.
    func renameForbidden(_ item: FileItem) -> Bool {
        viewModel.state.insideTrash || TrashService.isInsideTrashFolder(item.path)
    }

    /// Commit rename — called from Enter key or OK button (all modes).
    private func commitInlineRename() {
        guard let item = renamingItem else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)

        endInlineRenameUI()

        guard !trimmed.isEmpty, trimmed != item.name else { return }
        actionDelegate?.panelDidRequestInlineRename(self, item: item, newName: trimmed)
    }

    /// Cancel rename — called from Escape, Tab, click elsewhere, panel switch (all modes).
    func cancelInlineRename() {
        guard renamingItem != nil else { return }
        endInlineRenameUI()
    }

    /// Clean up rename UI and restore focus — shared by commit and cancel.
    private func endInlineRenameUI() {
        renamingItem = nil
        renameText = ""

        // --- Detailed mode cleanup ---
        if let field = inlineRenameField {
            (field.superview as? NameCellView)?.setEditing(false)
            (field.superview as? NSTableCellView)?.textField?.isHidden = false
            field.removeFromSuperview()
            inlineRenameField = nil
            tableView.inlineRenameField = nil
            inlineRenameOKButton?.removeFromSuperview()
            inlineRenameOKButton = nil
            // Restore cursor on the row
            let row = viewModel.cursorIndex
            if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? FileListRowView {
                rowView.isCursor = true
                rowView.isPanelActive = isActivePanel
            }
        }

        // --- Brief / Thumbnails cleanup ---
        if viewModel.viewMode != .detailed {
            updateAlternateHosting()
        }

        // --- Restore keyboard focus (all modes) ---
        restoreKeyboardFocus()
    }

    /// Restore first responder to the correct list control for the current view mode.
    private func restoreKeyboardFocus() {
        if viewModel.viewMode == .detailed {
            view.window?.makeFirstResponder(tableView)
        } else if let cv = findCollectionView() {
            view.window?.makeFirstResponder(cv)
        }
    }

    // --- Detailed mode: overlay text field + OK button ---

    private func startDetailedInlineRename(for item: FileItem) {
        let row = viewModel.cursorIndex
        guard let nameColIdx = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) else { return }
        guard let cellView = tableView.view(atColumn: nameColIdx, row: row, makeIfNecessary: false) as? NSTableCellView else { return }

        let field = NSTextField(frame: .zero)
        field.stringValue = item.name
        InlineRenameLook.apply(to: field, font: InlineRenameLook.font(matching: (cellView as? NameCellView)?.label.font))
        field.isEditable = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let okBtn = NSButton(frame: .zero)
        okBtn.title = "OK"
        okBtn.bezelStyle = .recessed
        okBtn.isBordered = false
        okBtn.font = .systemFont(ofSize: 11, weight: .medium)
        okBtn.contentTintColor = PanelAppearanceSettings.accentNSColor
        okBtn.target = self
        okBtn.action = #selector(inlineRenameOKTapped(_:))
        okBtn.translatesAutoresizingMaskIntoConstraints = false
        okBtn.setContentHuggingPriority(.required, for: .horizontal)

        cellView.addSubview(field)
        cellView.addSubview(okBtn)
        NSLayoutConstraint.activate([
            okBtn.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
            okBtn.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            okBtn.widthAnchor.constraint(equalToConstant: 26),
            field.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: okBtn.leadingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
        ])

        // Put the row's own name away. NameCellView keeps its label as a plain subview, so
        // `cellView.textField` is nil here and hiding THAT quietly did nothing — which is why
        // the name kept showing through the transparent editor.
        (cellView as? NameCellView)?.setEditing(true)
        cellView.textField?.isHidden = true
        inlineRenameField = field
        inlineRenameOKButton = okBtn
        tableView.inlineRenameField = field

        if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? FileListRowView {
            rowView.isCursor = false
        }

        view.window?.makeFirstResponder(field)
        selectNameWithoutExtension(in: field, name: item.name)
    }

    /// Select only the name part (before last dot) in a text field.
    private func selectNameWithoutExtension(in field: NSTextField, name: String) {
        DispatchQueue.main.async {
            guard let editor = field.currentEditor() else { return }
            InlineRenameLook.styleEditor(of: field)
            if let dotRange = name.range(of: ".", options: .backwards),
               dotRange.lowerBound != name.startIndex {
                let len = name.distance(from: name.startIndex, to: dotRange.lowerBound)
                editor.selectedRange = NSRange(location: 0, length: len)
            } else {
                editor.selectedRange = NSRange(location: 0, length: name.utf16.count)
            }
        }
    }

    @objc private func inlineRenameOKTapped(_ sender: NSButton) {
        commitInlineRename()
    }

    // MARK: - NSTextFieldDelegate (inline rename in detailed mode)

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === inlineRenameField else { return }
        renameText = field.stringValue
    }

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard control === inlineRenameField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitInlineRename()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelInlineRename()
            return true
        }
        return false
    }

    // MARK: - Drag & Drop (NSTableView)

    /// Custom pasteboard type for remote file paths (can't use .fileURL for remote).
    private static let remotePathsType = NSPasteboard.PasteboardType("com.fcxl.remotePaths")
    /// Entries dragged out of an archive. They have no file URL — item.path is a path INSIDE
    /// the archive, so handing it over as NSURL produced a drag of a file that doesn't exist
    /// and the drop silently did nothing. Same approach as remote paths above.
    private static let archivePathsType = NSPasteboard.PasteboardType("com.fcxl.archivePaths")

    /// Открыть удалённый файл в системной программе: сначала скачать, потом отдать.
    private func openRemoteWithSystem(_ item: FileItem) {
        guard let session = viewModel.remoteSession else { return }

        // Уже скачанное открываем сразу — ни полосы, ни ожидания.
        if let ready = RemoteFileCache.shared.readyCopy(of: item,
                                                        connectionID: session.connection.id) {
            viewModel.operationsService.openWithSystem(ready)
            RemoteEditWatcher.shared.watch(localPath: ready, item: item, session: session)
            return
        }

        // Файл едет из облака, и это не мгновение: полоса с отменой обязательна. Раньше
        // здесь крутился только значок запуска — на большом файле программа выглядела
        // повисшей, и прервать это было нечем.
        let cancel = CancelBox()
        let progress = DialogService.shared.showProgress(
            title: L("queue.downloadSingle", item.name),
            message: item.name,
            cancelHandler: { cancel.raise() })
        let total = Int64(item.size)

        Task { @MainActor in
            defer { progress.close() }
            do {
                let local = try await RemoteFileCache.shared.localCopy(
                    of: item, session: session,
                    progress: { done, known in
                        let whole = total > 0 ? total : known
                        Task { @MainActor in
                            progress.update(currentFile: item.name,
                                            progress: whole > 0 ? Double(done) / Double(whole) : 0,
                                            bytesDone: done, bytesTotal: whole,
                                            filesDone: 0, filesTotal: 1)
                        }
                        return cancel.raised || progress.isCancelled
                    })
                viewModel.operationsService.openWithSystem(local)
                // Внешняя программа получила копию — с этого мгновения за ней присмотр:
                // сохранённые правки предложим отправить обратно в облако.
                RemoteEditWatcher.shared.watch(localPath: local, item: item, session: session)
            } catch let error as RemoteFileSystemError {
                if case .transferCancelled = error { return }
                DialogService.shared.showError(title: L("error.openFile"),
                                               message: error.errorDescription ?? "")
            } catch {
                DialogService.shared.showError(title: L("error.openFile"),
                                               message: error.localizedDescription)
            }
        }
    }

    /// Показать или спрятать надпись о том, почему список пуст.
    ///
    /// Только когда список пуст: беда, случившаяся при обновлении уже показанной папки,
    /// не должна закрывать собой файлы, которые человек видит.
    private func updateTroubleLabel() {
        guard troubleLabel != nil else { return }
        let text = viewModel.errorMessage
        let show = viewModel.items.isEmpty && !(text?.isEmpty ?? true)
        troubleLabel.stringValue = text ?? ""
        troubleLabel.isHidden = !show
    }

    /// Drag SOURCE — provides file URL (local) or custom pasteboard (remote).
    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard viewModel.items.indices.contains(row) else { return nil }
        let item = viewModel.items[row]
        guard item.name != ".." else { return nil }

        if viewModel.insideRemote {
            NSLog("[DD-source] remote item: \(item.name) path=\(item.path)")
            let pbItem = NSPasteboardItem()
            pbItem.setString(item.path, forType: Self.remotePathsType)
            return pbItem
        }
        if viewModel.insideArchive {
            let pbItem = NSPasteboardItem()
            pbItem.setString(item.path, forType: Self.archivePathsType)
            return pbItem
        }
        return NSURL(fileURLWithPath: item.path)
    }

    /// Multi-selection drag: when drag begins, add ALL selected items to pasteboard
    /// (not just the clicked row). NSTableView only calls pasteboardWriterForRow for
    /// the clicked row since we manage selection via PanelViewModel, not NSTableView.
    func tableView(_ tableView: NSTableView,
                   draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        // Mark drag as started so deferred deselect is skipped
        self.tableView.dragDidStart = true
        // Collect all selected items + the dragged row
        var paths: [String] = []
        for item in viewModel.items where item.name != ".." {
            if viewModel.selectedPaths.contains(item.path) {
                paths.append(item.path)
            }
        }
        // If nothing was selected, the single clicked item is already on pasteboard
        if paths.isEmpty { return }
        // If the dragged item is already in selected set, replace pasteboard with ALL selected
        let clickedRow = rowIndexes.first ?? 0
        if viewModel.items.indices.contains(clickedRow) {
            let clickedItem = viewModel.items[clickedRow]
            if viewModel.selectedPaths.contains(clickedItem.path) {
                session.draggingPasteboard.clearContents()
                if viewModel.insideRemote {
                    let items = paths.map { path -> NSPasteboardItem in
                        let pbItem = NSPasteboardItem()
                        pbItem.setString(path, forType: Self.remotePathsType)
                        return pbItem
                    }
                    session.draggingPasteboard.writeObjects(items)
                } else if viewModel.insideArchive {
                    let items = paths.map { path -> NSPasteboardItem in
                        let pbItem = NSPasteboardItem()
                        pbItem.setString(path, forType: Self.archivePathsType)
                        return pbItem
                    }
                    session.draggingPasteboard.writeObjects(items)
                } else {
                    let urls = paths.map { NSURL(fileURLWithPath: $0) }
                    session.draggingPasteboard.writeObjects(urls)
                }
                showDragStack(in: session, paths: paths)
            }
        }
    }

    /// Put a stack of files under the cursor when several are dragged.
    ///
    /// The table starts its drag from the row under the mouse and makes ONE dragging item for
    /// it, however many rows are selected — so a drag of twelve files looked exactly like a drag
    /// of one, and the person only learnt otherwise after dropping. The brief and thumbnail modes
    /// hand AppKit one item per file and get the pile for free; here the pile is drawn.
    private func showDragStack(in session: NSDraggingSession, paths: [String]) {
        guard paths.count > 1 else { return }
        let isReal = !viewModel.insideArchive && !viewModel.insideRemote
        let directories = Set(viewModel.items.filter(\.isDirectory).map(\.path))
        let icons = paths.prefix(DragStackImage.shownCards).map {
            DragStackImage.icon(forPath: $0, isReal: isReal,
                                isDirectory: directories.contains($0))
        }
        let image = DragStackImage.make(icons: icons, count: paths.count,
                                        accent: PanelAppearanceSettings.accentNSColor)
        // Centred on the cursor rather than left hanging where the row happened to be. The
        // point comes from the window (the session's own location is in SCREEN coordinates,
        // which `convert(_:from: nil)` would misread as window ones).
        let inWindow = tableView.window?.mouseLocationOutsideOfEventStream ?? .zero
        let origin = tableView.convert(inWindow, from: nil)
        let frame = NSRect(x: origin.x - image.size.width / 2,
                           y: origin.y - image.size.height / 2,
                           width: image.size.width, height: image.size.height)
        session.enumerateDraggingItems(options: [], for: tableView,
                                       classes: [NSPasteboardItem.self, NSURL.self],
                                       searchOptions: [:]) { item, index, stop in
            if index == 0 {
                item.setDraggingFrame(frame, contents: image)
            } else {
                // Anything else the table made carries no picture of its own — one pile is
                // the whole point.
                item.setDraggingFrame(frame, contents: NSImage(size: NSSize(width: 1, height: 1)))
            }
        }
    }

    /// Drop TARGET validation — accept file URLs or remote paths, highlight directory targets.
    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Archive entries first: they carry no file URL, so without this the drop was
        // rejected here and acceptDrop never even ran — which is why dragging out of an
        // archive appeared to do nothing at all.
        let archivePaths = droppedArchivePaths(from: info)
        if !archivePaths.isEmpty {
            if viewModel.insideArchive {
                // One exception to "archive → archive is not a thing": dropping an entry onto
                // the ".." row extracts it OUT, into the folder next to the archive — Total
                // Commander's gesture. Only for THIS panel's own drag: entries arriving from
                // the other panel belong to a different archive, and extracting them here
                // would name the wrong source.
                guard info.draggingSource as? NSTableView === tableView,
                      viewModel.items.indices.contains(row),
                      viewModel.items[row].name == ".." else { return [] }
                tableView.setDropRow(row, dropOperation: .on)
                return .copy
            }
            if viewModel.items.indices.contains(row) {
                let target = viewModel.items[row]
                tableView.setDropRow(target.isDirectory && target.name != ".." ? row : -1,
                                     dropOperation: .on)
            } else {
                tableView.setDropRow(-1, dropOperation: .on)
            }
            // Always copy: extracting is the only outcome, and you cannot MOVE a file out of
            // an archive by dragging it (that would mean deleting the entry behind the user).
            return .copy
        }

        let remotePaths = droppedRemotePaths(from: info)
        let filePaths = droppedFilePaths(from: info)
        let isRemoteDrop = !remotePaths.isEmpty
        let paths = isRemoteDrop ? remotePaths : filePaths
        if paths.isEmpty {
            let types = info.draggingPasteboard.types ?? []
            NSLog("[DD-validate] REJECTED — no paths. PB types: \(types.map(\.rawValue))")
        }
        guard !paths.isEmpty else { return [] }

        let shouldMove = dropShouldMove(info)

        // If hovering over a directory, highlight it as drop target
        if viewModel.items.indices.contains(row) {
            let target = viewModel.items[row]
            if target.isDirectory, target.name != ".." {
                tableView.setDropRow(row, dropOperation: .on)
            } else {
                tableView.setDropRow(-1, dropOperation: .on)
            }
        } else {
            tableView.setDropRow(-1, dropOperation: .on)
        }

        return shouldMove ? .move : .copy
    }

    /// Drop TARGET acceptance — trigger copy/move via actionDelegate.
    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        // Entries dragged out of an archive: the only sensible outcome is to EXTRACT them
        // into the target folder — dropping a still-compressed blob into a plain folder would
        // be useless. Handled before the copy/move path, which cannot read them at all.
        let archiveEntries = droppedArchivePaths(from: info)
        if !archiveEntries.isEmpty {
            if viewModel.insideArchive {
                // validateDrop allowed nothing but the ".." row in this state.
                extractDroppedEntriesOut(archiveEntries)
                return true
            }
            var targetFolder: FileItem?
            if viewModel.items.indices.contains(row) {
                let item = viewModel.items[row]
                if item.isDirectory, item.name != ".." { targetFolder = item }
            }
            let destination = targetFolder?.path ?? viewModel.currentPath
            extractDroppedEntries(archiveEntries, to: destination)
            return true
        }

        let remotePaths = droppedRemotePaths(from: info)
        let isRemoteDrop = !remotePaths.isEmpty
        NSLog("[DD-accept] isRemoteDrop=\(isRemoteDrop) remotePaths=\(remotePaths.count) row=\(row)")
        let localPaths = isRemoteDrop ? [] : droppedFilePaths(from: info)
        guard isRemoteDrop || !localPaths.isEmpty else { return false }

        var targetFolder: FileItem?
        if viewModel.items.indices.contains(row) {
            let item = viewModel.items[row]
            if item.isDirectory, item.name != ".." {
                targetFolder = item
            }
        }

        let shouldMove = dropShouldMove(info)
        let destination = targetFolder?.path ?? viewModel.currentPath

        let droppedItems: [FileItem]
        if isRemoteDrop {
            // Remote ДД: look up FileItems from the OTHER panel's viewModel
            let remotePathSet = Set(remotePaths)
            // Find items in either panel's viewModel (the source panel has them)
            let allPanelItems: [FileItem]
            if let otherVC = findOtherPanelVC() {
                allPanelItems = otherVC.viewModel.items + viewModel.items
            } else {
                allPanelItems = viewModel.items
            }
            droppedItems = allPanelItems.filter { remotePathSet.contains($0.path) && $0.name != ".." }
        } else {
            droppedItems = localPaths.compactMap { FileItem.fromPath($0) }
        }
        guard !droppedItems.isEmpty else { return false }

        // Open the copy/move dialog a short beat AFTER the drop, via a runloop TIMER (not
        // GCD — a parked main queue would starve the modal's SwiftUI buttons). The delay lets
        // the drag-and-drop session AND the system's trackpad-gesture state fully unwind first;
        // otherwise a modal opened straight off a mouse drag blocks Mission Control / space
        // switching until it's dismissed (F5 has no drag session, so it's unaffected).
        let move = shouldMove
        let items = droppedItems
        let dest = destination
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self else { return }
            if move {
                self.actionDelegate?.panelDidRequestMove(self, items: items, to: dest)
            } else {
                self.actionDelegate?.panelDidRequestCopy(self, items: items, to: dest)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    /// Find the other panel's ViewController (for remote ДД item lookup).
    private func findOtherPanelVC() -> PanelViewController? {
        guard let splitVC = parent as? MainSplitViewController else { return nil }
        return self === splitVC.leftPanelVC ? splitVC.rightPanelVC : splitVC.leftPanelVC
    }

    /// Extract remote paths from drag pasteboard (custom type for remote ДД).
    private func droppedRemotePaths(from info: NSDraggingInfo) -> [String] {
        let pasteboard = info.draggingPasteboard
        guard let items = pasteboard.pasteboardItems else { return [] }
        let paths = items.compactMap { $0.string(forType: Self.remotePathsType) }
        return paths
    }

    /// Entries were dropped out of an archive: hand the work to the window controller,
    /// which owns the operations service — same as every other panel-initiated operation.
    /// The source archive comes from the OTHER panel, the one sitting inside it.
    private func extractDroppedEntries(_ entries: [String], to destination: String) {
        // The panel sitting inside the archive is the source: THIS one when entries were
        // dropped onto its own ".." row, the OTHER one for a cross-panel drag.
        let sourceVC = viewModel.insideArchive ? self : findOtherPanelVC()
        guard let sourceVC, sourceVC.viewModel.insideArchive,
              let archivePath = sourceVC.viewModel.archivePath else { return }
        actionDelegate?.panelDidRequestExtractEntries(self, entries: entries,
                                                      fromArchive: archivePath,
                                                      to: destination)
    }

    /// Entries dropped onto ".." while THIS panel is inside the archive: extract them into the
    /// folder ".." leads out to — the one holding the archive.
    func extractDroppedEntriesOut(_ entries: [String]) {
        guard let destination = viewModel.archiveParentFolder else { return }
        extractDroppedEntries(entries, to: destination)
    }

    /// Entry paths dragged out of an archive (custom type — they have no file URL).
    private func droppedArchivePaths(from info: NSDraggingInfo) -> [String] {
        guard let items = info.draggingPasteboard.pasteboardItems else { return [] }
        return items.compactMap { $0.string(forType: Self.archivePathsType) }
    }

    /// Extract file paths from drag pasteboard.
    private func droppedFilePaths(from info: NSDraggingInfo) -> [String] {
        let pasteboard = info.draggingPasteboard
        let classes: [AnyClass] = [NSURL.self]
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: classes, options: options) as? [URL] else {
            return []
        }
        return Array(Set(urls.map(\.path)))
    }

    /// Determine if the drop should be a move (Cmd or Shift held, or source says move-only).
    private func dropShouldMove(_ info: NSDraggingInfo) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if flags.contains(.command) || flags.contains(.shift) {
            return true
        }
        return info.draggingSourceOperationMask.contains(.move) &&
            !info.draggingSourceOperationMask.contains(.copy)
    }

    // MARK: - Row Refresh

    /// Push cursor-beauty settings + the cursor row into the detailed-mode table so it can
    /// paint the feathered glow. Hides the glow when beauty is off, the panel is inactive,
    /// or there's no valid cursor.
    private func updateDetailedCursorGlow() {
        guard let table = tableView else { return }
        let beautyOn = UserDefaults.standard.bool(forKey: PanelAppearanceSettings.beautyModeEnabledKey)
        table.cursorGlowColor = resolvedCursorBackgroundColor ?? .selectedContentBackgroundColor
        table.cursorGlowBlur = PanelAppearanceSettings.resolvedCursorGlow
        table.cursorGlowHeightFraction = PanelAppearanceSettings.resolvedCursorHeightFraction
        table.cursorGlowWidthFraction = PanelAppearanceSettings.resolvedCursorWidthFraction
        table.cursorGlowCorner = PanelAppearanceSettings.resolvedCursorCorner
        table.cursorGlowOffsetX = PanelAppearanceSettings.resolvedCursorOffsetX
        table.cursorGlowOffsetY = PanelAppearanceSettings.resolvedCursorOffsetY
        table.cursorGlowAnchorX = PanelAppearanceSettings.resolvedCursorAnchorX
        table.cursorGlowAnchorY = PanelAppearanceSettings.resolvedCursorAnchorY
        let idx = viewModel.cursorIndex
        if beautyOn, isActivePanel, viewModel.items.indices.contains(idx) {
            table.cursorGlowRow = idx
        } else {
            table.cursorGlowRow = nil
        }
    }

    /// The last cursor row this refresh styled — the other end of the band on the next move.
    private var lastCursorBandRow = -1

    /// Visible rows that still carry the cursor highlight while not BEING the cursor row.
    ///
    /// The band refresh only repaints rows between the previous cursor row and the new one, and
    /// `lastCursorBandRow` goes stale whenever the cursor moves while this table is off screen —
    /// switching to brief or thumbnails does exactly that. The lit row then falls outside the
    /// band, nobody clears it, and the panel shows TWO cursors. Pure, so the rule is testable
    /// without a table.
    static func staleCursorRows(visible: Range<Int>, cursor: Int,
                                carriesCursor: (Int) -> Bool) -> [Int] {
        visible.filter { $0 != cursor && carriesCursor($0) }
    }

    private func refreshVisibleRowStates(cursorBandOnly: Bool = false) {
        updateDetailedCursorGlow()
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.length > 0 else { return }
        var start = max(0, visibleRange.location)
        var end = min(tableView.numberOfRows, visibleRange.location + visibleRange.length)
        if cursorBandOnly {
            // Everything between the old and the new cursor rows, padded by the wave's
            // reach, clipped to what is on screen. A one-row step touches a handful of
            // rows; Home/End touches at most one screenful — never the whole list.
            let spread = PanelAppearanceSettings.resolvedCursorIconZoomSpread + 1
            let current = viewModel.cursorIndex
            let previous = lastCursorBandRow >= 0 ? lastCursorBandRow : current
            start = max(start, min(current, previous) - spread)
            end = min(end, max(current, previous) + spread + 1)
            lastCursorBandRow = current
            guard start < end else { return }
        } else {
            lastCursorBandRow = viewModel.cursorIndex
        }
        if cursorBandOnly {
            // One cursor at a time, whatever the band covered — see staleCursorRows.
            let visible = max(0, visibleRange.location)..<min(tableView.numberOfRows,
                                                              visibleRange.location + visibleRange.length)
            for row in Self.staleCursorRows(visible: visible, cursor: viewModel.cursorIndex, carriesCursor: {
                (tableView.rowView(atRow: $0, makeIfNecessary: false) as? FileListRowView)?.isCursor ?? false
            }) {
                (tableView.rowView(atRow: row, makeIfNecessary: false) as? FileListRowView)?.isCursor = false
            }
        }
        for row in start..<end {
            guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? FileListRowView,
                  viewModel.items.indices.contains(row)
            else { continue }
            let item = viewModel.items[row]
            rowView.cursorBackgroundColor = resolvedCursorBackgroundColor
            rowView.isCursor = (row == viewModel.cursorIndex)
            rowView.isPanelActive = isActivePanel
            rowView.isItemSelected = viewModel.selectedPaths.contains(item.path)
            // The wave: neighbours lift too, easing down with distance from the cursor.
            // Icon and text ride the same distance, so they grow together.
            let distance = isActivePanel ? abs(row - viewModel.cursorIndex) : Int.max
            // Icon "lift" on the cursor row (settings-gated) — re-applied as the cursor moves.
            let iconColForZoom = tableView.column(withIdentifier: .init("icon"))
            if iconColForZoom >= 0 {
                CursorIconZoom.apply(to: (rowView.view(atColumn: iconColForZoom) as? NSTableCellView)?.imageView,
                                     scale: CursorIconZoom.scale(atDistance: distance))
            }
            // Also update name color + marquee scroll on/off
            let nameColIdx = tableView.column(withIdentifier: .init("name"))
            if nameColIdx >= 0,
               let cellView = rowView.view(atColumn: nameColIdx) as? NSTableCellView,
               let marquee = cellView.subviews.compactMap({ $0 as? MarqueeTextField }).first {
                let isCursor = rowView.isCursor
                let isSelected = rowView.isItemSelected
                let defaultColor = colorForName(of: item)
                // Курсорный цвет имени — только в той панели, которой управляют: иначе в
                // соседней остаётся ярко подсвеченная строка, и панели выглядят одинаково
                // активными.
                let nameColor = PanelAppearanceSettings.fileNameColor(
                    isCursor: isCursor && isActivePanel, isSelected: isSelected,
                    cursor: resolvedCursorNameColor, selected: PanelAppearanceSettings.selectedNameNSColor, normal: defaultColor)
                // Re-apply the name font so the enlargement follows the cursor as it moves
                // (the cell itself isn't rebuilt on a plain cursor move) — and the
                // neighbours within reach get their share of it.
                let rowFont = PanelAppearanceSettings.resolvedListFont(atDistance: distance)

                // A symlink/hardlink name is an ATTRIBUTED string (italic + a 🔗 attachment).
                // Assigning .textColor on such a field throws that attributed string away and
                // re-renders a plain one — which is why the link marker only survived on rows
                // this refresh had not touched yet. Rebuild it with the new colour instead.
                marquee.font = rowFont
                marquee.attributedStringValue = decoratedName(for: item, font: rowFont, color: nameColor)
                // The cursor row draws at a larger font, so the dots are sized for it as well.
                (cellView as? NameCellView)?.setTags(viewModel.tagsByPath[item.path] ?? [], font: rowFont)
                (cellView as? NameCellView)?.setGit(viewModel.gitByPath[item.path],
                                                    font: gitGutterFont, gutter: gitGutterWidth,
                                                    isCursor: isCursor)
                (cellView as? NameCellView)?.setVaultLock(
                    vaultLockImage(for: item, ink: nameColor, isCursor: isCursor))
                if isCursor {
                    marquee.startMarqueeIfOverflowing(delay: 1.5)
                } else {
                    marquee.stopMarquee()
                }
            }
            // Metadata columns (type/size/dates/…) must track the cursor contrast too.
            let metadataColor = Self.metadataTextColor(
                isCursor: rowView.isCursor, isActivePanel: isActivePanel,
                cursor: resolvedCursorNameColor, file: resolvedFileNameColor)
            for col in 0..<tableView.numberOfColumns {
                let colID = tableView.tableColumns[col].identifier.rawValue
                guard colID != "icon", colID != "name" else { continue }
                (rowView.view(atColumn: col) as? NSTableCellView)?.textField?.textColor = metadataColor
            }
            // The ".." chevron tracks the ".." text colour exactly (template + tint).
            if item.name == ".." {
                let iconColIdx = tableView.column(withIdentifier: .init("icon"))
                if iconColIdx >= 0,
                   let iconCell = rowView.view(atColumn: iconColIdx) as? NSTableCellView {
                    iconCell.imageView?.contentTintColor = upChevronTint(
                        isCursor: rowView.isCursor, isSelected: rowView.isItemSelected)
                }
            }
        }
    }

    // MARK: - Cell Factories

    /// Tint for the ".." chevron — EXACTLY the ".." name colour: folder-name colour
    /// normally, accent when selected, cursor contrast on the cursor row.
    /// Цвет значка «..» — ровно тот же, что у его текста, тем же правилом. Раньше значок
    /// брал цвет курсора и в неактивной панели, где текст его уже не берёт: в новой пустой
    /// папке стрелка горела зелёной подсветкой курсора над серым «..».
    /// Замок хранилища для колонки пометок подробного вида; nil — не хранилище.
    private func vaultLockImage(for item: FileItem, ink: NSColor, isCursor: Bool) -> NSImage? {
        guard item.name != "..", VaultService.isVault(item.path) else { return nil }
        return GitBadgeChip.vaultLockImage(unlocked: VaultService.isMountedFast(item.path),
                                           font: gitGutterFont,
                                           ink: isCursor && isActivePanel ? GitBadgeChip.cursorInk : ink)
    }

    private func upChevronTint(isCursor: Bool, isSelected: Bool) -> NSColor {
        PanelAppearanceSettings.fileNameColor(
            isCursor: isCursor && isActivePanel, isSelected: isSelected,
            cursor: resolvedCursorNameColor, selected: PanelAppearanceSettings.selectedNameNSColor,
            normal: resolvedFolderNameColor)
    }

    private func makeIconCell(for item: FileItem, isCursor: Bool, isSelected: Bool,
                              cursorDistance: Int, in tableView: NSTableView) -> NSView {
        let id = NSUserInterfaceItemIdentifier("icon-cell")
        let iconSize = resolvedDetailedIconSize()
        let edgeInset = PanelAppearanceSettings.resolvedIconEdgeInset
        let cellView: NSTableCellView
        let imageView: NSImageView

        if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView,
           let existingImage = existing.imageView {
            cellView = existing
            imageView = existingImage
            // Update size constraints for current scale
            for constraint in imageView.constraints {
                if constraint.firstAttribute == .width || constraint.firstAttribute == .height {
                    constraint.constant = iconSize
                }
            }
        } else {
            cellView = NSTableCellView()
            cellView.identifier = id
            imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(imageView)
            cellView.imageView = imageView
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: edgeInset),
                imageView.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: iconSize),
                imageView.heightAnchor.constraint(equalToConstant: iconSize),
            ])
        }
        // Left inset of the icon from the panel edge (settings) — reused cells too.
        for c in cellView.constraints where c.firstItem === imageView && c.firstAttribute == .leading {
            c.constant = edgeInset
        }

        if item.name == ".." {
            // Go-up entry — a thin double chevron drawn centred in the regular icon box,
            // so it stays aligned with the folder icons; its scale sizes the glyph itself.
            // It's a template image: tinted to EXACTLY the ".." text colour.
            imageView.image = PanelAppearanceSettings.upArrowIcon(size: iconSize, scale: resolvedUpIconScale)
            imageView.contentTintColor = upChevronTint(isCursor: isCursor, isSelected: isSelected)
        } else if item.isAppBundle, FileManager.default.fileExists(atPath: item.path) {
            // .app bundle — its own icon, remembered per path.
            imageView.image = AppIconCache.icon(path: item.path, size: iconSize)
            imageView.contentTintColor = nil
        } else if item.isDirectory {
            // Network browser: special icons for computers and shares
            if item.path.hasPrefix(NetworkBrowserService.networkRoot + "/") && item.name != ".." {
                let isShare = NetworkBrowserService.shareInfo(from: item.path) != nil
                let symbolName = isShare ? "folder.badge.gearshape" : "desktopcomputer"
                let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                    ?? NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!
                let config = NSImage.SymbolConfiguration(pointSize: iconSize * 0.75, weight: .medium)
                imageView.image = symbol.withSymbolConfiguration(config)
                imageView.contentTintColor = isShare ? .systemBlue : .systemOrange
            } else if let custom = CustomFolderIconService.icon(for: item, size: iconSize) {
                // A picture the user assigned in Finder wins over the configured folder style.
                imageView.image = custom
                imageView.contentTintColor = nil
            } else {
                imageView.image = FolderIconRenderer.image(
                    style: resolvedFolderIconStyle,
                    size: iconSize,
                    tintColor: resolvedFolderIconTintColor
                )
            }
        } else {
            imageView.image = iconForFile(item)
        }
        // Badge AFTER the icon is chosen, so it works for files, folders and .app bundles
        // alike — a symlink to any of them still reads as a symlink.
        if item.isSymlink, item.name != "..", let base = imageView.image {
            imageView.image = Self.symlinkBadgedIcon(base, size: iconSize)
            imageView.contentTintColor = nil                  // composite, not a template
        }

        // "Lift" the icon on the cursor row (settings-gated). Detailed mode reads the scale
        // live; refreshVisibleRowStates re-applies it as the cursor moves.
        CursorIconZoom.apply(to: imageView, scale: CursorIconZoom.scale(atDistance: cursorDistance))
        return cellView
    }

    private func resolvedDetailedIconSize() -> CGFloat {
        max(10, 16 * max(resolvedIconScale, PanelAppearanceSettings.minimumIconScale))
    }

    /// The row makes room for the icon rather than cropping it.
    ///
    /// The icon used to be capped at the row's height, so past a certain scale the slider did
    /// nothing at all — the setting said 3× and the list stayed the same. A row is as tall as
    /// its own setting OR as tall as the icon needs, whichever is more.
    private var effectiveRowHeight: CGFloat {
        max(18, max(resolvedRowHeight, resolvedDetailedIconSize() + 4))
    }

    private func makeNameCell(for item: FileItem, row: Int, in tableView: NSTableView) -> NSView {
        let id = NSUserInterfaceItemIdentifier("name-cell")
        let cellView: NameCellView
        if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? NameCellView {
            cellView = existing
        } else {
            cellView = NameCellView()
            cellView.identifier = id
        }
        let label = cellView.label

        // Name leading is just a small padding — the gap between icon and name
        // is already handled by the icon column width (iconSize + gap + 4).

        let isCursor = (row == viewModel.cursorIndex)
        let cursorDistance = isActivePanel ? abs(row - viewModel.cursorIndex) : Int.max
        let isSelected = viewModel.selectedPaths.contains(item.path)
        let defaultColor = colorForName(of: item)
        let textColor = PanelAppearanceSettings.fileNameColor(
            isCursor: isCursor && isActivePanel, isSelected: isSelected,
            cursor: resolvedCursorNameColor, selected: PanelAppearanceSettings.accentNSColor, normal: defaultColor)

        // Name uses the configured list font, enlarged by the cursor wave: full on the
        // cursor row, easing down over the neighbours it reaches.
        let baseFont = PanelAppearanceSettings.resolvedListFont(atDistance: cursorDistance)
        label.font = baseFont
        label.attributedStringValue = decoratedName(for: item, font: baseFont, color: textColor)
        cellView.setTags(viewModel.tagsByPath[item.path] ?? [], font: baseFont)
        // The gutter is drawn at the LIST's font, not the cursor-enlarged one: a column that
        // widened under the cursor would shift every name as the cursor passed.
        cellView.setGit(viewModel.gitByPath[item.path], font: gitGutterFont,
                        gutter: gitGutterWidth, isCursor: isCursor)
        cellView.setVaultLock(vaultLockImage(for: item, ink: textColor, isCursor: isCursor))
        // The eye lives at the cell's edge, outside the truncating label — a long name
        // ends in "…" BEFORE the eye instead of swallowing it.
        cellView.setHiddenEye(item.isHidden && item.name != ".."
            ? Self.hiddenEyeImage(pointSize: baseFont.pointSize * 0.72,
                                  color: textColor.withAlphaComponent(0.55))
            : nil)

        // Marquee scroll for the cursor row when the name is truncated.
        if isCursor {
            label.startMarqueeIfOverflowing(delay: 1.5)
        } else {
            label.stopMarquee()
        }
        return cellView
    }

    private func makeTextCell(text: String, id: String, alignment: NSTextAlignment,
                              isCursor: Bool = false, in tableView: NSTableView) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("text-\(id)")
        let cellView: NSTableCellView
        let label: NSTextField

        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView,
           let existingLabel = existing.textField {
            cellView = existing
            label = existingLabel
        } else {
            cellView = NSTableCellView()
            cellView.identifier = identifier
            label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(label)
            cellView.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        label.stringValue = text
        label.alignment = alignment
        // Metadata columns follow the list font/size (but not the cursor enlargement, so
        // columns keep their width).
        label.font = PanelAppearanceSettings.resolvedListFont()
        // On the cursor row the metadata columns must stay readable against the
        // cursor background — use the (contrasting) cursor name colour, slightly
        // dimmed so the name still reads as primary.
        label.textColor = Self.metadataTextColor(isCursor: isCursor, isActivePanel: isActivePanel,
                                                 cursor: resolvedCursorNameColor,
                                                 file: resolvedFileNameColor)
        return cellView
    }

    /// The colour of a type/size/date cell. The cursor colour only on the ACTIVE panel's
    /// cursor row: the inactive panel draws no cursor bar, and a row whose name was plain while
    /// its type, date and size stayed in the cursor's green was the giveaway — the cells were
    /// made with `isCursor` alone whenever the list was rebuilt.
    static func metadataTextColor(isCursor: Bool, isActivePanel: Bool,
                                  cursor: NSColor, file: NSColor) -> NSColor {
        isCursor && isActivePanel ? cursor.withAlphaComponent(0.8) : file.withAlphaComponent(0.7)
    }

    /// Fingers left — up. Fingers right — back DOWN the trail the ups left, one folder per
    /// swipe, all the way to where the climb began; with no trail beneath, forward in the
    /// history; with none of that, into the folder under the cursor.
    private func performSwipe(_ direction: SwipeNavigator.Direction) {
        switch direction {
        case .up:
            viewModel.goUp()
        case .into:
            if viewModel.descendTrail() { return }
            if viewModel.canGoForward {
                viewModel.goForward()
            } else if let item = viewModel.cursorItem, item.isDirectory, item.name != ".." {
                _ = viewModel.open(item)
            }
        }
    }

    // MARK: - Symlink Badge

    /// Base icon + a Finder-style link arrow in the bottom-left corner.
    ///
    /// The list already italicises a symlink's name and puts a 🔗 after it, but the ICON said
    /// nothing at all — you had to read the row to know. Finder badges the icon itself, which
    /// is what the eye actually looks at.
    static func symlinkBadgedIcon(_ base: NSImage, size: CGFloat) -> NSImage {
        let badged = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            base.draw(in: rect)

            let d = max(7, size * 0.52)                       // badge diameter
            let circle = NSRect(x: 0, y: 0, width: d, height: d).insetBy(dx: 0.5, dy: 0.5)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            let ring = NSBezierPath(ovalIn: circle)
            ring.lineWidth = 0.75
            ring.stroke()

            if let arrow = NSImage(systemSymbolName: "arrow.up.forward",
                                   accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: d * 0.58, weight: .heavy)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
                if let glyph = arrow.withSymbolConfiguration(config) {
                    let g = glyph.size
                    glyph.draw(in: NSRect(x: circle.midX - g.width / 2,
                                          y: circle.midY - g.height / 2,
                                          width: g.width, height: g.height))
                }
            }
            return true
        }
        badged.isTemplate = false                             // it is a composite, not a mask
        return badged
    }

    /// Builds an attributed string: "filename 🔒" with an outline padlock after the name —
    /// the same quiet spot the symlink's chain link lives in. Shut in the row's own colour
    /// while the vault is locked; open and green while its volume is mounted. The folder
    /// icon stays clean — the story is told beside the name, not on top of the artwork.
    static func vaultAttributedName(_ name: String, font: NSFont, color: NSColor,
                                    unlocked: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: name + " ",
            attributes: [.font: font, .foregroundColor: color]
        )
        // Того же роста, что значок ветки Git в подробном виде: пометки — одна семья.
        let symbolSize = GitBadgeChip.markSymbolPointSize(for: font)
        let symbolName = unlocked ? "lock.open" : "lock"
        // The open padlock burns red — a quiet warning that the safe is standing open.
        let glyphColor: NSColor = unlocked ? .systemRed : color
        if let symbolImage = NSImage(systemSymbolName: symbolName,
                                     accessibilityDescription: "vault") {
            let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
            let tinted = symbolImage.withSymbolConfiguration(config) ?? symbolImage
            let attachment = NSTextAttachment()
            attachment.image = tinted
            // Equal HEIGHT for both states: "lock.open" is a wider symbol (the shackle swings
            // out to the side), and squeezing it into the same square shrank the whole
            // padlock. Width follows the glyph's own proportions instead.
            let g = tinted.size
            let width = g.height > 0 ? symbolSize * g.width / g.height : symbolSize
            let yOffset = (font.capHeight - symbolSize) / 2
            attachment.bounds = CGRect(x: 0, y: yOffset, width: width, height: symbolSize)
            let iconStr = NSMutableAttributedString(attachment: attachment)
            iconStr.addAttribute(.foregroundColor, value: glyphColor,
                                 range: NSRange(location: 0, length: iconStr.length))
            result.append(iconStr)
        }
        return result
    }

    /// Builds an attributed string: "filename ☁" for a file that lives in iCloud Drive.
    ///
    /// Only the states worth a mark get one: a file that is HERE and current looks like any
    /// other file, because that is what it is. The badge appears when the file is not on this
    /// Mac, is on its way, or is behind the cloud's version — the cases where opening it needs
    /// the network, and a person deserves to know before the double click.
    static func cloudAttributedName(_ name: String, font: NSFont, color: NSColor,
                                    state: CloudState) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: name + " ",
            attributes: [.font: font, .foregroundColor: color])
        let symbolName: String
        let glyphColor: NSColor
        switch state {
        case .inCloudOnly:   symbolName = "icloud.and.arrow.down"; glyphColor = .systemBlue
        case .downloading:   symbolName = "arrow.down.circle.dotted"; glyphColor = .systemBlue
        case .uploading:     symbolName = "icloud.and.arrow.up"; glyphColor = .systemBlue
        case .outdated:      symbolName = "exclamationmark.icloud"; glyphColor = .systemOrange
        case .here, .local:  return result                         // nothing to say
        }
        let symbolSize = font.pointSize * 0.9
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "iCloud") {
            let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
            let tinted = symbol.withSymbolConfiguration(config) ?? symbol
            let attachment = NSTextAttachment()
            attachment.image = tinted
            // Equal HEIGHT, width from the glyph's own proportions — the cloud symbols are
            // wider than they are tall, and squeezing them into a square shrinks them.
            let g = tinted.size
            let width = g.height > 0 ? symbolSize * g.width / g.height : symbolSize
            let yOffset = (font.capHeight - symbolSize) / 2
            attachment.bounds = CGRect(x: 0, y: yOffset, width: width, height: symbolSize)
            let iconStr = NSMutableAttributedString(attachment: attachment)
            iconStr.addAttribute(.foregroundColor, value: glyphColor,
                                 range: NSRange(location: 0, length: iconStr.length))
            result.append(iconStr)
        }
        return result
    }

    /// Builds an attributed string: "filename 🔗" with an SF Symbol link badge.
    static func symlinkAttributedName(_ name: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: name + " ",
            attributes: [.font: font, .foregroundColor: color]
        )
        let symbolSize = font.pointSize * 0.9
        if let symbolImage = NSImage(systemSymbolName: "link", accessibilityDescription: "symlink") {
            let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
            let tinted = symbolImage.withSymbolConfiguration(config) ?? symbolImage
            let attachment = NSTextAttachment()
            attachment.image = tinted
            let yOffset = (font.capHeight - symbolSize) / 2
            attachment.bounds = CGRect(x: 0, y: yOffset, width: symbolSize, height: symbolSize)
            let iconStr = NSMutableAttributedString(attachment: attachment)
            iconStr.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: iconStr.length))
            result.append(iconStr)
        }
        return result
    }

    /// Builds an attributed string: "filename ↱" with an SF Symbol badge for a Finder alias.
    ///
    /// The system draws that badge on the alias's ICON, but the panel resolves icons from the
    /// file's EXTENSION (one lookup per type, not per file), so the badge never reaches a row.
    /// The name carries it instead — the same way a symlink carries its chain link.
    static func aliasAttributedName(_ name: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: name + " ",
            attributes: [.font: font, .foregroundColor: color]
        )
        let symbolSize = font.pointSize * 0.9
        if let symbolImage = NSImage(systemSymbolName: "arrowshape.turn.up.right",
                                     accessibilityDescription: "alias") {
            let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
            let tinted = symbolImage.withSymbolConfiguration(config) ?? symbolImage
            let attachment = NSTextAttachment()
            attachment.image = tinted
            let yOffset = (font.capHeight - symbolSize) / 2
            attachment.bounds = CGRect(x: 0, y: yOffset, width: symbolSize, height: symbolSize)
            let iconStr = NSMutableAttributedString(attachment: attachment)
            iconStr.addAttribute(.foregroundColor, value: color,
                                 range: NSRange(location: 0, length: iconStr.length))
            result.append(iconStr)
        }
        return result
    }

    /// Builds an attributed string: "filename 📎" with an SF Symbol badge for hardlinks.
    static func hardlinkAttributedName(_ name: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: name + " ",
            attributes: [.font: font, .foregroundColor: color]
        )
        let symbolSize = font.pointSize * 0.9
        if let symbolImage = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "hardlink") {
            let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
            let tinted = symbolImage.withSymbolConfiguration(config) ?? symbolImage
            let attachment = NSTextAttachment()
            attachment.image = tinted
            let yOffset = (font.capHeight - symbolSize) / 2
            attachment.bounds = CGRect(x: 0, y: yOffset, width: symbolSize, height: symbolSize)
            let iconStr = NSMutableAttributedString(attachment: attachment)
            iconStr.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: iconStr.length))
            result.append(iconStr)
        }
        return result
    }

    // MARK: - Icon Loading

    private func iconForFile(_ item: FileItem) -> NSImage {
        var ext = item.fileExtension.lowercased()
        if ext.hasPrefix(".") { ext = String(ext.dropFirst()) }
        guard !ext.isEmpty else { return Self.fileIcon }

        if let cached = Self.iconCache[ext] { return cached }

        // Not cached yet: this row draws the generic document icon now, and the
        // real icon has to arrive later. Nothing used to redraw the row once it
        // did, so the FIRST file of every new extension kept the blank page
        // until something else happened to reload the table — a scroll, a
        // folder change, a click. Second and later files of the same extension
        // looked fine because the cache was warm by then.
        //
        // Only one load per extension: ten .jpg rows used to fire ten identical
        // lookups, all racing to write the same cache entry.
        guard !Self.iconLoadsInFlight.contains(ext) else { return Self.fileIcon }
        Self.iconLoadsInFlight.insert(ext)

        DispatchQueue.global(qos: .utility).async {
            let icon: NSImage
            if let contentType = UTType(filenameExtension: ext) {
                icon = NSWorkspace.shared.icon(for: contentType)
            } else {
                icon = Self.fileIcon
            }
            DispatchQueue.main.async { [weak self] in
                Self.iconCache[ext] = icon
                Self.iconLoadsInFlight.remove(ext)
                self?.refreshVisibleIconsIfNeeded(for: ext)
            }
        }
        return Self.fileIcon
    }

    /// Redraw the on-screen rows whose extension just got its real icon.
    /// Scoped to visible rows of that one extension — a full reloadData here
    /// would fight the cursor and the field editor during rename.
    private func refreshVisibleIconsIfNeeded(for ext: String) {
        guard let tableView, tableView.numberOfRows > 0 else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }

        // Reload the visible rows of this extension so their real icon replaces the placeholder.
        // The row being inline-renamed is EXCLUDED: reloadData(forRowIndexes:) on it would tear
        // down its field editor and drop the user's typing. That one row's icon heals on the
        // next natural reload (rename commit reloads the directory); the rest update now, so a
        // pending rename no longer freezes every other row of the extension on the placeholder.
        let renamingPath = renamingItem?.path
        var rowsToRedraw = IndexSet()
        for row in visible.lowerBound..<visible.upperBound
        where viewModel.items.indices.contains(row) {
            if let renamingPath, viewModel.items[row].path == renamingPath { continue }
            var rowExt = viewModel.items[row].fileExtension.lowercased()
            if rowExt.hasPrefix(".") { rowExt = String(rowExt.dropFirst()) }
            if rowExt == ext { rowsToRedraw.insert(row) }
        }
        guard !rowsToRedraw.isEmpty else { return }
        tableView.reloadData(forRowIndexes: rowsToRedraw,
                             columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    private func formatDate(_ date: Date?) -> String {
        // У компьютера в сети и у общей папки даты нет вовсе (см. NetworkBrowserService
        // .virtualDate) — пустая клетка честнее, чем «01.01.0001».
        guard let date, date != NetworkBrowserService.virtualDate else { return "-" }
        return dateFormatter.string(from: date)
    }

    // MARK: - NSMenuDelegate (Context Menu)

    /// Explicit clicked row for the custom popover menu (NSTableView.clickedRow
    /// isn't reliably populated when we build the menu ourselves in menu(for:)).
    var contextMenuRowOverride: Int?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = contextMenuRowOverride ?? tableView.clickedRow

        // Activate this panel on right-click
        onBecameActive?()

        let clicked: FileItem?
        if viewModel.items.indices.contains(row) {
            // Move cursor to clicked row
            viewModel.setCursor(index: row)
            clicked = viewModel.items[row]
        } else {
            clicked = nil
        }
        populateContextMenu(menu, for: clicked)
    }

    /// The one place that decides WHICH context menu a panel shows. Every view mode routes here:
    /// the detailed table through `menuNeedsUpdate`, the brief and thumbnail grids through the
    /// menu closures they are handed. They used to decide separately, and the brief mode never
    /// learned about the Trash — right-clicking there offered to pack and rename things that were
    /// already thrown away.
    func populateContextMenu(_ menu: NSMenu, for item: FileItem?) {
        menu.removeAllItems()
        if viewModel.state.insideTrash {
            // A short menu of its own: copying, packing or renaming something that is already in
            // the Trash makes no sense, and offering it would only invite mistakes.
            buildTrashContextMenu(into: menu, hasItem: item != nil)
        } else if let item {
            buildFileContextMenu(for: item, into: menu)
            // Раскладка — только здесь. Меню пустого места и Корзины короткие, шесть строк
            // и три: прятать в них нечего, а кнопка «Ещё» была бы длиннее спрятанного.
            applyContextLayout(to: menu)
        } else {
            buildBackgroundContextMenu(into: menu)
        }
        menu.applyAccentStyle()
    }

    /// Собрать меню так, как его задал человек.
    ///
    /// Ничего не менял — меню остаётся ровно таким, каким его построил сборщик. Отправил
    /// пункты под «Ещё» — они уходят вниз, остальное на месте. Собрал меню сам — показываем
    /// ровно его список: штатные пункты, команды программы, разделители, в его порядке.
    private func applyContextLayout(to menu: NSMenu) {
        let layout = ContextMenuLayout.shared
        guard layout.isCustomised else { return }
        guard layout.isExplicit else { hideUnderMore(in: menu, extra: layout.extra); return }

        // Штатный пункт берём из уже собранного меню — со всеми условиями, которые сборщик
        // проверил (распаковка только у архива, «пройти по ссылке» только у ссылки). Чего он
        // для этого файла не построил, того в меню и не будет: список человека — это выбор,
        // а не приказ показывать неподходящее.
        var built: [String: NSMenuItem] = [:]
        for item in menu.items {
            if let id = item.identifier?.rawValue { built[id] = item }
        }
        let mainRows = ContextMenuSplit.tidy(layout.main.compactMap { contextRow(for: $0, built: built) })
        let extraRows = ContextMenuSplit.tidy(layout.extra.compactMap { contextRow(for: $0, built: built) })
        menu.removeAllItems()
        // Погасшие строки должны остаться погасшими: автоматический пересчёт AppKit
        // зажёг бы их обратно.
        menu.autoenablesItems = false
        for row in mainRows { menu.addItem(row) }
        if !extraRows.isEmpty {
            if !mainRows.isEmpty { menu.addItem(.separator()) }
            menu.addItem(ContextMoreMenuItem(hiddenRows: extraRows))
        }
    }

    /// Старая раскладка: основная часть как была, спрятанное — под «Ещё».
    private func hideUnderMore(in menu: NSMenu, extra: [String]) {
        let entries = menu.items.map { item -> ContextMenuSplit.Entry in
            item.isSeparatorItem ? .separator : .item(id: item.identifier?.rawValue)
        }
        let split = ContextMenuSplit.split(entries: entries, extra: extra)
        guard !split.extra.isEmpty else { return }
        let built = menu.items
        menu.removeAllItems()
        for index in split.main { menu.addItem(built[index]) }
        menu.addItem(.separator())
        // Спрятанное едет вместе с кнопкой: окно меню дописывает его на месте, поэтому
        // пересобирать и показывать меню второй раз незачем.
        menu.addItem(ContextMoreMenuItem(hiddenRows: split.extra.map { built[$0] }))
    }

    /// Строка меню по имени из раскладки: разделитель, штатный пункт или команда программы.
    private func contextRow(for id: String, built: [String: NSMenuItem]) -> NSMenuItem? {
        if id == ContextMenuLayout.separatorID { return .separator() }
        if let item = built[id] { return item }
        guard CommandRegistry.isCommandID(id), let command = CommandRegistry.command(id: id) else {
            return nil
        }
        return Self.commandRow(command)
    }

    /// Команда программы — своей строкой в контекстном меню: то же действие, тот же значок, та
    /// же проверка доступности, что и в строке меню. Недоступная сейчас не прячется, а гаснет:
    /// строка, которая то есть, то нет, читается как сбой, а погасшая объясняет себя сама.
    static func commandRow(_ command: PaletteCommand) -> NSMenuItem {
        // Доступность спрашиваем ПЕРВОЙ: проверка пункта успевает переписать и слово
        // («Закрепить» ↔ «Открепить», «Запереть» ↔ «Отпереть»), и галочку переключателя.
        // Спросив после, мы показали бы вчерашнее.
        let enabled = CommandRegistry.isEnabled(command)
        let row = NSMenuItem(title: command.currentTitle, action: command.item.action,
                             keyEquivalent: "")
        row.target = command.item.target
        row.tag = command.item.tag
        row.representedObject = command.item.representedObject
        row.image = command.item.image
        row.identifier = NSUserInterfaceItemIdentifier(command.stableID)
        // Галочка переключателя — вид списка, поле сортировки, столбцы, скрытые файлы:
        // без неё в меню не видно, что уже выбрано.
        row.state = command.item.state
        row.toolTip = command.item.toolTip
        row.isEnabled = enabled
        return row
    }

    /// The Trash's own context menu: put back, erase, empty. Nothing else applies here.
    private func buildTrashContextMenu(into menu: NSMenu, hasItem: Bool) {
        if hasItem {
            menu.addStyledItem(title: L("trash.restore"), symbolName: "arrow.uturn.backward", id: "trash.restore") {
                [weak self] in
                guard let self else { return }
                actionDelegate?.panelDidRequestRestoreFromTrash(self, items: selectedOrCursorItems())
            }
            menu.addStyledItem(title: L("delete.permanent.confirm"), symbolName: "flame",
                               isDestructive: true, id: "delete.permanent.confirm") { [weak self] in
                guard let self else { return }
                actionDelegate?.panelDidRequestDeletePermanently(self, items: selectedOrCursorItems())
            }
            menu.addItem(.separator())
        }
        menu.addStyledItem(title: L("trash.empty"), symbolName: "trash.slash", isDestructive: true, id: "trash.empty") {
            [weak self] in
            guard let self else { return }
            actionDelegate?.panelDidRequestEmptyTrash(self)
        }
    }

    /// The name exactly as it should appear, symlink/hardlink decoration included.
    ///
    /// Both the cell builder and the cursor-move repaint go through here. They used to build it
    /// separately, and the repaint's `textColor = …` flattened the whole attributed string into one
    /// colour — the same trap documented for symlinks a few lines below.
    ///
    /// The tag dots are deliberately NOT part of this string: they live in a sibling view, because
    /// anything at the end of a truncating label is the first thing to disappear, and a tagged file
    /// that renders without its dot reads as untagged.
    private func decoratedName(for item: FileItem, font: NSFont, color: NSColor) -> NSAttributedString {
        // Branch view shows WHERE in the subtree the file lives — the subpath is the name.
        let shownName = item.branchPath ?? item.name
        let base: NSMutableAttributedString
        if item.isSymlink {
            let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            base = NSMutableAttributedString(
                attributedString: Self.symlinkAttributedName(shownName, font: italic, color: color))
        } else if item.isAlias {
            base = NSMutableAttributedString(
                attributedString: Self.aliasAttributedName(shownName, font: font, color: color))
        } else if item.isHardlink {
            base = NSMutableAttributedString(
                attributedString: Self.hardlinkAttributedName(shownName, font: font, color: color))
        } else if item.name != "..", CloudStatusService.isInCloudDrive(item.path),
                  case let state = CloudStatusService.state(of: item.path), state != .here,
                  state != .local {
            base = NSMutableAttributedString(
                attributedString: Self.cloudAttributedName(shownName, font: font, color: color,
                                                           state: state))
        } else {
            base = NSMutableAttributedString(string: shownName,
                                             attributes: [.font: font, .foregroundColor: color])
        }
        return base
    }

    /// The eye, tinted by hand and cached: a template symbol inside an NSTextAttachment
    /// renders plain black, ignoring the row's colour — so the tint is baked into the
    /// image, one per size-and-colour, reused across every row.
    nonisolated(unsafe) private static var hiddenEyeCache: [String: NSImage] = [:]

    private static func hiddenEyeImage(pointSize: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(Int(pointSize * 10))-\(color.description)"
        if let cached = hiddenEyeCache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "eye.slash",
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        hiddenEyeCache[key] = tinted
        return tinted
    }

    // MARK: - Finder tags

    /// Write a tag change over a selection, off the main thread, and say so when it fails.
    ///
    /// Each file costs a getxattr plus a setxattr, and on a network mount every one of those is a
    /// round trip — a few thousand selected files would freeze the window for the whole batch. The
    /// writes report a Bool that used to be discarded, so tagging something read-only looked
    /// exactly like tagging something successfully: no dot, no message, nothing to act on.
    func applyTagChange(to paths: [String], _ write: @escaping (String) -> Bool) {
        // A progress dialog with a working Cancel, but only once the batch is big enough to be
        // worth one: each file costs a getxattr plus a setxattr, and on a network mount every one
        // of those is a round trip — a few thousand files run for many seconds with no way out.
        // Below the threshold the writes finish before a dialog could even appear.
        let showsProgress = paths.count >= 50
        let progress = showsProgress
            ? DialogService.shared.showProgress(title: L("context.tags"),
                                                message: L("tags.applying"),
                                                cancelHandler: nil)
            : nil

        Task.detached(priority: .userInitiated) {
            var failed: [String] = []
            var done = 0
            for path in paths {
                if await MainActor.run(body: { progress?.isCancelled ?? false }) { break }
                if !write(path) { failed.append(path) }
                done += 1
                // Every 25 files: often enough to look alive, rare enough not to spend the batch
                // hopping to the main thread.
                if done % 25 == 0 || done == paths.count {
                    let snapshot = done
                    let name = (path as NSString).lastPathComponent
                    await MainActor.run {
                        progress?.update(currentFile: name,
                                         progress: Double(snapshot) / Double(paths.count),
                                         bytesDone: 0, bytesTotal: 0,
                                         filesDone: snapshot, filesTotal: paths.count)
                    }
                }
            }
            let failedPaths = failed
            await MainActor.run { [weak self] in
                progress?.close()
                guard let self else { return }
                // The paths did not change, only the tags on them, so the scan has to be forced.
                viewModel.refreshTags(force: true)
                guard !failedPaths.isEmpty else { return }
                let names = failedPaths.prefix(5).map { ($0 as NSString).lastPathComponent }
                    .joined(separator: "\n")
                let more = failedPaths.count > 5 ? "\n…" : ""
                DialogService.shared.showError(
                    title: L("tags.writeFailed.title"),
                    message: L("tags.writeFailed.message", failedPaths.count) + "\n\n" + names + more)
            }
        }
    }

    /// "Tags" submenu: the seven Finder colours with a tick on the ones already set, plus a clear.
    /// Applies to the whole selection, so tagging a batch is one gesture.
    private func buildTagsMenuItem(for item: FileItem) -> NSMenuItem {
        let parent = NSMenuItem(title: L("context.tags"), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        let submenu = NSMenu()

        let targets = viewModel.operationTargets.map(\.path)
        let paths = targets.isEmpty ? [item.path] : targets
        // Ticked when EVERY selected file already carries it — a half-tagged selection reads as
        // unticked, and choosing the colour then tags the rest rather than clearing the ones set.
        for tag in FinderTag.allCases {
            let allHave = paths.allSatisfy { FinderTagService.hasTag(tag, at: $0) }
            submenu.addStyledItem(title: tag.localizedName, symbolName: "circle.fill",
                                  tint: tag.color) { [weak self] in
                self?.toggleTag(tag, at: paths)
            }
            if allHave { submenu.items.last?.state = .on }
        }

        submenu.addItem(NSMenuItem.separator())
        submenu.addStyledItem(title: L("context.tags.clear"), symbolName: "xmark.circle", id: "context.tags.clear") {
            [weak self] in
            self?.clearTags(at: paths)
        }

        parent.submenu = submenu
        return parent
    }

    /// "Create link" submenu: the three kinds, gathered under one row.
    ///
    /// Three near-identical lines in the middle of the file menu read as clutter and made the
    /// menu long; behind one row they read as a choice, which is what they are. A hard link is
    /// offered only for files — a folder cannot have one.
    private func buildLinksMenuItem(for item: FileItem) -> NSMenuItem {
        let parent = NSMenuItem(title: L("context.createLink"), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        let submenu = NSMenu()

        submenu.addStyledItem(title: L("context.createSymlink"),
                              symbolName: "link.badge.plus", id: "context.createSymlink") { [weak self] in
            guard let self else { return }
            actionDelegate?.panelDidRequestCreateSymlink(self, item: item)
        }
        submenu.addStyledItem(title: L("context.createAlias"),
                              symbolName: "arrowshape.turn.up.right", id: "context.createAlias") { [weak self] in
            guard let self else { return }
            actionDelegate?.panelDidRequestCreateAlias(self, item: item)
        }
        // Kept on the row even for a folder, greyed out: a command that simply vanishes on
        // some files leaves the user looking for it. A folder cannot have a hard link —
        // that is a rule of the filesystem, and the row says so instead of disappearing.
        submenu.addStyledItem(title: L("context.createHardlink"),
                              symbolName: "doc.on.doc.fill", id: "context.createHardlink") { [weak self] in
            guard let self else { return }
            actionDelegate?.panelDidRequestCreateHardlink(self, item: item)
        }
        if item.isDirectory {
            // Without this AppKit would re-enable the row from its own validation the moment a
            // native menu displayed it; our popup reads the flag directly, and the two must not
            // disagree about the same menu.
            submenu.autoenablesItems = false
            submenu.items.last?.isEnabled = false
            submenu.items.last?.toolTip = L("hardlink.error.directory")
        }

        parent.submenu = submenu
        return parent
    }

    /// The tools that exist only for certain kinds of file, gathered into one submenu.
    /// Nil when nothing applies — a row that opens an empty submenu is worse than no row.
    private func fileToolsMenuItem(for item: FileItem) -> NSMenuItem? {
        guard item.name != "..", !item.isDirectory,
              !viewModel.insideArchive, !viewModel.insideRemote else { return nil }
        let submenu = NSMenu()
        let controller = { [weak self] in
            self?.view.window?.windowController as? MainWindowController
        }
        let kind = fileCategory(extension: item.fileExtension)

        if TextRecognitionService.canReadText(in: item.path) {
            submenu.addStyledItem(title: L("context.recognizeText"),
                                  symbolName: "text.viewfinder", id: "context.recognizeText") { [weak self] in
                guard let self else { return }
                controller()?.recognizeText(in: viewModel)
            }
        }
        if kind == .pdf {
            let several = viewModel.operationTargets.filter {
                fileCategory(extension: $0.fileExtension) == .pdf
            }.count > 1
            if several {
                submenu.addStyledItem(title: L("context.pdfMerge"),
                                      symbolName: "square.stack", id: "context.pdfMerge") { [weak self] in
                    guard let self else { return }
                    controller()?.mergePDFs(in: viewModel)
                }
            }
            submenu.addStyledItem(title: L("context.pdfSplit"),
                                  symbolName: "square.split.2x1", id: "context.pdfSplit") { [weak self] in
                guard let self else { return }
                controller()?.splitPDF(in: viewModel)
            }
            submenu.addStyledItem(title: L("context.pdfRotate"),
                                  symbolName: "rotate.right", id: "context.pdfRotate") { [weak self] in
                guard let self else { return }
                controller()?.rotatePDF(in: viewModel)
            }
        }
        if kind == .image {
            submenu.addStyledItem(title: L("context.pdfMake"),
                                  symbolName: "doc.badge.plus", id: "context.pdfMake") { [weak self] in
                guard let self else { return }
                controller()?.makePDF(in: viewModel)
            }
            submenu.addStyledItem(title: L("context.convertImages"),
                                  symbolName: "photo.badge.arrow.down", id: "context.convertImages") { [weak self] in
                guard let self else { return }
                controller()?.convertImages(in: viewModel)
            }
            // Only on a photograph that actually carries something: on a picture with no
            // notes in it the item would do nothing and mean nothing.
            if PhotoMetadataService.hasMetadata(path: item.path) {
                submenu.addStyledItem(title: L("context.cleanMetadata"),
                                      symbolName: "eye.slash", id: "context.cleanMetadata") { [weak self] in
                    guard let self else { return }
                    controller()?.cleanPhotoMetadata(in: viewModel)
                }
            }
        }
        guard submenu.numberOfItems > 0 else { return nil }

        // Named by what it holds: on a PDF the row says so outright, and the person knows
        // what is inside before opening it.
        let title = kind == .pdf ? L("context.fileTools.pdf")
                  : kind == .image ? L("context.fileTools.image")
                  : L("context.fileTools")
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        parent.image = NSImage(systemSymbolName: "wand.and.rays", accessibilityDescription: nil)
        return parent
    }

    /// «Открыть с помощью…» — один пункт, открывающий окно выбора.
    ///
    /// Подменю здесь было и ушло: в него пришлось встраивать ВТОРОЕ подменю «всегда
    /// открывать», потому что меню закрывается от первого щелчка и галочке в нём не выжить.
    /// В своём окне выбор программы и «Открывать всегда» — одно движение.
    private func openWithMenuItem(for item: FileItem) -> NSMenuItem? {
        guard item.name != "..", !item.isDirectory, !viewModel.insideArchive else { return nil }
        let menuItem = NSMenuItem(title: L("context.openWith"),
                                  action: #selector(OpenWithAppMenuTarget.open(_:)),
                                  keyEquivalent: "")
        let target = OpenWithAppMenuTarget { [weak self] in
            // Следующим тактом: окно нельзя открывать из-под закрывающегося меню — модальный
            // цикл, начатый там, ловит окно в неотвечающее состояние.
            DispatchQueue.main.async { self?.showOpenWithDialog(for: item) }
        }
        menuItem.target = target
        menuItem.representedObject = target
        return menuItem
    }

    /// Показать окно выбора программы и сделать то, что человек выбрал.
    func showOpenWithDialog(for item: FileItem) {
        let applications = Self.applicationsThatOpen(item.path)
        let kind = DefaultApplication.kindLabel(forFileAt: item.path)
        let choice = FCXLDialog.runModal(size: NSSize(width: 470, height: 640)) { session in
            OpenWithDialogView(session: session,
                               fileName: item.name,
                               kindLabel: kind,
                               applications: applications)
        }
        guard let choice else { return }
        // Правило меняется ПЕРЕД открытием: если система откажет (неподписанная программа,
        // чужой тип), человек услышит об этом сразу, а не на следующем двойном щелчке.
        if choice.always, let kind {
            bindDefaultApplication(choice.application, forFileAt: item.path, kind: kind)
        }
        ExternalOpenService.open([URL(fileURLWithPath: item.path)],
                                 withApplicationAt: choice.application)
    }

    // MARK: - File Context Menu

    /// The menu builder's public door — the settings preview builds a real menu through it,
    /// and the shape tests hold the menu's order and captions through it too.
    func makeFileContextMenu(for item: FileItem, into menu: NSMenu) {
        buildFileContextMenu(for: item, into: menu)
        // И предпросмотр в настройках показывает меню таким, каким его разложил человек.
        applyContextLayout(to: menu)
    }

    private func buildFileContextMenu(for item: FileItem, into menu: NSMenu) {
        // Marking the file's own kind, at the very top: it is a step BEFORE the commands under
        // it — pick the group, then act on it — and everything below works on the selection.
        if item.name != ".." {
            menu.addStyledItem(title: L("menu.selectSameType"),
                               symbolName: "square.on.square.dashed", id: "menu.selectSameType") { [weak self] in
                self?.viewModel.selectSameType()
            }
            if item.isDirectory {
                // A folder has no extension to group by. Greyed rather than hidden, so the row
                // does not come and go as the cursor moves.
                menu.autoenablesItems = false
                menu.items.last?.isEnabled = false
                menu.items.last?.toolTip = L("context.selectSameType.filesOnly")
            }
            menu.addItem(.separator())
        }

        // Open
        // The one activation path — activateItem's own doc says not to bypass it. This handler used
        // to re-implement it and lost everything the real one does: entering an archive as a
        // container, extracting an entry to temp before opening, routing .djvu to the bundled
        // reader, and the launch spinner.
        menu.addStyledItem(title: L("context.open"), symbolName: "arrow.right.circle", id: "context.open") { [weak self] in
            self?.activateItem(item)
        }
        // Right under "Open": the two answer the same question — what happens to this file —
        // and hunting for the submenu halfway down the menu was the complaint.
        if let openWith = openWithMenuItem(for: item) {
            openWith.image = NSImage(systemSymbolName: "arrow.up.forward.app",
                                     accessibilityDescription: nil)
            openWith.identifier = NSUserInterfaceItemIdentifier("context.openWith")
            menu.addItem(openWith)
        }

        // A vault: the counterpart of Enter. An open one offers to lock; a locked one says
        // plainly what Enter will do anyway.
        if item.name != "..", VaultService.isVault(item.path), !viewModel.insideArchive,
           !viewModel.insideRemote {
            if VaultService.isUnlocked(item.path) {
                menu.addStyledItem(title: L("vault.lock.menu"), symbolName: "lock.fill", id: "vault.lock.menu") {
                    [weak self] in
                    guard let self else { return }
                    (view.window?.windowController as? MainWindowController)?
                        .lockVault(at: item.path)
                }
            } else {
                menu.addStyledItem(title: L("vault.unlock.menu"), symbolName: "lock.open", id: "vault.unlock.menu") {
                    [weak self] in
                    self?.activateItem(item)
                }
            }
            // The way in, switchable after the fact: forget the remembered password (back to
            // typing it), or let the next typed unlock enrol it for the fingerprint.
            if VaultService.hasStoredPassword(for: item.path) {
                menu.addStyledItem(title: L("vault.forgetTouchID.menu"),
                                   symbolName: "touchid", id: "vault.forgetTouchID.menu") { [weak self] in
                    guard self != nil else { return }
                    VaultService.forgetPassword(for: item.path)
                    VaultService.setTouchIDDeclined(true, for: item.path)
                }
            } else if VaultService.touchIDDeclined(for: item.path) {
                menu.addStyledItem(title: L("vault.enableTouchID.menu"),
                                   symbolName: "touchid", id: "vault.enableTouchID.menu") { [weak self] in
                    guard self != nil else { return }
                    VaultService.setTouchIDDeclined(false, for: item.path)
                }
            }
        }

        // For a disk image: the road Enter does NOT take, named plainly. Same pair as
        // Shift+Enter — the setting decides which of the two is the default, and this offers
        // the other one without making the user go and change the setting.
        if item.name != ".." && !item.isDirectory && !viewModel.insideArchive,
           DiskImageOpenMode.isDiskImage(item.path) {
            let other = DiskImageOpenMode.chosen.opposite
            // Имя строки — как у всех: без него пункт не собрать в своё меню, а человек
            // вправе поставить его куда хочет. Их два, по дороге: строка и значок разные.
            menu.addStyledItem(title: L(other == .panel ? "context.diskImage.panel"
                                                        : "context.diskImage.finder"),
                               symbolName: other == .panel ? "externaldrive" : "macwindow",
                               id: other == .panel ? "context.diskImage.panel"
                                                   : "context.diskImage.finder") {
                [weak self] in
                self?.activateItem(item, diskImageRoad: other)
            }
        }

        // For a .app bundle: offer to browse its contents as a folder.
        if viewModel.isAppBundle(item) {
            menu.addStyledItem(title: L("context.enterAppBundle"), symbolName: "folder", id: "context.enterAppBundle") { [weak self] in
                self?.enterAppBundle(item)
            }
        }

        if item.name != "..", !viewModel.insideRemote, !viewModel.insideArchive {
            menu.addStyledItem(title: L("context.revealInFinder"), symbolName: "magnifyingglass", id: "context.revealInFinder") {
                [weak self] in
                self?.revealInFinder(fallback: item)
            }
        }

        // The file-type tools — recognition, PDF work, image conversion — in ONE submenu.
        // They had been accumulating as top-level rows, and the menu had grown past what a
        // glance can take in; a submenu keeps them one thought ("do something to this kind of
        // file") and one row.
        if let tools = fileToolsMenuItem(for: item) {
            tools.identifier = NSUserInterfaceItemIdentifier("context.fileTools")
            menu.addItem(tools)
        }

        // Marks: the colour tags and the shelf — both ways of SETTING a file aside rather than
        // doing something to it, which is why they stand together.
        if item.name != ".." {
            var opened = false
            func markSection() {
                guard !opened else { return }
                opened = true
                menu.addItem(.separator())
            }
            if !viewModel.insideRemote, !viewModel.insideArchive {
                markSection()
                let tagsItem = buildTagsMenuItem(for: item)
                tagsItem.identifier = NSUserInterfaceItemIdentifier("context.tags")
                menu.addItem(tagsItem)
            }
            if viewModel.state.insideStack {
                markSection()
                menu.addStyledItem(title: L("stack.remove"), symbolName: "tray.and.arrow.up", id: "stack.remove") {
                    [weak self] in
                    guard let self else { return }
                    (view.window?.windowController as? MainWindowController)?
                        .removeSelectionFromDropStack()
                }
                menu.addStyledItem(title: L("stack.clear"), symbolName: "tray", id: "stack.clear") { [weak self] in
                    guard let self else { return }
                    DropStackStore.clear()
                    viewModel.loadStackDirectory()
                }
            } else if !viewModel.insideArchive, !viewModel.insideRemote,
                      !viewModel.state.insideNetworkBrowser {
                markSection()
                menu.addStyledItem(title: L("stack.add"), symbolName: "tray.and.arrow.down", id: "stack.add") {
                    [weak self] in
                    guard let self else { return }
                    (view.window?.windowController as? MainWindowController)?
                        .addSelectionToDropStack()
                }
            }
        }

        guard item.name != ".." else { return }
        menu.addItem(.separator())

        // View
        menu.addStyledItem(title: L("context.view"), symbolName: "eye", id: "context.view") { [weak self] in
            guard let self else { return }
            actionDelegate?.panelDidRequestView(self, item: item)
        }

        // Edit — files only
        if !item.isDirectory {
            menu.addStyledItem(title: L("context.edit"), symbolName: "pencil.line", id: "context.edit") { [weak self] in
                guard let self else { return }
                actionDelegate?.panelDidRequestEdit(self, item: item)
            }
        }

        // Rename — inline, exactly like F2 (menuNeedsUpdate already moved the cursor to
        // this item), so it never opens a separate dialog window.
        // A text cursor over a character, not another pencil: Edit right above already uses
        // pencil.line, and at menu size the two were near-identical.
        menu.addStyledItem(title: L("context.rename"), symbolName: "character.cursor.ibeam", id: "context.rename") { [weak self] in
            guard let self else { return }
            self.startInlineRename()
        }
        // В папке, лежащей в корзине, меню обычное — но переименование там отнимает у файла
        // путь возврата. Пункт гаснет с подсказкой, а не пропадает: строка, которая приходит
        // и уходит, читается как сбой.
        if renameForbidden(item) {
            menu.autoenablesItems = false
            menu.items.last?.isEnabled = false
            menu.items.last?.toolTip = L("trash.rename.blocked")
        }

        // Multi-Rename (Total Commander style) — batch rename of the selection (or the cursor
        // file). Routes to MainWindowController, which reads operationTargets and opens the tool.
        menu.addStyledItem(title: L("context.multiRename"), symbolName: "pencil.and.list.clipboard", id: "context.multiRename") { [weak self] in
            guard let self else { return }
            self.actionDelegate?.panelDidRequestMultiRename(self)
        }

        menu.addItem(.separator())

        // Clipboard operations. The context menu follows the Finder/Explorer model — put the
        // files aside, then Paste decides where they land. Immediate panel-to-panel copy/move
        // stays on F5/F6 and the footer buttons, which is the Total Commander model.
        menu.addStyledItem(title: "\(L("context.copy")) (Cmd+C)", symbolName: "doc.on.doc", id: "context.copy") { [weak self] in
            self?.copySelectedFilesToClipboard()
        }

        if !viewModel.insideArchive {
            menu.addStyledItem(title: "\(L("context.cut")) (Cmd+X)", symbolName: "scissors", id: "context.cut") { [weak self] in
                self?.cutSelectedFilesToClipboard()
            }
        }

        if Self.clipboardHasFiles() {
            menu.addStyledItem(title: "\(L("context.paste")) (Cmd+V)", symbolName: "doc.on.clipboard", id: "context.paste") { [weak self] in
                guard let self else { return }
                actionDelegate?.panelDidRequestPasteFromClipboard(self)
            }
        }

        // Delete
        menu.addStyledItem(title: L("context.delete"), symbolName: "trash", isDestructive: true, id: "context.delete") { [weak self] in
            guard let self else { return }
            let deleteItems = self.selectedOrCursorItems()
            actionDelegate?.panelDidRequestDelete(self, items: deleteItems)
        }

        menu.addItem(.separator())

        // Pack
        if !viewModel.insideArchive {
            menu.addStyledItem(title: L("context.pack"), symbolName: "archivebox", id: "context.pack") { [weak self] in
                guard let self else { return }
                actionDelegate?.panelDidRequestPack(self, items: selectedOrCursorItems())
            }
            // Unpack sits right next to Pack — they are the pair. Green because this item only
            // exists when the cursor is on an archive, so the colour answers "is this an
            // archive?" before the text is read.
            if viewModel.isArchiveFile(item) {
                menu.addStyledItem(title: L("context.unpack"), symbolName: "archivebox.fill",
                                   tint: .systemGreen, id: "context.unpack") { [weak self] in
                    guard let self else { return }
                    // Every selected archive, mirroring Pack above. Passing only the item
                    // under the cursor is why unpacking a multi-selection extracted just one.
                    let archives = self.selectedOrCursorItems().filter { self.viewModel.isArchiveFile($0) }
                    actionDelegate?.panelDidRequestExtract(self, items: archives.isEmpty ? [item] : archives)
                }
            }
            // Format list as a SUBMENU, not a dialog: the format is the only choice here, and
            // hovering to pick it is one gesture instead of opening a window to answer one
            // question. applyAccentStyle() recurses into submenus, so this keeps our look.
            let packHereMenu = NSMenu(title: "")
            // Built from the enum: a format added there appears here by itself, so the menu
            // can never fall behind the pack dialog's list.
            let formats = ArchiveFormat.allCases.map { ($0.displayName, $0) }
            for (label, format) in formats {
                packHereMenu.addStyledItem(title: label, symbolName: "archivebox") { [weak self] in
                    guard let self else { return }
                    actionDelegate?.panelDidRequestPackInPlace(
                        self, items: self.selectedOrCursorItems(), format: format)
                }
            }
            let packHereItem = NSMenuItem(title: L("context.packInPlace"), action: nil, keyEquivalent: "")
            packHereItem.submenu = packHereMenu
            packHereItem.identifier = NSUserInterfaceItemIdentifier("context.packInPlace")
            menu.addItem(packHereItem)
        }

        menu.addItem(.separator())

        // Copy File Path
        // A clipboard, not a chain link: the link glyph now belongs to "Create link" one
        // block below, and two rows wearing it meant two different things.
        menu.addStyledItem(title: L("context.copyFilePath"),
                           symbolName: "arrow.right.doc.on.clipboard", id: "context.copyFilePath") { [weak self] in
            self?.copyPathToClipboard(item.path)
        }

        // Symlink / Hardlink / Follow
        if !viewModel.insideArchive && !viewModel.insideRemote {
            let linksItem = buildLinksMenuItem(for: item)
            linksItem.identifier = NSUserInterfaceItemIdentifier("context.createLink")
            menu.addItem(linksItem)

            if item.isSymlink, let target = item.symlinkTarget {
                menu.addStyledItem(title: L("context.followSymlink"), symbolName: "arrow.uturn.right", id: "context.followSymlink") { [weak self] in
                    self?.followSymlink(to: target)
                }
            }
        }

        // Send To submenu
        if !viewModel.insideArchive {
            let sendToMenu = buildSendToMenu(for: item)
            if sendToMenu.numberOfItems > 0 {
                let sendToItem = NSMenuItem(title: L("context.sendTo"), action: nil, keyEquivalent: "")
                if let image = NSImage(systemSymbolName: "paperplane", accessibilityDescription: nil) {
                    image.isTemplate = true
                    sendToItem.image = image
                }
                sendToItem.submenu = sendToMenu
                sendToItem.identifier = NSUserInterfaceItemIdentifier("context.sendTo")
                menu.addItem(sendToItem)
            }
        }

        // Open a FOLDER in the external terminal — local panels only: a remote listing or
        // an archive has no working directory a shell could stand in.
        if item.isDirectory, !viewModel.insideArchive, !viewModel.insideRemote,
           !viewModel.state.insideTrash {
            menu.addStyledItem(title: L("context.openInTerminal"),
                               symbolName: "terminal", id: "context.openInTerminal") { [weak self] in
                guard let self else { return }
                actionDelegate?.panelDidRequestOpenInTerminal(self, path: item.path)
            }
        }

        menu.addItem(.separator())

        // Change attributes — the whole selection at once, TC's Files ▸ Change Attributes.
        // Local files only: remote listings, archives and the trash have no chmod to offer.
        if !viewModel.insideArchive, !viewModel.insideRemote, !viewModel.state.insideTrash {
            menu.addStyledItem(title: L("context.changeAttributes"),
                               symbolName: "slider.horizontal.3", id: "context.changeAttributes") { [weak self] in
                guard let self else { return }
                actionDelegate?.panelDidRequestChangeAttributes(self, items: selectedOrCursorItems())
            }
        }

        // Properties
        menu.addStyledItem(title: L("context.properties"), symbolName: "info.circle", id: "context.properties") { [weak self] in
            guard let self else { return }
            actionDelegate?.panelDidRequestProperties(self, item: item)
        }
    }

    // MARK: - Команды строки меню

    /// Файл под курсором, кроме «..»: команды меню работают с ним, как контекстное меню —
    /// с тем, по чему щёлкнули.
    var cursorFile: FileItem? {
        guard let item = viewModel.cursorItem, item.name != ".." else { return nil }
        return item
    }

    var isInlineRenaming: Bool { renamingItem != nil }

    /// Пути, к которым относится команда: выделенное, иначе — то, что под курсором.
    var targetPaths: [String] { selectedOrCursorItems().map(\.path) }

    func openCursorItem() {
        guard let item = cursorFile else { return }
        activateItem(item)
    }

    func openWithDialogForCursor() {
        guard let item = cursorFile else { return }
        showOpenWithDialog(for: item)
    }

    /// Показать в Finder всё выделенное, иначе — переданный файл (тот, по которому щёлкнули).
    func revealInFinder(fallback: FileItem) {
        let targets = viewModel.operationTargets.map(\.path)
        FinderTagService.revealInFinder(targets.isEmpty ? [fallback.path] : targets)
    }

    func revealTargetsInFinder() {
        guard let item = cursorFile else { return }
        revealInFinder(fallback: item)
    }

    func copyPathToClipboard(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    func copyCursorPathToClipboard() {
        guard let item = cursorFile else { return }
        copyPathToClipboard(item.path)
    }

    func copyFolderPathToClipboard() {
        copyPathToClipboard(viewModel.currentPath)
    }

    /// Перейти к цели символической ссылки: в её папку, курсором на неё.
    func followSymlink(to target: String) {
        let parentDir = URL(fileURLWithPath: target).deletingLastPathComponent().path
        viewModel.loadDirectory(at: parentDir)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self,
                  let idx = viewModel.items.firstIndex(where: { $0.path == target }) else { return }
            viewModel.setCursor(index: idx)
        }
    }

    func followSymlinkAtCursor() {
        guard let item = cursorFile, item.isSymlink, let target = item.symlinkTarget else { return }
        followSymlink(to: target)
    }

    func enterAppBundle(_ item: FileItem) {
        viewModel.pushHistory(from: viewModel.currentPath, to: item.path)
        _ = viewModel.open(item, forceFolder: true)
    }

    func enterAppBundleAtCursor() {
        guard let item = cursorFile, viewModel.isAppBundle(item) else { return }
        enterAppBundle(item)
    }

    /// Поставить метку всем целям; если она уже у всех — снять со всех.
    func toggleTag(_ tag: FinderTag, at paths: [String]) {
        let allHave = paths.allSatisfy { FinderTagService.hasTag(tag, at: $0) }
        applyTagChange(to: paths) { path in
            if allHave {
                var names = FinderTagService.tags(at: path)
                names.removeAll { $0 == tag.rawValue }
                return FinderTagService.setTags(names, at: path)
            }
            guard !FinderTagService.hasTag(tag, at: path) else { return true }
            return FinderTagService.toggle(tag, at: path)
        }
    }

    func clearTags(at paths: [String]) {
        applyTagChange(to: paths) { FinderTagService.clear(at: $0) }
    }

    func toggleTagOnTargets(_ tag: FinderTag) {
        let paths = targetPaths
        guard !paths.isEmpty else { return }
        toggleTag(tag, at: paths)
    }

    func clearTagsOnTargets() {
        let paths = targetPaths
        guard !paths.isEmpty else { return }
        clearTags(at: paths)
    }

    /// Запереть открытое хранилище под курсором или открыть запертое — как в контекстном меню.
    func lockOrUnlockVaultAtCursor() {
        guard let item = cursorFile, VaultService.isVault(item.path) else { return }
        if VaultService.isUnlocked(item.path) {
            (view.window?.windowController as? MainWindowController)?.lockVault(at: item.path)
        } else {
            activateItem(item)
        }
    }

    /// Открыть образ диска той дорогой, которую настройка НЕ выбрала.
    func openDiskImageOtherWay() {
        guard let item = cursorFile, !item.isDirectory,
              DiskImageOpenMode.isDiskImage(item.path) else { return }
        activateItem(item, diskImageRoad: DiskImageOpenMode.chosen.opposite)
    }

    // MARK: - Background Context Menu

    private func buildBackgroundContextMenu(into menu: NSMenu) {
        if !viewModel.insideArchive {
            menu.addStyledItem(title: "\(L("context.mkdir")) (F7)", symbolName: "folder.badge.plus", id: "context.mkdir") { [weak self] in
                guard let self else { return }
                actionDelegate?.panelDidRequestMkdir(self)
            }
        }
        // The CURRENT folder in the external terminal — the background twin of the
        // per-folder item above.
        if !viewModel.insideArchive, !viewModel.insideRemote, !viewModel.state.insideTrash,
           !viewModel.state.insideNetworkBrowser {
            menu.addStyledItem(title: L("context.openInTerminal"),
                               symbolName: "terminal", id: "context.openInTerminal") { [weak self] in
                guard let self else { return }
                actionDelegate?.panelDidRequestOpenInTerminal(self, path: viewModel.currentPath)
            }
        }

        menu.addStyledItem(title: L("context.refresh"), symbolName: "arrow.clockwise", id: "context.refresh") { [weak self] in
            self?.viewModel.loadDirectory(resetCursor: false)
        }

        menu.addStyledItem(title: "\(L("context.selectAll")) (Cmd+A)", symbolName: "checkmark.circle", id: "context.selectAll") { [weak self] in
            self?.viewModel.selectAll()
        }

        if !viewModel.insideArchive {
            menu.addItem(.separator())
            menu.addStyledItem(title: "\(L("context.createTextFile")) (⇧F4)", symbolName: "doc.badge.plus", id: "context.createTextFile") { [weak self] in
                guard let self else { return }
                actionDelegate?.panelDidRequestCreateTextFile(self)
            }

            // Paste from clipboard — show only when the clipboard actually holds files.
            if Self.clipboardHasFiles() {
                menu.addStyledItem(title: "\(L("context.paste")) (Cmd+V)", symbolName: "doc.on.clipboard", id: "context.paste") { [weak self] in
                    guard let self else { return }
                    actionDelegate?.panelDidRequestPasteFromClipboard(self)
                }
            }

            menu.addItem(.separator())
        }

        menu.addStyledItem(title: L("context.copyPath"), symbolName: "folder", id: "context.copyPath") { [weak self] in
            self?.copyFolderPathToClipboard()
        }
    }

    /// Check whether the clipboard holds anything pasteable — a live remote payload of ours,
    /// or local file URLs (which may have come from Finder).
    static func clipboardHasFiles() -> Bool {
        if FileClipboard.remotePayload != nil { return true }
        let pb = NSPasteboard.general
        return pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Read file URLs from NSPasteboard.general.
    static func clipboardFileURLs() -> [URL] {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return []
        }
        return urls
    }

    /// Copy the selection to the clipboard (Cmd+C).
    ///
    /// On a remote panel (FTP/SFTP/WebDAV) the item paths are SERVER paths, so they are
    /// stored as a remote payload, not as local file URLs — a `file://` of a server path
    /// would point at an unrelated LOCAL file of the same name. SMB is not remote here: it
    /// is a real macOS mount, so its paths take the ordinary local path.
    func copySelectedFilesToClipboard() {
        let items = selectedOrCursorItems()
        guard !items.isEmpty else { return }
        if viewModel.insideRemote {
            guard let session = viewModel.remoteSession else { return }
            FileClipboard.copyRemote(items: items,
                                     connectionID: session.connection.id,
                                     label: session.connection.label,
                                     sourceDir: viewModel.currentPath)
        } else {
            FileClipboard.copy(items.map(\.path))
        }
    }

    /// Cut the selection (Cmd+X): same clipboard contents as a copy, but marked so paste MOVES.
    /// See FileClipboard for why the mark lives in the app.
    func cutSelectedFilesToClipboard() {
        let items = selectedOrCursorItems()
        guard !items.isEmpty else { return }
        if viewModel.insideRemote {
            guard let session = viewModel.remoteSession else { return }
            FileClipboard.cutRemote(items: items,
                                    connectionID: session.connection.id,
                                    label: session.connection.label,
                                    sourceDir: viewModel.currentPath)
        } else {
            FileClipboard.cut(items.map(\.path))
        }
    }

    // MARK: - Send To Submenu

    func buildSendToMenu(for item: FileItem) -> NSMenu {
        let fileURL = URL(fileURLWithPath: item.path)
        let sendToMenu = NSMenu()

        // System sharing services (preferred — opens "share" flow, not "open document").
        // Telegram et al expect this path: they show "send to chat" dialog
        // instead of trying to render the file as content.
        let services = NSSharingService.availableSharingServices(forItems: [fileURL])
        var servicesByTitle: [String: NSSharingService] = [:]
        for service in services {
            servicesByTitle[service.title.lowercased()] = service
        }

        // Installed messengers — share via NSSharingService when possible,
        // otherwise fall back to NSWorkspace.open (legacy path).
        let installedMessengers = MessengerDetection.installedMessengers()
        let consumedServiceTitles: Set<String> = Set(
            installedMessengers
                .compactMap { servicesByTitle[$0.name.lowercased()]?.title.lowercased() }
        )

        for app in installedMessengers {
            let menuItem = NSMenuItem(title: app.name, action: nil, keyEquivalent: "")
            menuItem.image = app.icon

            if let service = servicesByTitle[app.name.lowercased()] {
                if Self.needsPackingBeforeSending(item, messenger: app.name) {
                    // Packed at the click, not when the menu is built — a right-click must not
                    // write a file.
                    let target = OpenWithAppMenuTarget { [weak self] in
                        self?.sendPacked(item, via: service)
                    }
                    menuItem.target = target
                    menuItem.action = #selector(OpenWithAppMenuTarget.open(_:))
                    menuItem.representedObject = target
                    menuItem.toolTip = L("sendTo.packedHint")
                } else {
                    let target = SharingServiceMenuTarget(
                        service: service, items: [fileURL], sourceWindow: view.window,
                        warnsAboutStuckPanel: Self.panelNeedsClosingHint(messenger: app.name))
                    menuItem.target = target
                    menuItem.action = #selector(SharingServiceMenuTarget.performSharingAction(_:))
                    menuItem.representedObject = target
                }
            } else {
                let path = item.path
                let bundleID = app.bundleID
                let target = OpenWithAppMenuTarget { [weak self] in
                    self?.viewModel.operationsService.openWithApp(path: path, bundleID: bundleID)
                }
                menuItem.target = target
                menuItem.action = #selector(OpenWithAppMenuTarget.open(_:))
                menuItem.representedObject = target
            }
            sendToMenu.addItem(menuItem)
        }

        // Remaining system sharing services (not already shown as messengers).
        let remainingServices = services.filter {
            !consumedServiceTitles.contains($0.title.lowercased())
        }
        if !remainingServices.isEmpty && sendToMenu.numberOfItems > 0 {
            sendToMenu.addItem(.separator())
        }
        for service in remainingServices {
            let target = SharingServiceMenuTarget(service: service, items: [fileURL],
                                                  sourceWindow: view.window)
            let serviceItem = NSMenuItem(
                title: service.title,
                action: #selector(SharingServiceMenuTarget.performSharingAction(_:)),
                keyEquivalent: ""
            )
            serviceItem.target = target
            serviceItem.representedObject = target
            serviceItem.image = service.image
            sendToMenu.addItem(serviceItem)
        }

        return sendToMenu
    }

    /// Which files a messenger cannot take as they are.
    ///
    /// Telegram and an SVG: its share extension takes the file for a picture (`public.svg-image`
    /// is an image type), fails to draw a preview of it — ImageIO cannot render SVG — and the
    /// message then sits in the chat at 0% and never uploads. Sending from Finder fails the same
    /// way, so it is not something the app can do better; packing the file first is what the
    /// person would otherwise do by hand.
    static func needsPackingBeforeSending(_ item: FileItem, messenger: String) -> Bool {
        guard !item.isDirectory else { return false }
        guard messenger.caseInsensitiveCompare("Telegram") == .orderedSame else { return false }
        return item.fileExtension.lowercased() == "svg"
    }

    /// Whose share panel will not close by its own button. Telegram's does not — not from here
    /// and not from Finder — so its panel is the one that gets a note saying which keys do.
    static func panelNeedsClosingHint(messenger: String) -> Bool {
        messenger.caseInsensitiveCompare("Telegram") == .orderedSame
    }

    /// Pack the file, then hand the archive to the share panel.
    private func sendPacked(_ item: FileItem, via service: NSSharingService) {
        do {
            let archive = try viewModel.operationsService.zipForSending(path: item.path)
            let target = SharingServiceMenuTarget(
                service: service, items: [URL(fileURLWithPath: archive)],
                sourceWindow: view.window, warnsAboutStuckPanel: true)
            target.performSharingAction(nil)
        } catch {
            DialogService.shared.showError(title: L("error.pack.title"),
                                           message: error.localizedDescription)
        }
    }

    // MARK: - Open With Helper



    // MARK: - View Mode Switching

    private func applyViewMode(_ mode: ViewMode) {
        // The sort bar stays clickable while the monitor is up, so the user can switch view mode
        // from under it. Re-installing the file list would draw it OVER the monitor and leave
        // isMonitorMode stale, so retire the monitor first.
        if isMonitorMode { hideMonitor() }
        let isDetailed = (mode == .detailed)

        if isDetailed {
            // Remove alternate hosting from view hierarchy completely
            removeAlternateHosting()
            scrollView.isHidden = false
            // The scrollView was hidden until now, so re-tile before reloading to recompute the
            // content height against the just-reactivated bottom constraint. Then re-clamp the
            // scroll to the cursor: without this, a stale offset left over from before could
            // reveal the table scrolled to the last row until a manual scroll fixed it.
            tableView.tile()
            tableView.reloadData()
            // The cursor may have moved in the other mode while this table was off screen; the
            // band must start from where it actually is now.
            lastCursorBandRow = viewModel.cursorIndex
            scrollView.layoutSubtreeIfNeeded()
            scrollToCursorIfNeeded()
            updateDetailedCursorGlow()
            if isActivePanel {
                claimFirstResponder()
            }
        } else {
            // Hide scrollView, show alternate hosting
            scrollView.isHidden = true
            installAlternateHosting()
            if isActivePanel {
                // Delay: SwiftUI needs one layout pass to create the internal NSCollectionView
                DispatchQueue.main.async { [weak self] in
                    self?.claimFirstResponder()
                }
            }
        }
    }

    private func installAlternateHosting() {
        if let existing = alternateHosting {
            // Already in hierarchy — just update content.  The brand-new collection is
            // momentarily 0-height here (SwiftUI sizes it a frame later); BriefFlowLayout
            // guards against that so no "folders in a row" frame is drawn.
            existing.rootView = AnyView(makeAlternateView())
            return
        }
        let hosting = NSHostingView(rootView: AnyView(makeAlternateView()))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)

        // Detach statusBar from scrollView, attach to alternateHosting instead
        statusBarToScrollViewConstraint.isActive = false

        let top = hosting.topAnchor.constraint(equalTo: sortBarHosting.bottomAnchor)
        let bottom = statusBarHosting.topAnchor.constraint(equalTo: hosting.bottomAnchor)
        let leading = hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let trailing = hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        NSLayoutConstraint.activate([top, bottom, leading, trailing])

        alternateTopConstraint = top
        alternateBottomConstraint = bottom
        alternateHosting = hosting
    }

    private func removeAlternateHosting() {
        guard let hosting = alternateHosting else { return }
        if let c = alternateTopConstraint { c.isActive = false }
        if let c = alternateBottomConstraint { c.isActive = false }
        hosting.removeFromSuperview()
        alternateHosting = nil
        alternateTopConstraint = nil
        alternateBottomConstraint = nil

        // Re-attach statusBar to scrollView
        statusBarToScrollViewConstraint.isActive = true
    }

    private func updateAlternateHosting() {
        alternateHosting?.rootView = AnyView(makeAlternateView())
    }

    /// Left-click on the empty panel background (any view mode): drop the marked selection —
    /// the cursor stays put, like Finder / Total Commander — dismiss any inline rename, and
    /// activate the panel.
    private func handleEmptyAreaClick() {
        cancelInlineRename()
        viewModel.clearSelection()
        onBecameActive?()
        // Below the last row is still a click in the list, and it had the same gap as a click on
        // a row: focus stayed wherever the viewer left it and the next arrow key beeped.
        reclaimListFocusIfLost()
    }

    private func makeAlternateView() -> some View {
        AlternateFileListWrapper(
            viewModel: viewModel,
            isActive: isActivePanel,
            onActivate: { [weak self] in self?.onBecameActive?() },
            onBackgroundClear: { [weak self] in self?.handleEmptyAreaClick() },
            onItemClick: { [weak self] index, flags in
                guard let self else { return }
                self.cancelInlineRename()
                // The window's event monitor already handled this exact click (it fires first,
                // for the same event). Re-running handleRowClick would double-toggle a Cmd
                // selection back off. Skip it; still run if the monitor somehow didn't fire.
                if index == self.monitorHandledClickRow,
                   Date().timeIntervalSince(self.monitorHandledClickTime) < 0.3 {
                    self.monitorHandledClickRow = -1
                    self.onBecameActive?()
                    return
                }
                self.handleRowClick(row: index, flags: flags)
                self.onBecameActive?()  // activate AFTER cursor is set
            },
            onItemDoubleClick: { [weak self] item in
                self?.activateItem(item)
            },
            onDeepPress: { [weak self] row in
                self?.handleDeepPress(row: row)
            },
            buildFileMenu: { [weak self] item -> NSMenu in
                let menu = NSMenu(title: "")
                self?.populateContextMenu(menu, for: item)
                return menu
            },
            buildBackgroundMenu: { [weak self] () -> NSMenu in
                let menu = NSMenu(title: "")
                self?.populateContextMenu(menu, for: nil)
                return menu
            },
            onRowsPerColumnChanged: { [weak self] rows in
                self?.briefRowsPerColumn = rows
            },
            onColumnsPerRowChanged: { [weak self] cols in
                self?.thumbnailColumnsPerRow = cols
            },
            onDropPaths: { [weak self] paths, targetFolder, shouldMove in
                guard let self, !paths.isEmpty else { return }
                let pathSet = Set(paths)
                // Try local FileItem.fromPath first; if empty, look up in panel ViewModels (remote ДД)
                var items = paths.compactMap { FileItem.fromPath($0) }
                if items.isEmpty {
                    // Remote paths: look up in both panels' items
                    if let splitVC = self.parent as? MainSplitViewController {
                        let allItems = splitVC.leftPanelVM.items + splitVC.rightPanelVM.items
                        items = allItems.filter { pathSet.contains($0.path) && $0.name != ".." }
                    }
                }
                guard !items.isEmpty else { return }
                let destination = targetFolder?.path ?? self.viewModel.currentPath
                cplog("[DROP] onDropPaths targetFolder=\(targetFolder?.name ?? "nil(current dir)") destination=\(destination) shouldMove=\(shouldMove) items=\(items.map(\.name))")
                // Open the dialog a beat AFTER the drop via a runloop TIMER (not GCD — that
                // would starve the modal's SwiftUI buttons). Lets the drag session + system
                // gesture state fully unwind, so the modal doesn't block trackpad space
                // switching. This is the real drop path (source=table, target=collection).
                let timer = Timer(timeInterval: 0.25, repeats: false) { _ in
                    if shouldMove {
                        self.actionDelegate?.panelDidRequestMove(self, items: items, to: destination)
                    } else {
                        self.actionDelegate?.panelDidRequestCopy(self, items: items, to: destination)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
            },
            onDropArchiveEntries: { [weak self] entries, targetFolder in
                // Routed to the same handler the table view uses, so extraction is decided
                // in one place for every view mode.
                guard let self else { return }
                if self.viewModel.insideArchive {
                    // The collections allow this drop only on "..": extract next to the archive.
                    self.extractDroppedEntriesOut(entries)
                    return
                }
                let destination = targetFolder?.path ?? self.viewModel.currentPath
                self.extractDroppedEntries(entries, to: destination)
            },
            onKeyDown: { [weak self] event -> Bool in
                self?.handleKeyEvent(event) ?? false
            },
            renamingPath: renamingItem?.path,
            renameText: renameText,
            onRenameTextChanged: { [weak self] text in
                self?.renameText = text
            },
            onCommitRename: { [weak self] item in
                self?.commitInlineRename()
            },
            onCancelRename: { [weak self] in
                self?.cancelInlineRename()
            }
        )
    }
}

// MARK: - Alternate View Modes Wrapper

/// SwiftUI wrapper that embeds FileListBriefView / FileListThumbnailsView for non-detailed modes.
private struct AlternateFileListWrapper: View {
    @ObservedObject var viewModel: PanelViewModel
    let isActive: Bool

    let onActivate: () -> Void
    /// Left-click on empty background: clear the marked selection + activate (separate from
    /// onActivate, which item right-click reuses and must NOT clear the selection).
    let onBackgroundClear: () -> Void
    let onItemClick: (Int, NSEvent.ModifierFlags) -> Void
    let onItemDoubleClick: (FileItem) -> Void
    let onDeepPress: (Int) -> Void
    let buildFileMenu: (FileItem) -> NSMenu
    let buildBackgroundMenu: () -> NSMenu
    let onRowsPerColumnChanged: (Int) -> Void
    let onColumnsPerRowChanged: (Int) -> Void
    let onDropPaths: ([String], FileItem?, Bool) -> Void
    /// Entries dragged OUT of an archive: no file URL, so they need their own channel.
    let onDropArchiveEntries: ([String], FileItem?) -> Void
    let onKeyDown: (NSEvent) -> Bool

    // Inline rename state
    let renamingPath: String?
    let renameText: String
    let onRenameTextChanged: (String) -> Void
    let onCommitRename: (FileItem) -> Void
    let onCancelRename: () -> Void

    @AppStorage("briefColumnWidth") private var briefItemWidth: Double = 190
    @AppStorage("briefRowHeight") private var briefRowHeight: Double = 26
    @AppStorage(PanelAppearanceSettings.iconScaleKey) private var iconScale: Double = PanelAppearanceSettings.defaultIconScale
    @AppStorage(PanelAppearanceSettings.folderNameColorHexKey) private var folderNameColorHex: String = ""
    @AppStorage(PanelAppearanceSettings.fileNameColorHexKey) private var fileNameColorHex: String = ""
    @AppStorage(PanelAppearanceSettings.cursorNameColorHexKey) private var cursorNameColorHex: String = ""
    @AppStorage(PanelAppearanceSettings.cursorBackgroundColorHexKey) private var cursorBackgroundColorHex: String = ""
    @AppStorage(PanelAppearanceSettings.folderIconColorHexKey) private var folderIconColorHex: String = ""
    @AppStorage(FolderIconStyle.storageKey) private var folderIconStyleRaw: String = FolderIconStyle.macos.rawValue
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    @AppStorage(PanelAppearanceSettings.cursorUsesCustomColorKey) private var cursorUsesCustomColor: Bool = false
    @AppStorage(PanelAppearanceSettings.upIconScaleKey) private var upIconScale: Double = PanelAppearanceSettings.defaultUpIconScale
    @AppStorage(PanelAppearanceSettings.upIconWeightKey) private var upIconWeight: Double = PanelAppearanceSettings.defaultUpIconWeight
    @AppStorage(PanelAppearanceSettings.upIconSymbolKey) private var upIconSymbol: String = PanelAppearanceSettings.defaultUpIconSymbol
    // Re-render (→ brief updateNSView → updateCursorGlow) when beauty / blur / height change.
    @AppStorage(PanelAppearanceSettings.beautyModeEnabledKey) private var beautyModeEnabled: Bool = false
    @AppStorage(PanelAppearanceSettings.cursorBlurKey) private var cursorBlurValue: Double = PanelAppearanceSettings.defaultCursorBlur
    @AppStorage(PanelAppearanceSettings.cursorHeightKey) private var cursorHeightValue: Double = PanelAppearanceSettings.defaultCursorHeight
    @AppStorage(PanelAppearanceSettings.cursorWidthKey) private var cursorWidthValue: Double = PanelAppearanceSettings.defaultCursorWidth
    @AppStorage(PanelAppearanceSettings.cursorCornerKey) private var cursorCornerValue: Double = PanelAppearanceSettings.defaultCursorCorner
    @AppStorage(PanelAppearanceSettings.cursorOffsetXKey) private var cursorOffsetXValue: Double = 0
    @AppStorage(PanelAppearanceSettings.cursorOffsetYKey) private var cursorOffsetYValue: Double = 0
    @AppStorage(PanelAppearanceSettings.cursorAnchorXKey) private var cursorAnchorXValue: Double = PanelAppearanceSettings.defaultCursorAnchor
    @AppStorage(PanelAppearanceSettings.cursorAnchorYKey) private var cursorAnchorYValue: Double = PanelAppearanceSettings.defaultCursorAnchor
    /// From the settings; the picture inside keeps the proportion the fixed 100/64 had.
    private var thumbnailCellSize: CGFloat { PanelAppearanceSettings.resolvedThumbnailSize }
    private var thumbnailPreviewSize: CGFloat { (thumbnailCellSize * 0.64).rounded() }

    private var resolvedFolderNameColor: NSColor {
        PanelAppearanceSettings.nsColor(from: folderNameColorHex, fallback: .systemYellow)
    }
    private var resolvedFileNameColor: NSColor {
        PanelAppearanceSettings.nsColor(from: fileNameColorHex, fallback: .labelColor)
    }
    // Read the beauty @AppStorage here so `body` depends on them → the panel re-renders
    // (→ updateNSView → updateCursorGlow) live while the sliders move.
    private var resolvedCursorBeauty: Bool { beautyModeEnabled }
    private var resolvedCursorBlur: CGFloat { CGFloat(max(0, min(30, cursorBlurValue))) }
    private var resolvedCursorHeightFraction: CGFloat {
        CGFloat(max(0.3, min(1.0, cursorHeightValue)))
    }
    private var resolvedCursorWidthFraction: CGFloat {
        CGFloat(max(0.01, min(1.0, cursorWidthValue)))
    }
    private var resolvedCursorCorner: CGFloat { CGFloat(max(0, min(20, cursorCornerValue))) }
    private var resolvedCursorOffsetX: CGFloat { CGFloat(max(-100, min(100, cursorOffsetXValue))) }
    private var resolvedCursorOffsetY: CGFloat { CGFloat(max(-30, min(30, cursorOffsetYValue))) }
    private var resolvedCursorAnchorX: CGFloat { CGFloat(max(0, min(1, cursorAnchorXValue))) }
    private var resolvedCursorAnchorY: CGFloat { CGFloat(max(0, min(1, cursorAnchorYValue))) }
    private var accentNSColor: NSColor {
        PanelAppearanceSettings.nsColor(from: accentColorHex, fallback: .systemPurple)
    }
    private var upIconScaleClamped: CGFloat {
        CGFloat(max(0.3, min(2.0, upIconScale)))
    }
    private var resolvedCursorNameColor: NSColor {
        PanelAppearanceSettings.resolvedCursorNameColor()
    }
    private var resolvedCursorBackgroundColor: NSColor? {
        PanelAppearanceSettings.resolvedCursorBackground()
    }
    private var resolvedFolderIconTintColor: NSColor? {
        PanelAppearanceSettings.optionalNSColor(from: folderIconColorHex)
    }
    private var resolvedFolderIconStyle: FolderIconStyle {
        FolderIconStyle(rawValue: folderIconStyleRaw) ?? .macos
    }

    var body: some View {
        switch viewModel.viewMode {
        case .detailed:
            EmptyView()
        case .brief:
            FileListBriefView(
                viewModel: viewModel,
                isActive: isActive,
                itemWidth: CGFloat(briefItemWidth),
                // The cell grows for a big icon here too, so the scale setting means the same
                // thing in every mode instead of quietly stopping at the row's height.
                itemHeight: max(PanelAppearanceSettings.resolvedListRowHeight,
                                CGFloat(16) * CGFloat(max(iconScale,
                                                          PanelAppearanceSettings.minimumIconScale)) + 4),
                iconSize: max(10, CGFloat(16) * CGFloat(max(iconScale,
                                                            PanelAppearanceSettings.minimumIconScale))),
                folderIconStyle: resolvedFolderIconStyle,
                folderIconTintColor: resolvedFolderIconTintColor,
                upIconScale: upIconScaleClamped,
                upIconWeight: upIconWeight,
                upIconSymbol: upIconSymbol,
                folderNameColor: resolvedFolderNameColor,
                fileNameColor: resolvedFileNameColor,
                colorGeneration: FileColorRulesStore.shared.generation,
                cursorNameColor: resolvedCursorNameColor,
                cursorBackgroundColor: resolvedCursorBackgroundColor,
                cursorBeauty: resolvedCursorBeauty,
                cursorBlur: resolvedCursorBlur,
                cursorHeightFraction: resolvedCursorHeightFraction,
                cursorWidthFraction: resolvedCursorWidthFraction,
                cursorCorner: resolvedCursorCorner,
                cursorOffsetX: resolvedCursorOffsetX,
                cursorOffsetY: resolvedCursorOffsetY,
                cursorAnchorX: resolvedCursorAnchorX,
                cursorAnchorY: resolvedCursorAnchorY,
                renamingPath: renamingPath,
                renameText: renameText,
                onRenameTextChanged: onRenameTextChanged,
                onCommitRename: onCommitRename,
                onCancelRename: onCancelRename,
                onRowsPerColumnChanged: onRowsPerColumnChanged,
                onItemPrimaryClick: onItemClick,
                onItemDoubleClick: onItemDoubleClick,
                onDeepPress: onDeepPress,
                onItemRightClick: { item, _ in
                    onActivate()
                    if let idx = viewModel.items.firstIndex(where: { $0.path == item.path }) {
                        viewModel.activateItemForContextMenu(at: idx)
                    }
                },
                menuForItem: buildFileMenu,
                backgroundMenu: buildBackgroundMenu,
                onBackgroundPrimaryClick: onBackgroundClear,
                onBeginDrag: { item in NSItemProvider(object: URL(fileURLWithPath: item.path) as NSURL) },
                onDropPaths: onDropPaths,
                onDropArchiveEntries: onDropArchiveEntries,
                keyHandler: onKeyDown
            )
        case .thumbnails:
            FileListThumbnailsView(
                viewModel: viewModel,
                isActive: isActive,
                cellSize: thumbnailCellSize,
                previewSize: thumbnailPreviewSize,
                useQuickLookPreviews: true,
                folderIconStyle: resolvedFolderIconStyle,
                folderIconTintColor: resolvedFolderIconTintColor,
                upIconScale: upIconScaleClamped,
                upIconWeight: upIconWeight,
                upIconSymbol: upIconSymbol,
                folderNameColor: resolvedFolderNameColor,
                fileNameColor: resolvedFileNameColor,
                colorGeneration: FileColorRulesStore.shared.generation,
                cursorNameColor: resolvedCursorNameColor,
                cursorBackgroundColor: resolvedCursorBackgroundColor,
                cursorBeauty: resolvedCursorBeauty,
                cursorBlur: resolvedCursorBlur,
                cursorCorner: resolvedCursorCorner,
                renamingPath: renamingPath,
                renameText: renameText,
                onRenameTextChanged: onRenameTextChanged,
                onCommitRename: onCommitRename,
                onCancelRename: onCancelRename,
                onColumnsPerRowChanged: onColumnsPerRowChanged,
                onItemPrimaryClick: onItemClick,
                onItemDoubleClick: onItemDoubleClick,
                onDeepPress: onDeepPress,
                onItemRightClick: { item, _ in
                    onActivate()
                    if let idx = viewModel.items.firstIndex(where: { $0.path == item.path }) {
                        viewModel.activateItemForContextMenu(at: idx)
                    }
                },
                menuForItem: buildFileMenu,
                backgroundMenu: buildBackgroundMenu,
                onBackgroundPrimaryClick: onBackgroundClear,
                onBeginDrag: { item in NSItemProvider(object: URL(fileURLWithPath: item.path) as NSURL) },
                onDropPaths: onDropPaths,
                onDropArchiveEntries: onDropArchiveEntries,
                keyHandler: onKeyDown
            )
        }
    }
}


