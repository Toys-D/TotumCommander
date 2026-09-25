import AppKit
import FCXLBridgeObjC
import FCXLDjVuUI

// Standalone DjVu reader shipped inside Totum Commander.app (Contents/Library).
// macOS has no DjVu support of any kind, so this exists so a .djvu can be read OUTSIDE
// the commander — the commander's own F3 viewer stays the in-place option. It shares the
// FCXLDjVuReader bridge with the commander; only the window is its own.

// MARK: - Window

final class ViewerWindowController: NSWindowController {
    private var pagesView: DjVuPagesView?

    convenience init(reader: FCXLDjVuReader, title: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.center()
        self.init(window: window)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.autoresizingMask = [.width, .height]

        let pages = DjVuPagesView(reader: reader)
        scrollView.documentView = pages
        pagesView = pages

        window.contentView = scrollView

        // Re-fit on resize; DjVuPagesView.layout() reads the clip width itself.
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            self?.pagesView?.needsLayout = true
        }
        scrollView.contentView.postsFrameChangedNotifications = true
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [ViewerWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched with a path argument (how the commander starts us). Finder passes
        // documents through application(_:open:) instead.
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first {
            open(path: path)
        } else if controllers.isEmpty {
            openPanel()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(path: url.path) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["djvu", "djv"]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            NSApp.terminate(nil)
            return
        }
        open(path: url.path)
    }

    private func open(path: String) {
        do {
            let reader = try FCXLDjVuReader(path: path)
            let controller = ViewerWindowController(
                reader: reader,
                title: (path as NSString).lastPathComponent)
            controllers.append(controller)
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось открыть DjVu"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
