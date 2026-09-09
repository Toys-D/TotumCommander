import AppKit
import Foundation

/// Manages the Dock tile progress indicator during file operations.
@MainActor
final class DockProgressManager {
    static let shared = DockProgressManager()

    private var progressView: NSProgressIndicator?
    private var activeOperations = 0
    private var lastProgress: Double = 0

    private init() {}

    /// Show progress indicator on the Dock tile.
    func beginOperation() {
        activeOperations += 1
        guard activeOperations == 1 else { return }
        setupProgressView()
        lastProgress = 0
    }

    /// Update progress (0.0 – 1.0).
    func updateProgress(_ progress: Double) {
        lastProgress = progress
        progressView?.doubleValue = progress * 100
    }

    /// End one operation. Hides the indicator when all operations complete.
    func endOperation() {
        activeOperations = max(0, activeOperations - 1)
        guard activeOperations == 0 else { return }
        teardownProgressView()
    }

    /// Force-reset everything (app going to background, error, etc.)
    func reset() {
        activeOperations = 0
        teardownProgressView()
    }

    private func setupProgressView() {
        // NSApp is an IMPLICITLY unwrapped global and nil until NSApplication.shared exists —
        // under tests, or in any headless run of the service, touching it is a crash, found
        // the hard way by the undo tests driving a real move. No app, no dock, nothing to draw.
        guard let app = NSApp else { return }
        let dockTile = app.dockTile

        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: dockTile.size.width, height: dockTile.size.height))
        imageView.image = app.applicationIconImage

        let bar = NSProgressIndicator(frame: NSRect(
            x: 2,
            y: 4,
            width: dockTile.size.width - 4,
            height: 14
        ))
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 100
        bar.doubleValue = 0
        bar.isIndeterminate = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: dockTile.size.width, height: dockTile.size.height))
        container.addSubview(imageView)
        container.addSubview(bar)

        dockTile.contentView = container
        dockTile.display()
        progressView = bar
    }

    private func teardownProgressView() {
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
        progressView = nil
    }
}
