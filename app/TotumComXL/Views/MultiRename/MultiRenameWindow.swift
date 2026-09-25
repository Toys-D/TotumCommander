import AppKit
import SwiftUI

/// Owns the Multi-Rename tool window. Resizable, chromeless (our in-content header + bottom bar
/// own the window), and single-instance. Modeled on AdvancedSearchPanelController — but a fresh
/// view model each open, because unlike a search the exact file set is the whole point.
@MainActor
final class MultiRenameWindow {
    static let shared = MultiRenameWindow()
    private var window: NSWindow?
    private var vm: MultiRenameViewModel?

    func show(items: [FileItem],
              rootPath: String,
              session: RemoteSession?,
              queue: OperationQueueService,
              onRenamed: @escaping () -> Void) {
        let viewModel = MultiRenameViewModel(items: items, rootPath: rootPath,
                                             session: session, queue: queue)
        viewModel.onRenamed = onRenamed
        self.vm = viewModel

        let content = MultiRenameView(vm: viewModel, onClose: { [weak self] in self?.close() })

        if let window {
            window.contentView = NSHostingView(rootView: content)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let w = MultiRenameNSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                                    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        // NSWindow defaults to isReleasedWhenClosed = true; close() would then over-release while
        // this controller still holds a reference and crash (same as SearchWindow).
        w.isReleasedWhenClosed = false
        w.title = L("mrt.title")
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.isMovableByWindowBackground = true
        w.contentView = NSHostingView(rootView: content)
        SettingsWindowAnimator.centerOnScreen(w)
        SettingsWindowAnimator.growOpen(w)
        w.makeKeyAndOrderFront(nil)
        self.window = w
    }

    func close() {
        if let window { SettingsWindowAnimator.closeWithShrink(window) }
        window = nil
        vm = nil
    }
}

private final class MultiRenameNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { MultiRenameWindow.shared.close() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { MultiRenameWindow.shared.close(); return }   // ESC
        super.keyDown(with: event)
    }
}
