import AppKit
import Carbon
import SwiftUI
import SwiftTerm

// MARK: - Input Source Helper

/// Switches the keyboard input source to English (ABC) when terminal gets focus,
/// and restores the previous layout when leaving.
@MainActor
enum TerminalInputSourceHelper {
    private static var savedInputSource: TISInputSource?

    static func switchToEnglish() {
        // Save current input source
        savedInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()

        // Find and select English/ABC input source
        guard let sources = TISCreateInputSourceList(
            [kTISPropertyInputSourceLanguages: ["en"]] as CFDictionary, false
        )?.takeRetainedValue() as? [TISInputSource] else { return }

        for source in sources {
            guard let categoryRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory) else { continue }
            let category = Unmanaged<CFString>.fromOpaque(categoryRef).takeUnretainedValue() as String
            if category == kTISCategoryKeyboardInputSource as String {
                TISSelectInputSource(source)
                return
            }
        }
    }

    static func restore() {
        guard let source = savedInputSource else { return }
        TISSelectInputSource(source)
        savedInputSource = nil
    }
}

// MARK: - Terminal Process Registry

/// Keeps track of every live terminal — a tab's (or the bottom strip's) split view with all its
/// parts — so their shell processes stop when the owning tab is closed.
@MainActor
final class TerminalProcessRegistry {
    static let shared = TerminalProcessRegistry()
    /// Fixed UUID for the bottom terminal panel (singleton).
    static let bottomTerminalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var views: [UUID: TerminalSplitView] = [:]

    func register(_ view: TerminalSplitView, for tabID: UUID) {
        views[tabID] = view
    }

    /// Stop every part of this tab's terminal.
    func terminate(tabID: UUID) {
        if let view = views[tabID] {
            view.terminateAll()
            views[tabID] = nil
        }
    }

    func terminateAll() {
        for (_, view) in views { view.terminateAll() }
        views.removeAll()
    }
}

// MARK: - Container View

/// NSView container that hosts LocalProcessTerminalView from SwiftTerm.
@MainActor
final class SwiftTermContainerView: NSView, LocalProcessTerminalViewDelegate {
    private var localTermView: LocalProcessTerminalView?
    /// SwiftTerm's own mouseDown handles selection and never asks for the keyboard, and it is
    /// `public`, not `open`, so it cannot be overridden from here. The terminal typed only
    /// because it grabbed focus once, when its shell started; anything that took focus away
    /// afterwards left no way back short of closing it. A click monitor gives it the
    /// click-to-focus every other input surface has — and the file list now relies on it.
    private var clickFocusMonitor: Any?
    private var currentDirectory: String = ""
    private var isStarted = false
    private var isFrozen = false
    private var dropHighlightBorder: CALayer?
    private var isDropTarget = false {
        didSet { updateDropHighlight() }
    }
    /// Оболочка вышла сама (`exit`): часть закрывается. Не зовётся, когда процесс останавливаем мы.
    var onProcessExit: (() -> Void)?
    /// Часть выбрали — щелчком или броском файла: она становится активной в своём разделении.
    var onActivated: (() -> Void)?
    /// Меню правого щелчка (и ⌃-щелчка) по терминалу; nil — щелчок уходит дальше.
    var makeContextMenu: (() -> NSMenu?)?
    private var contextMenuMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Terminate the shell process when this view is deallocated (tab closed).
    deinit {
        if let clickFocusMonitor { NSEvent.removeMonitor(clickFocusMonitor) }
        if let contextMenuMonitor { NSEvent.removeMonitor(contextMenuMonitor) }
        let tv = localTermView
        MainActor.assumeIsolated {
            tv?.terminate()
        }
    }

    /// Explicitly terminate the shell process (e.g. when closing a tab).
    func terminateProcess() {
        // Сами останавливаем — это не выход оболочки, часть уже убирают.
        onProcessExit = nil
        guard let tv = localTermView else { return }
        // Send SIGHUP to the entire process group (kills shell + its children)
        let pid = tv.process.shellPid
        if pid > 0 {
            kill(-pid, SIGHUP)   // negative PID = send to process group
            kill(pid, SIGTERM)
        }
        tv.terminate()
        removeClickToFocus()
        localTermView = nil
    }

    /// Отдать клавиатуру этой части.
    @discardableResult
    func takeKeyboard() -> Bool {
        guard let tv = localTermView, let window else { return false }
        return window.makeFirstResponder(tv)
    }

    /// Держит ли эта часть клавиатуру — сама или что-то внутри неё.
    var holdsKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    /// Папка, в которой оболочка стоит сейчас: после `cd` новая часть открывается там же.
    /// Оболочка не обязана сообщать о смене папки, поэтому спрашиваем систему о процессе.
    var workingDirectory: String {
        if let pid = localTermView?.process.shellPid,
           let directory = Self.directory(ofProcess: pid) {
            return directory
        }
        return currentDirectory
    }

    /// Текущая папка процесса — у системы, по номеру процесса.
    nonisolated static func directory(ofProcess pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// Send a raw byte (e.g. control code) to the terminal process.
    /// Used to work around SwiftTerm bug with non-Latin keyboard layouts.
    func sendBytes(_ bytes: [UInt8]) {
        localTermView?.send(bytes)
    }

    func setFrozen(_ frozen: Bool) {
        if isFrozen && !frozen {
            // Unfreezing — show terminal and update its frame
            isFrozen = false
            localTermView?.isHidden = false
            localTermView?.frame = bounds
        } else if !isFrozen && frozen {
            // Freezing — hide terminal to prevent expensive relayouts
            isFrozen = true
            localTermView?.isHidden = true
        }
    }

    override func layout() {
        super.layout()
        if !isFrozen {
            localTermView?.frame = bounds
        }
    }

    func startTerminal(directory: String) {
        guard !isStarted else { return }
        isStarted = true
        currentDirectory = directory

        let tv = LocalProcessTerminalView(frame: bounds)
        tv.processDelegate = self

        // Style: dark background, green text, monospace font
        let termFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.font = termFont
        tv.nativeBackgroundColor = NSColor(white: 0.08, alpha: 1.0)
        tv.nativeForegroundColor = NSColor(red: 0.8, green: 0.9, blue: 0.8, alpha: 1.0)
        tv.caretColor = NSColor.green
        tv.caretTextColor = NSColor.black

        addSubview(tv)
        tv.frame = bounds
        tv.autoresizingMask = [.width, .height]
        localTermView = tv

        // Use SwiftTerm's default environment (TERM, LANG, COLORTERM)
        // plus PATH and HOME for a working shell
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        let currentEnv = ProcessInfo.processInfo.environment
        // Ensure essential vars are present. ZDOTDIR — where zsh keeps its .zshrc and history,
        // when someone moved them (and where the tests put them, away from the real ones).
        for key in ["PATH", "HOME", "SHELL", "TMPDIR", "ZDOTDIR"] {
            if let val = currentEnv[key] {
                env.append("\(key)=\(val)")
            }
        }

        let shell = currentEnv["SHELL"] ?? "/bin/zsh"
        let startDir = directory.isEmpty ? nil : directory
        tv.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env,
            currentDirectory: startDir
        )

        // Focus terminal so user can type immediately
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
        }

        installClickToFocus(on: tv)
        installContextMenu(on: tv)
    }

    /// Clicking anywhere in the terminal hands it the keyboard. The event is passed on untouched,
    /// so SwiftTerm's own selection handling is unaffected.
    private func installClickToFocus(on tv: LocalProcessTerminalView) {
        guard clickFocusMonitor == nil else { return }
        clickFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self, weak tv] event in
            // Спрятанный терминал (нижняя полоса в режиме «Прятать») лежит поверх панелей
            // невидимым — щелчок по списку там не должен отдавать ему клавиатуру.
            guard let tv, let window = tv.window,
                  event.window === window, !tv.isHiddenOrHasHiddenAncestor, tv.superview != nil,
                  window.firstResponder !== tv
            else { return event }
            let inTerminal = tv.convert(event.locationInWindow, from: nil)
            if tv.bounds.contains(inTerminal) {
                window.makeFirstResponder(tv)
                self?.onActivated?()
            }
            return event
        }
    }

    private func removeClickToFocus() {
        if let clickFocusMonitor {
            NSEvent.removeMonitor(clickFocusMonitor)
            self.clickFocusMonitor = nil
        }
        if let contextMenuMonitor {
            NSEvent.removeMonitor(contextMenuMonitor)
            self.contextMenuMonitor = nil
        }
    }

    /// Правый щелчок (или ⌃-щелчок) по терминалу — своё меню программы. Сам SwiftTerm меню
    /// не показывает, а мышью удобнее, чем держать в голове клавиши.
    private func installContextMenu(on tv: LocalProcessTerminalView) {
        guard contextMenuMonitor == nil else { return }
        contextMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) {
            [weak self, weak tv] event in
            guard let self, let tv, let window = tv.window, event.window === window,
                  !tv.isHiddenOrHasHiddenAncestor,
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  tv.bounds.contains(tv.convert(event.locationInWindow, from: nil)),
                  let menu = self.makeContextMenu?()
            else { return event }
            window.makeFirstResponder(tv)
            self.onActivated?()
            ContextPopupMenuController.shared.show(menu, at: window.convertPoint(toScreen: event.locationInWindow))
            return nil
        }
    }

    /// Выделено ли что-нибудь в терминале — есть ли что копировать.
    var hasSelection: Bool { localTermView?.selectionActive ?? false }

    func copySelection() { localTermView?.copy(self) }

    func pasteClipboard() { localTermView?.paste(self) }

    func changeDirectory(_ path: String) {
        guard let tv = localTermView, path != currentDirectory else { return }
        currentDirectory = path
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "cd '\(escaped)'\n"
        let bytes = Array(cmd.utf8)
        tv.send(bytes)
    }

    // MARK: - Drag & Drop (file path insertion)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
              localTermView != nil else {
            return []
        }
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        guard let urls = sender.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]
              ) as? [URL] else {
            return false
        }
        // Источника нет — тащили из другой программы (Finder).
        return insertDroppedPaths(urls, fromAnotherApp: sender.draggingSource == nil)
    }

    /// Пути брошенных файлов — в строку терминала, и клавиатура — ему же.
    ///
    /// Бросок в терминал — это начало команды: дальше печатают здесь. Раньше путь вставлялся,
    /// а фокус оставался в списке, откуда тащили, и первое же нажатие уходило не туда.
    /// Из другой программы бросок ещё и выводит окно вперёд — иначе печатать было бы в Finder.
    @discardableResult
    func insertDroppedPaths(_ urls: [URL], fromAnotherApp: Bool) -> Bool {
        guard let tv = localTermView, !urls.isEmpty else { return false }
        let escapedPaths = urls.map { Self.shellEscapePath($0.path) }
        tv.send(Array(escapedPaths.joined(separator: " ").utf8))
        guard let window else { return true }
        if fromAnotherApp {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else if !window.isKeyWindow {
            window.makeKey()
        }
        window.makeFirstResponder(tv)
        onActivated?()
        return true
    }

    private func updateDropHighlight() {
        if isDropTarget {
            if dropHighlightBorder == nil {
                let border = CALayer()
                border.borderColor = NSColor.controlAccentColor.cgColor
                border.borderWidth = 2
                border.cornerRadius = 4
                border.frame = bounds
                border.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                layer?.addSublayer(border)
                dropHighlightBorder = border
            }
        } else {
            dropHighlightBorder?.removeFromSuperlayer()
            dropHighlightBorder = nil
        }
    }

    /// Escapes a file path for safe insertion into a shell command line.
    static func shellEscapePath(_ path: String) -> String {
        let safeChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-"))
        if path.unicodeScalars.allSatisfy({ safeChars.contains($0) }) {
            return path
        }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // SwiftTerm handles resize internally
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Could update window title if needed
    }

    nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        if let dir = directory {
            Task { @MainActor in
                self.currentDirectory = dir
            }
        }
    }

    nonisolated func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            // В разделении часть просто закрывается — как вкладка в iTerm после `exit`.
            if let onProcessExit = self.onProcessExit {
                onProcessExit()
                return
            }
            let msg = "\r\n[Process exited with code \(exitCode ?? -1)]\r\n"
            self.localTermView?.feed(text: msg)
        }
    }
}
