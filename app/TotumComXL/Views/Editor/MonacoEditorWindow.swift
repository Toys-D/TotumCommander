import AppKit
import WebKit

/// NSView subclass that forces arrow cursor instead of text cursor.
private final class ArrowCursorView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// Editor window powered by Monaco Editor (VS Code engine) via WKWebView.
/// Replaces NSTextView-based editor for full-featured code editing.
@MainActor
final class MonacoEditorWindow: NSWindowController, NSWindowDelegate {
    private let identifier: UUID
    private var source: EditorDocumentSource
    private var currentPath: String
    private let onClose: (UUID) -> Void
    private let operations: FileOperationsService
    private var monaco: MonacoEditorController!
    private var statusLabel: NSTextField?
    private var isDirty = false
    private var bypassCloseValidation = false
    private var keyMonitor: Any?

    // Tab support
    private struct Tab {
        let path: String
        var source: EditorDocumentSource
        var content: String = ""
        var lastSaved: String = ""
        var language: String = "plaintext"
        /// Encoding the file was decoded with, so a save writes it back in the same encoding
        /// instead of silently converting everything to UTF-8.
        var encoding: String.Encoding = .utf8
        /// Set when the bytes couldn't be decoded to text — saving must be blocked so the
        /// "(Cannot decode file)" placeholder never overwrites the real file.
        var isReadOnly: Bool = false
        /// For a file opened from an archive: true once its temp copy has been saved and thus
        /// differs from the archive. Drives the "update archive?" prompt on close (TC-style).
        var archiveNeedsUpdate: Bool = false
        var isDirty: Bool { content != lastSaved }
        var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
    }
    private var tabs: [Tab] = []
    private var activeTabIndex = 0
    private var tabBar: NSView?

    /// Paths of unsaved (dirty) tabs backed by a real file on the given volume. Archive-sourced
    /// tabs live in a temp dir (not the volume), so they're excluded — the eject warning only
    /// cares about edits that would be orphaned when the volume disappears.
    func dirtyFileSystemPaths(onVolume volumeRoot: String) -> [String] {
        let prefix = volumeRoot.hasSuffix("/") ? volumeRoot : volumeRoot + "/"
        return tabs.compactMap { tab -> String? in
            guard tab.isDirty else { return nil }
            guard case .fileSystem = tab.source else { return nil }
            return (tab.path == volumeRoot || tab.path.hasPrefix(prefix)) ? tab.path : nil
        }
    }

    init(identifier: UUID, path: String, source: EditorDocumentSource,
         operations: FileOperationsService, onClose: @escaping (UUID) -> Void) {
        self.identifier = identifier
        self.currentPath = path
        self.source = source
        self.operations = operations
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        // ARC owns this window (a strong reference is kept) — without this flag
        // close() ALSO releases it and the second release crashes (SearchWindow bug).
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 350)
        window.setFrameAutosaveName("MonacoEditorFrame")
        if !window.setFrameUsingName("MonacoEditorFrame") { window.center() }

        super.init(window: window)
        window.delegate = self

        // Monaco controller
        monaco = MonacoEditorController()

        // Layout: tab bar (accessory) + webView + status bar
        let contentSize = window.contentLayoutRect.size
        let statusH: CGFloat = 22
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))

        // Status bar
        let statusBar = NSTextField(labelWithString: L("editor.status.initial"))
        statusBar.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusBar.textColor = .secondaryLabelColor
        statusBar.frame = NSRect(x: 8, y: 2, width: contentSize.width - 16, height: statusH - 4)
        statusBar.autoresizingMask = [.width]
        self.statusLabel = statusBar
        container.addSubview(statusBar)

        // WebView
        monaco.webView.frame = NSRect(x: 0, y: statusH, width: contentSize.width, height: contentSize.height - statusH)
        monaco.webView.autoresizingMask = [.width, .height]
        container.addSubview(monaco.webView)

        window.contentView = container

        // Tab bar as accessory
        let tabBarView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 26))
        tabBarView.wantsLayer = true
        self.tabBar = tabBarView
        let tabAccessory = NSTitlebarAccessoryViewController()
        tabAccessory.layoutAttribute = .bottom
        tabAccessory.view = tabBarView
        window.addTitlebarAccessoryViewController(tabAccessory)

        // Toolbar as accessory (uses ArrowCursorView to fix cursor)
        let toolbarView = buildToolbar()
        toolbarView.addCursorRect(toolbarView.bounds, cursor: .arrow)
        // Wrap in ArrowCursorView
        let toolbarWrapper = ArrowCursorView(frame: toolbarView.frame)
        toolbarWrapper.addSubview(toolbarView)
        toolbarView.frame.origin = .zero
        let toolbarAccessory = NSTitlebarAccessoryViewController()
        toolbarAccessory.layoutAttribute = .bottom
        toolbarAccessory.view = toolbarWrapper
        window.addTitlebarAccessoryViewController(toolbarAccessory)

        // Callbacks
        monaco.onCursorChanged = { [weak self] line, col, total, selLen in
            guard let self else { return }
            var s = L("editor.status.position", line, col, total)
            if selLen > 0 { s += "  |  " + L("editor.status.selection", selLen) }
            s += "  |  UTF-8"
            self.statusLabel?.stringValue = s
        }

        monaco.onDirtyChanged = { [weak self] dirty in
            guard let self else { return }
            self.isDirty = dirty
            // Sync current tab content from Monaco
            self.monaco.getContent { [weak self] text in
                guard let self, self.activeTabIndex < self.tabs.count else { return }
                self.tabs[self.activeTabIndex].content = text
            }
            self.updateTitle()
            self.renderTabBar()
        }

        monaco.onReady = { [weak self] in
            guard let self else { return }
            self.loadFileContent()
            // Put keyboard focus into the editor so typing works right after F4, and the
            // window's Cmd+S key monitor receives events (it only fires while this window is key).
            self.window?.makeFirstResponder(self.monaco.webView)
            self.monaco.focusEditor()
        }

        // Create initial tab
        let lang = MonacoEditorController.detectLanguage(for: path)
        tabs.append(Tab(path: path, source: source, language: lang))
        activeTabIndex = 0
        updateTitle()
        renderTabBar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
        DispatchQueue.main.async { [weak self] in self?.renderTabBar() }
    }

    // MARK: - File Loading

    private func loadFileContent() {
        guard activeTabIndex < tabs.count else { return }
        let tab = tabs[activeTabIndex]
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: tab.path), options: [.mappedIfSafe])
            let decoded = MonacoEditorController.decodeText(data)
            tabs[activeTabIndex].content = decoded.text
            tabs[activeTabIndex].lastSaved = decoded.text
            tabs[activeTabIndex].encoding = decoded.encoding
            tabs[activeTabIndex].isReadOnly = !decoded.decodable
            monaco.setContent(decoded.text, language: tab.language)
            if wordWrapEnabled { monaco.toggleWordWrap(true) }
        } catch {
            tabs[activeTabIndex].isReadOnly = true
            monaco.setContent("// Error loading file: \(error.localizedDescription)", language: "plaintext")
        }
    }

    // MARK: - Tabs

    func addTab(path: String, source: EditorDocumentSource) {
        if let idx = tabs.firstIndex(where: { $0.path == path }) {
            switchToTab(idx)
            return
        }
        saveCurrentTabContent()
        let lang = MonacoEditorController.detectLanguage(for: path)
        tabs.append(Tab(path: path, source: source, language: lang))
        activeTabIndex = tabs.count - 1
        currentPath = path
        self.source = source
        loadFileContent()
        window?.makeFirstResponder(monaco.webView)
        monaco.focusEditor()
        updateTitle()
        renderTabBar()
    }

    private func saveCurrentTabContent() {
        guard activeTabIndex < tabs.count else { return }
        monaco.getContent { [weak self] text in
            guard let self, self.activeTabIndex < self.tabs.count else { return }
            self.tabs[self.activeTabIndex].content = text
        }
    }

    private func switchToTab(_ index: Int) {
        guard index >= 0 && index < tabs.count && index != activeTabIndex else { return }
        saveCurrentTabContent()
        // Small delay to ensure content is saved
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.activeTabIndex = index
            let tab = self.tabs[index]
            self.currentPath = tab.path
            self.source = tab.source
            if tab.content.isEmpty {
                self.loadFileContent()
            } else {
                self.monaco.setContent(tab.content, language: tab.language)
            }
            self.window?.makeFirstResponder(self.monaco.webView)
            self.monaco.focusEditor()
            self.updateTitle()
            self.renderTabBar()
        }
    }

    private func closeTab(_ index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        Task { @MainActor in
            await closeTabAsync(index)
        }
    }

    private func closeTabAsync(_ index: Int) async {
        guard index >= 0 && index < tabs.count else { return }
        // Sync content
        if index == activeTabIndex {
            tabs[index].content = await monaco.getContentAsync()
        }
        if tabs[index].isDirty {
            let fileName = tabs[index].fileName
            let decision = await fcxlPresentModalAsync {
                DialogService.shared.showSaveChangesConfirmation(
                    title: L("editor.saveChanges.title"),
                    message: "«\(fileName)»: " + L("editor.saveChanges.message"))
            }
            switch decision {
            case .save:
                // Keep the tab open if the save failed — don't discard the edits.
                if !(await saveTab(at: index)) { return }
            case .cancel: return
            case .discard: break
            }
        }

        // TC-style: offer to write the edited file back into its archive before closing.
        if !(await updateArchiveOnClose(at: index)) { return }

        guard index < tabs.count else { return }
        cleanupArchiveTemp(for: tabs[index])
        tabs.remove(at: index)
        if tabs.isEmpty {
            bypassCloseValidation = true
            window?.performClose(nil)
            return
        }
        if activeTabIndex >= tabs.count { activeTabIndex = tabs.count - 1 }
        let tab = tabs[activeTabIndex]
        currentPath = tab.path
        source = tab.source
        monaco.setContent(tab.content, language: tab.language)
        updateTitle()
        renderTabBar()
    }

    // MARK: - Tab Bar Rendering

    private static let tabBarHeight: CGFloat = 26

    private func renderTabBar() {
        guard let bar = tabBar else { return }
        bar.subviews.forEach { $0.removeFromSuperview() }
        let isDark = (window?.effectiveAppearance ?? NSApp.effectiveAppearance)
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let h = Self.tabBarHeight
        bar.layer?.backgroundColor = (isDark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.9, alpha: 1)).cgColor

        var x: CGFloat = 4
        for (i, tab) in tabs.enumerated() {
            let isActive = i == activeTabIndex
            let title = tab.fileName + (tab.isDirty ? " \u{2022}" : "")

            // Tab button
            let btn = NSButton(frame: NSRect(x: x, y: 2, width: 10, height: h - 4))
            btn.isBordered = false
            btn.title = title
            btn.font = .systemFont(ofSize: 11, weight: isActive ? .semibold : .regular)
            btn.contentTintColor = isActive ? .labelColor : .secondaryLabelColor
            btn.alignment = .left
            btn.sizeToFit()
            btn.frame.size.width += 28  // room for close button
            btn.frame.size.height = h - 4
            btn.tag = i
            btn.target = self
            btn.action = #selector(tabClicked(_:))
            if isActive {
                btn.wantsLayer = true
                btn.layer?.backgroundColor = (isDark ? NSColor(white: 0.28, alpha: 1) : NSColor(white: 0.8, alpha: 1)).cgColor
                btn.layer?.cornerRadius = 4
            }
            bar.addSubview(btn)

            // Close button (✕) on each tab
            let closeBtn = NSButton(frame: NSRect(x: x + btn.frame.width - 18, y: (h - 14) / 2, width: 14, height: 14))
            closeBtn.isBordered = false
            closeBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("tabs.close"))
            closeBtn.imageScaling = .scaleProportionallyDown
            closeBtn.contentTintColor = isDark ? NSColor(white: 0.5, alpha: 1) : NSColor(white: 0.4, alpha: 1)
            closeBtn.tag = i
            closeBtn.target = self
            closeBtn.action = #selector(closeTabClicked(_:))
            closeBtn.toolTip = L("tabs.close")
            bar.addSubview(closeBtn)
            x += btn.frame.width + 2
        }
    }

    @objc private func tabClicked(_ sender: NSButton) { switchToTab(sender.tag) }
    @objc private func closeTabClicked(_ sender: NSButton) { closeTab(sender.tag) }

    // MARK: - Toolbar

    private var currentFontSize: Int = 13

    private func buildToolbar() -> NSView {
        let h: CGFloat = 30
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: h))
        panel.wantsLayer = true
        // Полоса собрана точными кадрами: тридцать точек высоты и штатные контролы по
        // двадцать два. В macOS 26 системные контролы стали выше и шире прежних, и такая
        // раскладка на них расползается — контролы наезжают друг на друга. Этот ключ Apple
        // и дала для плотных полос: он просит у контролов прежние, тесные размеры, и
        // раскладка остаётся той же, что здесь посчитана.
        if #available(macOS 26.0, *) { panel.prefersCompactControlSizeMetrics = true }
        let isDark = (window?.effectiveAppearance ?? NSApp.effectiveAppearance)
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        panel.layer?.backgroundColor = (isDark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.92, alpha: 1)).cgColor

        var x: CGFloat = 6
        let y: CGFloat = (h - 22) / 2

        // Font picker
        let fontPopup = NSPopUpButton(frame: NSRect(x: x, y: y, width: 120, height: 22), pullsDown: false)
        fontPopup.focusRingType = .none
        fontPopup.font = .systemFont(ofSize: 11)
        fontPopup.controlSize = .small
        for name in MonacoEditorController.editorFonts {
            fontPopup.addItem(withTitle: name)
        }
        fontPopup.selectItem(withTitle: "SF Mono")
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        panel.addSubview(fontPopup)
        x += 124

        // Font size
        let sizeField = NSTextField(frame: NSRect(x: x, y: y + 1, width: 34, height: 20))
        sizeField.font = .systemFont(ofSize: 11)
        sizeField.stringValue = "\(currentFontSize)"
        sizeField.alignment = .center
        sizeField.tag = 100  // identifier
        panel.addSubview(sizeField)
        x += 36

        let sizeDown = NSButton(frame: NSRect(x: x, y: y, width: 20, height: 22))
        sizeDown.title = "−"; sizeDown.bezelStyle = .smallSquare
        sizeDown.target = self; sizeDown.action = #selector(fontSizeDown(_:))
        panel.addSubview(sizeDown)
        x += 21

        let sizeUp = NSButton(frame: NSRect(x: x, y: y, width: 20, height: 22))
        sizeUp.title = "+"; sizeUp.bezelStyle = .smallSquare
        sizeUp.target = self; sizeUp.action = #selector(fontSizeUp(_:))
        panel.addSubview(sizeUp)
        x += 25

        // Separator
        let sep1 = NSBox(frame: NSRect(x: x, y: y + 2, width: 1, height: 18))
        sep1.boxType = .separator; panel.addSubview(sep1); x += 5

        // Theme
        let themePopup = NSPopUpButton(frame: NSRect(x: x, y: y, width: 110, height: 22), pullsDown: false)
        themePopup.focusRingType = .none
        themePopup.font = .systemFont(ofSize: 11)
        themePopup.controlSize = .small
        for (i, theme) in MonacoEditorController.editorThemes.enumerated() {
            themePopup.addItem(withTitle: theme.name); themePopup.lastItem?.tag = i
        }
        themePopup.selectItem(withTitle: MonacoEditorController.editorThemes[0].name)
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        panel.addSubview(themePopup)
        x += 114

        // Separator
        let sep2 = NSBox(frame: NSRect(x: x, y: y + 2, width: 1, height: 18))
        sep2.boxType = .separator; panel.addSubview(sep2); x += 5

        // Toggle buttons with SF Symbols
        func addImgToggle(_ symbol: String, tooltip: String, action: Selector, on: Bool = false) {
            let btn = NSButton(frame: NSRect(x: x, y: y, width: 28, height: 22))
            let tintColor: NSColor = on ? .controlAccentColor : .secondaryLabelColor
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
                .withSymbolConfiguration(config)
            btn.isBordered = false
            btn.setButtonType(.momentaryPushIn)
            btn.imageScaling = .scaleProportionallyDown
            btn.toolTip = tooltip
            btn.target = self; btn.action = action
            btn.contentTintColor = tintColor
            panel.addSubview(btn)
            x += 30
        }

        addImgToggle("text.word.spacing", tooltip: L("editor.toolbar.wordWrap"), action: #selector(wrapToggled(_:)), on: true)
        addImgToggle("paragraphsign", tooltip: L("editor.toolbar.invisibles"), action: #selector(whitespaceToggled(_:)))
        addImgToggle("sidebar.right", tooltip: L("editor.toolbar.minimap"), action: #selector(minimapToggled(_:)), on: true)
        addImgToggle("line.3.horizontal", tooltip: L("editor.toolbar.lineHighlight"), action: #selector(lineHighlightToggled(_:)))

        // Separator
        let sep3 = NSBox(frame: NSRect(x: x, y: y + 2, width: 1, height: 18))
        sep3.boxType = .separator; panel.addSubview(sep3); x += 5

        // Language
        let langPopup = NSPopUpButton(frame: NSRect(x: x, y: y, width: 110, height: 22), pullsDown: false)
        langPopup.focusRingType = .none
        langPopup.font = .systemFont(ofSize: 11)
        langPopup.controlSize = .small
        for lang in MonacoEditorController.editorLanguages {
            langPopup.addItem(withTitle: lang.name)
        }
        let detectedLang = MonacoEditorController.detectLanguage(for: currentPath)
        langPopup.selectItem(withTitle: MonacoEditorController.languageName(for: detectedLang))
        langPopup.target = self
        langPopup.action = #selector(langChanged(_:))
        panel.addSubview(langPopup)

        return panel
    }

    // MARK: - Toolbar Actions

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        guard let name = sender.selectedItem?.title else { return }
        let escaped = MonacoEditorController.escapeForJSString(name)
        monaco.webView.evaluateJavaScript("editor.updateOptions({ fontFamily: '\(escaped)' })")
    }

    @objc private func fontSizeDown(_ sender: Any) {
        currentFontSize = max(8, currentFontSize - 1)
        monaco.setFontSize(currentFontSize)
        updateSizeField()
    }

    @objc private func fontSizeUp(_ sender: Any) {
        currentFontSize = min(72, currentFontSize + 1)
        monaco.setFontSize(currentFontSize)
        updateSizeField()
    }

    private func updateSizeField() {
        // Find size field by tag in toolbar accessory
        if let toolbar = window?.titlebarAccessoryViewControllers.last?.view {
            if let field = toolbar.subviews.first(where: { $0.tag == 100 }) as? NSTextField {
                field.stringValue = "\(currentFontSize)"
            }
        }
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        let tag = sender.selectedItem?.tag ?? 0
        guard tag < MonacoEditorController.editorThemes.count else { return }
        monaco.setTheme(MonacoEditorController.editorThemes[tag].id)
    }

    @objc private func wrapToggled(_ sender: NSButton) {
        wordWrapEnabled.toggle()
        monaco.toggleWordWrap(wordWrapEnabled)
        sender.state = wordWrapEnabled ? .on : .off
        sender.contentTintColor = wordWrapEnabled ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func whitespaceToggled(_ sender: NSButton) {
        whitespaceMode = (whitespaceMode + 1) % 3
        let modes = ["none", "boundary", "all"]
        monaco.toggleWhitespace(modes[whitespaceMode])
        let isOn = whitespaceMode > 0
        sender.state = isOn ? .on : .off
        sender.contentTintColor = isOn ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func minimapToggled(_ sender: NSButton) {
        minimapEnabled.toggle()
        monaco.toggleMinimap(minimapEnabled)
        sender.state = minimapEnabled ? .on : .off
        sender.contentTintColor = minimapEnabled ? .controlAccentColor : .secondaryLabelColor
    }

    private var lineHighlightMode = 0  // 0=none, 1=gutter, 2=line, 3=all
    @objc private func lineHighlightToggled(_ sender: NSButton) {
        lineHighlightMode = (lineHighlightMode + 1) % 4
        let modes = ["none", "gutter", "line", "all"]
        monaco.webView.evaluateJavaScript("toggleLineHighlight('\(modes[lineHighlightMode])')")
        let isOn = lineHighlightMode > 0
        sender.state = isOn ? .on : .off
        sender.contentTintColor = isOn ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func langChanged(_ sender: NSPopUpButton) {
        guard let name = sender.selectedItem?.title else { return }
        monaco.setLanguage(MonacoEditorController.languageID(for: name))
    }

    // MARK: - Save

    /// Save one tab by index. Works for background tabs too — it never switches the active
    /// tab, so there's no getContent/switchToTab race, and writes the tab's own path and
    /// encoding. Returns false and leaves the file untouched on any failure.
    @discardableResult
    private func saveTab(at index: Int) async -> Bool {
        guard index >= 0, index < tabs.count else { return false }

        // File whose bytes never decoded is shown as a placeholder — never write it back.
        if tabs[index].isReadOnly {
            DialogService.shared.showWarning(
                title: L("editor.error.saveTitle"),
                message: L("editor.error.readOnly"))
            return false
        }

        // The active tab's text is fresh from Monaco; background tabs already hold their
        // edited content in `tabs[index].content`.
        let text = index == activeTabIndex ? await monaco.getContentAsync() : tabs[index].content
        guard let data = text.data(using: tabs[index].encoding) else {
            DialogService.shared.showError(
                title: L("editor.error.saveTitle"),
                message: L("editor.error.encodeUtf8"))
            return false
        }
        do {
            // For an archive file, `path` is the extracted temp copy — Cmd+S writes there
            // (TC-style), and the archive itself is updated on close via updateArchiveOnClose.
            try data.write(to: URL(fileURLWithPath: tabs[index].path), options: .atomic)
            tabs[index].lastSaved = text
            tabs[index].content = text
            if case .archive = tabs[index].source { tabs[index].archiveNeedsUpdate = true }
            if index == activeTabIndex {
                monaco.markSaved()
                isDirty = false
            }
            updateTitle()
            renderTabBar()
            return true
        } catch {
            DialogService.shared.showError(title: L("editor.error.saveTitle"), message: error.localizedDescription)
            return false
        }
    }

    /// TC-style archive write-back: before an archive-sourced tab closes, offer to pack the
    /// edited temp file back into the archive. Returns false only if the user cancels (the
    /// tab must stay open). One prompt, on close — never on every Cmd+S.
    private func updateArchiveOnClose(at index: Int) async -> Bool {
        guard index >= 0, index < tabs.count else { return true }
        guard case let .archive(archivePath, entryPath, _) = tabs[index].source,
              tabs[index].archiveNeedsUpdate else { return true }

        let fileName = tabs[index].fileName
        let decision = await fcxlPresentModalAsync {
            DialogService.shared.showSaveChangesConfirmation(
                title: L("editor.archiveUpdate.title"),
                message: "«\(fileName)»: " + L("editor.archiveUpdate.message"))
        }
        switch decision {
        case .cancel:
            return false
        case .discard:
            return true                       // leave the archive untouched, close the tab
        case .save:
            do {
                try await operations.updateArchiveEntry(
                    editedFilePath: tabs[index].path,
                    archivePath: archivePath,
                    entryPath: entryPath)
                if index < tabs.count { tabs[index].archiveNeedsUpdate = false }
                return true
            } catch {
                let ns = error as NSError
                // User cancelled the pack/rebuild progress — keep the tab open.
                if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return false }
                DialogService.shared.showError(
                    title: L("editor.error.saveTitle"),
                    message: error.localizedDescription)
                return false                  // keep the tab open so the edits aren't lost
            }
        }
    }

    /// Remove the extracted temp directory of an archive-sourced tab once it's fully closed.
    private func cleanupArchiveTemp(for tab: Tab) {
        if case let .archive(_, _, temporaryRoot) = tab.source {
            FileOperationsService.cleanupTemporaryDirectory(temporaryRoot)
        }
    }

    @discardableResult
    private func saveFile() async -> Bool {
        await saveTab(at: activeTabIndex)
    }

    // MARK: - Title

    private func updateTitle() {
        let fileName = URL(fileURLWithPath: currentPath).lastPathComponent
        window?.title = "\(fileName) — \(currentPath)\(isDirty ? L("editor.title.dirtySuffix") : "")"
    }

    // MARK: - Key Monitor

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let kc = event.keyCode

            if kc == 53 { self.requestClose(); return nil }                    // Esc

            if mods == [.command] {
                switch kc {
                case 13: self.closeTab(self.activeTabIndex); return nil         // Cmd+W
                case 1: Task { @MainActor in await self.saveFile() }; return nil  // Cmd+S
                case 3: self.monaco.showFind(); return nil                     // Cmd+F
                case 15: self.monaco.showReplace(); return nil                 // Cmd+R
                case 37: self.promptGoToLine(); return nil                      // Cmd+L
                default: break
                }
            }

            if mods == [.command, .shift] {
                switch kc {
                case 46: self.toggleMonacoMinimap(); return nil                 // Cmd+Shift+M
                case 13: self.toggleMonacoWordWrap(); return nil                // Cmd+Shift+W
                case 34: self.toggleMonacoWhitespace(); return nil             // Cmd+Shift+I
                default: break
                }
            }

            return event
        }
    }

    // MARK: - Actions

    private func requestClose() {
        Task { @MainActor in
            guard await canClose() else { return }
            bypassCloseValidation = true
            window?.performClose(nil)
        }
    }

    private func canClose() async -> Bool {
        // Sync current tab content
        if activeTabIndex < tabs.count {
            tabs[activeTabIndex].content = await monaco.getContentAsync()
        }

        // Check each tab: first the unsaved buffer, then the archive write-back.
        for i in tabs.indices {
            if tabs[i].isDirty {
                let fileName = tabs[i].fileName
                let decision = await fcxlPresentModalAsync {
                    DialogService.shared.showSaveChangesConfirmation(
                        title: L("editor.saveChanges.title"),
                        message: "«\(fileName)»: " + L("editor.saveChanges.message"))
                }
                switch decision {
                case .save:
                    // Save the tab by index directly — no switchToTab (which defers by 0.05s
                    // and would race saveFile into writing the wrong tab's content).
                    if !(await saveTab(at: i)) { return false }
                case .cancel: return false
                case .discard: break
                }
            }
            // Archive write-back is independent of buffer dirtiness: the temp file may already
            // differ from the archive from an earlier Cmd+S.
            if !(await updateArchiveOnClose(at: i)) { return false }
        }
        return true
    }

    private func promptGoToLine() {
        // Unified input dialog (FCXLMessageDialog); enter via a runloop callout so its
        // buttons work even when invoked from a parked (SwiftUI/key-handler) context.
        fcxlPresentModal {
            guard let value = DialogService.shared.showTextInput(
                title: L("editor.goToLine"),
                message: L("editor.lineNumber"),
                defaultValue: "",
                confirmButtonTitle: "OK",
                cancelButtonTitle: L("common.cancel")
            ), let num = Int(value.trimmingCharacters(in: .whitespaces)), num > 0 else { return }
            self.monaco.goToLine(num)
        }
    }

    private var minimapEnabled = true
    private func toggleMonacoMinimap() {
        minimapEnabled.toggle()
        monaco.toggleMinimap(minimapEnabled)
    }

    private var wordWrapEnabled = true
    private func toggleMonacoWordWrap() {
        wordWrapEnabled.toggle()
        monaco.toggleWordWrap(wordWrapEnabled)
    }

    private var whitespaceMode = 0  // 0=none, 1=boundary, 2=all
    private func toggleMonacoWhitespace() {
        whitespaceMode = (whitespaceMode + 1) % 3
        let modes = ["none", "boundary", "all"]
        monaco.toggleWhitespace(modes[whitespaceMode])
    }

    // MARK: - Window Delegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if bypassCloseValidation { return true }
        // Can't call async from sync delegate — defer to Task
        Task { @MainActor in
            if await canClose() {
                bypassCloseValidation = true
                sender.performClose(nil)
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        // Drop every extracted archive temp dir (write-back already happened in canClose).
        for tab in tabs { cleanupArchiveTemp(for: tab) }
        onClose(identifier)
    }
}
