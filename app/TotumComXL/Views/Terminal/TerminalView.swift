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

/// Keeps track of all live SwiftTermContainerView instances so we can
/// terminate their shell processes when the owning tab is closed.
@MainActor
final class TerminalProcessRegistry {
    static let shared = TerminalProcessRegistry()
    /// Fixed UUID for the bottom terminal panel (singleton).
    static let bottomTerminalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var views: [UUID: SwiftTermContainerView] = [:]

    func register(_ view: SwiftTermContainerView, for tabID: UUID) {
        views[tabID] = view
    }

    /// Return existing container for this tab (to reuse across SwiftUI re-renders).
    func existing(for tabID: UUID) -> SwiftTermContainerView? {
        views[tabID]
    }



    func terminate(tabID: UUID) {
        if let view = views[tabID] {
            view.terminateProcess()
            views[tabID] = nil
        }
    }

    func terminateAll() {
        for (_, view) in views { view.terminateProcess() }
        views.removeAll()
    }
}

/// SwiftUI wrapper for an embedded terminal panel powered by SwiftTerm.
struct TerminalPanelView: View {
    let initialDirectory: String
    @Binding var panelHeight: CGFloat
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 0) {
            TerminalResizeHandle(panelHeight: $panelHeight, isDragging: $isDragging)
            ZStack {
                SwiftTermRepresentable(initialDirectory: initialDirectory, frozen: isDragging)
                if isDragging {
                    Rectangle()
                        .fill(Color(nsColor: NSColor(white: 0.08, alpha: 1.0)))
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

// MARK: - Resize Handle

private struct TerminalResizeHandle: View {
    @Binding var panelHeight: CGFloat
    @Binding var isDragging: Bool
    @State private var dragStartY: CGFloat?
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 5)
            .contentShape(Rectangle())
            .cursor(.resizeUpDown)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartY == nil {
                            dragStartY = value.startLocation.y
                            dragStartHeight = panelHeight
                            isDragging = true
                        }
                        let delta = dragStartY! - value.location.y
                        panelHeight = max(80, min(600, dragStartHeight! + delta))
                    }
                    .onEnded { _ in
                        dragStartY = nil
                        dragStartHeight = nil
                        isDragging = false
                    }
            )
    }
}

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Embeddable Terminal View (for panel tabs)

/// Standalone terminal view for embedding in panel tabs.
struct EmbeddedTerminalView: NSViewRepresentable {
    let initialDirectory: String
    let tabID: UUID

    func makeNSView(context: Context) -> SwiftTermContainerView {
        // Reuse existing terminal to preserve history across tab switches
        if let existing = TerminalProcessRegistry.shared.existing(for: tabID) {
            return existing
        }
        let view = SwiftTermContainerView()
        view.startTerminal(directory: initialDirectory)
        TerminalProcessRegistry.shared.register(view, for: tabID)
        return view
    }

    func updateNSView(_ nsView: SwiftTermContainerView, context: Context) {}
}

// MARK: - NSViewRepresentable

private struct SwiftTermRepresentable: NSViewRepresentable {
    let initialDirectory: String
    let frozen: Bool

    func makeNSView(context: Context) -> SwiftTermContainerView {
        // Reuse existing bottom terminal to preserve history
        if let existing = TerminalProcessRegistry.shared.existing(for: TerminalProcessRegistry.bottomTerminalID) {
            return existing
        }
        let view = SwiftTermContainerView()
        view.startTerminal(directory: initialDirectory)
        TerminalProcessRegistry.shared.register(view, for: TerminalProcessRegistry.bottomTerminalID)
        return view
    }

    func updateNSView(_ nsView: SwiftTermContainerView, context: Context) {
        nsView.setFrozen(frozen)
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
        let tv = localTermView
        MainActor.assumeIsolated {
            tv?.terminate()
        }
    }

    /// Explicitly terminate the shell process (e.g. when closing a tab).
    func terminateProcess() {
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
        // Ensure essential vars are present
        for key in ["PATH", "HOME", "SHELL", "TMPDIR"] {
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
    }

    /// Clicking anywhere in the terminal hands it the keyboard. The event is passed on untouched,
    /// so SwiftTerm's own selection handling is unaffected.
    private func installClickToFocus(on tv: LocalProcessTerminalView) {
        guard clickFocusMonitor == nil else { return }
        clickFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak tv] event in
            guard let tv, let window = tv.window,
                  event.window === window, !tv.isHidden, tv.superview != nil,
                  window.firstResponder !== tv
            else { return event }
            let inTerminal = tv.convert(event.locationInWindow, from: nil)
            if tv.bounds.contains(inTerminal) {
                window.makeFirstResponder(tv)
            }
            return event
        }
    }

    private func removeClickToFocus() {
        if let clickFocusMonitor {
            NSEvent.removeMonitor(clickFocusMonitor)
            self.clickFocusMonitor = nil
        }
    }

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
        guard let tv = localTermView,
              let urls = sender.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]
              ) as? [URL], !urls.isEmpty else {
            return false
        }

        let escapedPaths = urls.map { Self.shellEscapePath($0.path) }
        let text = escapedPaths.joined(separator: " ")
        tv.send(Array(text.utf8))
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
            let msg = "\r\n[Process exited with code \(exitCode ?? -1)]\r\n"
            self.localTermView?.feed(text: msg)
        }
    }
}
