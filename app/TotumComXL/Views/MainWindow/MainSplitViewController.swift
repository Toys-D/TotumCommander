import AppKit
import Combine
import SwiftUI

/// Manages left panel, center divider, and right panel in a manual horizontal layout.
/// Supports drag-to-resize, double-click-to-center, context menu, and dynamic width from Settings.
final class MainSplitViewController: NSViewController {

    let leftPanelVM: PanelViewModel
    let rightPanelVM: PanelViewModel
    let leftTabsVM: PanelTabsViewModel
    let rightTabsVM: PanelTabsViewModel

    private(set) var leftPanelVC: PanelViewController!
    private(set) var rightPanelVC: PanelViewController!
    private var dividerHosting: NSHostingView<CenterDividerView>!

    /// Подсветка «вы здесь» в тоннеле идёт за панелью, а не только за переключением
    /// сторон: в другую папку можно уйти, не меняя активную панель.
    private var dividerPathObservers: [AnyCancellable] = []

    private(set) var activePanel: PanelSide = .left

    /// The proportion of available width given to left panel (0.0–1.0)
    private var splitRatio: CGFloat = 0.5

    // Drag state
    private var escMonitor: Any?
    private var dragMonitor: Any?
    private var dragStartX: CGFloat?
    private var dragBaseRatio: CGFloat = 0.5
    private var lastClickTime: Date = .distantPast

    // Constraints managed dynamically
    private var leftWidthConstraint: NSLayoutConstraint!
    private var dividerWidthConstraint: NSLayoutConstraint!

    weak var panelActionDelegate: PanelActionDelegate? {
        didSet {
            leftPanelVC?.actionDelegate = panelActionDelegate
            rightPanelVC?.actionDelegate = panelActionDelegate
        }
    }

    /// Callbacks for divider actions (set by MainWindowController)
    var onDividerCopy: (() -> Void)?
    var onDividerMove: (() -> Void)?
    var onDividerDelete: (() -> Void)?
    var onDividerMkdir: (() -> Void)?
    var onDividerView: (() -> Void)?
    var onDividerEdit: (() -> Void)?
    var onDividerNetwork: (() -> Void)?
    var queueVM: OperationQueueViewModel?
    var onShowQueuePanel: (() -> Void)?

    enum PanelSide {
        case left, right
    }

    // MARK: - Init

    init(leftPanel: PanelViewModel, rightPanel: PanelViewModel,
         leftTabs: PanelTabsViewModel, rightTabs: PanelTabsViewModel) {
        self.leftPanelVM = leftPanel
        self.rightPanelVM = rightPanel
        self.leftTabsVM = leftTabs
        self.rightTabsVM = rightTabs
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))

        // Left panel
        leftPanelVC = PanelViewController(viewModel: leftPanelVM, tabsVM: leftTabsVM, side: .left)
        addChild(leftPanelVC)
        leftPanelVC.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(leftPanelVC.view)

        // Center divider
        dividerHosting = TunnelDropHostingView(rootView: makeDividerRootView())
        dividerHosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dividerHosting)

        // Right panel
        rightPanelVC = PanelViewController(viewModel: rightPanelVM, tabsVM: rightTabsVM, side: .right)
        addChild(rightPanelVC)
        rightPanelVC.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rightPanelVC.view)

        let dividerWidth = resolvedDividerWidth()

        // Prevent hosting view from collapsing
        dividerHosting.setContentHuggingPriority(.required, for: .horizontal)
        dividerHosting.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Panels should compress before divider
        leftPanelVC.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leftPanelVC.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rightPanelVC.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rightPanelVC.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dividerWidthConstraint = dividerHosting.widthAnchor.constraint(equalToConstant: dividerWidth)
        dividerWidthConstraint.priority = .required

        // Left panel width — managed by splitRatio
        // We'll compute actual width in viewDidLayout
        leftWidthConstraint = leftPanelVC.view.widthAnchor.constraint(equalToConstant: 500)
        leftWidthConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            // Left panel
            leftPanelVC.view.topAnchor.constraint(equalTo: container.topAnchor),
            leftPanelVC.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            leftPanelVC.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            leftWidthConstraint,

            // Center divider — fixed width
            dividerHosting.topAnchor.constraint(equalTo: container.topAnchor),
            dividerHosting.leadingAnchor.constraint(equalTo: leftPanelVC.view.trailingAnchor),
            dividerHosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            dividerWidthConstraint,

            // Right panel
            rightPanelVC.view.topAnchor.constraint(equalTo: container.topAnchor),
            rightPanelVC.view.leadingAnchor.constraint(equalTo: dividerHosting.trailingAnchor),
            rightPanelVC.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rightPanelVC.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Minimum widths
        leftPanelVC.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        rightPanelVC.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        observePanelPaths()

        // Propagate action delegate
        leftPanelVC.actionDelegate = panelActionDelegate
        rightPanelVC.actionDelegate = panelActionDelegate

        // Set initial active panel
        leftPanelVC.isActivePanel = true
        rightPanelVC.isActivePanel = false

        // Listen for panel focus changes
        leftPanelVC.onBecameActive = { [weak self] in
            self?.setActivePanel(.left)
        }
        rightPanelVC.onBecameActive = { [weak self] in
            self?.setActivePanel(.right)
        }

        // Observe divider width setting changes (from Settings slider)
        UserDefaults.standard.addObserver(self, forKeyPath: "centerDividerWidth", options: .new, context: nil)

        // Install drag monitor for divider resizing and double-click
        installDragMonitor()

        // ESC monitor — close embedded viewer/editor
        installEscMonitor()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applySplitRatio()
    }

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: "centerDividerWidth")
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - KVO for Settings

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "centerDividerWidth" {
            let newWidth = resolvedDividerWidth()
            dividerWidthConstraint?.constant = newWidth
            applySplitRatio()
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    // MARK: - Split Ratio

    private func availableWidth() -> CGFloat {
        let total = view.bounds.width
        let divider = dividerWidthConstraint?.constant ?? resolvedDividerWidth()
        return max(1, total - divider)
    }

    private func applySplitRatio() {
        let available = availableWidth()
        let leftWidth = max(200, min(available - 200, available * splitRatio))
        leftWidthConstraint?.constant = leftWidth
    }

    func setSplitRatio(_ ratio: CGFloat, animated: Bool = false) {
        splitRatio = max(0.15, min(0.85, ratio))
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                applySplitRatio()
                view.layoutSubtreeIfNeeded()
            }
        } else {
            applySplitRatio()
        }
        updateDividerActivePath()
    }

    // MARK: - ESC Monitor (close embedded panels)

    private func installEscMonitor() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            guard let window = self.view.window, event.window === window else { return event }

            // Close embedded editor first (has save dialog)
            if self.isEditorEmbedded {
                NotificationCenter.default.post(name: .fcxlRequestEditorClose, object: nil)
                return nil
            }

            // Close embedded viewer
            if self.isViewerEmbedded {
                self.closeEmbeddedViewer()
                return nil
            }

            // Not consumed — let PanelViewController handle it (clear selection, etc.)
            return event
        }
    }

    // MARK: - Drag Monitor (resize by dragging divider)

    private func installDragMonitor() {
        // Правый клик монитор больше не трогает: он съедал его на подлёте и показывал
        // меню пропорций ПОВЕРХ всего — меню папок и операций туннеля не открывались
        // никогда. Теперь правые клики разбирает сам SwiftUI: у кнопок свои меню, у
        // остального — общее меню туннеля с теми же пропорциями.
        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown:
                guard self.isMouseOverDivider(event) else { break }
                let now = Date()
                // Double-click detection (uses user-configured interval)
                if now.timeIntervalSince(self.lastClickTime) < DoubleClickSettings.currentInterval {
                    self.setSplitRatio(0.5, animated: true)
                    self.lastClickTime = .distantPast
                    self.dragStartX = nil
                    break
                }
                self.lastClickTime = now
                self.dragStartX = event.locationInWindow.x
                self.dragBaseRatio = self.splitRatio
            case .leftMouseDragged:
                guard let startX = self.dragStartX else { break }
                let dx = event.locationInWindow.x - startX
                let available = self.availableWidth()
                let newRatio = self.dragBaseRatio + dx / available
                self.setSplitRatio(newRatio)
            case .leftMouseUp:
                self.dragStartX = nil
            default:
                break
            }
            return event
        }
    }

    private func isMouseOverDivider(_ event: NSEvent) -> Bool {
        guard let window = view.window, event.window === window else { return false }
        let pointInView = dividerHosting.convert(event.locationInWindow, from: nil)
        return dividerHosting.bounds.contains(pointInView)
    }

    // MARK: - Context Menu

    // MARK: - Helpers

    private func resolvedDividerWidth() -> CGFloat {
        let raw = UserDefaults.standard.double(forKey: "centerDividerWidth")
        return CGFloat(raw > 0 ? raw : 36)
    }

    // MARK: - Center Divider

    private func makeDividerRootView() -> CenterDividerView {
        CenterDividerView(
            activePanelPath: activePanelViewModel.currentPath,
            isLeftPanelActive: activePanel == .left,
            splitRatio: splitRatio,
            onSwap: { [weak self] in self?.swapPanels() },
            onCopy: { [weak self] in self?.onDividerCopy?() },
            onMove: { [weak self] in self?.onDividerMove?() },
            onDelete: { [weak self] in self?.onDividerDelete?() },
            onMkdir: { [weak self] in self?.onDividerMkdir?() },
            onView: { [weak self] in self?.onDividerView?() },
            onEdit: { [weak self] in self?.onDividerEdit?() },
            onQuickLink: { [weak self] path in self?.openQuickLink(path) },
            onNetwork: { [weak self] in self?.onDividerNetwork?() },
            onLocalNetwork: { [weak self] in
                // A popover action runs INSIDE SwiftUI's update pass. Swapping the panel's
                // tab and reloading it right there left NSCollectionView asking for layout
                // attributes of items that were already gone — an AppKit assertion, i.e. a
                // hard crash. Let the popover finish closing first (same runloop-callout
                // pattern the drag-drop dialog uses).
                RunLoop.main.perform(inModes: [.common]) {
                    self?.activePanelVC.openLocalNetwork()
                }
            },
            onConnectNetworkDriveAction: { [weak self] in
                // Same runloop-callout reason as above: this opens a modal from inside
                // SwiftUI's update pass, which parks the queue and kills the dialog's buttons.
                RunLoop.main.perform(inModes: [.common]) {
                    self?.activePanelVC.connectNetworkDrive()
                }
            },
            queueVM: queueVM,
            onShowQueuePanel: { [weak self] in self?.onShowQueuePanel?() },
            onSetRatio: { [weak self] ratio in self?.setSplitRatio(ratio, animated: true) },
            onSyncLeftToRight: { [weak self] in self?.syncLeftToRight() },
            onSyncRightToLeft: { [weak self] in self?.syncRightToLeft() },
            onPopUpMenu: { [weak self] menu in
                guard let self, let event = NSApp.currentEvent else { return }
                NSMenu.popUpContextMenu(menu, with: event, for: self.dividerHosting)
            }
        )
    }

    private func updateDividerActivePath() {
        guard let hosting = dividerHosting else { return }
        // Модель панели объявляет о себе на каждый чих — курсор, выделение, значки git.
        // Пересобирать дерево SwiftUI на каждое объявление дорого и без нужды, поэтому
        // только когда меняется то, что туннель правда показывает.
        guard hosting.rootView.activePanelPath != activePanelViewModel.currentPath
                || hosting.rootView.isLeftPanelActive != (activePanel == .left)
                || hosting.rootView.splitRatio != splitRatio else { return }
        hosting.rootView = makeDividerRootView()
    }

    private func observePanelPaths() {
        dividerPathObservers = [leftPanelVM, rightPanelVM].map { vm in
            vm.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.updateDividerActivePath() }
        }
    }

    /// Быстрая ссылка туннеля и папки меню «Переход»: открыть в активной панели.
    func openQuickLink(_ path: String) {
        activePanelViewModel.loadDirectory(at: path)
    }

    /// Открыть в правой панели папку левой — и наоборот.
    func syncLeftToRight() {
        rightPanelVM.loadDirectory(at: leftPanelVM.currentPath)
    }

    func syncRightToLeft() {
        leftPanelVM.loadDirectory(at: rightPanelVM.currentPath)
    }

    /// Доля левой панели — для галочки в меню пропорций.
    var currentSplitRatio: CGFloat { splitRatio }

    func swapPanels() {
        let leftPath = leftPanelVM.currentPath
        let rightPath = rightPanelVM.currentPath
        leftPanelVM.loadDirectory(at: rightPath)
        rightPanelVM.loadDirectory(at: leftPath)
    }

    // MARK: - Active Panel

    func setActivePanel(_ side: PanelSide) {
        guard activePanel != side else { return }
        activePanel = side
        leftPanelVC.isActivePanel = (side == .left)
        rightPanelVC.isActivePanel = (side == .right)
        updateDividerActivePath()
    }

    var activePanelViewModel: PanelViewModel {
        activePanel == .left ? leftPanelVM : rightPanelVM
    }

    var inactivePanelViewModel: PanelViewModel {
        activePanel == .left ? rightPanelVM : leftPanelVM
    }

    var activePanelVC: PanelViewController {
        activePanel == .left ? leftPanelVC : rightPanelVC
    }

    var inactivePanelVC: PanelViewController {
        activePanel == .left ? rightPanelVC : leftPanelVC
    }

    /// Toggle the system monitor in the ACTIVE panel, keeping it unique in the app: opening it in
    /// one panel closes it in the other, so the sampler only ever runs once and the second panel
    /// always keeps showing files.
    func toggleMonitorInActivePanel() {
        let other = inactivePanelVC
        if other.isMonitorMode { other.toggleMonitor() }
        activePanelVC.toggleMonitor()
    }

    // MARK: - Embedded Viewer

    private(set) var isViewerEmbedded = false
    private var embeddedViewerHosting: NSView?

    /// Чем открыть просмотр заново — чтобы вернуть его на место после правки.
    private struct ViewerRequest {
        let viewModel: PanelViewModel
        let useNativeQL: Bool
        let operations: FileOperationsService?
    }
    /// Просмотр, открытый сейчас.
    private var currentViewer: ViewerRequest?
    /// Просмотр, отступивший ради правки: вернётся, когда правка закроется.
    private var viewerBehindEditor: ViewerRequest?
    /// Что сделать, когда редактор действительно закроется — он ведь может ещё спросить
    /// про сохранение, и до его ответа место не освободится.
    private var afterEditorCloses: (() -> Void)?

    func showEmbeddedViewer(viewModel: PanelViewModel, useNativeQL: Bool,
                            operations: FileOperationsService? = nil) {
        let request = ViewerRequest(viewModel: viewModel, useNativeQL: useNativeQL,
                                    operations: operations)
        // Место одно. Если там правка — сначала закрыть её, и не напрямую: несохранённое
        // спросят, и просмотр откроется уже после ответа.
        if PanelSlot.step(opening: .viewer, current: slotOccupant) == .closeEditorFirst {
            afterEditorCloses = { [weak self] in self?.openViewerNow(request) }
            NotificationCenter.default.post(name: .fcxlRequestEditorClose, object: nil)
            return
        }
        openViewerNow(request)
    }

    /// Кто сейчас занимает место рядом с панелью.
    private var slotOccupant: PanelSlot.Occupant {
        if isEditorEmbedded { return .editor }
        if isViewerEmbedded { return .viewer }
        return .nobody
    }

    private func openViewerNow(_ request: ViewerRequest) {
        let viewModel = request.viewModel
        let useNativeQL = request.useNativeQL
        let operations = request.operations
        closeEmbeddedViewer()
        currentViewer = request

        let onClose: () -> Void = { [weak self] in
            self?.closeEmbeddedViewer()
        }

        let hostingView: NSView
        if useNativeQL {
            let panel = EmbeddedViewerPanel(viewModel: viewModel, onClose: onClose, operations: operations)
            hostingView = NSHostingView(rootView: panel)
        } else {
            let viewer = UnifiedFileViewer(viewModel: viewModel, onClose: onClose, operations: operations)
            hostingView = NSHostingView(rootView: viewer)
        }

        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let inactiveVC = activePanel == .left ? rightPanelVC! : leftPanelVC!
        inactiveVC.view.isHidden = true

        view.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: inactiveVC.view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: inactiveVC.view.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: inactiveVC.view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: inactiveVC.view.trailingAnchor),
        ])

        embeddedViewerHosting = hostingView
        isViewerEmbedded = true
    }

    func closeEmbeddedViewer() {
        currentViewer = nil
        guard isViewerEmbedded else { return }
        embeddedViewerHosting?.removeFromSuperview()
        embeddedViewerHosting = nil
        leftPanelVC.view.isHidden = false
        rightPanelVC.view.isHidden = false
        isViewerEmbedded = false
        // Return focus to the active panel
        activePanelVC.claimFirstResponder()
    }

    // MARK: - Embedded Editor

    private(set) var isEditorEmbedded = false
    private var embeddedEditorHosting: NSView?
    private var embeddedEditorPath: String?
    private var embeddedEditorSource: EditorDocumentSource = .fileSystem
    private var embeddedEditorIsDirty = false

    func showEmbeddedEditor(filePath: String,
                            source: EditorDocumentSource = .fileSystem,
                            operations: FileOperationsService? = nil) {
        stepViewerAsideForEditor()
        closeEmbeddedEditor()

        let onClose: () -> Void = { [weak self] in
            self?.closeEmbeddedEditor()
        }

        embeddedEditorPath = filePath
        embeddedEditorSource = source
        embeddedEditorIsDirty = false
        let editor = EmbeddedEditorPanel(filePath: filePath, source: source,
                                         operations: operations, onClose: onClose,
                                         onDirtyChange: { [weak self] in self?.embeddedEditorIsDirty = $0 })
        let hostingView = NSHostingView(rootView: editor)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let inactiveVC = activePanel == .left ? rightPanelVC! : leftPanelVC!
        inactiveVC.view.isHidden = true

        view.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: inactiveVC.view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: inactiveVC.view.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: inactiveVC.view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: inactiveVC.view.trailingAnchor),
        ])

        embeddedEditorHosting = hostingView
        isEditorEmbedded = true
    }

    /// Embed the native RTF editor (NSTextView) instead of Monaco, for .rtf/.rtfd files.
    /// Shares the same panel slot and close path as the Monaco editor.
    func showEmbeddedRTFEditor(filePath: String) {
        stepViewerAsideForEditor()
        closeEmbeddedEditor()

        let onClose: () -> Void = { [weak self] in
            self?.closeEmbeddedEditor()
        }

        embeddedEditorPath = filePath
        embeddedEditorSource = .fileSystem
        embeddedEditorIsDirty = false
        let editor = RTFEditorPanel(filePath: filePath, onClose: onClose,
                                    onDirtyChange: { [weak self] in self?.embeddedEditorIsDirty = $0 })
        let hostingView = NSHostingView(rootView: editor)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let inactiveVC = activePanel == .left ? rightPanelVC! : leftPanelVC!
        inactiveVC.view.isHidden = true

        view.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: inactiveVC.view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: inactiveVC.view.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: inactiveVC.view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: inactiveVC.view.trailingAnchor),
        ])

        embeddedEditorHosting = hostingView
        isEditorEmbedded = true
    }

    /// Убрать просмотр с места, запомнив, чем его вернуть.
    private func stepViewerAsideForEditor() {
        guard PanelSlot.step(opening: .editor, current: slotOccupant) == .closeViewerFirst,
              let showing = currentViewer else { return }
        closeEmbeddedViewer()
        viewerBehindEditor = showing
    }

    func closeEmbeddedEditor() {
        guard isEditorEmbedded else { return }
        embeddedEditorHosting?.removeFromSuperview()
        embeddedEditorHosting = nil
        leftPanelVC.view.isHidden = false
        rightPanelVC.view.isHidden = false
        isEditorEmbedded = false
        embeddedEditorPath = nil
        embeddedEditorIsDirty = false
        // Место освободилось: сначала то, что ждало очереди (человек нажал F3 поверх правки),
        // иначе — просмотр, отступивший ради этой правки.
        let pending = afterEditorCloses
        afterEditorCloses = nil
        let waiting = viewerBehindEditor
        viewerBehindEditor = nil
        if let pending {
            pending()
            return
        }
        if let waiting, PanelSlot.restoresViewer(steppedAside: true) {
            openViewerNow(waiting)
            return
        }
        // Return keyboard focus to the active panel (Monaco's WKWebView held it) — same as the
        // embedded viewer. The async tick lets the WebView release first responder first.
        DispatchQueue.main.async { [weak self] in
            self?.activePanelVC.claimFirstResponder()
        }
    }

    /// Path of the embedded editor's file if it has unsaved changes and lives on the given volume
    /// (archive-sourced edits live in temp, so they're excluded). Used by the disk-eject warning.
    func dirtyEmbeddedEditorPath(onVolume volumeRoot: String) -> String? {
        guard isEditorEmbedded, embeddedEditorIsDirty, let path = embeddedEditorPath else { return nil }
        guard case .fileSystem = embeddedEditorSource else { return nil }
        let prefix = volumeRoot.hasSuffix("/") ? volumeRoot : volumeRoot + "/"
        return (path == volumeRoot || path.hasPrefix(prefix)) ? path : nil
    }

    // MARK: - Hidden Files

    func setShowHiddenFiles(_ show: Bool) {
        leftPanelVM.setShowHiddenFiles(show)
        rightPanelVM.setShowHiddenFiles(show)
    }
}

// MARK: - Приём папок в туннель

/// Хостинг туннеля, принимающий перетаскивание папок на всей своей площади.
///
/// SwiftUI-овский .onDrop внутри этого хостинга до бросков не доживал — человек тащил
/// папку, и «абсолютно ничего не менялось». AppKit-назначение на самом виде надёжно:
/// заявленные типы, ясные ответы, и падать некуда.
final class TunnelDropHostingView: NSHostingView<CenterDividerView> {

    required init(rootView: CenterDividerView) {
        super.init(rootView: rootView)
        // Высоту туннеля задаёт окно, а не содержимое: по умолчанию NSHostingView требует
        // под SwiftUI минимальную высоту, а туннель прижат к верху и низу контейнера — при
        // низком окне ограничения спорили, и туннель вылезал над панелями.
        sizingOptions = []
        // SwiftUI за рамку своего вида не режет; если содержимое всё же вылезло — режем сами.
        clipsToBounds = true
        registerForDraggedTypes([.fileURL])
    }

    @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("туннель собирается кодом, не из архива")
    }

    /// Папки из текущего переноса: буфер читается один раз при входе, не на каждый сдвиг.
    private var carried: [URL] = []

    /// Правая кнопка: меню папки, операции или пустого места — по рамкам кнопок, которые
    /// вид отдаёт наружу. Меню — AppKit со значками, как контекстное меню панели.
    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        let fromTop = isFlipped ? local.y : bounds.height - local.y
        let geometry = TunnelDropState.shared
        let store = TunnelStore.shared
        if let index = geometry.folderSlots.firstIndex(where: { $0.minY <= fromTop && fromTop <= $0.maxY }),
           store.folders.indices.contains(index) {
            return TunnelContextMenu.folder(store.folders[index],
                                            activePanelPath: rootView.activePanelPath)
        }
        if let index = geometry.actionSlots.firstIndex(where: { $0.minY <= fromTop && fromTop <= $0.maxY }),
           store.actions.indices.contains(index) {
            return TunnelContextMenu.action(store.actions[index])
        }
        return TunnelContextMenu.split(for: rootView)
    }

    /// Правый щелчок показывает меню сам: NSHostingView ведёт события по-своему, и
    /// полагаться на то, что он спросит menu(for:), нельзя.
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        carried = droppedFolders(sender)
        guard !carried.isEmpty else { return [] }
        showInsertion(for: sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !carried.isEmpty else { return [] }
        showInsertion(for: sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        TunnelDropState.shared.insertionIndex = nil
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        TunnelDropState.shared.insertionIndex = nil
        carried = []
    }

    /// Куда бросили, там папка и стоит; несколько — одна под другой, начиная с места броска.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { TunnelDropState.shared.insertionIndex = nil }
        let folders = carried.isEmpty ? droppedFolders(sender) : carried
        guard !folders.isEmpty else { return false }
        var index = insertionIndex(for: sender)
        var added = false
        for url in folders where TunnelStore.shared.addFolder(path: url.path, at: index) {
            added = true
            index += 1
        }
        return added
    }

    /// Точка переноса в координатах туннеля (ось вниз, как у рамок кнопок).
    private func insertionIndex(for info: NSDraggingInfo) -> Int {
        let local = convert(info.draggingLocation, from: nil)
        let fromTop = isFlipped ? local.y : bounds.height - local.y
        return TunnelDrop.insertionIndex(y: fromTop, slots: TunnelDropState.shared.folderSlots)
    }

    private func showInsertion(for info: NSDraggingInfo) {
        let index = insertionIndex(for: info)
        if TunnelDropState.shared.insertionIndex != index {
            TunnelDropState.shared.insertionIndex = index
        }
    }

    /// Из брошенного — только папки: файлам в списке путей туннеля делать нечего.
    private func droppedFolders(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }
}
