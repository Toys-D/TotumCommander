import AppKit
import SwiftUI
import Quartz
import Combine
import FCXLBridgeObjC

final class MainWindowController: NSWindowController, NSToolbarDelegate, PanelActionDelegate, NSMenuItemValidation {

    /// The two panels. Readable from outside by the embedded viewer, which hands the keyboard
    /// back to the active panel after one of its own buttons was pressed.
    let splitVC: MainSplitViewController
    private let operationsService: FileOperationsService
    private let remoteTransferService = RemoteTransferService()
    private let queueService: OperationQueueService
    private let queueVM: OperationQueueViewModel
    let queuePanelController: OperationQueuePanelController

    // MARK: - Toolbar identifiers
    private static let toolbarID = NSToolbar.Identifier("MainToolbar")
    private static let hiddenFilesItemID = NSToolbarItem.Identifier("toggleHiddenFiles")
    private static let settingsItemID = NSToolbarItem.Identifier("openSettings")
    private static let diskInfoItemID = NSToolbarItem.Identifier("diskInfo")
    private static let monitorItemID = NSToolbarItem.Identifier("systemMonitor")
    private static let themeItemID = NSToolbarItem.Identifier("toggleTheme")
    private static let trashItemID = NSToolbarItem.Identifier("openTrash")
    private static let stackItemID = NSToolbarItem.Identifier("openDropStack")
    private var dropStackObserver: NSObjectProtocol?
    private var dropStackThemeObserver: NSObjectProtocol?
    private static let flexibleSpaceID = NSToolbarItem.Identifier.flexibleSpace
    /// Черта между кнопками. У каждой своё имя: панель не пускает в себя два пункта
    /// с одинаковым именем.
    private static let separatorPrefix = "buttonSeparator"

    private static func separatorID(_ index: Int) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("\(separatorPrefix)\(index)")
    }

    // MARK: - State
    private(set) var showHiddenFiles: Bool
    private var terminalWindowController: NSWindowController?
    private var viewerWindowController: NSWindowController?
    private var terminalKeyMonitor: Any?

    // Quick Look (system QLPreviewPanel) — single-item data source bound to
    // the active panel's cursor. Arrow keys are forwarded to the file
    // manager so the cursor moves there, and the QL refreshes to the new file.
    private var quickLookCurrentURL: URL?
    private var quickLookViewModel: PanelViewModel?
    private var quickLookCursorObserver: AnyCancellable?

    // MARK: - Init

    init(leftInitialPath: String, rightInitialPath: String, showHiddenFiles: Bool) {
        self.showHiddenFiles = showHiddenFiles

        let bridgeService = CoreBridgeService()
        let fileOps = FileOperationsService(bridgeService: bridgeService)
        self.operationsService = fileOps
        // Внешнее управление работает той же службой, а не своей копией.
        ControlServer.shared.operationsService = fileOps
        let qs = OperationQueueService(fileOps: fileOps)
        self.queueService = qs
        let qvm = OperationQueueViewModel(queueService: qs)
        self.queueVM = qvm
        self.queuePanelController = OperationQueuePanelController(viewModel: qvm)

        let leftVM = PanelViewModel(
            service: bridgeService,
            initialPath: leftInitialPath,
            pathDefaultsKey: "leftPanelPath",
            viewModeDefaultsKey: "leftViewMode",
            showHiddenFiles: showHiddenFiles
        )
        let rightVM = PanelViewModel(
            service: bridgeService,
            initialPath: rightInitialPath,
            pathDefaultsKey: "rightPanelPath",
            viewModeDefaultsKey: "rightViewMode",
            showHiddenFiles: showHiddenFiles
        )

        let leftTabsVM = PanelTabsViewModel(panelKey: "left", initialPath: leftInitialPath)
        let rightTabsVM = PanelTabsViewModel(panelKey: "right", initialPath: rightInitialPath)

        splitVC = MainSplitViewController(
            leftPanel: leftVM, rightPanel: rightVM,
            leftTabs: leftTabsVM, rightTabs: rightTabsVM
        )

        // Window
        let contentRect = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        // ARC owns this window (a strong reference is kept) — without this flag
        // close() ALSO releases it and the second release crashes (SearchWindow bug).
        window.isReleasedWhenClosed = false
        // The bundle's own name, so the fresh copy (launch.sh --fresh) says who it is.
        let productName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "Totum Commander"
        window.title = AppIdentity.windowTitle(product: productName, version: AppIdentity.version,
                                               build: APP_BUILD, showsBuild: AppIdentity.showsBuildInTitle)
        window.minSize = NSSize(width: 980, height: 640)
        window.setFrameAutosaveName("MainWindowFrame")
        // Из автосохранения берётся только РАЗМЕР; место — всегда середина экрана. Место
        // с прошлого разрешения или отстёгнутого монитора система молча втискивала в
        // левый нижний угол, и окно каждый раз открывалось не там, где его ждут.
        Self.placeAtLaunch(window)
        // NO .moveToActiveSpace on the MAIN window, and that is a lesson learned twice over.
        // The flag was here so that ACTIVATING the app brought the window to the current
        // desktop — but a window with this flag moves whenever it is ordered front, and the
        // Space-switch observer below orders it front on every arrival. Net effect: the window
        // FOLLOWED the user across desktops — leave the desktop, and the window quietly came
        // along; come back, and it is not there any more, some other program is, and this one
        // reads as "fallen to the bottom". A document window belongs to its desktop; macOS
        // itself restores the front app per Space when the window stays put. The transient
        // windows (settings, dialogs, palette, queue) keep the flag — a panel SHOULD come to
        // wherever the user is looking.
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unifiedCompact

        super.init(window: window)

        // Use a container VC as content view controller
        let containerVC = MainContainerViewController(
            splitVC: splitVC,
            footerBar: FooterBar(
                onRename: { [weak self] in self?.handleRename() },
                onView: { [weak self] in self?.handleView() },
                onEdit: { [weak self] in self?.handleEdit() },
                onCopy: { [weak self] in self?.handleCopy() },
                onMove: { [weak self] in self?.handleMove() },
                onMkdir: { [weak self] in self?.handleMkdir() },
                onDelete: { [weak self] in self?.handleDelete() },
                onSearch: { [weak self] in self?.handleSearch() },
                onTerminal: { [weak self] in self?.handleTerminal() },
                onTerminalBottom: { [weak self] in self?.handleTerminalBottom() },
                onTerminalActive: { [weak self] in self?.handleTerminalActive() },
                onTerminalLeft: { [weak self] in self?.handleTerminalInPanel(.left) },
                onTerminalRight: { [weak self] in self?.handleTerminalInPanel(.right) }
            )
        )
        // Operation queue in center divider — MUST be set BEFORE contentViewController
        // because setting contentViewController triggers viewDidLoad → makeDividerRootView()
        splitVC.queueVM = queueVM
        splitVC.onShowQueuePanel = { [weak self] in
            self?.queuePanelController.toggle()
        }

        window.contentViewController = containerVC

        // The control socket answers questions about what the panels show; it can only do that
        // if someone tells it. Off unless the user turned it on — see ControlServer.
        ControlServer.shared.stateProvider = { [weak splitVC] in
            guard let splitVC else { return [:] }
            let left = splitVC.leftPanelVM
            let right = splitVC.rightPanelVM
            return [
                "active panel": splitVC.activePanel == .left ? "left" : "right",
                "left folder": left.currentPath,
                "left cursor": left.cursorItem?.name ?? "(none)",
                "left selected": String(left.selectedPaths.count),
                "left items": String(left.items.count),
                "right folder": right.currentPath,
                "right cursor": right.cursorItem?.name ?? "(none)",
                "right selected": String(right.selectedPaths.count),
                "right items": String(right.items.count),
            ]
        }
        ControlServer.shared.syncWithSetting()

        // The number on the shelf button follows the shelf itself, wherever it was changed —
        // a context menu in either panel, another window, the shelf listing. One road, so no
        // caller can forget to repaint it.
        dropStackObserver = NotificationCenter.default.addObserver(
            forName: .fcxlDropStackChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDropStackButton() }
        }
        // The theme decides both colours, so the badge is redrawn when it changes.
        dropStackThemeObserver = NotificationCenter.default.addObserver(
            forName: .fcxlAppearanceChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDropStackButton() }
        }
        // And once at startup: the shelf outlives the program, so it may already hold things.
        DispatchQueue.main.async { [weak self] in self?.refreshDropStackButton() }

        // Context menu delegate
        splitVC.panelActionDelegate = self

        // Center divider action callbacks
        splitVC.onDividerCopy = { [weak self] in self?.handleCopy() }
        splitVC.onDividerMove = { [weak self] in self?.handleMove() }
        splitVC.onDividerDelete = { [weak self] in self?.handleDelete() }
        splitVC.onDividerMkdir = { [weak self] in self?.handleMkdir() }
        splitVC.onDividerView = { [weak self] in self?.handleView() }
        splitVC.onDividerEdit = { [weak self] in self?.handleEdit() }
        splitVC.onDividerNetwork = { [weak self] in self?.handleNetwork()
        }

        // Viewer handler — connects F3 / Space to actual viewer opening
        operationsService.viewerOpenHandler = { [weak self] item in
            self?.openViewerForItem(item)
        }

        // Toolbar
        applyToolbarLook()
        // Вид панели меняется в настройках и должен становиться виден сразу, а не с
        // перезапуском: панель пересобирается целиком — набор пунктов у неё тоже другой.
        NotificationCenter.default.addObserver(
            forName: .fcxlToolbarLookChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyToolbarLook() }
        }

        NotificationCenter.default.addObserver(
            forName: .fcxlUpdateAvailabilityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSettingsButton() }
        }

        // Interface tint (per-theme) on the window chrome; re-apply when the theme or
        // the chosen interface colour changes.
        applyInterfaceBackground()
        NotificationCenter.default.addObserver(
            forName: .fcxlAppearanceChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyInterfaceBackground()
        }

        // Cmd+` — toggle terminal (local monitor intercepts before macOS window cycling)
        // Close network mount tabs when volume is unmounted (from Finder or diskutil).
        // Volume mount/unmount events are posted on NSWorkspace's OWN notification
        // center, not NotificationCenter.default — listening on the wrong one
        // means the observer never fires (e.g. the other panel's disk list not
        // refreshing after an eject).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            else { return }
            let volumePath = volumeURL.path
            let leftClosed = self.splitVC.leftTabsVM.closeTabsOnVolume(volumePath)
            let rightClosed = self.splitVC.rightTabsVM.closeTabsOnVolume(volumePath)
            if leftClosed {
                self.splitVC.leftPanelVM.loadDirectory(at: self.splitVC.leftTabsVM.activeTab.path)
            }
            if rightClosed {
                self.splitVC.rightPanelVM.loadDirectory(at: self.splitVC.rightTabsVM.activeTab.path)
            }
        }

        // Arriving back at the desktop this window lives on must put it in front. macOS picks
        // which app to front on a Space switch, and a window carrying .moveToActiveSpace does not
        // count as belonging to that desktop — so anything else open there won the z-order and
        // covered us. Nothing else brings the window back, so ask for it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reclaimFocusOnArrival()
        }

        terminalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 50,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  self?.window?.isKeyWindow == true else { return event }
            self?.handleTerminal()
            return nil  // consume event — don't let macOS cycle windows
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// Собрать панель инструментов заново — по нынешнему выбору человека.
    func applyToolbarLook() {
        guard let window else { return }
        let look = ToolbarLook.chosen
        let toolbar = NSToolbar(identifier: Self.toolbarID)
        toolbar.delegate = self
        toolbar.displayMode = look.displayMode
        toolbar.allowsUserCustomization = false
        // Стиль окна — вместе с видом панели: в узкой полосе заголовка подписей не бывает.
        window.toolbarStyle = look.windowStyle
        window.toolbar = toolbar
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let item = makeToolbarItem(itemIdentifier) else { return nil }
        dress(item, look: ToolbarLook.chosen)
        return item
    }

    /// Кнопка панели: значок и подпись в одну строку, подпись справа — одна большая кнопка,
    /// а не значок с подписью под ним; без подписей — один значок. Своё вью у пункта всегда,
    /// потому что только вью можно перекрасить под тёмный фон заголовка — см. dress.
    static func toolbarButton(label: String, image: NSImage?, look: ToolbarLook) -> NSButton {
        let button = NSButton(title: label, target: nil, action: nil)
        button.bezelStyle = .toolbar
        // The frame only under the mouse, as a toolbar item draws it — always on, it outlined
        // every button like a form control.
        button.showsBorderOnlyWhileMouseInside = true
        button.font = .systemFont(ofSize: 12)
        if look.showsIcon, let image {
            button.image = image
            button.imagePosition = look.showsLabel ? .imageLeading : .imageOnly
            button.imageScaling = .scaleProportionallyDown
        } else {
            button.imagePosition = .noImage
        }
        button.sizeToFit()
        return button
    }

    /// Одеть пункт по выбранному виду: пункт получает свою кнопку, она же становится целью
    /// нажатия — и несёт облик, который читается на нынешнем цвете заголовка.
    private func dress(_ item: NSToolbarItem, look: ToolbarLook) {
        // A line between buttons has its view already; it takes the appearance all the same —
        // a dark line on a dark titlebar is no line at all.
        guard item.view == nil else { item.view?.appearance = toolbarAppearance; return }
        let button = Self.toolbarButton(label: item.label, image: item.image, look: look)
        button.target = item.target
        button.action = item.action
        button.toolTip = item.toolTip
        button.appearance = toolbarAppearance
        item.view = button
    }

    /// Облик кнопок панели под цвет заголовка: на тёмном заголовке — тёмный, чтобы подписи и
    /// значки стали светлыми; nil — цвет не задан, кнопки следуют окну.
    private var toolbarAppearance: NSAppearance?

    /// Картинка пункта — и в самом пункте, и в его кнопке с подписью, если она есть.
    private static func setImage(_ image: NSImage?, on item: NSToolbarItem) {
        item.image = image
        if let button = item.view as? NSButton, ToolbarLook.chosen.showsIcon {
            button.image = image
        }
    }

    private func makeToolbarItem(_ itemIdentifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        if itemIdentifier.rawValue.hasPrefix(Self.separatorPrefix) {
            return Self.groupSeparatorItem(itemIdentifier)
        }
        switch itemIdentifier {
        case Self.hiddenFilesItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L("toolbar.label.hidden")
            item.toolTip = L("hidden.help")
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleHiddenFiles(_:))
            item.image = NSImage(systemSymbolName: showHiddenFiles ? "eye.fill" : "eye.slash",
                                 accessibilityDescription: nil)
            return item

        case Self.settingsItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L("toolbar.label.settings")
            item.toolTip = L("settings.title")
            item.isBordered = true
            item.target = NSApp.delegate
            item.action = #selector(AppDelegate.showSettingsWindow(_:))
            item.image = Self.settingsSymbol(updateAvailable: UpdateChecker.shared.available != nil,
                                             appearance: window?.effectiveAppearance)
            if let release = UpdateChecker.shared.available {
                item.toolTip = String(format: L("settings.updates.badgeTip"), release.version)
            }
            return item

        case Self.diskInfoItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L("toolbar.label.disks")
            item.toolTip = L("diskinfo.title")
            item.isBordered = true
            item.target = self
            item.action = #selector(showDiskInfo(_:))
            // NOT a bare "info.circle": alone it reads as "help/about", and the button shows
            // DISK properties. No stock symbol combines the two, so a drive glyph carries a
            // small info badge, punched out the way system badges are.
            item.image = Self.diskInfoSymbol()
            return item

        case Self.trashItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L("toolbar.label.trash")
            item.toolTip = L("trash.title")
            item.isBordered = true
            item.target = self
            item.action = #selector(openTrash(_:))
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            return item

        case Self.stackItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L("toolbar.label.stack")
            item.toolTip = L("stack.tooltip")
            item.isBordered = true
            item.target = self
            item.action = #selector(openDropStack(_:))
            item.image = Self.dropStackSymbol(count: DropStackStore.count,
                                              appearance: window?.effectiveAppearance)
            return item

        case Self.monitorItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L("toolbar.label.monitor")
            item.toolTip = L("monitor.toggle")
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleMonitor(_:))
            item.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
            return item

        case Self.themeItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L("toolbar.label.theme")
            item.toolTip = L("settings.appearance.toggleTooltip")
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleTheme(_:))
            item.image = themeToolbarImage()
            return item

        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.flexibleSpaceID] + Self.toolbarItemOrder(separators: ToolbarLook.showsSeparators)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarItemOrder(separators: true) + [Self.flexibleSpaceID]
    }

    /// Кнопки панели: полка, корзина, монитор, диски, тема, скрытые файлы, настройки —
    /// и черта между каждыми двумя, когда человек их попросил.
    static func toolbarItemOrder(separators: Bool) -> [NSToolbarItem.Identifier] {
        let buttons = [stackItemID, trashItemID, monitorItemID, diskInfoItemID,
                       themeItemID, hiddenFilesItemID, settingsItemID]
        guard separators else { return buttons }
        var result: [NSToolbarItem.Identifier] = []
        for (index, button) in buttons.enumerated() {
            if index > 0 { result.append(separatorID(index)) }
            result.append(button)
        }
        return result
    }

    /// Черта между группами — в стиле программы: тонкая линия системного цвета разделителя,
    /// которая сама темнеет и светлеет вместе с темой.
    private static func groupSeparatorItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        // Подпись пустая нарочно: под чертой подписывать нечего, а место под строку
        // панель отводит всем одинаково — иначе кнопки рядом поехали бы вверх.
        item.label = ""
        item.paletteLabel = ""
        let container = separatorView()
        item.view = container
        item.minSize = container.frame.size
        item.maxSize = container.frame.size
        return item
    }

    /// The line itself: the system separator colour, which lightens and darkens with the
    /// appearance the view is given.
    static func separatorView() -> NSView {
        let size = NSSize(width: 11, height: 24)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let line = NSBox(frame: NSRect(x: 5, y: 3, width: 1, height: size.height - 6))
        line.boxType = .separator
        line.autoresizingMask = [.minXMargin, .maxXMargin, .height]
        container.addSubview(line)
        return container
    }

    // MARK: - App Lifecycle (FSWatcher pause/resume)

    func pauseFSWatchers() {
        splitVC.leftPanelVM.pauseFSWatcher()
        splitVC.rightPanelVM.pauseFSWatcher()
    }

    func resumeFSWatchers() {
        splitVC.leftPanelVM.resumeFSWatcher()
        splitVC.rightPanelVM.resumeFSWatcher()
    }

    func stopWatchersForVolume(_ volumePath: String) {
        splitVC.leftPanelVM.stopWatcherIfOnVolume(volumePath)
        splitVC.rightPanelVM.stopWatcherIfOnVolume(volumePath)
    }

    /// True when a remote session can be worked with right now. Otherwise tells the user WHY
    /// (still connecting / never connected / connection lost) and returns false, so an
    /// operation is refused up front instead of firing at a socket that isn't there.
    @discardableResult
    private func remoteSessionIsReady(_ session: RemoteSession?) -> Bool {
        guard let session else {
            DialogService.shared.showError(title: L("network.manager"),
                                           message: L("network.error.notConnected"))
            return false
        }
        guard let reason = session.notReadyReason else { return true }
        DialogService.shared.showError(title: L("network.manager"), message: reason)
        return false
    }

    func prepareForVolumeEject(_ volumePath: String) {
        splitVC.leftPanelVM.prepareForVolumeEject(volumePath)
        splitVC.rightPanelVM.prepareForVolumeEject(volumePath)

        // Close tabs that are on the ejected volume
        let leftClosed = splitVC.leftTabsVM.closeTabsOnVolume(volumePath)
        let rightClosed = splitVC.rightTabsVM.closeTabsOnVolume(volumePath)

        // Reload panels if their active tab was closed
        if leftClosed {
            splitVC.leftPanelVM.loadDirectory(at: splitVC.leftTabsVM.activeTab.path)
        }
        if rightClosed {
            splitVC.rightPanelVM.loadDirectory(at: splitVC.rightTabsVM.activeTab.path)
        }
    }

    /// Titles of active (queued/running/paused) queue operations whose source, destination, or
    /// remote local path is on the given volume — used to warn before ejecting it (a force
    /// unmount mid-write corrupts the file being written).
    func activeOperationTitles(onVolume volumeRoot: String) -> [String] {
        let prefix = volumeRoot.hasSuffix("/") ? volumeRoot : volumeRoot + "/"
        func onVolume(_ p: String?) -> Bool {
            guard let p = p else { return false }
            return p == volumeRoot || p.hasPrefix(prefix)
        }
        return queueService.operations
            .filter(\.isActive)
            .filter { op in
                onVolume(op.destinationPath)
                    || onVolume(op.remoteParams?.localPath)
                    || op.items.contains { onVolume($0.path) }
            }
            .map(\.displayTitle)
    }

    /// Paths of unsaved editor documents (standalone windows + the embedded editor) whose file
    /// lives on the given volume — used to warn before ejecting so an edit isn't silently orphaned.
    func unsavedEditorPaths(onVolume volumeRoot: String) -> [String] {
        var paths = EditorWindowManager.shared.dirtyDocumentPaths(onVolume: volumeRoot)
        if let embedded = splitVC.dirtyEmbeddedEditorPath(onVolume: volumeRoot) {
            paths.append(embedded)
        }
        return paths
    }

    // MARK: - Toolbar Actions

    @objc func toggleHiddenFiles(_ sender: Any?) {
        showHiddenFiles.toggle()
        UserDefaults.standard.set(showHiddenFiles, forKey: "showHiddenFiles")
        splitVC.setShowHiddenFiles(showHiddenFiles)

        if let toolbar = window?.toolbar,
           let item = toolbar.items.first(where: { $0.itemIdentifier == Self.hiddenFilesItemID }) {
            Self.setImage(NSImage(systemSymbolName: showHiddenFiles ? "eye.fill" : "eye.slash",
                                  accessibilityDescription: nil), on: item)
        }
    }

    /// Quick light/dark toggle. The full 3-way choice (incl. "follow system") lives in
    /// Settings → Colors; both read the same `appearanceMode` key, so they stay in sync.
    @objc func toggleTheme(_ sender: Any?) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let newMode = isDark ? 1 : 2   // currently dark → light (1); currently light → dark (2)
        UserDefaults.standard.set(newMode, forKey: PanelAppearanceSettings.appearanceModeKey)
        PanelAppearanceSettings.applyAppearanceMode()
        setThemeIcon(dark: newMode == 2)
    }

    private func themeToolbarImage() -> NSImage? {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSImage(systemSymbolName: isDark ? "moon.fill" : "sun.max.fill",
                       accessibilityDescription: nil)
    }

    /// Tints the window (titlebar gaps + background) with the per-theme interface colour.
    private func applyInterfaceBackground() {
        guard let window else { return }
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = PanelAppearanceSettings.interfaceColorKey(dark: dark)
        let hasCustom = !(UserDefaults.standard.string(forKey: key) ?? "").isEmpty
        // The window background is visible only in the (transparent) titlebar strip —
        // everything below is covered by the panels' own backgrounds. So a dedicated
        // titlebar colour simply takes over the window background; otherwise the
        // interface tint (or the stock titlebar) shows as before.
        let titlebarColor = PanelAppearanceSettings.titlebarNSColor(dark: dark)
        if let titlebarColor {
            window.backgroundColor = titlebarColor
            window.titlebarAppearsTransparent = true
        } else {
            window.backgroundColor = PanelAppearanceSettings.interfaceNSColor(dark: dark)
            // Blend the titlebar into the tint only when a custom colour is set;
            // otherwise leave the default system titlebar untouched.
            window.titlebarAppearsTransparent = hasCustom
        }
        // The toolbar reads on whatever colour the titlebar got: a dark colour under the
        // light theme turned its labels and icons black on slate. The buttons take the
        // appearance that contrasts with that colour — every one of them, and the lines
        // between them, now and whenever the colour changes.
        let onTitlebar = titlebarColor ?? (hasCustom ? window.backgroundColor : nil)
        toolbarAppearance = ContrastAppearance.appearance(on: onTitlebar)
        window.toolbar?.items.forEach { $0.view?.appearance = toolbarAppearance }
        // The window's NAME too: the titlebar draws it, so the titlebar takes the same
        // appearance — the whole strip reads on its colour, name and buttons alike.
        Self.titlebarView(of: window)?.appearance = toolbarAppearance
    }

    /// The strip that draws the window's name and holds the toolbar — reached through the
    /// close button, which lives in it. nil for a window without one.
    static func titlebarView(of window: NSWindow) -> NSView? {
        window.standardWindowButton(.closeButton)?.superview
    }

    private func setThemeIcon(dark: Bool) {
        guard let toolbar = window?.toolbar,
              let item = toolbar.items.first(where: { $0.itemIdentifier == Self.themeItemID })
        else { return }
        Self.setImage(NSImage(systemSymbolName: dark ? "moon.fill" : "sun.max.fill",
                              accessibilityDescription: nil), on: item)
    }

    /// A drive glyph with an ⓘ badge at its lower-right — "properties of the DISK", not "help".
    /// Composed because SF Symbols has drive badges for plus/minus/checkmark and friends, but
    /// none for info. A template image, so it follows the toolbar tint in both appearances.
    static func diskInfoSymbol() -> NSImage {
        let fallback = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)!
        guard let base = NSImage(systemSymbolName: "internaldrive",
                                 accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)),
              let badge = NSImage(systemSymbolName: "info.circle.fill",
                                  accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        else { return fallback }

        let baseSize = base.size
        let badgeSize = badge.size
        // The badge hangs a third past the drive's corner, like every system badge does.
        let canvas = NSSize(width: baseSize.width + badgeSize.width * 0.35,
                            height: baseSize.height + badgeSize.height * 0.35)
        let image = NSImage(size: canvas)
        image.lockFocus()
        base.draw(in: NSRect(x: 0, y: canvas.height - baseSize.height,
                             width: baseSize.width, height: baseSize.height),
                  from: .zero, operation: .sourceOver, fraction: 1)
        // Punch a hole first: in a template image only alpha exists, and without the gap the
        // badge would melt into the drive outline instead of sitting on top of it.
        let badgeRect = NSRect(x: canvas.width - badgeSize.width, y: 0,
                               width: badgeSize.width, height: badgeSize.height)
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.5, dy: -1.5)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        badge.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    @objc func showDiskInfo(_ sender: Any?) {
        // Toolbar actions run as main-QUEUE blocks; open the modal on a runloop callout so the
        // dialog's own button paints immediately (same pattern as the other FCXL dialogs).
        fcxlPresentModal {
            _ = FCXLDialog.runModal(size: NSSize(width: 470, height: 480)) { (session: FCXLDialogSession<Bool>) in
                DiskInfoView(session: session)
            }
        }
    }

    /// Open the Trash in the ACTIVE panel. Its path is the virtual /TRASH, so the ordinary
    /// loadDirectory routing does the rest — the same road the drive bar's button used to take.
    /// Open the shelf in the active panel, or leave it if it is already showing — the same
    /// two-way behaviour the Trash button has.
    @objc func openDropStack(_ sender: Any?) {
        let vm = splitVC.activePanelViewModel
        if vm.state.insideStack || DropStackStore.isStackPath(vm.currentPath) {
            vm.goUp()
            return
        }
        vm.loadDirectory(at: DropStackStore.stackRoot)
    }

    /// Put the selection (or the file under the cursor) on the shelf, and say what happened:
    /// silence after a command that looks like it copied something is its own kind of lie.
    func addSelectionToDropStack() {
        let vm = splitVC.activePanelViewModel
        let chosen = vm.selectedPaths.isEmpty
            ? [vm.cursorItem?.path].compactMap { $0 }
            : Array(vm.selectedPaths)
        let usable = chosen.filter { ($0 as NSString).lastPathComponent != ".." }
        guard !usable.isEmpty else { return }
        // The badge on the toolbar button is the feedback: it moves the moment something
        // lands (through .fcxlDropStackChanged) and keeps saying how full the shelf is,
        // instead of a message that flashes once and is gone.
        DropStackStore.add(usable)
    }

    /// Take the selection off the shelf. Only meaningful while the shelf is what the panel shows.
    func removeSelectionFromDropStack() {
        let vm = splitVC.activePanelViewModel
        guard vm.state.insideStack else { return }
        let chosen = vm.selectedPaths.isEmpty
            ? [vm.cursorItem?.path].compactMap { $0 }
            : Array(vm.selectedPaths)
        guard !chosen.isEmpty else { return }
        DropStackStore.remove(chosen)
        vm.loadStackDirectory()
    }

    /// Keep the number on the shelf button honest.
    func refreshDropStackButton() {
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.stackItemID })
        else { return }
        let count = DropStackStore.count
        Self.setImage(Self.dropStackSymbol(count: count, appearance: window?.effectiveAppearance), on: item)
        item.toolTip = count > 0 ? "\(L("stack.title")) (\(count))" : L("stack.tooltip")
        item.view?.toolTip = item.toolTip
    }

    /// A tray, and — when the shelf holds anything — how many, in a pill of the app's own
    /// accent colour.
    ///
    /// Two things have to be right for it to look like the rest of the toolbar. The count must
    /// be DRAWN, because the toolbar shows icons only and a number in the item's label is a
    /// number nobody sees. And the colours must be resolved in the WINDOW's appearance: drawn
    /// outside it they resolve against the light theme, which is why the tray came out nearly
    /// black on a dark toolbar instead of the quiet grey every other button has.
    static func dropStackSymbol(count: Int, appearance: NSAppearance? = nil) -> NSImage {
        let tray = NSImage(systemSymbolName: "tray.full", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            ?? NSImage(systemSymbolName: "tray", accessibilityDescription: nil)!
        guard count > 0 else { return tray }

        let text = count > 99 ? "99+" : String(count)
        let font = NSFont.systemFont(ofSize: 8, weight: .bold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let badgeHeight: CGFloat = 12
        let badgeWidth = max(badgeHeight, textSize.width + 7)
        let base = tray.size
        let canvas = NSSize(width: base.width + badgeWidth * 0.45,
                            height: base.height + badgeHeight * 0.35)

        let draw = {
            let image = NSImage(size: canvas)
            image.lockFocus()
            // The tray is a template symbol; the finished image cannot stay one, or the badge
            // would lose its colour with it — so the tray is tinted by hand, in the same
            // secondary grey the other toolbar glyphs read as.
            let trayRect = NSRect(x: 0, y: 0, width: base.width, height: base.height)
            tray.draw(in: trayRect, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.secondaryLabelColor.set()
            // sourceIn, not sourceAtop: the grey is semi-transparent, and painting it OVER the
            // symbol left the symbol's own black showing through — the tray came out heavier
            // and darker than every button beside it. sourceIn replaces the colour outright,
            // keeping only the glyph's shape, which is exactly what the system does to a
            // template image.
            trayRect.fill(using: .sourceIn)

            let badgeRect = NSRect(x: canvas.width - badgeWidth, y: canvas.height - badgeHeight,
                                   width: badgeWidth, height: badgeHeight)
            PanelAppearanceSettings.accentNSColor.setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: badgeHeight / 2,
                         yRadius: badgeHeight / 2).fill()
            (text as NSString).draw(
                at: NSPoint(x: badgeRect.midX - textSize.width / 2,
                            y: badgeRect.midY - textSize.height / 2),
                withAttributes: [
                    .font: font,
                    .foregroundColor: PanelAppearanceSettings.contrastingTextColor(
                        on: PanelAppearanceSettings.accentNSColor),
                ])
            image.unlockFocus()
            image.isTemplate = false
            return image
        }
        guard let appearance else { return draw() }
        var result = NSImage()
        appearance.performAsCurrentDrawingAppearance { result = draw() }
        return result
    }

    /// The Settings gear — with a dot at its corner while a newer release is known, the same
    /// accent the shelf's counter wears. A dot, not a number: there is nothing to count.
    static func settingsSymbol(updateAvailable: Bool, appearance: NSAppearance? = nil) -> NSImage {
        let gear = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)!
        guard updateAvailable else { return gear }
        let base = gear.size
        let dot: CGFloat = 7
        let canvas = NSSize(width: base.width + dot * 0.4, height: base.height + dot * 0.4)
        let draw = {
            let image = NSImage(size: canvas)
            image.lockFocus()
            let gearRect = NSRect(x: 0, y: 0, width: base.width, height: base.height)
            gear.draw(in: gearRect, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.secondaryLabelColor.set()
            gearRect.fill(using: .sourceIn)
            PanelAppearanceSettings.accentNSColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: canvas.width - dot, y: canvas.height - dot,
                                        width: dot, height: dot)).fill()
            image.unlockFocus()
            image.isTemplate = false
            return image
        }
        guard let appearance else { return draw() }
        var result = NSImage()
        appearance.performAsCurrentDrawingAppearance { result = draw() }
        return result
    }

    /// Redraw the gear when a check changes what is known.
    func refreshSettingsButton() {
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.settingsItemID })
        else { return }
        let release = UpdateChecker.shared.available
        Self.setImage(Self.settingsSymbol(updateAvailable: release != nil,
                                          appearance: window?.effectiveAppearance), on: item)
        item.toolTip = release.map { String(format: L("settings.updates.badgeTip"), $0.version) }
            ?? L("settings.title")
        item.view?.toolTip = item.toolTip
    }

    /// Uninstall a program: find what it left, show the list, and put what was ticked in the
    /// Trash. The Trash and not oblivion — a guess about which folder belongs to which program
    /// has to be undoable.
    func uninstallApplication(at appPath: String) {
        let name = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let bundleID = AppUninstaller.programBundle(at: appPath)
            .flatMap { Bundle(path: $0)?.bundleIdentifier }

        // The window opens FIRST and searches with its own spinner. Finding the leftovers of a
        // five-gigabyte program takes seconds, and doing it before opening made the delete key
        // look like a freeze.
        fcxlPresentModal { [weak self] in
            guard let chosen = DialogService.shared.showUninstallDialog(
                appPath: appPath, appName: name, bundleID: bundleID), !chosen.isEmpty else { return }
            self?.trashUninstallPaths(chosen, appName: name)
        }
    }

    /// Two roads to the same Trash. What lies in the person's own Library goes the ordinary
    /// way, with the app's progress and undo. What lies in /Library cannot be trashed by a
    /// user, so it is moved by an elevated `mv` — macOS asks for the password itself, and the
    /// files still land in the Trash rather than disappearing.
    private func trashUninstallPaths(_ paths: [String], appName: String) {
        let mine = paths.filter { AppUninstaller.isRemovableByUser($0) }
        let theirs = paths.filter { !AppUninstaller.isRemovableByUser($0) }
        let items = mine.compactMap { FileItem.fromPath($0) }
        let ops = splitVC.activePanelViewModel.operationsService

        Task { @MainActor in
            do {
                if !items.isEmpty { try await ops.trashItems(items) }
                if !theirs.isEmpty {
                    try await Task.detached(priority: .userInitiated) {
                        try AppUninstaller.trashWithAdministrator(theirs)
                    }.value
                }
                splitVC.leftPanelVM.reloadKeepingCursor()
                splitVC.rightPanelVM.reloadKeepingCursor()
            } catch {
                DialogService.shared.showOperationError(
                    title: String(format: L("uninstall.title"), appName), error: error)
            }
        }
    }

    @objc func openTrash(_ sender: Any?) {
        let vm = splitVC.activePanelViewModel
        // A second press goes back where the panel stood — through goUp, the same road ".."
        // takes out of the Trash, so the return path is remembered in exactly one place.
        if vm.state.insideTrash || TrashService.isTrashPath(vm.currentPath) {
            vm.goUp()
            return
        }
        vm.loadDirectory(at: TrashService.trashRoot)
    }

    /// What the toolbar's Trash button does, as a plain function the tests can call: the button
    /// itself needs a whole window to exist.
    static func trashDestination() -> String { TrashService.trashRoot }

    // MARK: - Selection by mask

    /// Total Commander's Num+ — pick a mask, everything matching it joins the selection. The
    /// mask is the SAME one the quick filter understands, so a pattern that narrowed the list
    /// can be reused here to select what it showed.
    @objc func handleSelectByMask(_ sender: Any?) {
        let vm = splitVC.activePanelViewModel
        fcxlPresentModal {
            guard let mask = MaskSelectionDialog.run(deselecting: false) else { return }
            vm.selectByMask(mask)
        }
    }

    /// Num− — the same, taking names OUT of the selection.
    @objc func handleDeselectByMask(_ sender: Any?) {
        let vm = splitVC.activePanelViewModel
        fcxlPresentModal {
            guard let mask = MaskSelectionDialog.run(deselecting: true) else { return }
            vm.deselectByMask(mask)
        }
    }

    /// Num* — everything selected becomes unselected and the other way round.
    @objc func handleInvertSelection(_ sender: Any?) {
        splitVC.activePanelViewModel.invertSelection()
    }

    /// Select every file sharing the cursor's extension — the everyday case a mask is usually
    /// typed for.
    @objc func handleSelectSameType(_ sender: Any?) {
        splitVC.activePanelViewModel.selectSameType()
    }

    /// Toggle the live system monitor in the ACTIVE panel (in place of its file list).
    @objc func toggleMonitor(_ sender: Any?) {
        // Routed through the split controller so the monitor stays unique: opening it in the
        // active panel closes any monitor showing in the other one.
        splitVC.toggleMonitorInActivePanel()
    }

    // MARK: - Footer Actions

    func handleRename() {
        splitVC.activePanelVC.startInlineRename()
    }

    /// Open the Multi-Rename tool on a panel's selection (or the cursor file). The menu routes to
    /// the active panel; the context menu passes its own panel. Follows the "selection else cursor,
    /// minus .." convention via PanelViewModel.operationTargets.
    // MARK: - Undo of file operations

    /// The text field being edited keeps its own Cmd+Z: a rename box mid-edit undoes TYPING,
    /// not the last file operation. Only when no text has the keyboard does the journal answer.
    private func editingUndoManager() -> UndoManager? {
        guard let responder = window?.firstResponder as? NSTextView,
              let manager = responder.undoManager else { return nil }
        return manager
    }

    @objc func handleUndoFileOperation(_ sender: Any?) {
        if let manager = editingUndoManager(), manager.canUndo { manager.undo(); return }
        let ops = operationsService
        let operation = UndoJournal.shared.undoDescription
        Task { @MainActor in
            do {
                try await UndoJournal.shared.undo { record in
                    try await ops.performUndo(of: record)
                }
            } catch {
                Self.explainUndoFailure(error, operation: operation, redo: false)
            }
            refreshBothPanels()
        }
    }

    @objc func handleRedoFileOperation(_ sender: Any?) {
        if let manager = editingUndoManager(), manager.canRedo { manager.redo(); return }
        let ops = operationsService
        let operation = UndoJournal.shared.redoDescription
        Task { @MainActor in
            do {
                var replacement: UndoJournal.Record?
                try await UndoJournal.shared.redo { record in
                    replacement = try await ops.performRedo(of: record)
                }
                // A re-trashed file lives under a NEW url in the bin; the record that just went
                // back onto the undo stack has to carry it or the next undo looks in the wrong
                // place.
                if let replacement { UndoJournal.shared.replaceNewestUndo(with: replacement) }
            } catch {
                Self.explainUndoFailure(error, operation: operation, redo: true)
            }
            refreshBothPanels()
        }
    }

    /// The failed walk-back, explained in full: WHICH operation would not come back, what
    /// exactly stood in the way of each file (with the places named), and — the part that
    /// spares the panic — that the undo itself survived and retries once the obstacle is gone.
    /// A bare "имя занято" answers none of the questions a person actually has at that moment.
    @MainActor
    static func explainUndoFailure(_ error: Error, operation: String?, redo: Bool) {
        // The service's own dialogs (a preflight refusal, say) have already spoken; a second
        // box repeating "cancelled" on top of them is noise, not explanation.
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.userCancelled.rawValue { return }

        var lines: [String] = []
        if let operation {
            lines.append(String(format: L(redo ? "undo.error.redoHeader" : "undo.error.header"),
                                operation))
        }
        lines.append(error.localizedDescription)
        lines.append("")
        lines.append(L("undo.retryHint"))
        DialogService.shared.showError(title: L(redo ? "undo.redoErrorTitle" : "undo.errorTitle"),
                                       message: lines.joined(separator: "\n"))
    }

    /// The hotlist, Cmd+D. The menu itself lives on the panel — the tab bar's star opens the
    /// same one — so the window controller only says WHICH panel: the active one, at the mouse.
    @objc func handleFavoriteFolders(_ sender: Any?) {
        splitVC.activePanelVC.showFavoriteFoldersMenu(at: NSEvent.mouseLocation)
    }

    /// Which two files to compare — the same rule Total Commander uses, and the one a person
    /// expects: two files picked in ONE panel, or otherwise the file under the cursor in each.
    ///
    /// Static and separate from the window so the rule can be read and tested on its own.
    static func filesToCompare(active: [FileItem], left: FileItem?, right: FileItem?)
        -> (String, String)? {
        let picked = active.filter { !$0.isDirectory && $0.name != ".." }
        if picked.count == 2 { return (picked[0].path, picked[1].path) }
        guard let left, let right, !left.isDirectory, !right.isDirectory,
              left.name != "..", right.name != "..", left.path != right.path else { return nil }
        return (left.path, right.path)
    }

    /// Show two files line against line.
    @objc func handleCompareFiles(_ sender: Any?) {
        guard let pair = comparablePair() else {
            DialogService.shared.showInfo(title: L("diff.title"), message: L("diff.needTwoFiles"))
            return
        }
        _ = FCXLDialog.runModal(size: NSSize(width: 1000, height: 700)) { session in
            FileDiffDialogView(session: session, leftPath: pair.0, rightPath: pair.1)
        }
    }

    /// The pair for the compare, if one is offered — from panels whose paths are real files on
    /// disk. Only the panels that CONTRIBUTE files have to be local: two files picked in one
    /// local panel compare fine while the other panel sits on FTP, since that panel is not in
    /// the conversation.
    private func comparablePair() -> (String, String)? {
        let active = splitVC.activePanelViewModel
        if isLocalPanel(active),
           let pair = Self.filesToCompare(active: active.selectedItems, left: nil, right: nil) {
            return pair
        }
        guard isLocalPanel(splitVC.leftPanelVM), isLocalPanel(splitVC.rightPanelVM) else {
            return nil
        }
        return Self.filesToCompare(active: [], left: splitVC.leftPanelVM.cursorItem,
                                   right: splitVC.rightPanelVM.cursorItem)
    }

    /// Compare the two panels' folders and optionally sync the chosen files.
    ///
    /// The copying goes through the ordinary FileOperationsService — same progress window, conflict
    /// dialog and queue as an F5 copy — rather than a second transfer path inside the compare tool.
    @objc func handleCompareDirectories(_ sender: Any?) {
        let leftVM = splitVC.leftPanelVC.viewModel
        let rightVM = splitVC.rightPanelVC.viewModel
        guard !leftVM.insideRemote, !rightVM.insideRemote else {
            DialogService.shared.showInfo(title: L("compare.title"), message: L("compare.localOnly"))
            return
        }
        let left = leftVM.currentPath, right = rightVM.currentPath
        guard left != right else {
            DialogService.shared.showInfo(title: L("compare.title"), message: L("compare.samePath"))
            return
        }

        let plan = FCXLDialog.runModal(size: NSSize(width: 900, height: 620)) { session in
            DirectoryCompareDialogView(session: session, leftRoot: left, rightRoot: right)
        }
        guard let plan, plan.total > 0 else { return }

        // Summarise before touching anything — the user has been flipping arrows per row, and this
        // is the last point where the whole operation can still be read at a glance.
        var lines: [String] = []
        if !plan.toRight.isEmpty {
            lines.append(String(format: L("compare.confirm.toRight"), plan.toRight.count,
                                (right as NSString).lastPathComponent))
        }
        if !plan.toLeft.isEmpty {
            lines.append(String(format: L("compare.confirm.toLeft"), plan.toLeft.count,
                                (left as NSString).lastPathComponent))
        }
        if !plan.moveRight.isEmpty {
            lines.append(String(format: L("compare.confirm.moveRight"), plan.moveRight.count,
                                (right as NSString).lastPathComponent))
        }
        if !plan.moveLeft.isEmpty {
            lines.append(String(format: L("compare.confirm.moveLeft"), plan.moveLeft.count,
                                (left as NSString).lastPathComponent))
        }
        // Deletions are spelled out separately and last, so they are the final thing read before
        // confirming — and the wording says Trash, because that is what actually happens.
        if !plan.deleteLeft.isEmpty {
            lines.append(String(format: L("compare.confirm.deleteLeft"), plan.deleteLeft.count,
                                (left as NSString).lastPathComponent))
        }
        if !plan.deleteRight.isEmpty {
            lines.append(String(format: L("compare.confirm.deleteRight"), plan.deleteRight.count,
                                (right as NSString).lastPathComponent))
        }
        if plan.deletions > 0 { lines.append(L("compare.confirm.trashNote")) }
        guard DialogService.shared.showConfirmationCustom(
            title: L("compare.confirm.title"),
            message: lines.joined(separator: "\n"),
            confirmTitle: L("compare.synchronize"),
            cancelTitle: L("button.cancel")) else { return }

        runSync(plan)
    }

    /// Carry out a sync plan: copy each way, then move the marked files to the Trash.
    ///
    /// Every step reports what went wrong. Silence here is dangerous — a user who asked for files to
    /// be deleted and saw no message would reasonably assume they were gone.
    private func runSync(_ plan: DirectorySyncPlan) {
        var missing: [String] = []

        func group(_ relativePaths: [String], from sourceRoot: String,
                   to destinationRoot: String) -> [String: [FileItem]] {
            var byDestination: [String: [FileItem]] = [:]
            for rel in relativePaths {
                let source = (sourceRoot as NSString).appendingPathComponent(rel)
                guard let item = FileItem.fromPath(source) else { missing.append(rel); continue }
                let destinationDir = ((destinationRoot as NSString)
                    .appendingPathComponent(rel) as NSString).deletingLastPathComponent
                byDestination[destinationDir, default: []].append(item)
            }
            return byDestination
        }

        var work = group(plan.toRight, from: plan.leftRoot, to: plan.rightRoot)
        for (destination, items) in group(plan.toLeft, from: plan.rightRoot, to: plan.leftRoot) {
            work[destination, default: []].append(contentsOf: items)
        }

        // Moves go through the service's real move — on one volume that is a rename, so it costs
        // nothing and cannot leave a half-copied file behind the way copy-then-delete could.
        var moves = group(plan.moveRight, from: plan.leftRoot, to: plan.rightRoot)
        for (destination, items) in group(plan.moveLeft, from: plan.rightRoot, to: plan.leftRoot) {
            moves[destination, default: []].append(contentsOf: items)
        }

        // Files the user marked for removal — moved to the Trash, never erased, so a wrong call in
        // the compare window stays recoverable.
        let doomed = plan.deleteLeft.map { (plan.leftRoot as NSString).appendingPathComponent($0) }
            + plan.deleteRight.map { (plan.rightRoot as NSString).appendingPathComponent($0) }
        var toTrash: [FileItem] = []
        for path in doomed {
            if let item = FileItem.fromPath(path) {
                toTrash.append(item)
            } else {
                missing.append((path as NSString).lastPathComponent)
            }
        }

        // NB: this used to be `guard !work.isEmpty else { return }`, which walked out before the
        // deletions ran — a plan of deletions only did nothing at all, without a word.
        guard !work.isEmpty || !moves.isEmpty || !toTrash.isEmpty else { return }

        Task { @MainActor in
            var problems: [String] = []

            for (destination, items) in work {
                do {
                    // The tree may not exist yet on the receiving side.
                    try operationsService.ensureDirectoryTree(at: destination)
                    try await operationsService.copyItems(items, to: destination,
                                                          queueService: queueService)
                } catch {
                    problems.append("\((destination as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }

            for (destination, items) in moves {
                do {
                    try operationsService.ensureDirectoryTree(at: destination)
                    try await operationsService.moveItems(items, to: destination,
                                                          queueService: queueService)
                } catch {
                    problems.append("\((destination as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }

            if !toTrash.isEmpty {
                do {
                    try await operationsService.trashItems(toTrash)
                } catch {
                    problems.append(error.localizedDescription)
                }
            }

            splitVC.leftPanelVM.loadDirectory(resetCursor: false)
            splitVC.rightPanelVM.loadDirectory(resetCursor: false)

            if !missing.isEmpty {
                problems.append(String(format: L("compare.error.missing"),
                                       missing.count, missing.prefix(3).joined(separator: ", ")))
            }
            if !problems.isEmpty {
                DialogService.shared.showError(title: L("compare.error.title"),
                                               message: problems.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Menu validation

    /// Grey out Tools items that cannot do anything right now, so the menu shows what is possible
    /// instead of letting the user pick something that answers with an explanatory dialog.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let vm = splitVC.activePanelVC.viewModel
        switch item.action {
        case #selector(handleUndoFileOperation(_:)):
            // The title says WHAT would be undone — a blind "Undo" over file operations is a
            // gamble nobody should take.
            if let manager = editingUndoManager(), manager.canUndo {
                item.title = L("menu.undo")
                return true
            }
            item.title = UndoJournal.shared.undoDescription
                .map { String(format: L("menu.undo.what"), $0) } ?? L("menu.undo")
            return UndoJournal.shared.canUndo
        case #selector(handleRedoFileOperation(_:)):
            if let manager = editingUndoManager(), manager.canRedo {
                item.title = L("menu.redo")
                return true
            }
            item.title = UndoJournal.shared.redoDescription
                .map { String(format: L("menu.redo.what"), $0) } ?? L("menu.redo")
            return UndoJournal.shared.canRedo
        case #selector(handleJoinFiles(_:)):
            return isLocalPanel(vm) && !partsToJoin().isEmpty
        case #selector(handleSplitFile(_:)):
            guard isLocalPanel(vm), let cursor = vm.cursorItem else { return false }
            return !cursor.isDirectory && cursor.name != ".."
        case #selector(handleChecksum(_:)):
            return isLocalPanel(vm) && vm.operationTargets.contains { !$0.isDirectory }
        case #selector(handleCompareFiles(_:)):
            return comparablePair() != nil
        case #selector(handleCompareDirectories(_:)):
            return isLocalPanel(splitVC.leftPanelVM) && isLocalPanel(splitVC.rightPanelVM)
                && splitVC.leftPanelVM.currentPath != splitVC.rightPanelVM.currentPath
        default:
            // Команды строки меню, добавленные ради палитры и туннеля, — в своём файле.
            return validateMenuCommand(item) ?? true
        }
    }

    /// Do this panel's rows correspond to real files on disk? Inside an archive and on a remote
    /// server the paths are virtual, and every tool here works by path.
    func isLocalPanel(_ vm: PanelViewModel) -> Bool {
        !vm.insideRemote && !vm.insideArchive
    }

    /// The part files a join would work on: whatever the user actually marked, otherwise the set
    /// belonging to the file under the cursor. Empty when neither is a numbered part.
    private func partsToJoin() -> [String] {
        let vm = splitVC.activePanelVC.viewModel
        // An explicit selection wins — if the user marked the parts, use exactly those.
        let marked = vm.operationTargets.filter { !$0.isDirectory }.map(\.path)
            .filter { FileJoiner.isPart($0) }
        if marked.count > 1 { return FileJoiner.ordered(marked) }
        guard let cursor = vm.cursorItem, !cursor.isDirectory else { return [] }
        return FileJoiner.parts(forPartAt: cursor.path) ?? []
    }

    // MARK: - Focus after a desktop switch

    /// Whether arriving at a desktop should hand the main window the focus.
    ///
    /// Only a window standing on the desktop the user just arrived at may be fronted. One sitting
    /// on another desktop must be left alone — pulling it forward would drag the user off the
    /// desktop they deliberately switched to, which is the very thing `.moveToActiveSpace` was
    /// added to stop. Minimised stays minimised: un-minimising was never asked for.
    ///
    /// And `isAppActive` is what keeps the window from JUMPING the queue. The window follows the
    /// user from desktop to desktop, so "arrived at its desktop" is true everywhere; without this
    /// the app shouldered its way to the front on every switch. What the user wants is the
    /// position they left: in front if it was in front, and behind whatever was covering it
    /// otherwise. macOS decides which app owns the new desktop — we only make sure that, when it
    /// picked US, our window is the one showing.
    nonisolated static func shouldReclaimFocus(isVisible: Bool,
                                               isMiniaturized: Bool,
                                               isOnActiveSpace: Bool,
                                               isAppActive: Bool) -> Bool {
        isVisible && !isMiniaturized && isOnActiveSpace && isAppActive
    }

    /// Front the window after a Space switch, if it is the one the user just arrived at.
    private func reclaimFocusOnArrival() {
        guard let window,
              Self.shouldReclaimFocus(isVisible: window.isVisible,
                                      isMiniaturized: window.isMiniaturized,
                                      isOnActiveSpace: window.isOnActiveSpace,
                                      isAppActive: NSApp.isActive)
        else { return }

        // No activate(ignoringOtherApps:) any more: that is what elbowed the app in front of
        // whatever the user had on the desktop they switched to. We are already the active app
        // here — this only makes sure our own window is the one on top of our own windows.
        // A modal dialog owns the keyboard, so it, not the main window, is the one to front.
        (NSApp.modalWindow ?? window).makeKeyAndOrderFront(nil)

        // macOS settles the new desktop's front app just after the switch, which can land after
        // this call. Re-assert once, and only while we are still the app it chose.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let window = self.window, NSApp.modalWindow == nil,
                  Self.shouldReclaimFocus(isVisible: window.isVisible,
                                          isMiniaturized: window.isMiniaturized,
                                          isOnActiveSpace: window.isOnActiveSpace,
                                          isAppActive: NSApp.isActive),
                  !window.isKeyWindow
            else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Split the file under the cursor into numbered parts.
    ///
    /// The parts default to the OTHER panel's folder, the way a commander works: you point one side
    /// at the source and the other at where the pieces should land.
    @objc func handleSplitFile(_ sender: Any?) {
        let vm = splitVC.activePanelVC.viewModel
        guard !vm.insideRemote, !vm.insideArchive else {
            DialogService.shared.showInfo(title: L("split.title"), message: L("split.localOnly"))
            return
        }
        guard let item = vm.cursorItem, !item.isDirectory, item.name != ".." else {
            DialogService.shared.showInfo(title: L("split.title"), message: L("split.pickFile"))
            return
        }
        let other = splitVC.inactivePanelViewModel.currentPath

        let request = FCXLDialog.runModal(size: NSSize(width: 520, height: 460)) { session in
            FileSplitDialogView(session: session, sourcePath: item.path,
                                sourceSize: item.size, defaultOutputDirectory: other)
        }
        guard let request else { return }

        Task { @MainActor in
            // Presets go up to 4.7 GB and the optional checksum reads the whole source a second
            // time — this ran in silence, with nothing on screen and no way out. The core reports
            // bytes as it copies and honours "stop": a cancelled run removes its partial parts.
            // The flag, not progress.isCancelled: the byte callback fires on the worker thread,
            // and the controller's state is main-actor — same pattern as the properties walk.
            let cancelled = AtomicFlag()
            let progress = DialogService.shared.showProgress(title: L("split.title"),
                                                             message: L("split.working"),
                                                             cancelHandler: { cancelled.value = true })
            let sourceName = (request.sourcePath as NSString).lastPathComponent
            let result = await Task.detached(priority: .userInitiated) { () -> (Int, String?) in
                let bridge = FCXLToolsBridge()
                let onBytes: (UInt64, UInt64) -> Bool = { done, total in
                    DispatchQueue.main.async {
                        progress.update(currentFile: sourceName,
                                        progress: total > 0 ? Double(done) / Double(total) : 0,
                                        bytesDone: Int64(min(done, UInt64(Int64.max))),
                                        bytesTotal: Int64(min(total, UInt64(Int64.max))),
                                        filesDone: 0, filesTotal: 1)
                    }
                    return cancelled.value
                }
                guard let parts = try? bridge.splitFile(atPath: request.sourcePath,
                                                        chunkSize: request.chunkBytes,
                                                        outputDir: request.outputDirectory,
                                                        progress: onBytes) as? [String]
                else { return (cancelled.value ? -1 : 0, nil) }
                // A checksum of the ORIGINAL file, stored beside the parts: joining can then prove
                // the rebuilt file is byte-identical, which is the whole point of splitting safely.
                var checksumPath: String?
                if request.writeChecksum,
                   let digests = try? bridge.allChecksumsForFile(atPath: request.sourcePath) as? [String: String],
                   let sha = digests["sha256"] {
                    let name = (request.sourcePath as NSString).lastPathComponent
                    let path = (request.outputDirectory as NSString)
                        .appendingPathComponent(name + ".sha256")
                    // Recorded only when actually written: the join flow later reads this path to
                    // verify the rebuilt file, and a phantom sidecar silently downgraded that
                    // verification — the one guarantee the checkbox promised.
                    if (try? "\(sha)  \(name)\n".write(toFile: path, atomically: true,
                                                       encoding: .utf8)) != nil {
                        checksumPath = path
                    }
                }
                return (parts.count, checksumPath)
            }.value
            progress.close()

            splitVC.leftPanelVM.loadDirectory(resetCursor: false)
            splitVC.rightPanelVM.loadDirectory(resetCursor: false)

            if result.0 < 0 {
                // Cancelled: the core already removed the partial parts — nothing to report.
            } else if result.0 == 0 {
                DialogService.shared.showError(title: L("split.title"), message: L("split.failed"))
            } else {
                DialogService.shared.showInfo(title: L("split.title"),
                                              message: String(format: L("split.done"), result.0))
            }
        }
    }

    /// Rejoin a numbered set from whichever part the cursor sits on.
    @objc func handleJoinFiles(_ sender: Any?) {
        let vm = splitVC.activePanelVC.viewModel
        guard !vm.insideRemote, !vm.insideArchive else {
            DialogService.shared.showInfo(title: L("join.title"), message: L("split.localOnly"))
            return
        }
        let parts = partsToJoin()
        guard let first = parts.first, parts.count > 1 else {
            DialogService.shared.showInfo(title: L("join.title"), message: L("join.pickPart"))
            return
        }
        let directory = (first as NSString).deletingLastPathComponent
        let name = FileJoiner.joinedName(forPartAt: first)
        let output = (directory as NSString).appendingPathComponent(name)
        let checksumFile = FileJoiner.checksumFile(forBase: name, in: directory)

        let request = FCXLDialog.runModal(size: NSSize(width: 520, height: 420)) { session in
            FileJoinDialogView(session: session, parts: parts, outputPath: output,
                               hasChecksum: checksumFile != nil)
        }
        guard let request else { return }

        Task { @MainActor in
            let cancelled = AtomicFlag()
            let progress = DialogService.shared.showProgress(title: L("join.title"),
                                                             message: L("join.working"),
                                                             cancelHandler: { cancelled.value = true })
            let outputName = (request.outputPath as NSString).lastPathComponent
            let verdict = await Task.detached(priority: .userInitiated) { () -> String in
                let bridge = FCXLToolsBridge()
                let onBytes: (UInt64, UInt64) -> Bool = { done, total in
                    DispatchQueue.main.async {
                        progress.update(currentFile: outputName,
                                        progress: total > 0 ? Double(done) / Double(total) : 0,
                                        bytesDone: Int64(min(done, UInt64(Int64.max))),
                                        bytesTotal: Int64(min(total, UInt64(Int64.max))),
                                        filesDone: 0, filesTotal: 1)
                    }
                    return cancelled.value
                }
                guard (try? bridge.joinFiles(request.parts, outputPath: request.outputPath,
                                             progress: onBytes)) != nil
                else { return cancelled.value ? "cancelled" : "failed" }
                // If the split wrote a checksum, use it: a set with a missing or truncated part
                // still joins into a plausible-looking file, and only the hash catches that.
                guard let checksumFile,
                      let stored = try? String(contentsOfFile: checksumFile, encoding: .utf8),
                      let expected = stored.split(separator: " ").first.map(String.init),
                      let digests = try? bridge.allChecksumsForFile(atPath: request.outputPath) as? [String: String],
                      let actual = digests["sha256"]
                else { return "ok-unverified" }
                return actual.caseInsensitiveCompare(expected) == .orderedSame ? "ok" : "mismatch"
            }.value
            progress.close()

            // Clearing the parts away is only safe once the result is known to be good. With a
            // mismatch the parts are the ONLY intact copy of the data, so they stay put no matter
            // what the checkbox said — losing them is unrecoverable, keeping them costs disk space.
            var deletedParts = false
            if request.deletePartsAfter, verdict == "ok" || verdict == "ok-unverified" {
                // Файл контрольной суммы — часть того же набора: его написала разрезка, и без
                // частей он никому не нужен. Уходит в корзину вместе с ними.
                let set = request.parts + (checksumFile.map { [$0] } ?? [])
                let items = set.compactMap { FileItem.fromPath($0) }
                if !items.isEmpty {
                    // Части не удалились — человек об этом узнаёт: галочка стояла, а файлы
                    // остались. Склейка при этом уже удалась, и итог ниже про неё честен.
                    do {
                        try await operationsService.trashItems(items)
                        deletedParts = true
                    } catch {
                        DialogService.shared.showOperationError(title: L("join.title"), error: error)
                    }
                }
            }

            splitVC.leftPanelVM.loadDirectory(resetCursor: false)
            splitVC.rightPanelVM.loadDirectory(resetCursor: false)

            let suffix = deletedParts ? "\n" + L("join.partsTrashed") : ""
            switch verdict {
            case "ok":
                DialogService.shared.showInfo(title: L("join.title"),
                                              message: L("join.doneVerified") + suffix)
            case "ok-unverified":
                DialogService.shared.showInfo(title: L("join.title"),
                                              message: L("join.done") + suffix)
            case "mismatch":
                DialogService.shared.showError(title: L("join.title"),
                                               message: L("join.mismatch") + "\n" + L("join.partsKept"))
            case "cancelled":
                break   // the core removed the partial output; the parts are untouched
            default:
                DialogService.shared.showError(title: L("join.title"), message: L("join.failed"))
            }
        }
    }

    /// Checksums for the selected files (or the file under the cursor). Local files only — the
    /// core hashes by path, and a remote entry has no local path to read.
    @objc func handleChecksum(_ sender: Any?) {
        let vm = splitVC.activePanelVC.viewModel
        guard !vm.insideRemote, !vm.insideArchive else {
            DialogService.shared.showInfo(title: L("checksum.title"), message: L("checksum.localOnly"))
            return
        }
        let paths = vm.operationTargets.filter { !$0.isDirectory }.map(\.path)
        guard !paths.isEmpty else {
            DialogService.shared.showInfo(title: L("checksum.title"), message: L("checksum.noFiles"))
            return
        }
        _ = FCXLDialog.runModal(size: NSSize(width: 560, height: 420)) { session in
            ChecksumDialogView(session: session, paths: paths)
        }
    }

    /// Read the text inside the chosen pictures, scans or PDFs.
    ///
    /// Everything that cannot hold text is quietly dropped from the selection rather than
    /// filling the window with files that answer "nothing found" — the person chose a folderful,
    /// not a list of failures.
    func recognizeText(in viewModel: PanelViewModel) {
        let targets = viewModel.operationTargets
            .filter { !$0.isDirectory && TextRecognitionService.canReadText(in: $0.path) }
            .map(\.path)
        guard !targets.isEmpty else { return }
        fcxlPresentModal { DialogService.shared.showTextRecognition(paths: targets) }
    }

    // MARK: - Vault

    /// Make a new vault in the active panel's folder.
    @objc func handleCreateVault(_ sender: Any?) {
        let vm = splitVC.activePanelViewModel
        guard !vm.insideArchive, !vm.insideRemote, vm.currentPath.hasPrefix("/") else {
            DialogService.shared.showInfo(title: L("vault.create.title"),
                                          message: L("vault.create.notHere"))
            return
        }
        let folder = vm.currentPath
        fcxlPresentModal { [weak self] in
            guard let request = DialogService.shared.showVaultCreate(folder: folder) else {
                return
            }
            self?.runVaultCreation(request)
        }
    }

    private func runVaultCreation(_ request: VaultCreateRequest) {
        let progress = DialogService.shared.showProgress(
            title: L("vault.create.title"), message: L("progress.preparing"),
            cancelHandler: nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: Error?
            do {
                try VaultService.create(at: request.path, sizeMB: request.sizeMB,
                                        password: request.password)
                if request.rememberInKeychain {
                    _ = VaultService.rememberPassword(request.password, for: request.path)
                }
                // The choice is remembered EITHER way: "no Touch ID" must keep meaning no,
                // or the first typed password would quietly re-enrol the vault.
                VaultService.setTouchIDDeclined(!request.rememberInKeychain, for: request.path)
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                progress.close()
                self?.splitVC.leftPanelVM.reloadKeepingCursor()
                self?.splitVC.rightPanelVM.reloadKeepingCursor()
                if let failure {
                    DialogService.shared.showOperationError(title: L("vault.create.title"),
                                                            error: failure)
                } else {
                    DialogService.shared.showInfo(
                        title: L("vault.create.title"),
                        message: String(format: L("vault.create.done"),
                                        (request.path as NSString).lastPathComponent))
                }
            }
        }
    }

    /// Lock a vault from the panel — the counterpart of Enter opening it.
    func lockVault(at path: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: Error?
            do { try VaultService.lock(path) } catch { failure = error }
            DispatchQueue.main.async {
                self?.splitVC.leftPanelVM.reloadKeepingCursor()
                self?.splitVC.rightPanelVM.reloadKeepingCursor()
                guard failure != nil else { return }
                // Something inside is still open. Instead of a dead-end "OK", the choice: tear
                // the volume away anyway, or go close the document by hand — and the HOLDER is
                // named, because "какой-то файл" is not a door anyone can go and close. What
                // force-locking cannot do is close the other program's window: macOS gives no
                // one that power, so the words promise locking, not closing.
                var message = String(format: L("vault.lock.busy"),
                                     (path as NSString).lastPathComponent)
                let holders = VaultService.holders(ofVault: path)
                if !holders.isEmpty {
                    message += "\n" + String(format: L("vault.lock.holders"),
                                              holders.joined(separator: ", "))
                }
                let force = DialogService.shared.showDestructiveConfirmation(
                    title: L("vault.lock.title"),
                    message: message,
                    confirmTitle: L("vault.lock.force"),
                    icon: "lock.trianglebadge.exclamationmark", iconColor: .orange)
                guard force else { return }
                let mount = VaultService.mountPoint(ofVault: path)
                DispatchQueue.global(qos: .userInitiated).async {
                    // First the polite road: ask the holders to CLOSE those documents by Apple
                    // Events — for Preview and its scriptable kin the window really closes.
                    // Then an ordinary lock; force-detach only for what ignored the request.
                    if let mount {
                        VaultService.closeDocuments(under: mount, holders: holders)
                        Thread.sleep(forTimeInterval: 0.6)
                    }
                    var forcedFailure: Error?
                    do {
                        try VaultService.lock(path)
                    } catch {
                        do { try VaultService.lock(path, force: true) } catch { forcedFailure = error }
                    }
                    DispatchQueue.main.async {
                        self?.splitVC.leftPanelVM.reloadKeepingCursor()
                        self?.splitVC.rightPanelVM.reloadKeepingCursor()
                        if let forcedFailure {
                            DialogService.shared.showOperationError(
                                title: L("vault.lock.title"), error: forcedFailure)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Context menu preview

    /// A real context menu over the real file panel, shown while the settings page's blur
    /// knobs are being turned. Built for the file under the cursor — the context the person
    /// asked to see is their own.
    func showContextMenuPreview() {
        let vc = splitVC.activePanelVC
        let vm = vc.viewModel
        guard let item = vm.cursorItem.flatMap({ $0.name == ".." ? nil : $0 })
                ?? vm.items.first(where: { $0.name != ".." && !$0.isDirectory })
                ?? vm.items.first(where: { $0.name != ".." }) else { return }
        let menu = NSMenu()
        vc.makeFileContextMenu(for: item, into: menu)
        guard let window = vc.view.window else { return }
        let inWindow = vc.view.convert(vc.view.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        // A third in from the panel's left, high enough for the menu to fit downward.
        let point = NSPoint(x: onScreen.minX + onScreen.width * 0.35,
                            y: onScreen.maxY - 60)
        ContextPopupMenuController.shared.showPreview(menu, at: point)
    }

    func dismissContextMenuPreview() {
        ContextPopupMenuController.shared.dismissPreview()
    }

    // MARK: - PDF

    private func chosenPDFs(in viewModel: PanelViewModel) -> [String] {
        viewModel.operationTargets
            .filter { !$0.isDirectory
                && fileCategory(extension: $0.fileExtension) == .pdf }
            .map(\.path)
    }

    /// Files a PDF can be made out of: pictures, and PDFs to be bound in whole.
    private func pdfSources(in viewModel: PanelViewModel) -> [String] {
        viewModel.operationTargets
            .filter { item in
                guard !item.isDirectory else { return false }
                let kind = fileCategory(extension: item.fileExtension)
                return kind == .image || kind == .pdf
            }
            .map(\.path)
    }

    /// Make one PDF out of pictures — scans, photographs of documents, a covering letter.
    func makePDF(in viewModel: PanelViewModel) {
        let targets = pdfSources(in: viewModel)
        guard !targets.isEmpty else {
            DialogService.shared.showInfo(title: L("pdf.make.title"),
                                          message: L("pdf.make.nothing"))
            return
        }
        fcxlPresentModal { [weak self] in
            guard let request = DialogService.shared.showPDFMake(paths: targets),
                  let first = request.order.first else { return }
            let target = PDFEditService.target(named: request.name, near: first,
                                               fallback: "PDF")
            self?.runPDF(title: L("pdf.make.title")) {
                [try PDFEditService.makePDF(from: request.order, into: target,
                                            pageSize: request.pageSize)]
            }
        }
    }

    @objc func handleMakePDF(_ sender: Any?) { makePDF(in: splitVC.activePanelViewModel) }

    /// Put several documents into one, in an order the person can change.
    func mergePDFs(in viewModel: PanelViewModel) {
        let targets = chosenPDFs(in: viewModel)
        guard targets.count > 1 else {
            DialogService.shared.showInfo(title: L("pdf.merge.title"),
                                          message: L("pdf.merge.needTwo"))
            return
        }
        fcxlPresentModal { [weak self] in
            guard let request = DialogService.shared.showPDFMerge(paths: targets),
                  let first = request.order.first else { return }
            let target = PDFEditService.target(named: request.name, near: first,
                                               fallback: "PDF")
            self?.runPDF(title: L("pdf.merge.title")) {
                [try PDFEditService.merge(request.order, into: target)]
            }
        }
    }

    /// Take a document apart.
    func splitPDF(in viewModel: PanelViewModel) {
        guard let path = chosenPDFs(in: viewModel).first else { return }
        let pages = PDFEditService.pageCount(of: path)
        guard pages > 1 else {
            DialogService.shared.showInfo(title: L("pdf.split.title"),
                                          message: L("pdf.split.onePage"))
            return
        }
        fcxlPresentModal { [weak self] in
            guard let request = DialogService.shared.showPDFSplit(path: path,
                                                                   pageCount: pages) else {
                return
            }
            self?.runPDF(title: L("pdf.split.title")) {
                try PDFEditService.split(path, parts: request.parts)
            }
        }
    }

    /// Turn pages, in one document or in several at once.
    func rotatePDF(in viewModel: PanelViewModel) {
        let targets = chosenPDFs(in: viewModel)
        guard let first = targets.first else { return }
        let pages = PDFEditService.pageCount(of: first)
        fcxlPresentModal { [weak self] in
            guard let request = DialogService.shared.showPDFRotate(paths: targets,
                                                                    pageCount: pages) else {
                return
            }
            self?.runPDF(title: L("pdf.rotate.title")) {
                var made: [String] = []
                for path in targets {
                    let count = PDFEditService.pageCount(of: path)
                    // The pages are chosen per document: "3-" means something different in a
                    // file of four pages and in one of forty.
                    let chosen = PDFEditService.pages(from: request.ranges, pageCount: count)
                    guard !chosen.isEmpty else { continue }
                    let target = request.replaces
                        ? path
                        : PDFEditService.freePath(near: path, suffix: L("pdf.rotate.suffix"))
                    made.append(try PDFEditService.rotate(path, degrees: request.degrees,
                                                          pages: chosen, target: target))
                }
                return made
            }
        }
    }

    /// Run one PDF job off the main thread and say plainly what came of it.
    private func runPDF(title: String, work: @escaping () throws -> [String]) {
        let progress = DialogService.shared.showProgress(
            title: title, message: L("progress.preparing"), cancelHandler: nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var made: [String] = []
            var failure: Error?
            do { made = try work() } catch { failure = error }
            let result = made
            DispatchQueue.main.async {
                progress.close()
                self?.splitVC.leftPanelVM.reloadKeepingCursor()
                self?.splitVC.rightPanelVM.reloadKeepingCursor()
                if let failure {
                    DialogService.shared.showOperationError(title: title, error: failure)
                } else {
                    DialogService.shared.showInfo(
                        title: title,
                        message: String(format: L("pdf.done"), result.count))
                }
            }
        }
    }

    @objc func handleMergePDFs(_ sender: Any?) { mergePDFs(in: splitVC.activePanelViewModel) }
    @objc func handleSplitPDF(_ sender: Any?) { splitPDF(in: splitVC.activePanelViewModel) }
    @objc func handleRotatePDF(_ sender: Any?) { rotatePDF(in: splitVC.activePanelViewModel) }

    /// Convert and resize the chosen pictures.
    @objc func handleConvertImages(_ sender: Any?) {
        convertImages(in: splitVC.activePanelViewModel)
    }

    func convertImages(in viewModel: PanelViewModel) {
        let targets = viewModel.operationTargets
            .filter { !$0.isDirectory && fileCategory(extension: $0.fileExtension) == .image }
            .map(\.path)
        guard !targets.isEmpty else {
            DialogService.shared.showInfo(title: L("convert.title"),
                                          message: L("convert.noPictures"))
            return
        }
        fcxlPresentModal { [weak self] in
            guard let options = DialogService.shared.showImageConvert(paths: targets) else {
                return
            }
            self?.runConversion(targets, options: options)
        }
    }

    private func runConversion(_ paths: [String],
                               options: ImageConversionService.Options) {
        let progress = DialogService.shared.showProgress(
            title: L("convert.progress"), message: L("progress.preparing"), cancelHandler: nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let steps = ImageConversionService.plan(paths: paths, options: options)
            var done = 0
            var failure: Error?
            for (index, step) in steps.enumerated() {
                if progress.isCancelled { break }
                DispatchQueue.main.async {
                    progress.update(currentFile: (step.source as NSString).lastPathComponent,
                                    progress: Double(index) / Double(max(steps.count, 1)),
                                    bytesDone: 0, bytesTotal: 0,
                                    filesDone: index, filesTotal: steps.count)
                }
                do {
                    _ = try ImageConversionService.convert(step, options: options)
                    done += 1
                } catch {
                    failure = error
                }
            }
            let finished = done
            DispatchQueue.main.async {
                progress.close()
                self?.splitVC.leftPanelVM.reloadKeepingCursor()
                self?.splitVC.rightPanelVM.reloadKeepingCursor()
                if let failure {
                    DialogService.shared.showOperationError(title: L("convert.title"),
                                                            error: failure)
                } else {
                    DialogService.shared.showInfo(
                        title: L("convert.title"),
                        message: String(format: L("convert.done"), finished))
                }
            }
        }
    }

    // MARK: - Age encryption

    /// Seal the chosen files with a password into the age format — or open sealed ones.
    /// One password per run: a batch is one act, not a quiz.
    /// From the Tools menu — the context menu deliberately stays lean; see docs/todo.md,
    /// where a user-arranged context menu is planned instead of piling every command in.
    @objc func handleEncryptAge(_ sender: Any?) {
        ageEncrypt(in: splitVC.activePanelViewModel)
    }

    @objc func handleDecryptAge(_ sender: Any?) {
        let vm = splitVC.activePanelViewModel
        let sealed = vm.operationTargets.filter { !$0.isDirectory && AgeCrypt.isAgeFile($0.path) }
        guard !sealed.isEmpty else {
            // Said plainly rather than a menu item that does nothing when pressed.
            DialogService.shared.showInfo(title: L("age.decrypt.title"),
                                          message: L("age.decrypt.nothingSealed"))
            return
        }
        ageDecrypt(in: vm)
    }

    func ageEncrypt(in viewModel: PanelViewModel) {
        // Folders ride too — packed into a quiet zip first, so the envelope still holds ONE
        // file. Vaults are excluded: they are already a lock, and zipping one makes no sense.
        let targets = viewModel.operationTargets
            .filter { !VaultService.isVault($0.path) }.map(\.path)
        guard !targets.isEmpty else { return }
        let subtitle = targets.count == 1
            ? (targets[0] as NSString).lastPathComponent
            : String(format: L("age.password.count"), targets.count)
        fcxlPresentModal { [weak self] in
            guard let password = DialogService.shared.showAgeEncrypt(subtitle: subtitle) else {
                return
            }
            self?.runAge(targets, password: password, decrypt: false)
        }
    }

    func ageDecrypt(in viewModel: PanelViewModel) {
        ageDecrypt(paths: viewModel.operationTargets
            .filter { !$0.isDirectory && AgeCrypt.isAgeFile($0.path) }.map(\.path))
    }

    /// The same road for a single file — Enter on an .age lands here.
    func ageDecrypt(paths: [String]) {
        let targets = paths
        guard !targets.isEmpty else { return }
        let name = (targets[0] as NSString).lastPathComponent
        fcxlPresentModal { [weak self] in
            guard let password = ArchivePasswords.ask(archiveName: targets.count == 1
                ? name : String(format: L("age.password.count"), targets.count)) else { return }
            self?.runAge(targets, password: password, decrypt: true)
        }
    }

    private func runAge(_ paths: [String], password: String, decrypt: Bool) {
        let title = L(decrypt ? "age.decrypt.title" : "age.encrypt.title")
        // The bridge is created here, before the dialog, so the cancel button can reach the
        // zip packing of a folder mid-flight — AgeCrypt itself polls isCancelled.
        let bridge = CoreBridgeService()
        let progress = DialogService.shared.showProgress(
            title: title, message: L("progress.preparing"),
            cancelHandler: { bridge.cancelArchiveOperations() })
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var done = 0
            var failure: Error?
            for (index, source) in paths.enumerated() {
                if progress.isCancelled { break }
                DispatchQueue.main.async {
                    progress.update(currentFile: (source as NSString).lastPathComponent,
                                    progress: Double(index) / Double(max(paths.count, 1)),
                                    bytesDone: 0, bytesTotal: 0,
                                    filesDone: index, filesTotal: paths.count)
                }
                var isFolder: ObjCBool = false
                FileManager.default.fileExists(atPath: source, isDirectory: &isFolder)
                do {
                    if decrypt {
                        let output = Self.freeAgePath(for: source, decrypt: true)
                        try AgeCrypt.decrypt(input: source, output: output, password: password,
                                             isCancelled: { progress.isCancelled })
                    } else if isFolder.boolValue {
                        // A folder: zip it quietly to a temporary file, seal the zip, drop
                        // the intermediate. The result is "папка.zip.age" next to the folder.
                        let tmpZip = NSTemporaryDirectory() + "fcxl-age-"
                            + UUID().uuidString + ".zip"
                        defer { try? FileManager.default.removeItem(atPath: tmpZip) }
                        try bridge.createArchive(
                            archivePath: tmpZip, format: .zip, sources: [source],
                            includeSubfolders: true, preservePaths: true,
                            compressionLevel: 6)
                        if progress.isCancelled { break }
                        let output = Self.freeAgePath(for: source + ".zip", decrypt: false)
                        try AgeCrypt.encrypt(input: tmpZip, output: output, password: password,
                                             isCancelled: { progress.isCancelled })
                    } else {
                        let output = Self.freeAgePath(for: source, decrypt: false)
                        try AgeCrypt.encrypt(input: source, output: output, password: password,
                                             isCancelled: { progress.isCancelled })
                    }
                    done += 1
                } catch AgeCrypt.AgeError.cancelled {
                    break
                } catch {
                    if progress.isCancelled { break }   // a cancelled zip pack is not a failure
                    failure = error
                    // The wrong password fails the same way for every file — no point
                    // grinding through the rest of the batch to repeat the message.
                    if (error as? AgeCrypt.AgeError) == .wrongPassword { break }
                }
            }
            let finished = done
            DispatchQueue.main.async {
                progress.close()
                self?.splitVC.leftPanelVM.reloadKeepingCursor()
                self?.splitVC.rightPanelVM.reloadKeepingCursor()
                if let failure {
                    DialogService.shared.showOperationError(title: title, error: failure)
                } else if finished > 0 {
                    DialogService.shared.showInfo(
                        title: title,
                        message: String(format: L(decrypt ? "age.decrypt.done"
                                                          : "age.encrypt.done"), finished))
                }
            }
        }
    }

    /// The output path next to the source: "имя.age" when sealing, the name without ".age"
    /// when opening (".decrypted" appended when the suffix is not there to shed). Never
    /// overwrites — a taken name gets " 2", " 3", …
    static func freeAgePath(for source: String, decrypt: Bool) -> String {
        let wanted: String
        if decrypt {
            wanted = source.lowercased().hasSuffix(".age")
                ? String(source.dropLast(4))
                : source + ".decrypted"
        } else {
            wanted = source + ".age"
        }
        guard FileManager.default.fileExists(atPath: wanted) else { return wanted }
        let base = (wanted as NSString).deletingPathExtension
        let ext = (wanted as NSString).pathExtension
        for n in 2...9999 {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return wanted
    }

    /// Take the invisible notes out of the chosen photographs.
    ///
    /// Asked first, always: this rewrites the files, and a place a photograph remembers cannot
    /// be put back once it is gone.
    func cleanPhotoMetadata(in viewModel: PanelViewModel) {
        let targets = viewModel.operationTargets
            .filter { !$0.isDirectory
                && fileCategory(extension: $0.fileExtension) == .image }
            .map(\.path)
        guard !targets.isEmpty else { return }
        fcxlPresentModal { [weak self] in
            guard let request = DialogService.shared.showCleanMetadata(paths: targets) else {
                return
            }
            self?.runCleaning(targets, request: request)
        }
    }

    private func runCleaning(_ paths: [String], request: CleanMetadataRequest) {
        Task { @MainActor in
            var cleaned = 0
            var failure: Error?
            for path in paths {
                do {
                    _ = try await Task.detached(priority: .userInitiated) {
                        try PhotoMetadataService.clean(path: path, what: request.what,
                                                       keepingOriginal: request.keepOriginal)
                    }.value
                    cleaned += 1
                } catch {
                    failure = error
                }
            }
            splitVC.leftPanelVM.reloadKeepingCursor()
            splitVC.rightPanelVM.reloadKeepingCursor()
            if let failure {
                DialogService.shared.showOperationError(title: L("exif.clean.title"),
                                                        error: failure)
            } else {
                DialogService.shared.showInfo(
                    title: L("exif.clean.title"),
                    message: String(format: L("exif.clean.done"), cleaned))
            }
        }
    }

    // MARK: - Folder rules

    /// Write the rules. They are kept whole, in order — the order is what decides which rule
    /// gets a file when two of them want it.
    @objc func handleFolderRules(_ sender: Any?) {
        guard let updated = DialogService.shared
            .showFolderRulesEditor(rules: FolderRuleStore.shared.all()) else { return }
        FolderRuleStore.shared.replaceAll(updated)
    }

    /// Run the rules over the folder in front of the person — after showing what that would do.
    @objc func handleApplyFolderRules(_ sender: Any?) {
        let vm = splitVC.activePanelViewModel
        guard !vm.insideRemote, !vm.insideArchive, vm.currentPath.hasPrefix("/") else {
            DialogService.shared.showInfo(title: L("rules.apply.title"),
                                          message: L("rules.apply.notHere"))
            return
        }
        let rules = FolderRuleStore.shared.active()
        guard !rules.isEmpty else {
            DialogService.shared.showInfo(title: L("rules.apply.title"),
                                          message: L("rules.apply.noRules"))
            return
        }
        let steps = FolderRules.plan(items: vm.allItems, rules: rules, tags: vm.tagsByPath)
        guard !steps.isEmpty else {
            DialogService.shared.showInfo(title: L("rules.apply.title"),
                                          message: L("rules.apply.nothingMatched"))
            return
        }
        guard let chosen = DialogService.shared.showFolderRulesApply(folder: vm.currentPath,
                                                                     steps: steps),
              !chosen.isEmpty else { return }
        Task { @MainActor in await runRuleSteps(chosen) }
    }

    /// Carry out a plan. Every step goes down the road that action already has in this program —
    /// the same copier, the same Trash, the same unpacker — so a rule cannot do anything the
    /// person could not have done by hand, and undo knows about it either way.
    private func runRuleSteps(_ steps: [RuleStep]) async {
        let ops = splitVC.activePanelViewModel.operationsService
        var failed: Error?

        func items(_ steps: [RuleStep]) -> [FileItem] {
            steps.compactMap { FileItem.fromPath($0.source) }
        }

        do {
            // Moves and copies are grouped by destination: one operation with its progress and
            // its conflict dialog, rather than one per file.
            for kind in [RuleAction.Kind.move, .copy] {
                let group = steps.filter { $0.action.kind == kind }
                let byFolder = Dictionary(grouping: group) {
                    ($0.target as NSString).deletingLastPathComponent
                }
                for (folder, group) in byFolder where !folder.isEmpty {
                    // A date-stamped subfolder ("2024/09") usually does not exist yet.
                    try FileManager.default.createDirectory(atPath: folder,
                                                            withIntermediateDirectories: true)
                    if kind == .move {
                        try await ops.moveItems(items(group), to: folder)
                    } else {
                        try await ops.copyItems(items(group), to: folder)
                    }
                }
            }

            for step in steps where step.action.kind == .rename {
                guard let item = FileItem.fromPath(step.source), !step.target.isEmpty else { continue }
                try ops.renameItem(item, to: (step.target as NSString).lastPathComponent)
            }

            let toTrash = items(steps.filter { $0.action.kind == .trash })
            if !toTrash.isEmpty { try await ops.trashItems(toTrash) }

            for step in steps where step.action.kind == .tag {
                _ = FinderTagService.setTags([step.action.tag], at: step.source)
            }

            let toShelf = steps.filter { $0.action.kind == .shelf }.map(\.source)
            if !toShelf.isEmpty { _ = DropStackStore.add(toShelf) }

            for step in steps where step.action.kind == .unpack {
                // The program's own unpacker, with its own "into a folder named after the
                // archive" rule — the same road as the panel's own unpack.
                let archive = step.source
                let folder = (archive as NSString).deletingLastPathComponent
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    ops.unpackArchive(at: archive, to: folder, createSubfolder: true,
                                      overwriteExisting: false) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            }
        } catch {
            failed = error
        }

        splitVC.leftPanelVM.reloadKeepingCursor()
        splitVC.rightPanelVM.reloadKeepingCursor()
        if let failed {
            DialogService.shared.showOperationError(title: L("rules.apply.title"), error: failed)
        }
    }

    @objc func handleMultiRename(_ sender: Any?) {
        openMultiRename(on: splitVC.activePanelVC)
    }

    private func openMultiRename(on panelVC: PanelViewController) {
        let vm = panelVC.viewModel
        let targets = vm.operationTargets
        guard !targets.isEmpty else { return }
        let session = vm.insideRemote ? vm.remoteSession : nil
        MultiRenameWindow.shared.show(
            items: targets,
            rootPath: vm.currentPath,
            session: session,
            queue: queueService,
            onRenamed: { [weak panelVC] in
                guard let panelVC else { return }
                let vm = panelVC.viewModel
                // Remote: re-list the server directory directly (a same-dir reloadKeepingCursor
                // wasn't repainting the FTP panel after a rename). Local keeps the cursor.
                if vm.insideRemote {
                    vm.startRemoteLoad(at: vm.currentPath)
                } else {
                    vm.reloadKeepingCursor()
                }
            })
    }

    /// Single entry point for rename with dialog (context menu "Rename").
    /// Enters via a runloop callout: the dialog is an FCXLDialog (SwiftUI), and a
    /// context-menu action parks the main queue — running the modal there kills its input.
    private func performRenameDialog(vm: PanelViewModel, item: FileItem) {
        fcxlPresentModal { [weak self] in self?.performRenameDialogNow(vm: vm, item: item) }
    }

    private func performRenameDialogNow(vm: PanelViewModel, item: FileItem) {
        guard let newName = DialogService.shared.showTextInput(
            title: L("context.rename"),
            message: L("rename.message"),
            defaultValue: item.name,
            confirmButtonTitle: L("rename.confirm"),
            selectNameOnly: true
        ) else { return }

        executeRename(vm: vm, item: item, newName: newName)
    }

    /// Single entry point for actual rename execution (inline + dialog both call this).
    private func executeRename(vm: PanelViewModel, item: FileItem, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }

        // Renaming a cut file leaves the pending paste pointing at the old, now-empty path.
        FileClipboard.invalidate(paths: [item.path])

        if vm.insideArchive, let archivePath = vm.archivePath {
            // A NESTED archive is a temp copy: an edit would land on it and silently evaporate
            // the moment the user leaves. Refused, not pretended.
            guard !vm.isNestedArchive else {
                DialogService.shared.showError(title: L("rename.errorTitle"),
                                               message: L("archive.nested.readOnly"))
                return
            }
            // Rename an entry inside the archive.
            let ops = operationsService
            Task { @MainActor in
                do {
                    try await ops.renameEntryInArchive(
                        item, archivePath: archivePath, to: trimmed, queueService: queueService)
                    vm.reloadKeepingCursor(preferredName: trimmed)
                } catch {
                    DialogService.shared.showOperationError(
                        title: L("rename.errorTitle"), error: error)
                }
            }
        } else if vm.insideRemote, let session = vm.remoteSession {
            guard remoteSessionIsReady(session) else { return }
            // Remote rename via protocol (RNFR/RNTO for FTP, SSH for SFTP)
            Task { @MainActor in
                do {
                    try await session.fileSystem.rename(at: item.path, to: trimmed)
                    vm.reloadKeepingCursor(preferredName: trimmed)
                } catch {
                    DialogService.shared.showOperationError(
                        title: L("rename.errorTitle"), error: error)
                }
            }
        } else {
            do {
                try operationsService.renameItem(item, to: trimmed)
                vm.reloadKeepingCursor(preferredName: trimmed)
            } catch {
                DialogService.shared.showOperationError(
                    title: L("rename.errorTitle"), error: error)
            }
        }
    }

    func handleView() {
        let vm = splitVC.activePanelViewModel
        // Folders are allowed — viewer shows their contents (folderPreview).
        // Only ".." is blocked because previewing the parent makes no sense.
        guard let item = vm.cursorItem, item.name != ".." else { return }
        performView(item: item, vm: vm)
    }

    /// Single entry point for view (F3, context menu).
    private func performView(item: FileItem, vm: PanelViewModel) {
        openViewerForItem(item)
    }

    private func openViewerForItem(_ item: FileItem) {
        let viewerInPanel = UserDefaults.standard.bool(forKey: "fcxl.viewerInPanel")
        let quickViewMode = UserDefaults.standard.string(forKey: "fcxl.quickViewMode") ?? "native"
        // For folders force our custom viewer — Apple Quick Look on a folder
        // just shows a folder icon (useless), while UnifiedFileViewer renders
        // a folderPreview list of contents with size totals.
        let useNativeQL = !item.isDirectory && (quickViewMode == "native")
        let vm = splitVC.activePanelViewModel

        // Files inside an archive aren't on disk — the viewers extract the file under the
        // cursor to a temp copy themselves (reactively, so preview follows the cursor). The
        // temp dirs are tracked by the service and cleaned up when the user leaves the archive.
        if viewerInPanel {
            // Embedded mode — toggle: open or close
            if splitVC.isViewerEmbedded {
                splitVC.closeEmbeddedViewer()
            } else {
                splitVC.showEmbeddedViewer(viewModel: vm, useNativeQL: useNativeQL, operations: operationsService)
            }
        } else if useNativeQL {
            openSystemQuickLook(vm: vm, item: item)
        } else {
            // Window mode for our custom UnifiedFileViewer (FCXL mode).
            if let wc = viewerWindowController, wc.window?.isVisible == true {
                wc.close()
                viewerWindowController = nil
            } else {
                let onClose: () -> Void = { [weak self] in
                    self?.viewerWindowController?.close()
                    self?.viewerWindowController = nil
                }

                let viewer = UnifiedFileViewer(viewModel: vm, onClose: onClose, operations: operationsService)
                let contentView: NSView = NSHostingView(rootView: viewer)

                // NSPanel with .nonactivatingPanel — doesn't steal keyboard focus
                let viewerPanel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                    styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                    backing: .buffered,
                    defer: false
                )
                // ARC owns this window (a strong reference is kept) — without this flag
                // close() ALSO releases it and the second release crashes (SearchWindow bug).
                viewerPanel.isReleasedWhenClosed = false
                viewerPanel.title = "\(L("button.f3.view")) — \(item.name)"
                viewerPanel.contentView = contentView
                viewerPanel.isFloatingPanel = true
                viewerPanel.hidesOnDeactivate = false
                viewerPanel.becomesKeyOnlyIfNeeded = true
                viewerPanel.center()
                viewerPanel.setFrameAutosaveName("ViewerWindowFrame")

                let wc = NSWindowController(window: viewerPanel)
                wc.showWindow(nil)
                viewerWindowController = wc
                // Return focus to main window
                self.window?.makeKey()
            }
        }
    }

    // MARK: - System QuickLook (file-manager–controlled cursor)

    /// Open / toggle the system QLPreviewPanel showing only the active panel's
    /// current cursor item. Arrow keys / F-keys are forwarded to the file
    /// manager (see previewPanel(_:handle:)) so the cursor moves there;
    /// when the cursor changes we refresh the QL data source.
    private func openSystemQuickLook(vm: PanelViewModel, item: FileItem) {
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible && panel.dataSource === self {
            panel.orderOut(nil)
            return
        }

        quickLookViewModel = vm
        quickLookCurrentURL = quickLookURL(for: item, vm: vm)

        // Re-render QL whenever the panel's cursor moves. objectWillChange
        // fires on any change in PanelViewModel, but we only react when the
        // cursor item's path actually changed (and only while QL is open).
        quickLookCursorObserver = vm.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak vm] _ in
                self?.refreshQuickLookFromCursor(vm: vm)
            }

        window?.makeFirstResponder(self)
        panel.makeKeyAndOrderFront(nil)
    }

    private func refreshQuickLookFromCursor(vm: PanelViewModel?) {
        guard let vm,
              let cursor = vm.cursorItem,
              cursor.name != ".." else { return }
        let newURL = quickLookURL(for: cursor, vm: vm)
        guard newURL != quickLookCurrentURL else { return }
        quickLookCurrentURL = newURL
        let panel = QLPreviewPanel.shared()
        guard panel?.isVisible == true, panel?.dataSource === self else { return }
        panel?.reloadData()
    }

    /// Disk URL to preview for `item`: inside an archive the entry is extracted to a temp file
    /// (so system Quick Look follows the cursor through the archive too); outside, the real path.
    private func quickLookURL(for item: FileItem, vm: PanelViewModel) -> URL? {
        if vm.insideArchive {
            guard !item.isDirectory, item.name != "..",
                  let archivePath = vm.archivePath,
                  let temp = operationsService.extractArchiveEntryForPreview(
                    archivePath: archivePath, entryPath: item.path) else { return nil }
            return URL(fileURLWithPath: temp)
        }
        return URL(fileURLWithPath: item.path)
    }

    func handleEdit() {
        let vm = splitVC.activePanelViewModel
        guard let item = vm.cursorItem, item.name != "..", !item.isDirectory else { return }
        performEdit(item: item, vm: vm)
    }

    /// Single entry point for edit (F4, context menu).
    private func performEdit(item: FileItem, vm: PanelViewModel) {
        let editorInPanel = UserDefaults.standard.bool(forKey: "fcxl.editorInPanel")

        // Toggle: F4 while the panel editor is open closes it through the save-aware
        // handler (never tear it down directly). Check this BEFORE extracting, so a
        // toggle-close doesn't create an unused temp dir.
        if editorInPanel, splitVC.isEditorEmbedded {
            NotificationCenter.default.post(name: .fcxlRequestEditorClose, object: nil)
            return
        }
        openEditor(for: item, vm: vm)
    }

    /// The editor road without F4's toggle: a file that was just created must open, whatever
    /// the panel editor is showing at the moment.
    private func openEditor(for item: FileItem, vm: PanelViewModel) {
        let editorInPanel = UserDefaults.standard.bool(forKey: "fcxl.editorInPanel")
        let road = FileOperationsService.editorRoad(
            externalConfigured: FileOperationsService.externalEditorPath != nil,
            editorInPanel: editorInPanel, insideArchive: vm.insideArchive)

        switch road {
        case .external:
            // Служба сама отдаст файл назначенной программе.
            operationsService.openEditor(for: item, archivePath: vm.archivePath,
                                         insideArchive: vm.insideArchive)
        case .embedded:
            // RTF → native rich-text editor (Monaco is plain-text only, would show raw markup).
            // Local files for now; RTF inside an archive still goes through the Monaco path.
            let ext = (item.name as NSString).pathExtension.lowercased()
            if (ext == "rtf" || ext == "rtfd"), !vm.insideArchive {
                splitVC.showEmbeddedRTFEditor(filePath: item.path)
                return
            }
            // Extract from the archive if needed, then open in the panel — archives included,
            // so the "editor in panel" setting is honoured for them too.
            guard let target = operationsService.prepareEditorTarget(
                for: item, archivePath: vm.archivePath, insideArchive: vm.insideArchive
            ) else { return }
            splitVC.showEmbeddedEditor(
                filePath: target.path, source: target.source, operations: operationsService)
        case .window:
            operationsService.openEditor(
                for: item,
                archivePath: vm.archivePath,
                insideArchive: vm.insideArchive
            )
        }
    }

    func handleCopy() {
        performFileOperation(isCopy: true)
    }

    func handleMove() {
        performFileOperation(isCopy: false)
    }

    func handleMkdir() {
        let vm = splitVC.activePanelViewModel
        performMkdir(vm: vm)
    }

    /// Single entry point for directory creation (F7, context menu, toolbar).
    /// Runloop callout so the FCXLDialog's input isn't starved when invoked from a
    /// parked main queue (SwiftUI context menu).
    private func performMkdir(vm: PanelViewModel) {
        fcxlPresentModal { [weak self] in self?.performMkdirNow(vm: vm) }
    }

    private func performMkdirNow(vm: PanelViewModel) {
        // Creating an empty folder inside an archive isn't supported — most
        // archive formats don't store standalone empty directories.
        guard !vm.insideArchive else {
            DialogService.shared.showWarning(
                title: L("mkdir.title"),
                message: L("archive.mkdir.unsupported")
            )
            return
        }

        guard let folderName = DialogService.shared.showTextInput(
            title: L("mkdir.title"),
            message: L("mkdir.message"),
            defaultValue: "",
            confirmButtonTitle: L("mkdir.create")
        ) else { return }

        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Курсор — на первое звено: «toys/alsde/dk» создаёт цепочку, а в этой папке
        // появляется только «toys».
        let cursorName = FileOperationsService.folderComponents(of: trimmed).first ?? trimmed

        if vm.insideRemote, let session = vm.remoteSession {
            guard remoteSessionIsReady(session) else { return }
            Task { @MainActor in
                do {
                    try await remoteTransferService.createRemoteDirectory(
                        name: trimmed, at: vm.currentPath, session: session)
                    vm.reloadKeepingCursor(preferredName: trimmed)
                } catch {
                    DialogService.shared.showOperationError(
                        title: L("mkdir.errorTitle"), error: error)
                }
            }
        } else {
            Task { @MainActor in
                do {
                    try operationsService.createDirectory(at: vm.currentPath, name: trimmed)
                    vm.reloadKeepingCursor(preferredName: cursorName)
                } catch let nsError as NSError
                    where nsError.domain == "FileOperationsService" && nsError.code == -100 {
                    // Read-only NTFS volume — create the folder via libntfs-3g
                    // (unmount → mkdir → remount), same as copy/move to NTFS.
                    do {
                        try await operationsService.createDirectoryOnNTFS(
                            at: vm.currentPath, name: trimmed)
                        vm.reloadKeepingCursor(preferredName: trimmed)
                        // The volume remounts asynchronously after the op — reload
                        // once more shortly in case it wasn't ready above.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            vm.reloadKeepingCursor(preferredName: trimmed)
                        }
                    } catch {
                        DialogService.shared.showOperationError(
                            title: L("mkdir.errorTitle"), error: error)
                    }
                } catch {
                    DialogService.shared.showOperationError(
                        title: L("mkdir.errorTitle"), error: error)
                }
            }
        }
    }

    func handleDelete() {
        let vm = splitVC.activePanelViewModel
        let items = selectedOrCursorItems(in: vm)
        guard !items.isEmpty else { return }
        performDelete(items: items, vm: vm)
    }

    /// Single entry point for delete (F8, Shift+Del, context menu).
    /// Runloop callout so the confirmation's FCXLDialog buttons work even when the delete
    /// is triggered from a SwiftUI context menu (which parks the main queue).
    ///
    /// `permanently` bypasses the Trash on local disks. Everywhere deletion is ALREADY
    /// permanent by nature — archives, remote panels, NTFS — both flavours do the same thing,
    /// so Shift changes nothing there rather than pretending to.
    private func performDelete(items: [FileItem], vm: PanelViewModel, permanently: Bool = false) {
        // Nothing to delete — e.g. the cursor is on ".." with no selection, so the panel
        // handed us an empty list. Bail before showing an empty confirmation dialog.
        guard !items.isEmpty else { return }

        // Хранилища запираются перед удалением, и там есть ожидание — оно не должно
        // замораживать окно. Обычные файлы идут прежней короткой дорогой.
        let vaults = items.filter { VaultService.isVault($0.path) }
        guard !vaults.isEmpty else {
            fcxlPresentModal { [weak self] in
                self?.performDeleteNow(items: items, vm: vm, permanently: permanently)
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self, await self.lockVaultsBeforeDelete(vaults) else { return }
            fcxlPresentModal { [weak self] in
                self?.performDeleteNow(items: items, vm: vm, permanently: permanently)
            }
        }
    }

    /// A vault goes to the Trash like any file — but never out from under its own mounted
    /// volume: an OPEN one is locked first, and if the lock refuses (a file inside is still
    /// open somewhere), the delete stops rather than tearing the image away from macOS.
    /// The remembered password goes with the vault; an orphaned key opens nothing.
    /// - Returns: false, если человек передумал или запереть не удалось.
    private func lockVaultsBeforeDelete(_ items: [FileItem]) async -> Bool {
        for item in items {
            if VaultService.isUnlocked(item.path) {
                do {
                    // Off the main thread, or diskarbitrationd waits 14 s for THIS app's
                    // answer while this thread waits for hdiutil (see lockOffMain).
                    try await VaultService.lockOffMain(item.path)
                } catch {
                    // Something inside is still open. The choice belongs to the person: tear
                    // the volume away anyway (the open program loses its file — said plainly),
                    // or leave everything as it is.
                    let close = DialogService.shared.showDestructiveConfirmation(
                        title: L("vault.lock.title"),
                        message: String(format: L("vault.delete.busy"),
                                        (item.path as NSString).lastPathComponent),
                        confirmTitle: L("vault.delete.closeAndDelete"),
                        icon: "lock.trianglebadge.exclamationmark", iconColor: .orange)
                    guard close else { return false }
                    // The same ladder as locking: ask the holders to close their documents by
                    // Apple Events first, then an ordinary lock, and force only what ignored
                    // the request. Ждём асинхронно: окно тем временем живёт.
                    if let mount = VaultService.mountPoint(ofVault: item.path) {
                        let vault = item.path
                        // lsof and osascript (up to 5 s per program) — off the main thread too.
                        await Task.detached(priority: .userInitiated) {
                            VaultService.closeDocuments(under: mount,
                                                        holders: VaultService.holders(ofVault: vault))
                        }.value
                        try? await Task.sleep(nanoseconds: 600_000_000)
                    }
                    do {
                        try await VaultService.lockOffMain(item.path)
                    } catch {
                        do {
                            try await VaultService.lockOffMain(item.path, force: true)
                        } catch {
                            DialogService.shared.showOperationError(title: L("vault.lock.title"),
                                                                    error: error)
                            return false
                        }
                    }
                }
            }
            VaultService.forgetPassword(for: item.path)
        }
        return true
    }

    /// Deleting a PROGRAM is a different job from deleting a file, so F8 forks here.
    ///
    /// Removing a program without its settings, caches and login items is almost never what
    /// was meant — the leftovers outlive the program by years. So a single program (a .app, or
    /// the folder makers like Adobe install one into) opens the uninstall list instead of the
    /// plain confirmation. Nothing is lost by it: the list has the program itself on the first
    /// line, so unticking the rest is exactly the old behaviour.
    ///
    /// The fork is deliberately narrow. Several items at once stay on the plain road, because
    /// the list is about ONE program; and Shift+Delete stays plain too — an erase that skips
    /// the Trash is a deliberate act, not a place to open a new dialog.
    private func uninstallInsteadOfDelete(items: [FileItem], vm: PanelViewModel,
                                          permanently: Bool) -> Bool {
        guard !permanently, items.count == 1, !vm.state.insideTrash, !vm.insideArchive,
              !vm.insideRemote, !vm.state.insideNetworkBrowser, !vm.state.insideStack,
              let item = items.first,
              // Программа, лежащая в папке ВНУТРИ корзины: признак там снят — панель просто
              // просматривает папку, — а искать «хвосты» уже выброшенной программы незачем.
              !TrashService.isInsideTrashFolder(item.path),
              let program = AppUninstaller.programBundle(at: item.path),
              // A copy of THIS program goes like a plain file: its leftovers are ours.
              !AppUninstaller.isOwnProgram(bundleID: Bundle(path: program)?.bundleIdentifier)
        else { return false }
        uninstallApplication(at: item.path)
        return true
    }

    private func performDeleteNow(items: [FileItem], vm: PanelViewModel, permanently requested: Bool) {
        // Deleting from the Trash IS erasing — there is no second trash to move things to, so the
        // red dialog appears whether or not Shift was held.
        let permanently = requested || vm.state.insideTrash
        if uninstallInsteadOfDelete(items: items, vm: vm, permanently: permanently) { return }
        // Deleting a file that is waiting to be pasted makes the pending cut meaningless.
        FileClipboard.invalidate(paths: items.map(\.path))
        // Inside an archive: delete entries from the archive itself. The
        // wrapper shows its own confirmation, so route before the generic one.
        if vm.insideArchive, let archivePath = vm.archivePath {
            // Same rule as rename: the nested temp copy takes edits to the grave.
            guard !vm.isNestedArchive else {
                DialogService.shared.showError(title: L("delete.errorTitle"),
                                               message: L("archive.nested.readOnly"))
                return
            }
            let ops = operationsService
            Task { @MainActor in
                do {
                    try await ops.deleteEntriesFromArchive(
                        items, archivePath: archivePath, queueService: queueService)
                } catch {
                    DialogService.shared.showOperationError(
                        title: L("delete.errorTitle"), error: error)
                }
                vm.reloadKeepingCursor()
            }
            return
        }

        let totalBytes = items.reduce(Int64(0)) { $0 + Int64($1.size) }
        // The red never-skippable dialog only where Shift actually changes the outcome: on a
        // local disk. A remote delete is permanent either way and keeps its usual question.
        if permanently && !vm.insideRemote {
            guard DialogService.shared.showPermanentDeleteConfirmation(
                items: items, totalBytes: totalBytes) else { return }
        } else {
            guard DialogService.shared.showDeleteConfirmation(
                items: items, totalBytes: totalBytes) else { return }
        }

        // Remember the next cursor target BEFORE deleting.
        let deletedPaths = Set(items.map(\.path))
        let nextCursorPath: String?
        if let cursorItem = vm.cursorItem, deletedPaths.contains(cursorItem.path) {
            let cursorIdx = vm.cursorIndex
            let allItems = vm.items
            // Look forward for first surviving item
            var found: String?
            for i in (cursorIdx + 1)..<allItems.count {
                if !deletedPaths.contains(allItems[i].path) {
                    found = allItems[i].path
                    break
                }
            }
            // Nothing forward — look backward
            if found == nil {
                for i in stride(from: cursorIdx - 1, through: 0, by: -1) {
                    if !deletedPaths.contains(allItems[i].path) {
                        found = allItems[i].path
                        break
                    }
                }
            }
            nextCursorPath = found
        } else {
            // Cursor not on a deleted item — keep it where it is
            nextCursorPath = vm.cursorItem?.path
        }

        vm.selectedPaths.removeAll()

        if vm.insideRemote, let session = vm.remoteSession {
            guard remoteSessionIsReady(session) else { return }
            // Remote delete via protocol. After completion, reload directory
            // (remote has no FSWatcher — must refresh explicitly).
            remoteTransferService.deleteRemoteItems(items, from: session) {
                vm.removeDeletedItems(deletedPaths, preferredCursorPath: nextCursorPath)
                vm.startRemoteLoad(at: vm.currentPath)
            }
        } else {
            let ops = operationsService
            Task { @MainActor in
                do {
                    if permanently {
                        try await ops.deleteItemsPermanently(items)
                    } else {
                        try await ops.trashItems(items)
                    }
                } catch {
                    DialogService.shared.showOperationError(
                        title: L("delete.errorTitle"), error: error)
                }
                // Immediately remove deleted items from display instead of
                // full loadDirectory, which causes Phase 1 (names-only) flicker
                // when sorted by date. FSWatcher refreshes from disk in ~300ms.
                if vm.state.insideTrash {
                    // No FSWatcher runs on the Trash view: reread it or the row would linger.
                    vm.loadTrashDirectory()
                } else {
                    vm.removeDeletedItems(deletedPaths, preferredCursorPath: nextCursorPath)
                }
            }
        }
    }

    /// Public entry point for F9 search — called from PanelViewController F-key handler.
    func triggerSearch() { handleSearch() }

    private func handleSearch() {
        let vm = splitVC.activePanelViewModel
        let dstVM = splitVC.inactivePanelViewModel
        let ops = operationsService

        AdvancedSearchPanelController.shared.show(
            rootPath: vm.currentPath,
            onNavigate: { [weak self] path in
                // Show the found item: open its folder in the active panel AND put
                // the cursor right on it (the search window closes so it's visible).
                let dirPath = (path as NSString).deletingLastPathComponent
                self?.splitVC.activePanelViewModel.loadDirectory(
                    at: dirPath, preferredCursorPath: path)
            },
            onCopy: { paths, destination in
                // Results usually live in SUBFOLDERS — build items from their full
                // paths (looking them up in the panel's current listing found nothing).
                let items = paths.compactMap { FileItem.fromPath($0) }
                guard !items.isEmpty else { return }
                Task { @MainActor [weak self] in
                    do {
                        // queueService, like every other copy gesture: it is what enables the
                        // "send to background queue" button inside the transfer.
                        try await ops.copyItems(items, to: destination,
                                                queueService: self?.queueService)
                    } catch {
                        DialogService.shared.showOperationError(title: L("copy.errorTitle"),
                                                       error: error)
                    }
                    vm.loadDirectory(resetCursor: false)
                    dstVM.loadDirectory(resetCursor: false)
                }
            },
            onDelete: { paths in
                let items = paths.compactMap { FileItem.fromPath($0) }
                guard !items.isEmpty else { return }
                Task { @MainActor in
                    do {
                        try await ops.trashItems(items)
                        // Out of the results only when they really left the disk — dropping the
                        // rows on a failed delete showed files as gone while they still existed.
                        AdvancedSearchPanelController.shared.removeFromResults(paths)
                    } catch {
                        DialogService.shared.showOperationError(title: L("delete.errorTitle"),
                                                       error: error)
                    }
                    vm.loadDirectory(resetCursor: false)
                }
            }
        )
    }

    // MARK: - Network

    func disconnectAllRemoteSessions() {
        if splitVC.leftPanelVM.insideRemote { splitVC.leftPanelVM.exitRemote() }
        if splitVC.rightPanelVM.insideRemote { splitVC.rightPanelVM.exitRemote() }
    }

    @objc func handleNetworkMenu(_ sender: Any?) { handleNetwork() }

    func handleNetwork() {
        // The connection manager is an FCXLDialog (SwiftUI). Opened synchronously from a
        // SwiftUI Button action (the volume-bar "FTP disk" popover), NSApp.runModal parks
        // the main GCD queue and the dialog's own SwiftUI buttons (Connect / Cancel / Add…)
        // go dead. Enter via a runloop callout so the queue stays free and input works —
        // the same pattern as performTransfer / openPackDialog.
        fcxlPresentModal { [weak self] in self?.handleNetworkNow() }
    }

    private func handleNetworkNow() {
        guard let connection = ConnectionManagerController.shared.showAndConnect() else { return }
        openRemoteConnection(connection, errorTitle: L("network.manager"))
    }

    /// Open a remote connection in the active panel: orange tab, spinner, listing, health probe.
    ///
    /// Every way into a remote comes through here, so a fix to the tab or error handling can
    /// never reach one entry point and miss another.
    private func openRemoteConnection(_ connection: RemoteConnection, errorTitle: String) {
        let session = ConnectionManagerService.shared.createSession(for: connection)
        let vm = splitVC.activePanelViewModel

        // Create orange remote tab
        let tabsVM = splitVC.activePanel == .left ? splitVC.leftTabsVM : splitVC.rightTabsVM
        tabsVM.newRemoteTab(title: session.tabTitle, connectionID: connection.id)

        vm.enterRemote(session: session)

        let tabID = tabsVM.activeTab.id
        tabsVM.beginLoading(tabID, tag: "remote-connect")

        Task { @MainActor in
            do {
                try await session.connect()
                // Прямо путь сессии, а не vm.loadDirectory(): та читает currentPath, а его
                // могло затереть местное чтение, докатившееся за время подключения.
                vm.startRemoteLoad(at: session.currentRemotePath)
                // Wait for remote listing to complete, then clear loading spinner
                await vm.remoteLoadTask?.value
                tabsVM.endLoading(tabID, tag: "remote-connect")
                // Background health check — warn user about server issues
                Task.detached(priority: .utility) {
                    await Self.checkRemoteHealth(session: session)
                }
            } catch {
                tabsVM.endLoading(tabID, tag: "remote-connect")
                vm.exitRemote()
                tabsVM.closeRemoteTabs()
                // Сервер не принял имя или пароль — спрашиваем их в нашем окне и пробуем ещё
                // раз. Раньше здесь был тупик: окно с английскими словами libcurl и пустая
                // панель, а сменить пароль можно было только через менеджер подключений.
                guard RemoteLogin.asksAgain(after: error),
                      RemoteLogin.canAskAgain(connection.proto) else {
                    DialogService.shared.showOperationError(title: errorTitle, error: error)
                    return
                }
                self.askLoginAndRetry(connection, reason: error, errorTitle: errorTitle)
            }
        }
    }

    /// Спросить имя и пароль в нашем окне и попробовать снова. Отказ человека — конец
    /// истории: он уже видел, что ответил сервер, второе окно с той же новостью ни к чему.
    private func askLoginAndRetry(_ connection: RemoteConnection, reason: Error,
                                  errorTitle: String) {
        // Через runloop, как и остальные наши модальные окна: NSApp.runModal из занятой
        // главной очереди оставляет кнопки диалога мёртвыми.
        fcxlPresentModal { [weak self] in
            guard let self else { return }
            guard let answer = NetworkAuthDialog.ask(
                server: connection.host.isEmpty ? connection.displayAddress : connection.host,
                share: nil,
                suggestedAccount: connection.username.isEmpty
                    ? NetworkAuthDialog.defaultAccount : connection.username,
                rejection: .credentials,
                explanation: reason.localizedDescription)
            else { return }

            let (updated, password) = RemoteLogin.applying(
                account: answer.account, password: answer.password,
                asGuest: answer.asGuest, to: connection)
            if updated.username != connection.username {
                ConnectionManagerService.shared.updateConnection(updated)
            }
            if answer.remember {
                ConnectionManagerService.shared.setPassword(password, for: updated.id)
            } else {
                ConnectionManagerService.shared.useOnce(password, for: updated.id)
            }
            self.openRemoteConnection(updated, errorTitle: errorTitle)
        }
    }

    private static func checkRemoteHealth(session: RemoteSession) async {
        var warnings: [String] = []

        // 1. Test directory listing (checks passive mode / data channel)
        do {
            _ = try await session.fileSystem.listDirectory(at: session.connection.initialPath.isEmpty ? "/" : session.connection.initialPath)
        } catch {
            warnings.append(L("network.health.listFailed"))
        }

        // 2. Test write access — try to create and delete a temp file
        let testDir = session.connection.initialPath.isEmpty ? "/" : session.connection.initialPath
        let testFileName = ".fcxl_write_test_\(UUID().uuidString.prefix(8))"
        let testPath = testDir.hasSuffix("/") ? testDir + testFileName : testDir + "/" + testFileName
        // Пробный файл — настоящий и пустой. Раньше источником служил /dev/null, а это
        // не файл, а устройство: rclone копировать устройства отказывается — и проверка
        // объявляла Google Drive «только для чтения», хотя загрузка туда прекрасно
        // работала. Человек читал «можно туда не пытаться что-нибудь скопировать» про
        // сервер, куда копировалось всё.
        let probeSource = NSTemporaryDirectory() + testFileName
        FileManager.default.createFile(atPath: probeSource, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: probeSource) }
        do {
            try await session.fileSystem.upload(
                localPath: probeSource, to: testPath
            ) { _, _ in false }
            // Upload succeeded — try to clean up
            try? await session.fileSystem.deleteItem(at: testPath, isDirectory: false)
        } catch {
            warnings.append(L("network.health.readOnly"))
        }

        // 3. Probe parallel-transfer support: open a SECOND connection while this one is open.
        //    Accepted → parallel transfers work; refused → the server allows one connection at a time.
        //    ONLY for FTP/SFTP, which have real per-session connections. An SMB "session" is just
        //    the shared macOS mount — a probe connect returns the SAME mount and its disconnect
        //    would `diskutil unmount` the share out from under the panel that is browsing it.
        //    WebDAV is stateless HTTP, so there is nothing to probe.
        switch session.connection.proto {
        case .ftp, .ftps, .sftp:
            let probe = await MainActor.run {
                ConnectionManagerService.shared.createSession(for: session.connection)
            }
            var parallelOK = true
            do {
                try await probe.fileSystem.connect()
                probe.fileSystem.disconnect()
            } catch {
                parallelOK = false
            }
            await MainActor.run {
                ConnectionManagerService.shared.setParallelSupport(parallelOK, for: session.connection.id)
            }
            // Inform the user ONCE only when the server is single-connection (transfers go serial).
            // Parallel-capable servers stay silent — that is the good default, no need to interrupt.
            if !parallelOK { warnings.append(L("network.health.serialOnly")) }
        case .smb, .webdav, .webdavs, .s3, .rclone:
            // no separate connection to probe — see comment above. For rclone there is one
            // helper process for every remote at once, and it does its own parallelism.
            break
        }

        guard !warnings.isEmpty else { return }
        await MainActor.run {
            DialogService.shared.showWarning(
                title: L("network.health.title"),
                message: warnings.joined(separator: "\n")
            )
        }
    }

    // MARK: - Terminal

    private func handleTerminal() {
        // If ANY terminal is already open anywhere — close it and return
        if closeAnyOpenTerminal() { return }

        // No terminal open — open one according to the setting
        let terminalPlacement = UserDefaults.standard.string(forKey: "terminalPlacement") ?? "ask"

        switch terminalPlacement {
        case "bottom":
            handleTerminalBottom()
        case "activePanel":
            handleTerminalActive()
        case "leftPanel":
            handleTerminalInPanel(.left)
        case "rightPanel":
            handleTerminalInPanel(.right)
        default:
            // "ask" — показать меню выбора размещения
            showTerminalPlacementMenu()
        }
    }

    /// Check all places where a terminal can be open, close the first one found.
    /// Returns true if a terminal was closed.
    private func closeAnyOpenTerminal() -> Bool {
        // 1. Bottom terminal
        if let containerVC = window?.contentViewController as? MainContainerViewController,
           containerVC.isBottomTerminalVisible {
            containerVC.hideBottomTerminal()
            return true
        }

        // 2. Terminal tab in left panel
        if let idx = splitVC.leftTabsVM.tabs.firstIndex(where: { $0.isTerminal }) {
            splitVC.leftPanelVC.closeTerminalTab(at: idx)
            return true
        }

        // 3. Terminal tab in right panel
        if let idx = splitVC.rightTabsVM.tabs.firstIndex(where: { $0.isTerminal }) {
            splitVC.rightPanelVC.closeTerminalTab(at: idx)
            return true
        }

        return false
    }

    private func showTerminalPlacementMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: L("settings.terminalPlacement.bottom"),
                     action: #selector(terminalMenuBottom), keyEquivalent: "")
        menu.addItem(withTitle: L("settings.terminalPlacement.activePanel"),
                     action: #selector(terminalMenuActive), keyEquivalent: "")
        menu.addItem(withTitle: L("settings.terminalPlacement.leftPanel"),
                     action: #selector(terminalMenuLeft), keyEquivalent: "")
        menu.addItem(withTitle: L("settings.terminalPlacement.rightPanel"),
                     action: #selector(terminalMenuRight), keyEquivalent: "")
        for item in menu.items { item.target = self }

        // Show at mouse location or center of window
        let pos = window?.mouseLocationOutsideOfEventStream ?? .zero
        menu.popUp(positioning: nil, at: pos, in: window?.contentView)
    }

    @objc private func terminalMenuBottom()  { handleTerminalBottom() }
    @objc private func terminalMenuActive() { handleTerminalActive() }
    @objc private func terminalMenuLeft()   { handleTerminalInPanel(.left) }
    @objc private func terminalMenuRight()  { handleTerminalInPanel(.right) }

    private func handleTerminalBottom() {
        guard let containerVC = window?.contentViewController as? MainContainerViewController else { return }
        containerVC.toggleBottomTerminal(directory: splitVC.activePanelViewModel.currentPath)
    }

    func handleTerminalShortcut() { handleTerminal() }

    private func handleTerminalActive() {
        let isLeft = splitVC.activePanel == .left
        openTerminalAsTab(in: isLeft ? splitVC.leftTabsVM : splitVC.rightTabsVM,
                          panelVM: isLeft ? splitVC.leftPanelVM : splitVC.rightPanelVM)
    }

    private func handleTerminalInPanel(_ side: MainSplitViewController.PanelSide) {
        switch side {
        case .left:
            openTerminalAsTab(in: splitVC.leftTabsVM, panelVM: splitVC.leftPanelVM)
        case .right:
            openTerminalAsTab(in: splitVC.rightTabsVM, panelVM: splitVC.rightPanelVM)
        }
    }

    private func openTerminalAsTab(in tabsVM: PanelTabsViewModel, panelVM: PanelViewModel) {
        let panelVC = tabsVM === splitVC.leftTabsVM ? splitVC.leftPanelVC! : splitVC.rightPanelVC!
        if tabsVM.activeTab.isTerminal {
            // Toggle OFF: close terminal tab, kill process, switch to files
            let idx = tabsVM.activeIndex
            panelVC.closeTerminalTab(at: idx)
        } else {
            // Toggle ON: create new terminal tab
            tabsVM.newTerminalTab(directory: panelVM.currentPath)
            panelVC.activateCurrentTab()
        }
    }

    // MARK: - File Operations Helpers

    private func performFileOperation(isCopy: Bool) {
        let srcVM = splitVC.activePanelViewModel
        let items = selectedOrCursorItems(in: srcVM)
        guard !items.isEmpty else { return }
        performTransfer(items: items, sourceVM: srcVM, isCopy: isCopy)
    }

    // MARK: - Unified Transfer (Copy / Move)

    /// Single entry point for ALL copy and move operations in the app.
    /// Called from: F5/F6, toolbar buttons, context menu, drag-and-drop (all view modes).
    ///
    /// - Parameters:
    ///   - items: files to copy/move
    ///   - sourceVM: ViewModel of the panel that owns the source files
    ///   - isCopy: true = copy, false = move
    ///   - destination: explicit destination path (skip dialog). nil = show dialog.
    /// `skipConfirmation` is for Paste: the destination was already chosen by standing in the
    /// folder, so asking "where to?" is a pointless extra click. Conflicts still prompt —
    /// that dialog lives further down, in the transfer itself.
    private func performTransfer(items: [FileItem],
                                 sourceVM: PanelViewModel,
                                 isCopy: Bool,
                                 destination: String? = nil,
                                 destinationVM: PanelViewModel? = nil,
                                 skipConfirmation: Bool = false) {
        // Escape the caller's context first. Footer/divider buttons and menu items
        // run their handlers as main-QUEUE work; showing the modal dialog inside
        // such a block parks the queue, and the dialog's own SwiftUI buttons (whose
        // actions need the main queue) stop responding. A runloop callout runs with
        // the queue free — the same reason the drag&drop path defers this way.
        RunLoop.main.perform { [weak self] in
            self?.performTransferNow(items: items, sourceVM: sourceVM, isCopy: isCopy,
                                     destination: destination, destinationVM: destinationVM,
                                     skipConfirmation: skipConfirmation)
        }
    }

    private func performTransferNow(items: [FileItem],
                                    sourceVM: PanelViewModel,
                                    isCopy: Bool,
                                    destination: String?,
                                    destinationVM: PanelViewModel?,
                                    skipConfirmation: Bool = false) {
        let dstVM = destinationVM ?? splitVC.inactivePanelViewModel
        let defaultDst = destination ?? dstVM.currentPath
        cplog("[COPY] performTransferNow isCopy=\(isCopy) destinationArg=\(destination ?? "nil") defaultDst=\(defaultDst)")

        // Show dialog (or skip if user disabled confirmation / this is a Paste)
        var resolvedDestination: String
        // F2 in the dialog: put the operation in the queue instead of running it now. Roads
        // the queue cannot carry (remote↔remote, in and out of archives) run directly as
        // before — the queue simply has no such operations to hold.
        var sendToQueue = false
        if skipConfirmation {
            resolvedDestination = defaultDst
        } else {
            guard let result = DialogService.shared.showCopyMoveDialog(
                items: items,
                defaultDestination: defaultDst,
                isCopy: isCopy
            ) else { cplog("[COPY] copy/move dialog CANCELLED"); return }
            resolvedDestination = result.destinationPath
            sendToQueue = result.sendToQueue
        }
        // A drop ONTO a vault's row named the bundle as the folder — and the copy landed among
        // the encrypted bands, where nobody would ever find it. An open vault's drop goes into
        // its volume; a locked one refuses and says why, because copying into a locked safe
        // cannot mean anything.
        if VaultService.isVault(resolvedDestination) {
            guard let volume = VaultService.mountPoint(ofVault: resolvedDestination) else {
                DialogService.shared.showInfo(title: L("vault.unlock.title"),
                                              message: L("vault.drop.locked"))
                return
            }
            resolvedDestination = volume
        }

        cplog("[COPY] resolvedDestination=\(resolvedDestination) srcRemote=\(sourceVM.insideRemote) dstRemote=\(dstVM.insideRemote) srcArchive=\(sourceVM.insideArchive)")

        // Clear the SOURCE panel's selection after moving/copying out of it — but not when the
        // source and destination are the same panel (a local paste into its own folder), where
        // clearing would wipe the selection the user is looking at.
        if sourceVM !== dstVM { sourceVM.selectedPaths.removeAll() }

        // Moving a cut file some other way (F6, drag) leaves the pending paste pointing at a
        // path that no longer holds it. A copy leaves the original in place, so it stays valid.
        if !isCopy { FileClipboard.invalidate(paths: items.map(\.path)) }

        let srcRemote = sourceVM.insideRemote
        let dstRemote = dstVM.insideRemote
        let srcSession = sourceVM.remoteSession
        let dstSession = dstVM.remoteSession
        let rts = remoteTransferService

        // Refuse before starting if either remote side isn't usable yet (still connecting) or
        // has gone dead. Every transfer entry point — F5/F6, toolbar, context menu, drag&drop,
        // paste — funnels through here, so this one check covers them all.
        if srcRemote, !remoteSessionIsReady(srcSession) { return }
        if dstRemote, !remoteSessionIsReady(dstSession) { return }

        let refreshBoth = { [weak self] in
            self?.splitVC.activePanelViewModel.loadDirectory(resetCursor: false)
            self?.splitVC.inactivePanelViewModel.loadDirectory(resetCursor: false)
        }

        let remoteDirectToQueue = UserDefaults.standard.object(forKey: "fcxl.remoteDirectToQueue") as? Bool ?? true

        if sourceVM.insideArchive, let archivePath = sourceVM.archivePath {
            // Moving OUT of a nested archive would delete entries from the temp copy — the
            // extraction half is fine, so the honest offer is: copy yes, move no.
            if !isCopy, sourceVM.isNestedArchive {
                DialogService.shared.showError(title: L("move.errorTitle"),
                                               message: L("archive.nested.readOnly"))
                return
            }
            // ARCHIVE → LOCAL: extract the selected entries out of the archive.
            // Destination must be a plain local folder.
            guard !dstVM.insideArchive, !dstRemote else {
                DialogService.shared.showError(
                    title: isCopy ? L("copy.errorTitle") : L("move.errorTitle"),
                    message: L("archive.extract.unsupportedDest")
                )
                return
            }
            let ops = operationsService
            let extracted = items
            Task { @MainActor in
                do {
                    let actuallyExtracted = try ops.copyItemsFromArchive(
                        extracted, archivePath: archivePath, to: resolvedDestination)
                    // Move (cut) out of an archive = extract then delete the
                    // entries from the archive — but ONLY the entries that were
                    // really extracted. Deleting skipped-on-conflict entries
                    // would remove them from the archive without writing them to
                    // disk (data loss).
                    if !isCopy && !actuallyExtracted.isEmpty {
                        try await ops.deleteEntriesFromArchive(
                            actuallyExtracted, archivePath: archivePath,
                            queueService: queueService)
                    }
                } catch {
                    DialogService.shared.showOperationError(
                        title: isCopy ? L("copy.errorTitle") : L("move.errorTitle"), error: error)
                }
                refreshBoth()
            }
        } else if srcRemote && !dstRemote, let session = srcSession {
            // REMOTE → LOCAL: download
            if remoteDirectToQueue || sendToQueue {
                let params = RemoteTransferParams(
                    connectionID: session.connection.id,
                    connectionLabel: session.connection.label,
                    remotePath: sourceVM.currentPath,
                    localPath: resolvedDestination
                )
                queueService.enqueueRemote(
                    kind: .remoteDownload,
                    items: items,
                    destination: resolvedDestination,
                    remoteParams: params,
                    onCompletion: { refreshBoth() },
                    // Remote source deleted ONLY on success (move) — not on a failed/cancelled op.
                    onSuccess: isCopy ? nil : { [weak self] in
                        self?.remoteTransferService.deleteRemoteItems(items, from: session) { refreshBoth() }
                    }
                )
            } else {
                let totalFiles = items.count
                let title = totalFiles == 1
                    ? L("queue.downloadSingle", items[0].name)
                    : L("queue.downloadMultiple", totalFiles)
                let progressController = DialogService.shared.showProgress(
                    title: title, message: "", cancelHandler: nil)
                let swappable = SwappableProgressReporter(progressController)
                let qs = queueService

                // Run this transfer on its OWN connection so two transfers to the same server go in
                // parallel — pausing one no longer stalls the other or blocks browsing. If the server
                // refuses a second connection, fall back to the shared panel session (serial).
                let xfer = ConnectionManagerService.shared.createSession(for: session.connection)
                var chosen: RemoteSession = session
                var ownsConnection = false
                var deleteWillDisconnect = false

                // Set once the running transfer is adopted into the queue (user clicked "В очередь").
                // The queue does NOT run an adopted transfer itself, so its completion must finalize
                // THAT op — otherwise it sits at 100% "running" forever (nobody marks it completed).
                var adoptedOpID: UUID?
                // The transfer's failure, caught so the ADOPTED op can wear it. Without this
                // the op was closed with no error — a green tick over a file that never
                // arrived, and no continue button anywhere.
                var transferFailure: Error?
                let onComplete: () -> Void = {
                    // Copy (or a failed/cancelled move) frees the dedicated connection here; a
                    // successful move frees it after its source-delete finishes (below).
                    if !deleteWillDisconnect, ownsConnection {
                        chosen.fileSystem.disconnect()
                        ConnectionManagerService.shared
                            .releaseTransferConnection(for: session.connection.id)
                        ownsConnection = false
                    }
                    if let id = adoptedOpID {
                        // Skip an op the user already cancelled from the queue (that path refreshed).
                        if qs.operations.first(where: { $0.id == id })?.isActive == true {
                            // Failed → the row goes red and offers to continue from the .part.
                            qs.markOperationCompleted(id, error: transferFailure)
                        }
                    } else {
                        // Nobody adopted this transfer, so nobody else will say it broke.
                        if let failure = transferFailure {
                            DialogService.shared.showWarning(title: title,
                                                             message: failure.localizedDescription)
                        }
                        refreshBoth()
                    }
                }
                // Delete the remote source ONLY on success (move) — never after a failed or
                // cancelled download, which would lose the still-untransferred files. The delete
                // still needs the connection, so drop it only after the delete completes.
                let onDeleteSources: (() -> Void)? = isCopy ? nil : {
                    deleteWillDisconnect = true
                    rts.deleteRemoteItems(items, from: chosen) {
                        if ownsConnection {
                        chosen.fileSystem.disconnect()
                        ConnectionManagerService.shared
                            .releaseTransferConnection(for: session.connection.id)
                        ownsConnection = false
                    }
                        refreshBoth()
                    }
                }

                let params = RemoteTransferParams(
                    connectionID: session.connection.id,
                    connectionLabel: session.connection.label,
                    remotePath: sourceVM.currentPath,
                    localPath: resolvedDestination
                )
                progressController.onSendToQueue = {
                    let (opID, queueReporter) = qs.adoptRunningOperation(
                        kind: .remoteDownload,
                        items: items,
                        destination: resolvedDestination,
                        remoteParams: params,
                        currentProgress: progressController.lastProgressValue,
                        currentFile: "",
                        bytesDone: progressController.lastBytesDoneValue,
                        bytesTotal: progressController.lastBytesTotalValue,
                        filesDone: progressController.lastFilesDoneValue,
                        filesTotal: progressController.lastFilesTotalValue,
                        // Source deletion is owned by the already-running transfer (started via
                        // rts.download/uploadItems with onSuccess); the queue must not double it.
                        onCompletion: { refreshBoth() }
                    )
                    adoptedOpID = opID
                    swappable.swap(to: queueReporter)
                    return true
                }
                progressController.showSendToQueueButton()

                // Open a dedicated connection (unless the connect-time probe already found the server
                // is single-connection), then start; fall back to the panel session on refusal.
                let parallelOff = ConnectionManagerService.shared.parallelSupport(for: session.connection.id) == false
                Task { @MainActor in
                    if !parallelOff {
                        do {
                            try await xfer.fileSystem.connect()
                            chosen = xfer
                            ownsConnection = true
                            // Make this direct transfer visible to the queue's per-server budget.
                            ConnectionManagerService.shared
                                .retainTransferConnection(for: session.connection.id)
                        } catch {
                            xfer.fileSystem.disconnect()
                            chosen = session   // server refused a 2nd connection → serial on the shared one
                        }
                    }
                    rts.downloadItems(items, from: chosen, to: resolvedDestination,
                                      reporter: swappable, onCompletion: onComplete,
                                      onSuccess: onDeleteSources,
                                      onFailure: { transferFailure = $0 })
                }
            }
        } else if !srcRemote && dstRemote, let session = dstSession {
            // LOCAL → REMOTE: upload
            if remoteDirectToQueue || sendToQueue {
                let params = RemoteTransferParams(
                    connectionID: session.connection.id,
                    connectionLabel: session.connection.label,
                    remotePath: resolvedDestination,
                    localPath: sourceVM.currentPath
                )
                queueService.enqueueRemote(
                    kind: .remoteUpload,
                    items: items,
                    destination: nil,
                    remoteParams: params,
                    onCompletion: { refreshBoth() },
                    // Local sources trashed ONLY on success (move) — not on a failed/cancelled upload.
                    onSuccess: isCopy ? nil : { [weak self] in
                        Task { @MainActor in
                            await self?.operationsService.trashMovedSources(items)
                            refreshBoth()
                        }
                    }
                )
            } else {
                let totalFiles = items.count
                let title = totalFiles == 1
                    ? L("queue.uploadSingle", items[0].name)
                    : L("queue.uploadMultiple", totalFiles)
                let progressController = DialogService.shared.showProgress(
                    title: title, message: "", cancelHandler: nil)
                let swappable = SwappableProgressReporter(progressController)
                let qs = queueService

                // Run this upload on its OWN connection (parallel transfers; pause one, the other
                // keeps going). Fall back to the shared panel session if the server refuses a 2nd one.
                let xfer = ConnectionManagerService.shared.createSession(for: session.connection)
                var chosen: RemoteSession = session
                var ownsConnection = false

                // Set once the running transfer is adopted into the queue (user clicked "В очередь").
                // The queue does NOT run an adopted transfer itself, so its completion must finalize
                // THAT op — otherwise it sits at 100% "running" forever (nobody marks it completed).
                var adoptedOpID: UUID?
                // See the download road: the failure must reach the adopted op, or it closes
                // with a green tick over files that never went anywhere.
                var transferFailure: Error?
                let onComplete: () -> Void = {
                    if ownsConnection {
                        chosen.fileSystem.disconnect()
                        ConnectionManagerService.shared
                            .releaseTransferConnection(for: session.connection.id)
                        ownsConnection = false
                    }
                    if let id = adoptedOpID {
                        // Skip an op the user already cancelled from the queue (that path refreshed).
                        if qs.operations.first(where: { $0.id == id })?.isActive == true {
                            qs.markOperationCompleted(id, error: transferFailure)
                        }
                    } else {
                        if let failure = transferFailure {
                            DialogService.shared.showWarning(title: title,
                                                             message: failure.localizedDescription)
                        }
                        refreshBoth()
                    }
                }
                // Local sources trashed ONLY on success (move) — never after a failed or
                // cancelled upload, which would lose files that never reached the server.
                let onDeleteSources: (() -> Void)? = isCopy ? nil : { [weak self] in
                    Task { @MainActor in
                        await self?.operationsService.trashMovedSources(items)
                        refreshBoth()
                    }
                }

                let params = RemoteTransferParams(
                    connectionID: session.connection.id,
                    connectionLabel: session.connection.label,
                    remotePath: resolvedDestination,
                    localPath: sourceVM.currentPath
                )
                progressController.onSendToQueue = {
                    let (opID, queueReporter) = qs.adoptRunningOperation(
                        kind: .remoteUpload,
                        items: items,
                        destination: nil,
                        remoteParams: params,
                        currentProgress: progressController.lastProgressValue,
                        currentFile: "",
                        bytesDone: progressController.lastBytesDoneValue,
                        bytesTotal: progressController.lastBytesTotalValue,
                        filesDone: progressController.lastFilesDoneValue,
                        filesTotal: progressController.lastFilesTotalValue,
                        // Source deletion is owned by the already-running transfer (started via
                        // rts.download/uploadItems with onSuccess); the queue must not double it.
                        onCompletion: { refreshBoth() }
                    )
                    adoptedOpID = opID
                    swappable.swap(to: queueReporter)
                    return true
                }
                progressController.showSendToQueueButton()

                // Open a dedicated connection (unless the connect-time probe already found the server
                // is single-connection), then start; fall back to the panel session on refusal.
                let parallelOff = ConnectionManagerService.shared.parallelSupport(for: session.connection.id) == false
                Task { @MainActor in
                    if !parallelOff {
                        do {
                            try await xfer.fileSystem.connect()
                            chosen = xfer
                            ownsConnection = true
                            // Make this direct transfer visible to the queue's per-server budget.
                            ConnectionManagerService.shared
                                .retainTransferConnection(for: session.connection.id)
                        } catch {
                            xfer.fileSystem.disconnect()
                            chosen = session   // server refused a 2nd connection → serial on the shared one
                        }
                    }
                    rts.uploadItems(items, to: chosen, remoteDestination: resolvedDestination,
                                    reporter: swappable, onCompletion: onComplete,
                                    onSuccess: onDeleteSources,
                                    onFailure: { transferFailure = $0 })
                }
            }
        } else if srcRemote && dstRemote {
            if let ss = srcSession, let ds = dstSession, ss.id == ds.id {
                // REMOTE → REMOTE (same server)
                if isCopy {
                    rts.copyRemoteItems(items, from: ss, to: ds, remoteDest: resolvedDestination) { refreshBoth() }
                } else {
                    rts.moveRemoteItems(items, on: ss, to: resolvedDestination) { refreshBoth() }
                }
            } else if let ss = srcSession, let ds = dstSession {
                // REMOTE → REMOTE (different servers): copy via temp
                rts.copyRemoteItems(items, from: ss, to: ds, remoteDest: resolvedDestination) { refreshBoth() }
            }
        } else if dstVM.insideArchive, let archivePath = dstVM.archivePath {
            // Adding into a nested archive would grow the temp copy and lose it on exit.
            guard !dstVM.isNestedArchive else {
                DialogService.shared.showError(
                    title: isCopy ? L("copy.errorTitle") : L("move.errorTitle"),
                    message: L("archive.nested.readOnly"))
                return
            }
            // LOCAL → ARCHIVE: add files into the existing archive.
            // Source must be plain local files — adding from inside another
            // archive or from a remote session isn't supported.
            guard !sourceVM.insideArchive, !srcRemote else {
                DialogService.shared.showError(
                    title: isCopy ? L("copy.errorTitle") : L("move.errorTitle"),
                    message: L("archive.add.unsupportedSource")
                )
                return
            }
            let relativePath = dstVM.currentArchiveRelativePath
            let ops = operationsService
            let movedItems = items
            Task { @MainActor in
                do {
                    try await ops.addItemsToArchive(
                        movedItems,
                        archivePath: archivePath,
                        destinationRelativePath: relativePath,
                        queueService: queueService
                    )
                    // Move (cut): trash the sources only after a successful add.
                    if !isCopy {
                        await ops.trashMovedSources(movedItems)
                    }
                } catch {
                    DialogService.shared.showOperationError(
                        title: isCopy ? L("copy.errorTitle") : L("move.errorTitle"), error: error)
                }
                refreshBoth()
            }
        } else {
            // LOCAL → LOCAL: standard copy/move
            cplog("[COPY] LOCAL→LOCAL branch, calling \(isCopy ? "copyItems" : "moveItems") to=\(resolvedDestination)")
            if sendToQueue {
                // The queue's own local executor — same service calls, serial, no modal
                // progress. Exactly what F2 promises: start it and give the hands back.
                queueService.enqueue(kind: isCopy ? .copy : .move,
                                     items: items,
                                     destination: resolvedDestination,
                                     onCompletion: refreshBoth)
                return
            }
            let ops = operationsService
            // Обновление — по НАСТОЯЩЕМУ завершению, через onCompletion: кнопка «В очередь»
            // в окне прогресса отпускает await сразу, и обновление после него заставало
            // папку ещё пустой, а когда файлы ложились, обновить было некому.
            Task { @MainActor in
                do {
                    if isCopy {
                        try await ops.copyItems(items, to: resolvedDestination,
                                                queueService: queueService, onCompletion: refreshBoth)
                    } else {
                        try await ops.moveItems(items, to: resolvedDestination,
                                                queueService: queueService, onCompletion: refreshBoth)
                    }
                } catch {
                    DialogService.shared.showOperationError(
                        title: isCopy ? L("copy.errorTitle") : L("move.errorTitle"), error: error)
                    refreshBoth()
                }
            }
        }
    }

    private func selectedOrCursorItems(in vm: PanelViewModel) -> [FileItem] {
        let selected = vm.items.filter { vm.selectedPaths.contains($0.path) && $0.name != ".." }
        if !selected.isEmpty { return selected }
        if let cursor = vm.cursorItem, cursor.name != ".." { return [cursor] }
        return []
    }

    // MARK: - PanelActionDelegate

    func panelDidRequestCopy(_ panel: PanelViewController, items: [FileItem]) {
        performTransfer(items: items, sourceVM: panel.viewModel, isCopy: true)
    }

    func panelDidRequestMove(_ panel: PanelViewController, items: [FileItem]) {
        performTransfer(items: items, sourceVM: panel.viewModel, isCopy: false)
    }

    func panelDidRequestCopy(_ panel: PanelViewController, items: [FileItem], to destination: String) {
        // For ДД: panel is the DROP TARGET. Source VM is the OTHER panel.
        let sourceVM = sourceVMForDroppedItems(items, dropTarget: panel)
        performTransfer(items: items, sourceVM: sourceVM, isCopy: true,
                        destination: destination, destinationVM: panel.viewModel)
    }

    func panelDidRequestMove(_ panel: PanelViewController, items: [FileItem], to destination: String) {
        let sourceVM = sourceVMForDroppedItems(items, dropTarget: panel)
        performTransfer(items: items, sourceVM: sourceVM, isCopy: false,
                        destination: destination, destinationVM: panel.viewModel)
    }

    /// For ДД: determine which panel owns the dragged items.
    private func sourceVMForDroppedItems(_ items: [FileItem], dropTarget: PanelViewController) -> PanelViewModel {
        let otherVM = dropTarget.viewModel === splitVC.leftPanelVM ? splitVC.rightPanelVM : splitVC.leftPanelVM
        // Check if items belong to the other panel
        if let firstItem = items.first,
           otherVM.items.contains(where: { $0.path == firstItem.path }) {
            return otherVM
        }
        return dropTarget.viewModel
    }

    func panelDidRequestDelete(_ panel: PanelViewController, items: [FileItem]) {
        performDelete(items: items, vm: panel.viewModel)
    }

    func panelDidRequestDeletePermanently(_ panel: PanelViewController, items: [FileItem]) {
        performDelete(items: items, vm: panel.viewModel, permanently: true)
    }

    func panelDidRequestRestoreFromTrash(_ panel: PanelViewController, items: [FileItem]) {
        let vm = panel.viewModel
        guard !items.isEmpty else { return }
        let ops = operationsService
        // Modal from a context menu: same runloop callout every other panel action uses.
        fcxlPresentModal { [weak self] in
            Task { @MainActor in
                do {
                    try await ops.restoreFromTrash(items)
                } catch {
                    DialogService.shared.showError(title: L("trash.title"),
                                                   message: error.localizedDescription)
                }
                vm.loadTrashDirectory()
                // The other panel may be showing the folder things were just restored into.
                self?.refreshBothPanels()
            }
        }
    }

    func panelDidRequestEmptyTrash(_ panel: PanelViewController) {
        let vm = panel.viewModel
        fcxlPresentModal {
            let count = TrashService.entries().count
            guard count > 0 else {
                DialogService.shared.showInfo(title: L("trash.title"),
                                              message: L("trash.alreadyEmpty"))
                return
            }
            let size = ByteText.file(Int64(TrashService.totalSize()))
            guard DialogService.shared.showDestructiveConfirmation(
                title: L("trash.empty"),
                message: L("trash.empty.message", count, size),
                confirmTitle: L("trash.empty.confirm")) else { return }
            let ops = self.operationsService
            Task { @MainActor in
                do {
                    try await ops.emptyTrash()
                } catch {
                    DialogService.shared.showError(title: L("trash.title"),
                                                   message: error.localizedDescription)
                }
                vm.loadTrashDirectory()
            }
        }
    }

    func panelDidRequestMkdir(_ panel: PanelViewController) {
        performMkdir(vm: panel.viewModel)
    }

    func panelDidRequestRename(_ panel: PanelViewController, item: FileItem) {
        performRenameDialog(vm: panel.viewModel, item: item)
    }

    func panelDidRequestInlineRename(_ panel: PanelViewController, item: FileItem, newName: String) {
        executeRename(vm: panel.viewModel, item: item, newName: newName)
    }

    func panelDidRequestMultiRename(_ panel: PanelViewController) {
        openMultiRename(on: panel)
    }

    func panelDidRequestCreateTextFile(_ panel: PanelViewController) {
        performCreateTextFile(vm: panel.viewModel)
    }

    func panelDidRequestPasteFromClipboard(_ panel: PanelViewController) {
        performPasteFromClipboard(vm: panel.viewModel)
    }

    func panelDidRequestNetwork(_ panel: PanelViewController) {
        handleNetwork()
    }

    func panelDidRequestOpenRemote(_ panel: PanelViewController, connection: RemoteConnection) {
        // То же подключение открывается и здесь — своей вкладкой и своей сессией. Одну
        // сессию двум панелям не отдать: у FTP один канал, и второй читатель его сломает.
        splitVC.setActivePanel(panel === splitVC.leftPanelVC ? .left : .right)
        openRemoteConnection(connection, errorTitle: L("network.manager"))
    }

    func panelDidRequestDisconnectRemote(_ panel: PanelViewController, session: RemoteSession) {
        // Как извлечение у хозяина: сессия закрывается в той панели, где живёт.
        for (vm, tabs) in [(splitVC.leftPanelVM, splitVC.leftTabsVM),
                           (splitVC.rightPanelVM, splitVC.rightTabsVM)]
        where vm.remoteSession === session {
            vm.exitRemote()
            tabs.closeRemoteTabs()
            vm.loadDirectory(at: tabs.activeTab.path)
        }
    }

    func panelDidRequestCreateSymlink(_ panel: PanelViewController, item: FileItem) {
        let linkPath = linkDestinationPath(for: item)
        do {
            try operationsService.createSymlink(at: linkPath, pointingTo: item.path)
            splitVC.inactivePanelViewModel.reloadKeepingCursor(
                preferredName: (linkPath as NSString).lastPathComponent)
        } catch {
            DialogService.shared.showError(title: L("context.createSymlink"), message: error.localizedDescription)
        }
    }

    func panelDidRequestCreateAlias(_ panel: PanelViewController, item: FileItem) {
        let linkPath = linkDestinationPath(for: item)
        do {
            try operationsService.createAlias(at: linkPath, pointingTo: item.path)
            splitVC.inactivePanelViewModel.reloadKeepingCursor(
                preferredName: (linkPath as NSString).lastPathComponent)
        } catch {
            DialogService.shared.showError(title: L("context.createAlias"),
                                           message: error.localizedDescription)
        }
    }

    /// Where a new link should go: the other panel, same name. If that name is taken — most
    /// often because BOTH panels are showing the same folder, so the "link" would land on the
    /// file itself — fall back to the app's existing copy-naming rule instead of failing with
    /// "file already exists", which tells the user nothing they can act on.
    private func linkDestinationPath(for item: FileItem) -> String {
        let destDir = splitVC.inactivePanelViewModel.currentPath
        let direct = (destDir as NSString).appendingPathComponent(item.name)
        guard FileManager.default.fileExists(atPath: direct) else { return direct }
        let unique = DialogService.generateCopyName(for: item.name, in: destDir)
        return (destDir as NSString).appendingPathComponent(unique)
    }

    func panelDidRequestCreateHardlink(_ panel: PanelViewController, item: FileItem) {
        let linkPath = linkDestinationPath(for: item)
        do {
            try operationsService.createHardlink(at: linkPath, pointingTo: item.path)
            splitVC.inactivePanelViewModel.reloadKeepingCursor(
                preferredName: (linkPath as NSString).lastPathComponent)
        } catch {
            DialogService.shared.showError(title: L("context.createHardlink"), message: error.localizedDescription)
        }
    }

    /// Single entry point for creating a text file (context menu).
    /// Runloop callout so the FCXLDialog input isn't starved from a parked main queue.
    private func performCreateTextFile(vm: PanelViewModel) {
        fcxlPresentModal { [weak self] in self?.performCreateTextFileNow(vm: vm) }
    }

    /// Total Commander's Shift+F4: ask a name, make the file, open it in the editor.
    /// A name that already exists is simply opened — "edit a new or existing file" is what the
    /// key means there, and an error over a name one just typed helps nobody. The editor is the
    /// same road F4 takes, so the external editor and "editor in the panel" settings hold.
    private func performCreateTextFileNow(vm: PanelViewModel) {
        // The same rule the menu item is enabled by — the F-key reaches here too.
        guard !vm.insideArchive else {
            DialogService.shared.showWarning(title: L("file.create.unavailableTitle"),
                                             message: L("file.create.unavailableMessage"))
            return
        }
        guard let typed = DialogService.shared.showTextInput(
            title: L("file.create.title"),
            message: L("file.create.message"),
            defaultValue: L("file.create.defaultName"),
            confirmButtonTitle: L("file.create.button")
        ) else { return }

        let fileName = FileOperationsService.textFileName(for: typed)
        guard !fileName.isEmpty else { return }
        let path = (vm.currentPath as NSString).appendingPathComponent(fileName)

        if !FileManager.default.fileExists(atPath: path) {
            do {
                try operationsService.createTextFile(at: vm.currentPath, name: fileName)
            } catch {
                DialogService.shared.showOperationError(
                    title: L("file.create.errorTitle"), error: error)
                return
            }
        }
        vm.reloadKeepingCursor(preferredName: fileName)
        guard let item = FileItem.fromPath(path) else { return }
        openEditor(for: item, vm: vm)
    }

    /// Single entry point for pasting files from clipboard (Cmd+V, context menu).
    private func performPasteFromClipboard(vm: PanelViewModel) {
        // A picture copied from anywhere — a browser, a screenshot, our own viewer — becomes a
        // PNG file in this folder. Checked BEFORE the file roads: a copied picture carries no
        // file URL, so those would find nothing and the paste would do nothing at all.
        if FileClipboard.remotePayload == nil, PanelViewController.clipboardFileURLs().isEmpty,
           let picture = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           !vm.insideArchive, !vm.insideRemote, !vm.state.insideNetworkBrowser {
            pastePicture(picture, into: vm)
            return
        }
        // A remote payload (files copied from an FTP/SFTP/WebDAV panel) takes priority while
        // it is still the current clipboard contents. Otherwise fall back to the system
        // pasteboard's local file URLs — which may have come from Finder.
        if let payload = FileClipboard.remotePayload {
            pasteRemotePayload(payload, into: vm)
        } else {
            pasteLocalClipboard(into: vm)
        }
    }

    /// Write a pasted picture into the panel's folder as PNG, under a free name, and put the
    /// cursor on it.
    private func pastePicture(_ picture: NSImage, into vm: PanelViewModel) {
        var rect = CGRect(origin: .zero, size: picture.size)
        guard let source = picture.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        let base = (vm.currentPath as NSString).appendingPathComponent(L("viewer.image.pastedName"))
        let destination = ImageEditor.copyPath(for: base + ".png", format: .png,
                                               suffix: L("viewer.image.copySuffix"))
        do {
            try ImageEditor.write(source, to: destination, format: .png)
            vm.reloadKeepingCursor(preferredName: (destination as NSString).lastPathComponent)
        } catch {
            DialogService.shared.showOperationError(title: L("viewer.image.paste"), error: error)
        }
    }

    /// Local file URLs on the pasteboard → this panel. Either a plain local copy/move, or an
    /// upload when the destination panel is remote.
    private func pasteLocalClipboard(into vm: PanelViewModel) {
        let urls = PanelViewController.clipboardFileURLs()
        guard !urls.isEmpty else { return }
        let items = urls.compactMap { FileItem.fromPath($0.path) }
        guard !items.isEmpty else { return }

        // Cut → move, plain copy → copy. The mark is void as soon as anything else lands on the
        // pasteboard, so a stale one can never turn an unrelated paste into a move.
        let isCut = FileClipboard.isCutPending
        if isCut { FileClipboard.clearCutMark() }

        if vm.insideRemote {
            guard let session = vm.remoteSession else { return }
            uploadPastedItems(items, to: session, remoteDir: vm.currentPath, isCopy: !isCut)
        } else {
            // destinationVM MUST be explicit. performTransfer defaults it to the INACTIVE
            // panel (right for F5/F6, wrong for paste): the clipboard is the source, the
            // destination is the panel being pasted into.
            performTransfer(items: items, sourceVM: vm, isCopy: !isCut,
                            destination: vm.currentPath, destinationVM: vm,
                            skipConfirmation: true)
        }
    }

    /// A remote payload → this panel. Three directions: download (to a local panel), same-server
    /// remote→remote, and — refused for now — cross-server.
    private func pasteRemotePayload(_ payload: FileClipboard.RemotePayload, into vm: PanelViewModel) {
        // The bookmark may have been deleted between copy and paste. Do NOT clear the
        // clipboard yet — only a paste that actually proceeds should consume it.
        guard ConnectionManagerService.shared.connection(for: payload.connectionID) != nil else {
            DialogService.shared.showError(title: L("context.paste"),
                                           message: L("clipboard.remoteGone"))
            return
        }

        let isCut = payload.isCut

        if !vm.insideRemote {
            // A cut is consumed once it is dispatched (matches local behaviour).
            if isCut { FileClipboard.clearCutMark() }
            downloadPastedItems(payload, to: vm.currentPath, isCut: isCut)
            return
        }

        // Destination is remote. Same server → move (rename) or copy; different server is
        // stage 3 and deliberately refused (F6 has no cross-server move either). These guards
        // must run BEFORE the clipboard is cleared, so a refused paste leaves it intact.
        //
        // "Same server" is decided by the actual endpoint (host/port/proto/user), NOT by
        // connection.id: two bookmarks to one physical server have different ids but a rename
        // between them works fine, so they must not be refused as cross-server.
        guard let destSession = vm.remoteSession else { return }
        guard let srcConn = ConnectionManagerService.shared.connection(for: payload.connectionID),
              Self.sameServer(srcConn, destSession.connection) else {
            DialogService.shared.showError(title: L("context.paste"),
                                           message: L("clipboard.crossServerUnsupported"))
            return
        }

        if isCut {
            // Pasting a cut back into its own folder is a no-op; don't touch anything.
            guard payload.sourceDir != vm.currentPath else { FileClipboard.clearCutMark(); return }
            FileClipboard.clearCutMark()
            // Server-side rename — instant, handles folders.
            remoteTransferService.moveRemoteItems(payload.items, on: destSession,
                                                  to: vm.currentPath) { [weak self] in self?.refreshBothPanels() }
        } else {
            // Same-server copy is a temp download+reupload and has no directory recursion yet,
            // so refuse folders with a clear message rather than silently copying nothing.
            if payload.items.contains(where: { $0.isDirectory }) {
                DialogService.shared.showError(title: L("context.copy"),
                                               message: L("clipboard.remoteCopyFolderUnsupported"))
                return
            }
            // Copying into the SAME folder would upload each file back over its own source name,
            // producing a self-conflict dialog and a pointless network round-trip. Refuse it
            // clearly — a duplicate-in-place on a server isn't supported.
            guard payload.sourceDir != vm.currentPath else {
                DialogService.shared.showError(title: L("context.copy"),
                                               message: L("clipboard.remoteCopySameDir"))
                return
            }
            remoteTransferService.copyRemoteItems(payload.items, from: destSession, to: destSession,
                                                  remoteDest: vm.currentPath) { [weak self] in self?.refreshBothPanels() }
        }
    }

    /// Two connections point at the same physical server if their endpoint matches — even when
    /// they are different saved bookmarks (different connection.id).
    private static func sameServer(_ a: RemoteConnection, _ b: RemoteConnection) -> Bool {
        // Compare the EFFECTIVE port, not the stored one: port 0 means "protocol default",
        // so a bookmark saved with an implicit port and one saved with the explicit default
        // (21/22/443) are the same server. Host is matched case-insensitively with any trailing
        // dot trimmed (FQDN forms "host" and "host." are equivalent).
        func normHost(_ h: String) -> String {
            var s = h.lowercased()
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        return a.proto == b.proto
            && normHost(a.host) == normHost(b.host)
            && a.effectivePort == b.effectivePort
            && a.username == b.username
    }

    /// A live, connected session for this server if either panel is currently showing it —
    /// reused instead of opening a fresh connection, which would ignore the per-server
    /// concurrency budget and can be refused by single-connection servers.
    private func liveRemoteSession(for connectionID: UUID) -> RemoteSession? {
        for vm in [splitVC.activePanelViewModel, splitVC.inactivePanelViewModel] {
            if let s = vm.remoteSession, s.connection.id == connectionID, s.isConnected {
                return s
            }
        }
        return nil
    }

    /// REMOTE → LOCAL download of pasted items. Honours fcxl.remoteDirectToQueue like F5/F6.
    private func downloadPastedItems(_ payload: FileClipboard.RemotePayload,
                                     to localDir: String, isCut: Bool) {
        let remoteDirectToQueue = UserDefaults.standard.object(forKey: "fcxl.remoteDirectToQueue") as? Bool ?? true
        let items = payload.items
        let cid = payload.connectionID
        // On a move, delete the sources ONLY after everything arrived. The source session may
        // have gone away since copy, so re-derive a fresh one from the bookmark at delete time.
        let onSuccess: (() -> Void)? = isCut ? { [weak self] in
            self?.deleteRemoteSources(items, connectionID: cid)
        } : nil

        // Direct download (setting off) only when a live session for this server already exists
        // — reusing it respects the connection budget. Otherwise fall through to the queue,
        // whose connectOrDowngrade opens (or serialises) the connection within budget.
        if !remoteDirectToQueue, let session = liveRemoteSession(for: cid) {
            remoteTransferService.downloadItems(
                items, from: session, to: localDir,     // panel session — do NOT disconnect it
                onCompletion: { [weak self] in self?.refreshBothPanels() },
                onSuccess: onSuccess)
            return
        }

        let params = RemoteTransferParams(
            connectionID: cid, connectionLabel: payload.label,
            remotePath: payload.sourceDir, localPath: localDir)
        _ = queueService.enqueueRemote(
            kind: .remoteDownload, items: items, destination: localDir,
            remoteParams: params,
            onCompletion: { [weak self] in self?.refreshBothPanels() },
            onSuccess: onSuccess)
    }

    /// LOCAL → REMOTE upload of pasted items. Honours fcxl.remoteDirectToQueue like F5/F6.
    private func uploadPastedItems(_ items: [FileItem], to session: RemoteSession,
                                   remoteDir: String, isCopy: Bool) {
        let remoteDirectToQueue = UserDefaults.standard.object(forKey: "fcxl.remoteDirectToQueue") as? Bool ?? true
        // On a move, trash the local sources ONLY after a clean upload.
        let onSuccess: (() -> Void)? = isCopy ? nil : { [weak self] in
            Task { @MainActor in
                await self?.operationsService.trashMovedSources(items)
                self?.refreshBothPanels()
            }
        }

        if remoteDirectToQueue {
            let params = RemoteTransferParams(
                connectionID: session.connection.id, connectionLabel: session.connection.label,
                remotePath: remoteDir, localPath: "")
            _ = queueService.enqueueRemote(
                kind: .remoteUpload, items: items, destination: nil,
                remoteParams: params,
                onCompletion: { [weak self] in self?.refreshBothPanels() },
                onSuccess: onSuccess)
        } else {
            // The destination panel's own session is live and connected — use it directly.
            remoteTransferService.uploadItems(
                items, to: session, remoteDestination: remoteDir,
                onCompletion: { [weak self] in self?.refreshBothPanels() },
                onSuccess: onSuccess)
        }
    }

    /// Delete remote sources after a verified-successful remote→local move. Reuses a live panel
    /// session for the server when one exists; otherwise enqueues a delete, whose executor opens
    /// the connection within the per-server budget — never a raw unbudgeted connection.
    private func deleteRemoteSources(_ items: [FileItem], connectionID: UUID) {
        if let session = liveRemoteSession(for: connectionID) {
            remoteTransferService.deleteRemoteItems(items, from: session) { [weak self] in
                self?.refreshBothPanels()       // panel session — do NOT disconnect it
            }
            return
        }
        guard let conn = ConnectionManagerService.shared.connection(for: connectionID) else {
            DialogService.shared.showError(title: L("button.move"),
                                           message: L("clipboard.sourceDeleteFailed"))
            return
        }
        let params = RemoteTransferParams(
            connectionID: connectionID, connectionLabel: conn.label, remotePath: "", localPath: "")
        _ = queueService.enqueueRemote(
            kind: .remoteDelete, items: items, destination: nil,
            remoteParams: params,
            onCompletion: { [weak self] in self?.refreshBothPanels() })
    }

    private func refreshBothPanels() {
        splitVC.activePanelViewModel.loadDirectory(resetCursor: false)
        splitVC.inactivePanelViewModel.loadDirectory(resetCursor: false)
    }

    func panelDidRequestView(_ panel: PanelViewController, item: FileItem) {
        // Folders are allowed — viewer shows their contents.
        performView(item: item, vm: panel.viewModel)
    }

    func panelDidRequestEdit(_ panel: PanelViewController, item: FileItem) {
        guard !item.isDirectory else { return }
        performEdit(item: item, vm: panel.viewModel)
    }

    func panelDidRequestOpenInTerminal(_ panel: PanelViewController, path: String) {
        ExternalTerminal.chosen.open(directory: path)
    }

    func panelDidRequestChangeAttributes(_ panel: PanelViewController, items: [FileItem]) {
        let vm = panel.viewModel
        guard !items.isEmpty, !vm.insideArchive, !vm.insideRemote, !vm.state.insideTrash else { return }
        let ops = operationsService
        // Modal from a context menu: the same runloop callout every other panel action uses.
        fcxlPresentModal { [weak self] in
            guard let self,
                  let changes = DialogService.shared.showChangeAttributesDialog(items: items),
                  !changes.isEmpty else { return }

            let progress = DialogService.shared.showProgress(
                title: L("attributes.progress"), message: "", cancelHandler: nil)
            // Through the protocol on purpose: its isCancelled is nonisolated, and the
            // cancel check runs on the worker thread.
            let cancelProbe: OperationProgressReporter = progress
            let refresh = { [weak self] in
                self?.splitVC.activePanelViewModel.loadDirectory(resetCursor: false)
                self?.splitVC.inactivePanelViewModel.loadDirectory(resetCursor: false)
            }
            Task.detached {
                let failures = ops.changeAttributes(
                    changes, items: items,
                    progress: { done, total, name in
                        Task { @MainActor in
                            progress.update(currentFile: name,
                                            progress: Double(done) / Double(max(total, 1)),
                                            bytesDone: 0, bytesTotal: 0,
                                            filesDone: done, filesTotal: total)
                        }
                    },
                    shouldCancel: { cancelProbe.isCancelled })
                await MainActor.run {
                    progress.close()
                    refresh()
                    if !failures.isEmpty {
                        let shown = failures.prefix(5).map { "• \($0.name): \($0.reason)" }
                            .joined(separator: "\n")
                        DialogService.shared.showWarning(
                            title: L("attributes.partialFail", failures.count),
                            message: shown + (failures.count > 5 ? "\n…" : ""))
                    }
                }
            }
        }
    }

    func panelDidRequestProperties(_ panel: PanelViewController, item: FileItem) {
        showProperties(for: item, viewModel: panel.viewModel)
    }

    func panelDidRequestPack(_ panel: PanelViewController, items: [FileItem]) {
        openPackDialog(items: items, sourceVM: panel.viewModel)
    }

    func panelDidRequestExtract(_ panel: PanelViewController, items: [FileItem]) {
        openExtractDialog(items: items, sourceVM: panel.viewModel)
    }

    func panelDidRequestExtractEntries(_ panel: PanelViewController, entries: [String],
                                       fromArchive archivePath: String, to destination: String) {
        var destination = destination
        // The same rule as the copy funnel: a vault row means the volume, never the bundle.
        if VaultService.isVault(destination) {
            guard let volume = VaultService.mountPoint(ofVault: destination) else {
                DialogService.shared.showInfo(title: L("vault.unlock.title"),
                                              message: L("vault.drop.locked"))
                return
            }
            destination = volume
        }
        // Dropped straight after a mouse drag: open any modal from a runloop callout, or the
        // dialog's buttons never receive input and the trackpad locks up (same reason the
        // copy/move dialog is deferred after a drop).
        fcxlPresentModal { [weak self] in
            self?.extractEntriesNow(entries, fromArchive: archivePath, to: destination, panel: panel)
        }
    }

    private func extractEntriesNow(_ entries: [String], fromArchive archivePath: String,
                                   to destination: String, panel: PanelViewController) {
        // Same promise as F5: never clobber silently. extractArchiveEntry simply writes, so a
        // "skip" answer means not extracting that entry at all.
        var toExtract: [String] = []
        var blanketChoice: ConflictDialogChoice?
        for entry in entries {
            let name = (entry as NSString).lastPathComponent
            let candidate = (destination as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: candidate) else {
                toExtract.append(entry)
                continue
            }
            let choice: ConflictDialogChoice
            if let blanket = blanketChoice {
                choice = blanket
            } else {
                guard let answer = DialogService.shared.showArchiveConflictDialog(fileName: name) else { return }
                choice = answer
                if answer == .replaceAll || answer == .skipAll { blanketChoice = answer }
            }
            switch choice {
            case .replace, .replaceAll: toExtract.append(entry)
            case .skip, .skipAll, .createCopy: break
            }
        }
        guard !toExtract.isEmpty else { return }

        runExtractEntriesAskingForPassword(toExtract, fromArchive: archivePath, to: destination)
    }

    /// The drag-out road, with the password conversation the other extraction roads already
    /// have. The work stays on a background queue — it is a blocking walk over the archive —
    /// and only the QUESTION hops to the main thread; the answer sends the walk out again.
    private func runExtractEntriesAskingForPassword(_ entries: [String],
                                                    fromArchive archivePath: String,
                                                    to destination: String) {
        let ops = operationsService
        let qs = queueService
        // The same window every other file operation puts up. Pulling a few videos out of an
        // archive takes a minute, and this road used to spend it in silence — nothing on screen
        // said the program was working, or let the person stop it.
        let progress = DialogService.shared.showProgress(
            title: L("progress.extracting"),
            message: L("progress.preparing"),
            cancelHandler: { ops.cancelArchiveOperations() })

        // The window is only the FIRST place the progress goes. "To the queue" swaps it for the
        // queue's own reporter and the walk carries on without noticing — the same trick the
        // network transfers use, and the reason this button can exist here at all.
        let reporter = SwappableProgressReporter(progress)
        var params = ArchiveOperationParams()
        params.archivePath = archivePath
        params.entryPaths = entries

        progress.onSendToQueue = { [weak self] in
            let (_, queueReporter) = qs.adoptRunningOperation(
                kind: .archiveExtract,
                items: [],
                destination: destination,
                archiveParams: params,
                currentProgress: progress.lastProgressValue,
                currentFile: "",
                bytesDone: progress.lastBytesDoneValue,
                bytesTotal: progress.lastBytesTotalValue,
                filesDone: progress.lastFilesDoneValue,
                filesTotal: progress.lastFilesTotalValue,
                onCompletion: { self?.forceRefreshBothPanels() })
            reporter.swap(to: queueReporter)
            return true
        }
        progress.showSendToQueueButton()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try ops.extractEntries(
                    entries, fromArchive: archivePath, to: destination,
                    onProgress: { name, fraction, bytesDone, bytesTotal, filesDone, filesTotal in
                        Task { @MainActor in
                            reporter.update(currentFile: name, progress: fraction,
                                            bytesDone: bytesDone, bytesTotal: bytesTotal,
                                            filesDone: filesDone, filesTotal: filesTotal)
                        }
                    },
                    // Polled from the background walk, so it must never wait on the main thread.
                    shouldCancel: { reporter.isCancelled })
                Task { @MainActor in
                    reporter.close()
                    self?.forceRefreshBothPanels()
                }
            } catch where ArchivePasswords.isPasswordFailure(error) {
                Task { @MainActor in
                    // The window goes before the question, or the two modals stack.
                    reporter.close()
                    guard let self else { return }
                    ArchivePasswords.forget(for: archivePath)
                    guard let entered = ArchivePasswords.ask(
                        archiveName: (archivePath as NSString).lastPathComponent) else { return }
                    ArchivePasswords.remember(entered, for: archivePath)
                    self.runExtractEntriesAskingForPassword(entries, fromArchive: archivePath,
                                                            to: destination)
                }
            } catch {
                Task { @MainActor in
                    reporter.close()
                    // showOperationError stays quiet about a cancellation on its own — stopping
                    // on purpose is not a failure to complain about.
                    DialogService.shared.showOperationError(title: L("archive.operationError"),
                                                            error: error)
                    self?.forceRefreshBothPanels()
                }
            }
        }
    }

    // MARK: - Properties

    private func showProperties(for item: FileItem, viewModel: PanelViewModel) {
        if viewModel.insideRemote {
            let sizeText = ByteText.file(Int64(item.size))
            let message = """
            \(L("properties.name")): \(item.name)
            \(L("properties.type")): \(item.isDirectory ? L("properties.type.folder") : L("properties.type.file"))
            \(L("properties.path")): \(item.path)
            \(L("properties.size")): \(sizeText)
            \(L("properties.permissions")): \(item.permissions)
            \(L("properties.owner")): \(item.owner)
            """
            DialogService.shared.showInfo(title: L("context.properties"), message: message)
            return
        }

        if viewModel.insideArchive {
            let sizeText = ByteText.file(Int64(item.size))
            let message = """
            \(L("properties.name")): \(item.name)
            \(L("properties.type")): \(item.isDirectory ? L("properties.type.archiveFolder") : L("properties.type.archiveFile"))
            \(L("properties.pathInArchive")): \(item.path)
            \(L("properties.archive")): \(viewModel.archivePath ?? L("common.notAvailable"))
            \(L("properties.size")): \(sizeText)
            """
            DialogService.shared.showInfo(title: L("context.properties"), message: message)
            return
        }

        let targetPath = item.path
        let fallbackName = item.name
        let ops = operationsService

        // Everything except a folder's recursive size comes from one stat, so the window can open
        // straight away. Summing the contents is what took seconds — it now runs behind the open
        // window and fills its rows in as it counts, the way Finder does it. A progress dialog used
        // to stand in front of the window instead, reporting a hardcoded 15% of "1 byte" that never
        // moved, so the wait had no end the user could see.
        // Runloop escape — same reason as openPackDialog, and it has to stay. The panel's context
        // menu invokes its action synchronously from inside its own NSEvent monitor; starting a
        // modal session there nests a run loop inside event handling and the dialog stops receiving
        // clicks — its buttons go dead and the window cannot be closed.
        RunLoop.main.perform { [weak self] in
            guard let self else { return }
            let properties: FileOperationsService.ItemProperties
            do {
                properties = try ops.properties(path: targetPath, fallbackName: fallbackName,
                                                measuringContents: false)
            } catch {
                DialogService.shared.showOperationError(
                    title: L("properties.readErrorTitle"), error: error)
                return
            }

            let info = FilePropertiesInfo(rows: Self.propertiesInfoRows(properties, contents: nil))
            let cancelled = AtomicFlag()

            if properties.isDirectory {
                DispatchQueue.global(qos: .userInitiated).async {
                    var lastPublished = Date.distantPast
                    let stats = FileOperationsService.directoryStats(
                        path: targetPath,
                        isCancelled: { cancelled.value },
                        progress: { running in
                            // Republishing on every batch would spend the walk's time on redraws.
                            guard Date().timeIntervalSince(lastPublished) > 0.25 else { return }
                            lastPublished = Date()
                            DispatchQueue.main.async {
                                info.rows = Self.propertiesInfoRows(properties, contents: running,
                                                                    stillCounting: true)
                            }
                        })
                    DispatchQueue.main.async {
                        guard !cancelled.value else { return }
                        info.rows = Self.propertiesInfoRows(properties, contents: stats)
                    }
                }
            }

            self.presentPropertiesEditor(properties, info: info, viewModel: viewModel)
            cancelled.value = true  // window closed — stop walking for a number nobody will read
        }
    }

    /// A flag written from the main thread and read by the walk on its own thread.
    private final class AtomicFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return flag }
            set { lock.lock(); flag = newValue; lock.unlock() }
        }
    }

    /// Present the editable properties window for a local item, then apply whatever the user
    /// changed (permissions and/or the hidden flag) and reload the panel so the result shows.
    private func presentPropertiesEditor(_ p: FileOperationsService.ItemProperties,
                                         info: FilePropertiesInfo,
                                         viewModel: PanelViewModel) {
        let input = FilePropertiesInput(
            name: p.name,
            path: p.path,
            isDirectory: p.isDirectory,
            isSymlink: p.isSymlink,
            mode: p.posixMode,
            info: info
        )

        guard let edit = DialogService.shared.showFilePropertiesEditor(input: input) else { return }
        guard edit.newMode != nil else { return }   // nothing touched

        let ops = operationsService
        var errorMessage: String?
        do {
            if let mode = edit.newMode {
                let failures = try ops.setPermissions(mode: mode, atPath: p.path,
                                                       recursive: edit.applyRecursive)
                if failures > 0 { errorMessage = L("properties.permPartialFail", failures) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        // A flipped hidden flag or a folder losing execute changes what the listing shows.
        viewModel.reloadKeepingCursor(preferredName: p.name)

        if let errorMessage {
            DialogService.shared.showError(
                title: L("properties.applyErrorTitle"), message: errorMessage)
        }
    }

    /// The read-only info lines for the properties window — everything except the name (it's the
    /// window title) and the permission string (now edited by the grid, not shown as text).
    /// - Parameters:
    ///   - contents: the folder's measured contents, or nil while the walk has not reported yet.
    ///   - stillCounting: marks the running totals as provisional, so a half-summed folder never
    ///     reads as a finished answer.
    private static func propertiesInfoRows(_ p: FileOperationsService.ItemProperties,
                                           contents: FileOperationsService.DirectoryStats?,
                                           stillCounting: Bool = false)
        -> [FilePropertiesInfoRow] {
        let typeText: String
        if p.isDirectory {
            typeText = p.isSymlink ? L("properties.type.folderSymlink") : L("properties.type.folder")
        } else {
            typeText = p.isSymlink ? L("properties.type.fileSymlink") : L("properties.type.file")
        }
        let directSize = ByteText.file(p.itemSizeBytes)
        // Nothing measured yet says so in full; a running total just trails an ellipsis, so three
        // rows do not all shout "calculating" at once.
        func measured(_ text: @autoclosure () -> String) -> String {
            guard contents != nil else { return L("properties.calculating") }
            return stillCounting ? text() + "…" : text()
        }
        let totalSize = measured(ByteCountFormatter.string(
            fromByteCount: contents?.totalBytes ?? 0, countStyle: .file))
        let df = DateFormatter.fcxlDisplay(date: .medium, time: .medium)
        let modText = p.modifiedDate.map { df.string(from: $0) } ?? L("common.notAvailable")
        let creText = p.createdDate.map { df.string(from: $0) } ?? L("common.notAvailable")

        var rows: [FilePropertiesInfoRow] = [
            FilePropertiesInfoRow(label: L("properties.type"), value: typeText),
            FilePropertiesInfoRow(label: L("properties.path"), value: p.path),
        ]
        if let target = p.symlinkTarget {
            rows.append(FilePropertiesInfoRow(label: L("properties.target"), value: target))
        }
        rows.append(FilePropertiesInfoRow(label: L("properties.size"), value: directSize))
        if p.isDirectory {
            rows.append(FilePropertiesInfoRow(label: L("properties.totalSize"), value: totalSize))
            rows.append(FilePropertiesInfoRow(label: L("properties.filesInside"),
                                              value: measured("\(contents?.filesCount ?? 0)")))
            rows.append(FilePropertiesInfoRow(label: L("properties.foldersInside"),
                                              value: measured("\(contents?.directoriesCount ?? 0)")))
        }
        rows.append(FilePropertiesInfoRow(label: L("properties.modifiedDate"), value: modText))
        rows.append(FilePropertiesInfoRow(label: L("properties.createdDate"), value: creText))
        return rows
    }

    // MARK: - Pack / Extract

    func panelDidRequestPackInPlace(_ panel: PanelViewController, items: [FileItem],
                                    format: ArchiveFormat) {
        packInPlace(items: items, sourceVM: panel.viewModel, format: format)
    }

    /// "Archive here": same packing as F5, but the destination is the folder the cursor is
    /// already in (not the other panel), and the only question asked is the format —
    /// everything else uses the pack dialog's own defaults.
    private func packInPlace(items: [FileItem], sourceVM: PanelViewModel, format: ArchiveFormat) {
        // Runloop escape — a menu handler is main-queue work, and packing puts a progress
        // window up which needs the queue free.
        RunLoop.main.perform { [weak self] in
            self?.packInPlaceNow(items: items, sourceVM: sourceVM, format: format)
        }
    }

    private func packInPlaceNow(items: [FileItem], sourceVM: PanelViewModel, format: ArchiveFormat) {
        guard !items.isEmpty else { return }
        guard !sourceVM.insideRemote else {
            DialogService.shared.showWarning(title: L("pack.unavailableTitle"),
                                             message: L("network.error.operationNotSupported"))
            return
        }
        guard !sourceVM.insideArchive else {
            DialogService.shared.showWarning(title: L("pack.unavailableTitle"),
                                             message: L("pack.unavailableInsideArchive"))
            return
        }

        // Same naming rule as the full dialog: one item → its name, several → the folder's.
        let sourceName = items.count == 1
            ? items[0].name
            : URL(fileURLWithPath: sourceVM.currentPath).lastPathComponent
        let baseName = archiveBaseName(from: sourceName)

        let fileName = PackDialogController.normalizedArchiveName(baseName + ".zip", format: format)
        // THE point of the command: pack where the cursor is.
        let archivePath = (sourceVM.currentPath as NSString).appendingPathComponent(fileName)

        let ops = operationsService
        Task { @MainActor in
            do {
                try await ops.packItems(
                    items,
                    to: archivePath,
                    format: format,
                    compressionLevel: format.defaultCompressionLevel,
                    preservePaths: true,
                    includeSubfolders: true,
                    deleteAfterPack: false,
                    separateArchives: false,
                    queueService: queueService,
                    onCompletion: { [weak self] in self?.forceRefreshBothPanels() }
                )
            } catch {
                DialogService.shared.showOperationError(title: L("archive.operationError"),
                                               error: error)
            }
            forceRefreshBothPanels()
        }
    }

    private func openPackDialog(items: [FileItem], sourceVM: PanelViewModel) {
        // Runloop escape — same reason as performTransfer (menu/button handlers are
        // main-queue work; the modal dialog needs the queue free to stay interactive).
        RunLoop.main.perform { [weak self] in
            self?.openPackDialogNow(items: items, sourceVM: sourceVM)
        }
    }

    private func openPackDialogNow(items: [FileItem], sourceVM: PanelViewModel) {
        guard !sourceVM.insideRemote else {
            DialogService.shared.showWarning(title: L("pack.unavailableTitle"),
                                             message: L("network.error.operationNotSupported"))
            return
        }
        guard !sourceVM.insideArchive else {
            DialogService.shared.showWarning(title: L("pack.unavailableTitle"),
                                             message: L("pack.unavailableInsideArchive"))
            return
        }

        let sourceName: String
        if items.count == 1 {
            sourceName = items[0].name
        } else {
            sourceName = URL(fileURLWithPath: sourceVM.currentPath).lastPathComponent
        }
        let baseName = archiveBaseName(from: sourceName)
        let defaultDestination = splitVC.inactivePanelViewModel.currentPath
        let defaultArchivePath = (defaultDestination as NSString).appendingPathComponent(baseName + ".zip")

        guard let result = DialogService.shared.showArchivePackDialog(
            defaultArchivePath: defaultArchivePath,
            defaultFormat: .zip,
            selectedItemsCount: items.count
        ) else { return }

        let rawPath = result.archivePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return }

        let ops = operationsService
        Task { @MainActor in
            do {
                try await ops.packItems(
                    items,
                    to: rawPath,
                    format: result.format,
                    compressionLevel: result.compressionLevel,
                    preservePaths: result.preservePaths,
                    includeSubfolders: result.includeSubfolders,
                    deleteAfterPack: result.deleteAfterPack,
                    separateArchives: result.separateArchives,
                    password: result.password,
                    queueService: queueService,
                    // Fires when a QUEUED pack finishes — refreshes the panels so a
                    // big archive built in the background still appears on its own.
                    onCompletion: { [weak self] in self?.forceRefreshBothPanels() }
                )
            } catch {
                DialogService.shared.showOperationError(
                    title: L("archive.operationError"), error: error)
            }
            forceRefreshBothPanels()
        }
    }

    private func openExtractDialog(items: [FileItem], sourceVM: PanelViewModel) {
        // Runloop escape — same reason as performTransfer (menu/button handlers are
        // main-queue work; the modal dialog needs the queue free to stay interactive).
        RunLoop.main.perform { [weak self] in
            self?.openExtractDialogNow(items: items, sourceVM: sourceVM)
        }
    }

    private func openExtractDialogNow(items: [FileItem], sourceVM: PanelViewModel) {
        guard !sourceVM.insideRemote else {
            DialogService.shared.showWarning(title: L("unpack.unavailableTitle"),
                                             message: L("network.error.operationNotSupported"))
            return
        }
        guard !sourceVM.insideArchive else {
            DialogService.shared.showWarning(title: L("unpack.unavailableTitle"),
                                             message: L("unpack.unavailableInsideArchive"))
            return
        }
        let archives = items.filter { sourceVM.isArchiveFile($0) }
        guard !archives.isEmpty else { return }

        let defaultDestination = splitVC.inactivePanelViewModel.currentPath
        guard let result = DialogService.shared.showArchiveExtractDialog(
            defaultDestinationPath: defaultDestination,
            createSubfolderDefault: true
        ) else { return }

        let destination = result.destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return }

        let ops = operationsService
        // One dialog for the whole selection, then one operation per archive: unpackArchive
        // handles a single archive by design, so extracting N of them is N queue entries.
        // "Apply to all" spans the whole selection, not just the current archive.
        var blanketChoice: ConflictDialogChoice? = result.overwriteExisting ? .replaceAll : nil
        for archive in archives {
            // Resolve collisions BEFORE extraction: libarchive decides overwrite-vs-skip from
            // one flag at start-up, so it cannot ask per file. We therefore ask up front and
            // then DELETE whatever the user chose to replace — with overwriteExisting:false
            // libarchive skips anything still on disk, so the survivors are exactly the
            // "skip" answers and everything else extracts. Without this the extraction just
            // clobbered existing files without a word.
            let conflicts = ops.existingDestinationPaths(forUnpacking: archive.path,
                                                         to: destination,
                                                         createSubfolder: result.createSubfolder)
            var toReplace: [String] = []
            for conflictPath in conflicts {
                let choice: ConflictDialogChoice
                if let blanket = blanketChoice {
                    choice = blanket
                } else {
                    guard let answer = DialogService.shared.showArchiveConflictDialog(
                        fileName: (conflictPath as NSString).lastPathComponent
                    ) else { return }                       // dialog dismissed = cancel everything
                    choice = answer
                    if answer == .replaceAll || answer == .skipAll { blanketChoice = answer }
                }
                switch choice {
                case .replace, .replaceAll: toReplace.append(conflictPath)
                case .skip, .skipAll, .createCopy: break    // leave it: libarchive skips it
                }
            }
            let replaced = toReplace.compactMap { FileItem.fromPath($0) }

        // Trashed through the service, not removed with FileManager: "Replace" used to delete the
        // old file permanently, and the swallowed failure then let libarchive skip the entry — so
        // "Replace" silently became "keep the old file". Recoverable now, and a failure is voiced.
        // The unpack starts only once the replacements are actually out of the way.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !replaced.isEmpty {
                await self.operationsService.trashMovedSources(replaced)
            }
            self.unpackAskingForPasswordIfNeeded(archive: archive, destination: destination,
                                                 createSubfolder: result.createSubfolder)
        }
        }
    }

    /// The unpack, with the password conversation around it: a protected archive refuses, the
    /// person is asked, the unpack runs again with the answer — and a password that WORKED is
    /// remembered for the session, while one that failed is forgotten and asked afresh rather
    /// than offered again as if it were good.
    private func unpackAskingForPasswordIfNeeded(archive: FileItem, destination: String,
                                                 createSubfolder: Bool) {
        let password = ArchivePasswords.remembered(for: archive.path) ?? ""
        operationsService.unpackArchive(
            at: archive.path,
            to: destination,
            createSubfolder: createSubfolder,
            // Always false: what the user agreed to replace is already gone, so anything
            // still present is a deliberate "skip".
            overwriteExisting: false,
            password: password,
            queueService: queueService
        ) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.forceRefreshBothPanels() }
                guard let error else {
                    ArchivePasswords.remember(password, for: archive.path)
                    return
                }
                guard ArchivePasswords.isPasswordFailure(error) else {
                    DialogService.shared.showOperationError(
                        title: L("archive.operationError"), error: error)
                    return
                }
                ArchivePasswords.forget(for: archive.path)
                guard let entered = ArchivePasswords.ask(archiveName: archive.name) else { return }
                ArchivePasswords.remember(entered, for: archive.path)
                self.unpackAskingForPasswordIfNeeded(archive: archive, destination: destination,
                                                     createSubfolder: createSubfolder)
            }
        }
    }

    /// Force-reloads both panels after an operation. The delayed passes catch
    /// asynchronous filesystem changes — notably an NTFS volume that unmounts
    /// and remounts around a libntfs-3g write (pack / unpack / copy to NTFS),
    /// which isn't visible yet on the immediate reload.
    private func forceRefreshBothPanels() {
        let reload = { [weak self] in
            guard let self else { return }
            self.splitVC.activePanelViewModel.loadDirectory(resetCursor: false)
            self.splitVC.inactivePanelViewModel.loadDirectory(resetCursor: false)
        }
        reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: reload)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: reload)
    }

    private func archiveBaseName(from name: String) -> String {
        // Single source of truth for extension stripping lives in
        // FileOperationsService; only the dialog's 30-char suggestion cap is here.
        return String(operationsService.archiveBaseName(from: name).prefix(30))
    }

    // MARK: - Floating Terminal

    private func openFloatingTerminal(directory: String) {
        if let existing = terminalWindowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let container = SwiftTermContainerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        container.startTerminal(directory: directory)

        let vc = NSViewController()
        vc.view = container

        let termWindow = NSWindow(contentViewController: vc)
        // ARC owns this window (a strong reference is kept) — without this flag
        // close() ALSO releases it and the second release crashes (SearchWindow bug).
        termWindow.isReleasedWhenClosed = false
        termWindow.title = "Terminal — \(URL(fileURLWithPath: directory).lastPathComponent)"
        termWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        termWindow.setContentSize(NSSize(width: 600, height: 400))
        termWindow.center()

        let wc = NSWindowController(window: termWindow)
        wc.showWindow(nil)
        terminalWindowController = wc
    }

    // MARK: - Helpers

    private func makeSeparator() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return view
    }

    // MARK: - Окно при запуске

    /// Рамка окна при запуске: сохранённый размер, место — середина видимой области.
    /// Размер больше экрана (окно когда-то было во весь старый экран) ужимается до 90 %
    /// видимой области, чтобы поля были видны; меньше минимального — растёт до него.
    static func launchFrame(saved: NSRect, visible: NSRect, minimum: NSSize) -> NSRect {
        var size = saved.size
        if size.width > visible.width || size.height > visible.height {
            size = NSSize(width: floor(visible.width * 0.9), height: floor(visible.height * 0.9))
        }
        size.width = min(max(size.width, minimum.width), visible.width)
        size.height = min(max(size.height, minimum.height), visible.height)
        // Начало округляется само по себе: .integral растянул бы рамку на пиксель.
        return NSRect(x: round(visible.midX - size.width / 2), y: round(visible.midY - size.height / 2),
                      width: size.width, height: size.height)
    }

    static func placeAtLaunch(_ window: NSWindow) {
        // Запись старых сборок: окно ставилось по ней ПОСЛЕ центрирования, и рамка с
        // отрицательным началом (окно с прошлого экрана) прижимала его в угол.
        UserDefaults.standard.removeObject(forKey: "windowFrame")
        guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        window.setFrame(launchFrame(saved: window.frame, visible: screen.visibleFrame,
                                    minimum: window.minSize), display: false)
    }

    // MARK: - QLPreviewPanel control

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return quickLookCurrentURL != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        quickLookCurrentURL = nil
        quickLookViewModel = nil
        quickLookCursorObserver?.cancel()
        quickLookCursorObserver = nil
        // Async to give QL a tick to release key window status — without
        // this MainWindowController stays first responder and arrow / F-keys
        // beep until the user clicks somewhere.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeKeyAndOrderFront(nil)
            self.splitVC.activePanelVC.claimFirstResponder()
        }
    }

    /// Backstop for Esc while a panel shows the monitor. `cancelOperation:` walks the responder
    /// chain, and the window controller is its last stop — so this fires even when focus sits
    /// somewhere inside the SwiftUI monitor that leaves the panel out of the chain.
    override func cancelOperation(_ sender: Any?) {
        for vc in [splitVC.leftPanelVC, splitVC.rightPanelVC] where vc?.isMonitorMode == true {
            vc?.toggleMonitor()
            return
        }
        super.cancelOperation(sender)
    }

    /// Give the active panel's file list keyboard focus. Called on launch so the cursor is
    /// live and arrow / F-keys work immediately, without the user having to click a panel first.
    func focusActivePanelList() {
        splitVC.activePanelVC.claimFirstResponder()
    }
}

// MARK: - QLPreviewPanelDataSource / Delegate

extension MainWindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return quickLookCurrentURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        return quickLookCurrentURL as NSURL?
    }

    /// Forward most key events back to the active file-manager panel so the
    /// cursor moves there (and we then refresh the QL via the cursor observer).
    /// Modifier combos (Cmd+C/V/F etc.) and Esc are passed to QL itself so
    /// copy/find inside the preview keeps working.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Cmd / Ctrl combos — let QL handle (Cmd+C copies selected text, etc.)
        if flags.contains(.command) || flags.contains(.control) {
            return false
        }
        // Esc — let QL close itself.
        if event.keyCode == 53 { return false }

        // Anything else — forward to active panel: arrow keys move cursor,
        // Space/F3 toggle viewer, F-keys (rename/copy/move/delete) work too.
        let activePanel = splitVC.activePanelVC
        return activePanel.handleKeyEvent(event)
    }
}

// MARK: - Container View Controller

/// Simple container that stacks NSSplitView + bottom terminal + footer vertically.
final class MainContainerViewController: NSViewController {

    private let splitVC: MainSplitViewController
    private let footerBar: FooterBar
    private var terminalView: SwiftTermContainerView?
    private var terminalHeightConstraint: NSLayoutConstraint?
    private var splitBottomToFooter: NSLayoutConstraint!
    private var splitBottomToDivider: NSLayoutConstraint?
    private var dividerView: NSView?
    private var terminalWrapper: NSView?

    var isBottomTerminalVisible: Bool { terminalView != nil }

    init(splitVC: MainSplitViewController, footerBar: FooterBar) {
        self.splitVC = splitVC
        self.footerBar = footerBar
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))

        addChild(splitVC)
        let splitView = splitVC.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(splitView)

        // Hairline directly UNDER the window titlebar (content starts right below
        // it), separating the title row from the panels.
        let topSeparator = NSView()
        topSeparator.translatesAutoresizingMaskIntoConstraints = false
        topSeparator.wantsLayer = true
        topSeparator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        container.addSubview(topSeparator)

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        container.addSubview(separator)

        let footerHosting = NSHostingView(rootView: footerBar)
        footerHosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footerHosting)

        splitBottomToFooter = splitView.bottomAnchor.constraint(equalTo: separator.topAnchor)

        NSLayoutConstraint.activate([
            topSeparator.topAnchor.constraint(equalTo: container.topAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topSeparator.heightAnchor.constraint(equalToConstant: 1),

            splitView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitBottomToFooter,

            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            footerHosting.topAnchor.constraint(equalTo: separator.bottomAnchor),
            footerHosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerHosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerHosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footerHosting.heightAnchor.constraint(equalToConstant: 29),
        ])

        self.view = container
    }

    // MARK: - Bottom Terminal

    func showBottomTerminal(directory: String) {
        guard terminalView == nil else { return }

        let container = view

        // Draggable divider
        let divider = TerminalDragDivider()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.onDrag = { [weak self] deltaY in
            guard let self, let hc = self.terminalHeightConstraint else { return }
            let newH = max(80, min(hc.constant - deltaY, container.bounds.height - 200))
            hc.constant = newH
        }
        container.addSubview(divider)
        self.dividerView = divider

        // Terminal
        let term = SwiftTermContainerView(frame: .zero)
        term.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(term)
        self.terminalView = term

        // Deactivate old splitView bottom
        splitBottomToFooter.isActive = false

        let splitView = splitVC.view
        let footerTop = container.subviews.first(where: {
            ($0 as? NSHostingView<FooterBar>) != nil
        })!

        // splitView bottom → divider top
        splitBottomToDivider = splitView.bottomAnchor.constraint(equalTo: divider.topAnchor)

        let heightConstraint = term.heightAnchor.constraint(equalToConstant: 200)
        terminalHeightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            splitBottomToDivider!,

            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 5),

            term.topAnchor.constraint(equalTo: divider.bottomAnchor),
            term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            term.bottomAnchor.constraint(equalTo: footerTop.topAnchor, constant: -1),
            heightConstraint,
        ])

        term.startTerminal(directory: directory)
        TerminalProcessRegistry.shared.register(term, for: TerminalProcessRegistry.bottomTerminalID)
    }

    func hideBottomTerminal() {
        guard let term = terminalView else { return }
        TerminalProcessRegistry.shared.terminate(tabID: TerminalProcessRegistry.bottomTerminalID)
        term.removeFromSuperview()
        dividerView?.removeFromSuperview()
        terminalView = nil
        dividerView = nil
        terminalHeightConstraint = nil

        splitBottomToDivider?.isActive = false
        splitBottomToDivider = nil
        splitBottomToFooter.isActive = true
    }

    func toggleBottomTerminal(directory: String) {
        if terminalView != nil {
            hideBottomTerminal()
        } else {
            showBottomTerminal(directory: directory)
        }
    }
}

// MARK: - Draggable Terminal Divider

private final class TerminalDragDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaY)
    }
}
