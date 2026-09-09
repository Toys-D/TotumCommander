import AppKit
import OSLog
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        // Before anything reads a colour: the shipped look answers where nothing is set.
        DefaultStyle.register()
        super.init()
    }


    private var mainWindowController: MainWindowController?
    private var appearanceObserver: NSKeyValueObservation?

    // MARK: - Entry Point

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        setupMainMenu()
        updateQuitKeyEquivalent()
        app.run()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        watchForTermination()
        installHelpShortcut()
        // Once the window is up: say out loud if another program holds any of the panel's
        // F-keys as a global hotkey. Found the hard way — Parallels held F6, and inside this
        // app that looked like a key that does nothing at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            FKeyAvailability.warnIfPanelKeysAreTaken()
        }
        FKeyModeManager.shared.syncOnLaunch()
        FKeyModeManager.shared.installCrashGuard()
        PanelAppearanceSettings.migrateAccentFromTabAccentIfNeeded()
        PanelAppearanceSettings.migrateCursorCustomFlagIfNeeded()
        PanelAppearanceSettings.migratePanelBackgroundPerThemeIfNeeded()
        PanelAppearanceSettings.migrateColorsPerThemeIfNeeded()
        PanelAppearanceSettings.migrateThemedBoolsIfNeeded()
        // Наследство отменённого выбора «быстро или с текстом» для тяжёлых PDF: теперь способ
        // один, и запомненные ответы никому не нужны.
        UserDefaults.standard.removeObject(forKey: "fcxl.pdfFastPaths")
        PanelAppearanceSettings.syncThemedColorsToEffective()   // load this theme's colours
        PanelAppearanceSettings.applyAppearanceMode()
        // Catch SYSTEM appearance changes (when theme = "follow system") so panels
        // swap their per-theme background AND colours live, not only on relaunch.
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated {
                PanelAppearanceSettings.syncThemedColorsToEffective()
                NotificationCenter.default.post(name: .fcxlAppearanceChanged, object: nil)
            }
        }

        let defaults = UserDefaults.standard
        let homePath = NSHomeDirectory()
        let leftPath = defaults.string(forKey: "leftPanelPath") ?? homePath
        let rightPath = defaults.string(forKey: "rightPanelPath") ?? homePath
        let showHidden = defaults.object(forKey: "showHiddenFiles") as? Bool ?? false

        let controller = MainWindowController(
            leftInitialPath: leftPath,
            rightInitialPath: rightPath,
            showHiddenFiles: showHidden
        )
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        mainWindowController = controller
        // As left, a plain window or maximized — the General settings decide.
        if let window = controller.window { WindowLaunchMode.apply(to: window) }
        // The look for a newer release (every three days) — after the window is up and the panels loaded,
        // so it never competes with the launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { UpdateChecker.shared.start() }

        // Keep the Quit item's ⌘Q ownership in sync with the setting toggle
        // (UserDefaults KVO can't observe dotted keys like "fcxl.cmdQToQuit").
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async { Self.updateQuitKeyEquivalent() }
        }

        // NOT `ignoringOtherApps: true`. That flag forces macOS to bring the app forward even when
        // it was launched into the background, and forcing it is what drags the user to whatever
        // desktop the app was last seen on. The polite form lets the system decide, and the main
        // window carries .moveToActiveSpace so activating brings the window to the desktop the user
        // is on instead of switching desktops.
        NSApp.activate()

        // Give the active (left) panel keyboard focus right away so the cursor is visible and
        // arrow / F-keys work on launch without the user first clicking a panel.
        DispatchQueue.main.async { [weak controller] in
            controller?.focusActivePanelList()
        }
    }

    @objc func showCommandPalette(_ sender: Any?) {
        MainActor.assumeIsolated { CommandPaletteController.shared.toggle() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Pause FSEvents watchers to avoid CPU wakeups while in background
        if let controller = mainWindowController {
            controller.pauseFSWatchers()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Resume FSEvents watchers and reload directories
        if let controller = mainWindowController {
            controller.resumeFSWatchers()
            // Coming back — from another app, another desktop, or the Dock — the file list should
            // be ready for the arrow keys straight away, not after a second click into the panel.
            controller.focusActivePanelList()
        }
    }

    /// Помощник rclone обязан уходить и тогда, когда программу снимают снаружи.
    ///
    /// `applicationWillTerminate` при этом не зовут вовсе, и чужой процесс оставался жить —
    /// с ключами от всех хранилищ человека в памяти. Ловим сигнал через источник событий,
    /// а не обработчиком сигнала: в обработчике нельзя почти ничего, а здесь можно всё.
    private var terminationWatch: DispatchSourceSignal?

    private func watchForTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            RcloneDaemon.terminateHelper()
            RemoteFileCache.cleanupAll()
            exit(0)
        }
        source.resume()
        terminationWatch = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The pasteboard outlives the app, but the "these were cut" mark is ours and in-memory.
        // Clear it explicitly so a paste after a restart can never be treated as a move.
        FileClipboard.clearCutMark()
        // Закладки пишутся с задержкой в две секунды, чтобы листание не било по диску.
        // Без этого закладка, поставленная прямо перед выходом, пропадала вместе с окном.
        ReaderMarksStore.shared.flush()
        FileOperationsService.cleanupSendDirectories()
        FKeyModeManager.shared.restoreSystemStateOnExit()
        mainWindowController?.pauseFSWatchers()
        TerminalProcessRegistry.shared.terminateAll()
        NTFSSessionManager.shared.deactivateAllSessions()
        mainWindowController?.disconnectAllRemoteSessions()
        // Помощник rclone — чужой процесс, и сам он не уйдёт. Отключение сессий просит об
        // этом асинхронно, а выход асинхронных задач не дожидается — поэтому здесь прямо
        // и сразу.
        RcloneDaemon.terminateHelper()
        // Копии удалённых файлов, скачанные ради просмотра, сеанс не переживают.
        RemoteFileCache.cleanupAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Cmd+Q

    /// The Quit menu item always calls NSApp.terminate directly — any way of
    /// activating it (mouse click, keyboard menu navigation, VoiceOver) quits.
    /// The "Cmd+Q quits the application" setting instead controls whether the
    /// item OWNS the ⌘Q key equivalent: when disabled, ⌘Q maps to nothing at
    /// all, so an accidental press is a no-op while the menu stays functional.
    private static weak var quitMenuItem: NSMenuItem?

    static func updateQuitKeyEquivalent() {
        let enabled = UserDefaults.standard.object(forKey: "fcxl.cmdQToQuit") as? Bool ?? true
        quitMenuItem?.keyEquivalent = enabled ? "q" : ""
    }

    // MARK: - Settings Window

    private var settingsWindowController: NSWindowController?
    private let settingsSizeGuard = SettingsWindowSizeGuard()

    /// The settings window, for dialogs that need it out of the way while they are open.
    var settingsWindow: NSWindow? { settingsWindowController?.window }

    @objc func showSettingsWindow(_ sender: Any?) {
        if let existing = settingsWindowController, let w = existing.window {
            // Always open centred (it may have been dragged) and grow from centre.
            w.setContentSize(SettingsWindowSizeGuard.minimum)
            SettingsWindowAnimator.centerOnScreen(w)
            SettingsWindowAnimator.growOpen(w)
            restoreSettingsPreview()
            // Modal: blocks the rest of the app until OK/ESC ends the session.
            NSApp.runModal(for: w)
            // The settings preview must not outlive the settings. The window is cached and
            // merely ordered out, so the page's own onDisappear cannot be relied on to fire.
            MainActor.assumeIsolated { ContextPopupMenuController.shared.dismissPreview() }
            return
        }

        let hostingController = NSHostingController(rootView: SettingsRootView())
        // Let AppKit (setContentSize + the animator) own the window size, not the
        // SwiftUI content — so per-section resize is driven by us.
        hostingController.sizingOptions = []
        let window = NSPanel(contentViewController: hostingController)
        window.title = L("settings.title")
        window.styleMask = [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView]
        // Custom chrome: no close/minimize/zoom buttons, clean title bar. The
        // bottom OK button dismisses it. (ESC still closes via cancelOperation.)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.setContentSize(SettingsWindowSizeGuard.minimum)
        // Меньше — нельзя: на узком окне список правил раскраски складывается в кашу.
        // Больше — сколько угодно.
        //
        // Одного `minSize` мало: он держит только руку на краю окна, а программный
        // `setFrame` проходит мимо него насквозь (проверено) — и анимация открытия, которая
        // ставит окно в 70% и растит обратно, спокойно оставляла его меньше минимума.
        // Поэтому ещё и делегат, который правит любой предложенный размер.
        window.minSize = SettingsWindowSizeGuard.minimum
        window.delegate = settingsSizeGuard
        // Build the SwiftUI view graph NOW (synchronously, at full size, before the
        // window is on screen) so the FIRST render doesn't fight the grow animation
        // — otherwise the first open stutters while every animation frame re-lays-out
        // a cold view tree. Subsequent opens reuse this warmed, cached window.
        window.contentView?.layoutSubtreeIfNeeded()
        // True-centre, then grow from the centre (set small BEFORE showing so it
        // appears small and visibly grows — frame grows, content grows with it).
        SettingsWindowAnimator.centerOnScreen(window)
        SettingsWindowAnimator.growOpen(window)

        let wc = NSWindowController(window: window)
        settingsWindowController = wc
        // Modal: blocks the rest of the app until OK/ESC ends the session.
        NSApp.runModal(for: window)
        MainActor.assumeIsolated { ContextPopupMenuController.shared.dismissPreview() }
    }

    /// Окно настроек не рождается заново, а достаётся из кармана: `onAppear` страницы
    /// при повторном открытии не срабатывает — и живой предпросмотр контекстного меню
    /// сам не поднимается, хотя страница открыта та самая. Поднимаем его здесь.
    private func restoreSettingsPreview() {
        guard SettingsSection.wantsContextMenuPreview(
            lastSection: UserDefaults.standard.string(forKey: SettingsSection.lastKey)) else { return }
        mainWindowController?.showContextMenuPreview()
    }

    // MARK: - Help Window

    private var helpWindowController: NSWindowController?
    private var helpKeyMonitor: Any?

    /// Клавиши, за которые не отвечает ни одна панель: справка и громкость.
    ///
    /// Монитор, а не пункт меню: ⌘⇧/ (то самое «⌘?») пункт ловит только когда клавиша даёт
    /// «?», а на русской раскладке она даёт «,» — поэтому сочетание узнаётся по коду клавиши.
    /// Здесь же и F10–F12: наш режим F-клавиш отнял их у системы, и звук возвращаем сами —
    /// по всей программе, а не только в панелях, ведь громкость нужна и в просмотрщике.
    private func installHelpShortcut() {
        helpKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isHelpKeystroke(keyCode: event.keyCode, flags: event.modifierFlags) {
                self?.showHelpWindow(nil)
                return nil
            }
            if let action = VolumeKeys.action(forKeyCode: event.keyCode,
                                              flags: event.modifierFlags) {
                VolumeKeys.perform(action)
                return nil
            }
            return event
        }
    }

    /// Справку открывают F1 — как во всякой программе и как в Total Commander — и «/» (код 44)
    /// с ⌘ и ⇧. И больше ничего: F1 с любым модификатором принадлежит не нам.
    static func isHelpKeystroke(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags.intersection([.command, .shift, .option, .control])
        if keyCode == 122 { return relevant.isEmpty }   // F1
        return keyCode == 44 && relevant == [.command, .shift]
    }

    /// Non-modal on purpose: the point of a manual is to keep it open while working in the app.
    @objc func showHelpWindow(_ sender: Any?) {
        if let existing = helpWindowController, let w = existing.window {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: HelpWindowView())
        let window = NSWindow(contentViewController: hosting)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.title = L("menu.help.guide")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 820, height: 560))
        window.center()
        let wc = NSWindowController(window: window)
        helpWindowController = wc
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Main Menu

    /// Give a menu item an SF Symbol. Template-rendered, so AppKit tints it with the menu's own
    /// text colour and it dims together with the item when validation greys it out.
    private static func icon(_ item: NSMenuItem?, _ symbol: String) {
        guard let item,
              let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        else { return }
        image.isTemplate = true
        // Name it, so the command palette can ask the item which symbol it uses — an image built
        // from a system symbol reports no name otherwise, and every palette row fell back to the
        // placeholder circle.
        image.setName(symbol)
        item.image = image
    }

    private static func setupMainMenu() {
        NSApplication.shared.mainMenu = buildMainMenu()
    }

    /// «Отправить» наполняется при открытии — службы зависят от файла под курсором.
    private static let sendToDelegate = MenuSendToDelegate()

    /// Пункт с клавишей, модификаторами и значком. Без модификаторов — F-клавиши и прочие
    /// «голые» клавиши: addItem по умолчанию вешает ⌘, и F5 превращался бы в ⌘F5.
    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?,
                            key: String = "", mods: NSEvent.ModifierFlags = [.command],
                            symbol: String? = nil, tag: Int = 0,
                            represented: Any? = nil) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        item.tag = tag
        item.representedObject = represented
        if let symbol { icon(item, symbol) }
        return item
    }

    private static func submenu(_ menu: NSMenu, _ title: String, symbol: String? = nil) -> NSMenu {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        if let symbol { icon(item, symbol) }
        let sub = NSMenu(title: title)
        item.submenu = sub
        return sub
    }

    /// Клавиша F1…F12 в виде keyEquivalent.
    static func fkey(_ number: Int) -> String {
        String(utf16CodeUnits: [unichar(NSF1FunctionKey + number - 1)], count: 1)
    }

    /// Подписи столбцов — те же, что в шапке списка.
    static func columnTitle(_ column: PanelColumn) -> String {
        switch column {
        case .name: return L("column.name")
        case .type: return L("properties.type")
        case .size: return L("column.size")
        case .dateCreated: return L("properties.createdDate")
        case .dateModified: return L("column.date")
        case .dateAdded: return L("column.dateAdded")
        case .permissions: return L("properties.permissions")
        case .owner: return L("properties.owner")
        case .origin: return L("column.origin")
        }
    }

    /// Строка меню целиком. Отдельно от установки, чтобы проверка могла собрать её и
    /// пересчитать, не трогая живое приложение.
    static func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        icon(appMenu.addItem(withTitle: L("menu.about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""), "info.circle")
        appMenu.addItem(.separator())
        icon(appMenu.addItem(withTitle: L("menu.settings"), action: #selector(AppDelegate.showSettingsWindow(_:)), keyEquivalent: ","), "gearshape")
        appMenu.addItem(.separator())
        icon(appMenu.addItem(withTitle: L("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"), "eye.slash")
        let hideOthers = appMenu.addItem(withTitle: L("menu.hideOthers"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        icon(appMenu.addItem(withTitle: L("menu.showAll"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""), "eye")
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: L("menu.quit"),
                                       action: #selector(NSApplication.terminate(_:)),
                                       keyEquivalent: "q")
        quitMenuItem = quitItem
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // MARK: Файл — всё, что делается с файлом под курсором и с выделением.
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: L("menu.file"))
        add(fileMenu, L("tabs.newTab"), #selector(MainWindowController.menuNewTab(_:)),
            key: "t", symbol: "plus.rectangle")
        add(fileMenu, L("tabs.close"), #selector(MainWindowController.menuCloseTab(_:)),
            key: "w", symbol: "xmark.rectangle")
        let tabsMenu = submenu(fileMenu, L("menu.file.tabs"), symbol: "rectangle.stack")
        add(tabsMenu, L("menu.tabs.next"), #selector(MainWindowController.menuNextTab(_:)),
            key: "\t", mods: [.control], symbol: "arrow.right.square")
        add(tabsMenu, L("menu.tabs.previous"), #selector(MainWindowController.menuPreviousTab(_:)),
            key: "\t", mods: [.control, .shift], symbol: "arrow.left.square")
        tabsMenu.addItem(.separator())
        add(tabsMenu, L("tabs.rename"), #selector(MainWindowController.menuRenameTab(_:)), symbol: "pencil")
        add(tabsMenu, L("tabs.pin"), #selector(MainWindowController.menuTogglePinTab(_:)), symbol: "pin")
        add(tabsMenu, L("tabs.closeOthers"), #selector(MainWindowController.menuCloseOtherTabs(_:)),
            symbol: "xmark.circle")
        add(tabsMenu, L("tabs.closeAllUnpinned"), #selector(MainWindowController.menuCloseUnpinnedTabs(_:)),
            symbol: "xmark.circle.fill")
        tabsMenu.addItem(.separator())
        let colorMenu = submenu(tabsMenu, L("tabs.color"), symbol: "paintpalette")
        for (index, preset) in TabColor.presets.enumerated() {
            add(colorMenu, preset.name, #selector(MainWindowController.menuTabColor(_:)),
                symbol: "circle.fill", tag: index)
        }
        colorMenu.addItem(.separator())
        add(colorMenu, L("tabs.color.reset"), #selector(MainWindowController.menuTabColor(_:)),
            symbol: "circle.slash", tag: -1)
        fileMenu.addItem(.separator())

        add(fileMenu, L("context.open"), #selector(MainWindowController.menuOpen(_:)),
            symbol: "arrow.right.circle")
        add(fileMenu, L("context.openWith"), #selector(MainWindowController.menuOpenWith(_:)),
            symbol: "square.and.arrow.up.on.square")
        add(fileMenu, L("context.revealInFinder"), #selector(MainWindowController.menuRevealInFinder(_:)),
            symbol: "magnifyingglass")
        add(fileMenu, L("context.openInTerminal"), #selector(MainWindowController.menuOpenInTerminal(_:)),
            symbol: "terminal")
        fileMenu.addItem(.separator())
        add(fileMenu, L("context.mkdir"), #selector(MainWindowController.menuMkdir(_:)),
            key: fkey(7), mods: [], symbol: "folder.badge.plus")
        add(fileMenu, L("context.createTextFile"), #selector(MainWindowController.menuCreateTextFile(_:)),
            key: fkey(4), mods: [.shift], symbol: "doc.badge.plus")
        fileMenu.addItem(.separator())
        add(fileMenu, L("context.view"), #selector(MainWindowController.menuView(_:)),
            key: fkey(3), mods: [], symbol: "eye")
        add(fileMenu, L("context.edit"), #selector(MainWindowController.menuEdit(_:)),
            key: fkey(4), mods: [], symbol: "pencil.line")
        add(fileMenu, L("context.rename"), #selector(MainWindowController.menuRename(_:)),
            key: fkey(2), mods: [], symbol: "character.cursor.ibeam")
        fileMenu.addItem(.separator())
        add(fileMenu, L("menu.file.copyTo"), #selector(MainWindowController.menuCopy(_:)),
            key: fkey(5), mods: [], symbol: "doc.on.doc")
        add(fileMenu, L("menu.file.moveTo"), #selector(MainWindowController.menuMove(_:)),
            key: fkey(6), mods: [], symbol: "arrow.right.doc.on.clipboard")
        add(fileMenu, L("context.delete"), #selector(MainWindowController.menuDelete(_:)),
            key: fkey(8), mods: [], symbol: "trash")
        add(fileMenu, L("menu.file.deletePermanently"), #selector(MainWindowController.menuDeletePermanently(_:)),
            key: fkey(8), mods: [.shift], symbol: "trash.slash")
        fileMenu.addItem(.separator())
        add(fileMenu, L("context.pack"), #selector(MainWindowController.menuPack(_:)),
            key: fkey(5), mods: [.command], symbol: "archivebox")
        add(fileMenu, L("context.unpack"), #selector(MainWindowController.menuUnpack(_:)),
            key: fkey(9), mods: [.command], symbol: "archivebox.fill")
        let packHere = submenu(fileMenu, L("context.packInPlace"), symbol: "archivebox")
        for (index, format) in ArchiveFormat.allCases.enumerated() {
            add(packHere, format.displayName, #selector(MainWindowController.menuPackInPlace(_:)),
                symbol: "archivebox", tag: index)
        }
        let links = submenu(fileMenu, L("context.createLink"), symbol: "link")
        add(links, L("context.createSymlink"), #selector(MainWindowController.menuCreateSymlink(_:)),
            symbol: "link.badge.plus")
        add(links, L("context.createAlias"), #selector(MainWindowController.menuCreateAlias(_:)),
            symbol: "arrowshape.turn.up.right")
        add(links, L("context.createHardlink"), #selector(MainWindowController.menuCreateHardlink(_:)),
            symbol: "doc.on.doc.fill")
        fileMenu.addItem(.separator())
        add(fileMenu, L("context.copyFilePath"), #selector(MainWindowController.menuCopyFilePath(_:)),
            symbol: "arrow.right.doc.on.clipboard")
        add(fileMenu, L("context.copyPath"), #selector(MainWindowController.menuCopyFolderPath(_:)),
            symbol: "folder")
        add(fileMenu, L("context.changeAttributes"), #selector(MainWindowController.menuChangeAttributes(_:)),
            symbol: "lock.rectangle")
        add(fileMenu, L("context.properties"), #selector(MainWindowController.menuProperties(_:)),
            key: "i", symbol: "info.circle")
        fileMenu.addItem(.separator())
        let networkItem = fileMenu.addItem(withTitle: L("network.connectToServer"),
                                           action: #selector(MainWindowController.handleNetworkMenu(_:)),
                                           keyEquivalent: "n")
        networkItem.keyEquivalentModifierMask = [.command, .shift]
        icon(networkItem, "network")
        fileMenu.addItem(.separator())
        // Закрыть окно — стандартный performClose по цепочке ответчиков; ⌘W отдан вкладке.
        add(fileMenu, L("menu.closeWindow"), #selector(NSWindow.performClose(_:)),
            key: "w", mods: [.command, .shift], symbol: "xmark.circle")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // MARK: Правка
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L("menu.edit"))
        // The standard first-responder actions, dispatched to nil. Whoever has the keyboard
        // answers: a text field's editor gives text semantics, and the file panel implements the
        // same selectors to give file semantics. Pointing these at file-only handlers instead
        // hijacked ⌘C/⌘V/⌘A inside every text field in the app.
        // Undo of FILE OPERATIONS — the handler forwards to a text field's own undo manager
        // when one is editing, so Cmd+Z in a rename box stays what it always was.
        icon(editMenu.addItem(withTitle: L("menu.undo"),
                          action: #selector(MainWindowController.handleUndoFileOperation(_:)),
                          keyEquivalent: "z"), "arrow.uturn.backward")
        let redoItem = editMenu.addItem(withTitle: L("menu.redo"),
                          action: #selector(MainWindowController.handleRedoFileOperation(_:)),
                          keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        icon(redoItem, "arrow.uturn.forward")
        editMenu.addItem(NSMenuItem.separator())
        icon(editMenu.addItem(withTitle: L("menu.cut"), action: #selector(NSText.cut(_:)),
                          keyEquivalent: "x"), "scissors")
        icon(editMenu.addItem(withTitle: L("menu.copy"), action: #selector(NSText.copy(_:)),
                          keyEquivalent: "c"), "doc.on.doc")
        icon(editMenu.addItem(withTitle: L("menu.paste"), action: #selector(NSText.paste(_:)),
                          keyEquivalent: "v"), "doc.on.clipboard")
        icon(editMenu.addItem(withTitle: L("menu.selectAll"), action: #selector(NSText.selectAll(_:)),
                          keyEquivalent: "a"), "checklist")
        editMenu.addItem(NSMenuItem.separator())
        // The Total Commander trio. No key equivalents here: the panel answers the numeric
        // keypad's + − * directly (MacBooks have no keypad, which is why these live in the menu
        // and in the command palette as well).
        icon(editMenu.addItem(withTitle: L("menu.selectByMask"),
                              action: #selector(MainWindowController.handleSelectByMask(_:)),
                              keyEquivalent: ""), "plus.square.dashed")
        icon(editMenu.addItem(withTitle: L("menu.deselectByMask"),
                              action: #selector(MainWindowController.handleDeselectByMask(_:)),
                              keyEquivalent: ""), "minus.square")
        icon(editMenu.addItem(withTitle: L("menu.invertSelection"),
                              action: #selector(MainWindowController.handleInvertSelection(_:)),
                              keyEquivalent: ""), "arrow.triangle.2.circlepath")
        icon(editMenu.addItem(withTitle: L("menu.selectSameType"),
                              action: #selector(MainWindowController.handleSelectSameType(_:)),
                              keyEquivalent: ""), "square.on.square.dashed")
        add(editMenu, L("menu.edit.clearSelection"), #selector(MainWindowController.menuClearSelection(_:)),
            symbol: "square.dashed")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // MARK: Вид — как показывать панель и что ещё открыть в окне.
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: L("menu.view"))
        for (index, (key, symbol)) in [("mode.detailed", "list.bullet"), ("mode.brief", "rectangle.grid.1x2"),
                                       ("mode.thumbnails", "photo.on.rectangle")].enumerated() {
            add(viewMenu, L(key), #selector(MainWindowController.menuViewMode(_:)),
                key: String(index + 1), symbol: symbol, tag: index)
        }
        viewMenu.addItem(.separator())
        let sortMenu = submenu(viewMenu, L("menu.view.sortBy"), symbol: "arrow.up.arrow.down")
        // Порядок — как MainWindowController.menuSortFields: tag и есть номер в нём.
        for (index, key) in ["column.name", "column.ext", "properties.type", "column.size",
                             "column.date", "properties.createdDate", "column.dateAdded",
                             "properties.owner", "properties.permissions"].enumerated() {
            add(sortMenu, L(key), #selector(MainWindowController.menuSortBy(_:)), tag: index)
        }
        sortMenu.addItem(.separator())
        add(sortMenu, L("menu.view.sortDescending"), #selector(MainWindowController.menuSortDescending(_:)))
        let columnsMenu = submenu(viewMenu, L("menu.view.columns"), symbol: "tablecells")
        for (index, column) in PanelColumn.allCases.enumerated() where column != .name {
            add(columnsMenu, columnTitle(column), #selector(MainWindowController.menuToggleColumn(_:)),
                tag: index)
        }
        viewMenu.addItem(.separator())
        add(viewMenu, L("menu.view.hiddenFiles"), #selector(MainWindowController.menuToggleHiddenFiles(_:)),
            key: ".", mods: [.command, .shift], symbol: "eye.slash")
        add(viewMenu, L("menu.view.branch"), #selector(MainWindowController.menuToggleBranchView(_:)),
            key: "b", mods: [.control], symbol: "arrow.triangle.branch")
        add(viewMenu, L("context.refresh"), #selector(MainWindowController.menuRefresh(_:)),
            key: "r", symbol: "arrow.clockwise")
        add(viewMenu, L("menu.view.folderSizes"), #selector(MainWindowController.menuFolderSizes(_:)),
            key: "\r", mods: [.command, .shift], symbol: "sum")
        viewMenu.addItem(.separator())
        add(viewMenu, L("terminal.title"), #selector(MainWindowController.menuTerminal(_:)),
            key: "`", symbol: "terminal")
        add(viewMenu, L("monitor.toggle"), #selector(MainWindowController.menuMonitor(_:)),
            symbol: "waveform.path.ecg")
        add(viewMenu, L("diskinfo.title"), #selector(MainWindowController.menuDiskInfo(_:)),
            symbol: "internaldrive")
        add(viewMenu, L("trash.title"), #selector(MainWindowController.menuTrash(_:)), symbol: "trash")
        add(viewMenu, L("stack.title"), #selector(MainWindowController.menuShelf(_:)), symbol: "tray.full")
        add(viewMenu, L("menu.view.queue"), #selector(MainWindowController.menuQueue(_:)),
            symbol: "clock.arrow.2.circlepath")
        viewMenu.addItem(.separator())
        add(viewMenu, L("settings.appearance.toggleTooltip"), #selector(MainWindowController.menuToggleTheme(_:)),
            symbol: "circle.lefthalf.filled")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // MARK: Переход — куда пойти и как расставить панели.
        let goMenuItem = NSMenuItem()
        let goMenu = NSMenu(title: L("menu.go"))
        add(goMenu, L("menu.go.up"), #selector(MainWindowController.menuGoUp(_:)),
            key: "\u{F700}", symbol: "arrow.up")
        add(goMenu, L("menu.go.back"), #selector(MainWindowController.menuGoBack(_:)),
            key: "[", symbol: "chevron.left")
        add(goMenu, L("menu.go.forward"), #selector(MainWindowController.menuGoForward(_:)),
            key: "]", symbol: "chevron.right")
        goMenu.addItem(.separator())
        let home = NSHomeDirectory()
        let places: [(title: String, path: String, key: String, mods: NSEvent.ModifierFlags, symbol: String)] = [
            (L("menu.go.home"), home, "h", [.command, .shift], "house"),
            (L("quickLink.desktop"), home + "/Desktop", "d", [.command, .shift], "desktopcomputer"),
            (L("quickLink.documents"), home + "/Documents", "o", [.command, .shift], "doc"),
            (L("quickLink.downloads"), home + "/Downloads", "l", [.command, .option], "arrow.down.circle"),
            (L("quickLink.applications"), "/Applications", "a", [.command, .shift], "a.square.fill"),
            (L("quickLink.pictures"), home + "/Pictures", "", [], "photo"),
            (L("quickLink.music"), home + "/Music", "", [], "music.note"),
            (L("quickLink.movies"), home + "/Movies", "", [], "film"),
            (L("menu.go.root"), "/", "c", [.command, .shift], "externaldrive")
        ]
        for place in places {
            add(goMenu, place.title, #selector(MainWindowController.menuGoFolder(_:)),
                key: place.key, mods: place.mods, symbol: place.symbol, represented: place.path)
        }
        goMenu.addItem(.separator())
        // The hotlist: the folders the user keeps returning to, on the classic Cmd+D.
        add(goMenu, L("menu.favorites"), #selector(MainWindowController.handleFavoriteFolders(_:)),
            key: "d", symbol: "star")
        add(goMenu, L("context.enterAppBundle"), #selector(MainWindowController.menuEnterAppBundle(_:)),
            symbol: "folder")
        add(goMenu, L("context.followSymlink"), #selector(MainWindowController.menuFollowSymlink(_:)),
            symbol: "arrow.uturn.right")
        goMenu.addItem(.separator())
        add(goMenu, L("menu.go.switchPanel"), #selector(MainWindowController.menuSwitchPanel(_:)),
            symbol: "rectangle.lefthalf.inset.filled.arrow.left")
        add(goMenu, L("divider.swap"), #selector(MainWindowController.menuSwapPanels(_:)),
            key: "u", mods: [.control], symbol: "arrow.left.arrow.right")
        add(goMenu, L("divider.syncLeft"), #selector(MainWindowController.menuSyncLeftToRight(_:)),
            symbol: "arrow.right.to.line")
        add(goMenu, L("divider.syncRight"), #selector(MainWindowController.menuSyncRightToLeft(_:)),
            symbol: "arrow.left.to.line")
        let ratioMenu = submenu(goMenu, L("menu.go.ratio"), symbol: "rectangle.split.2x1")
        add(ratioMenu, L("divider.center"), #selector(MainWindowController.menuSetRatio(_:)), tag: 50)
        ratioMenu.addItem(.separator())
        for percent in [30, 40, 60, 70] {
            add(ratioMenu, "\(percent) / \(100 - percent)", #selector(MainWindowController.menuSetRatio(_:)),
                tag: percent)
        }
        goMenuItem.submenu = goMenu
        mainMenu.addItem(goMenuItem)

        // MARK: Инструменты
        let toolsMenuItem = NSMenuItem()
        let toolsMenu = NSMenu(title: L("menu.tools"))
        // The palette lists every OTHER menu item, so it sits at the top of Tools and is skipped by
        // the registry itself — a command that opens the palette from inside the palette is noise.
        icon(toolsMenu.addItem(withTitle: L("menu.tools.commandPalette"),
                          action: #selector(AppDelegate.showCommandPalette(_:)),
                          keyEquivalent: "p"), "command")
        // No explicit target: setupMainMenu is static, so `self` here would be the CLASS, and an
        // instance method is not found on it — the item validates as disabled and ⌘P does nothing.
        // Leaving it nil sends the action down the responder chain, which ends at the app delegate.
        toolsMenu.addItem(NSMenuItem.separator())
        // Поиск: F9 панель принимает сама, меню даёт привычное ⌘F.
        add(toolsMenu, L("button.f9.search"), #selector(MainWindowController.menuSearch(_:)),
            key: "f", symbol: "magnifyingglass")
        toolsMenu.addItem(NSMenuItem.separator())
        icon(toolsMenu.addItem(withTitle: L("vault.create.menu"),
                          action: #selector(MainWindowController.handleCreateVault(_:)),
                          keyEquivalent: ""), "lock.shield")
        add(toolsMenu, L("menu.tools.vault"), #selector(MainWindowController.menuVaultToggle(_:)),
            symbol: "lock.open")
        // The age pair lives beside the vault: both answer "so nobody else can read this".
        icon(toolsMenu.addItem(withTitle: L("age.encrypt.menu"),
                          action: #selector(MainWindowController.handleEncryptAge(_:)),
                          keyEquivalent: ""), "lock.doc")
        icon(toolsMenu.addItem(withTitle: L("age.decrypt.menu"),
                          action: #selector(MainWindowController.handleDecryptAge(_:)),
                          keyEquivalent: ""), "lock.open")
        toolsMenu.addItem(NSMenuItem.separator())
        icon(toolsMenu.addItem(withTitle: L("context.pdfMake"),
                          action: #selector(MainWindowController.handleMakePDF(_:)),
                          keyEquivalent: ""), "doc.badge.plus")
        icon(toolsMenu.addItem(withTitle: L("context.pdfMerge"),
                          action: #selector(MainWindowController.handleMergePDFs(_:)),
                          keyEquivalent: ""), "square.stack")
        icon(toolsMenu.addItem(withTitle: L("context.pdfSplit"),
                          action: #selector(MainWindowController.handleSplitPDF(_:)),
                          keyEquivalent: ""), "square.split.2x1")
        icon(toolsMenu.addItem(withTitle: L("context.pdfRotate"),
                          action: #selector(MainWindowController.handleRotatePDF(_:)),
                          keyEquivalent: ""), "rotate.right")
        toolsMenu.addItem(NSMenuItem.separator())
        icon(toolsMenu.addItem(withTitle: L("context.convertImages"),
                          action: #selector(MainWindowController.handleConvertImages(_:)),
                          keyEquivalent: ""), "photo.badge.arrow.down")
        add(toolsMenu, L("context.recognizeText"), #selector(MainWindowController.menuRecognizeText(_:)),
            symbol: "text.viewfinder")
        add(toolsMenu, L("context.cleanMetadata"), #selector(MainWindowController.menuCleanMetadata(_:)),
            symbol: "eye.slash")
        toolsMenu.addItem(NSMenuItem.separator())
        icon(toolsMenu.addItem(withTitle: L("menu.tools.applyRules"),
                          action: #selector(MainWindowController.handleApplyFolderRules(_:)),
                          keyEquivalent: ""), "wand.and.rays")
        icon(toolsMenu.addItem(withTitle: L("menu.tools.rules"),
                          action: #selector(MainWindowController.handleFolderRules(_:)),
                          keyEquivalent: ""), "slider.horizontal.3")
        toolsMenu.addItem(NSMenuItem.separator())
        icon(toolsMenu.addItem(withTitle: L("menu.tools.multiRename"),
                          action: #selector(MainWindowController.handleMultiRename(_:)),
                          keyEquivalent: ""), "textformat.abc")
        icon(toolsMenu.addItem(withTitle: L("menu.tools.checksum"),
                          action: #selector(MainWindowController.handleChecksum(_:)),
                          keyEquivalent: ""), "number")
        icon(toolsMenu.addItem(withTitle: L("menu.tools.compare"),
                          action: #selector(MainWindowController.handleCompareDirectories(_:)),
                          keyEquivalent: ""), "arrow.left.arrow.right")
        // Beside the folder comparison: that one says WHICH files differ, this one says how.
        icon(toolsMenu.addItem(withTitle: L("menu.tools.compareFiles"),
                          action: #selector(MainWindowController.handleCompareFiles(_:)),
                          keyEquivalent: ""), "doc.on.doc")
        toolsMenu.addItem(NSMenuItem.separator())
        icon(toolsMenu.addItem(withTitle: L("menu.tools.split"),
                          action: #selector(MainWindowController.handleSplitFile(_:)),
                          keyEquivalent: ""), "scissors")
        icon(toolsMenu.addItem(withTitle: L("menu.tools.join"),
                          action: #selector(MainWindowController.handleJoinFiles(_:)),
                          keyEquivalent: ""), "square.stack.3d.down.right")
        toolsMenu.addItem(NSMenuItem.separator())
        let tagsMenu = submenu(toolsMenu, L("context.tags"), symbol: "tag")
        for (index, tag) in FinderTag.allCases.enumerated() {
            let item = add(tagsMenu, tag.localizedName, #selector(MainWindowController.menuToggleTag(_:)),
                           tag: index)
            item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [tag.color]))
        }
        tagsMenu.addItem(.separator())
        add(tagsMenu, L("context.tags.clear"), #selector(MainWindowController.menuClearTags(_:)),
            symbol: "xmark.circle")
        let sendTo = submenu(toolsMenu, L("context.sendTo"), symbol: "paperplane")
        sendTo.delegate = sendToDelegate
        add(toolsMenu, L("menu.tools.diskImage"), #selector(MainWindowController.menuDiskImageOtherWay(_:)),
            symbol: "externaldrive")
        add(toolsMenu, L("context.uninstall"), #selector(MainWindowController.menuUninstall(_:)),
            symbol: "xmark.app")
        toolsMenuItem.submenu = toolsMenu
        mainMenu.addItem(toolsMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("menu.window"))
        icon(windowMenu.addItem(withTitle: L("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"), "minus.circle")
        icon(windowMenu.addItem(withTitle: L("menu.zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""), "arrow.up.left.and.arrow.down.right")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApplication.shared.windowsMenu = windowMenu

        // Help menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: L("menu.help"))
        // «?» живёт на клавише «/» под Shift, поэтому маска — ⇧⌘: с одной ⌘ AppKit
        // ждал бы нажатия, которого на клавиатуре нет. Русская раскладка на той же клавише
        // даёт «,», и её ловит монитор ниже — по коду клавиши, а не по символу.
        let helpItem = helpMenu.addItem(withTitle: L("menu.help.guide"),
                                        action: #selector(AppDelegate.showHelpWindow(_:)),
                                        keyEquivalent: "?")
        helpItem.keyEquivalentModifierMask = [.command, .shift]
        icon(helpItem, "questionmark.circle")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApplication.shared.helpMenu = helpMenu

        // The Edit menu is the one macOS extends with items of its own (Start Dictation, Emoji &
        // Symbols, AutoFill). Freeze its contents now, so the command palette can tell those from
        // the app's own commands. Every other menu needs no such declaration — anything appearing
        // in one later was put there by this app.
        MainActor.assumeIsolated { CommandRegistry.markSystemExtended(editMenu) }
        return mainMenu
    }
}

/// Следит, чтобы окно настроек не становилось меньше того размера, в котором открывается.
///
/// `minSize` окна останавливает только мышь на его краю; программный `setFrame` — а именно
/// им и работает анимация открытия — проходит мимо ограничения. Делегат правит КАЖДЫЙ
/// предложенный размер, откуда бы он ни пришёл.
final class SettingsWindowSizeGuard: NSObject, NSWindowDelegate {
    static let minimum = NSSize(width: 660, height: 580)

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, Self.minimum.width),
               height: max(frameSize.height, Self.minimum.height))
    }
}
