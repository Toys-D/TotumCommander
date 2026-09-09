import AppKit
import SwiftUI

/// One AppKit overlay spanning the whole sort bar that handles column-divider
/// resize for ALL columns at once — cursor feedback and dragging.
///
/// Why a single overlay instead of a small NSView per column: the visual
/// header is drawn by SortBarView in SwiftUI (NSTableView.headerView is nil),
/// and embedding one NSViewRepresentable per column divider inside SwiftUI
/// button overlays proved unreliable — the tiny NSViews didn't receive hover
/// (cursorUpdate) or mouse events through the SwiftUI Button + overlay stack,
/// so neither the resize cursor nor dragging worked. A single full-width NSView
/// that computes divider positions itself — the way NSTableHeaderView works
/// internally — receives events reliably and passes clicks that aren't near a
/// divider straight through to the sort buttons below.
@MainActor
struct ColumnResizeOverlay: NSViewRepresentable {

    /// A draggable divider: its x-position (from the bar's left edge), the
    /// column it resizes (the one to its left), and that column's current width.
    struct Divider {
        let x: CGFloat
        let column: PanelColumn
        let currentWidth: CGFloat
    }

    var dividers: [Divider]
    /// Live drag: absolute desired width for the column. Caller clamps/applies.
    var onResize: (PanelColumn, CGFloat) -> Void
    /// Drag ended — persist once.
    var onCommit: () -> Void
    /// Double-click on a divider → auto-fit that column to its content.
    var onAutoFit: (PanelColumn) -> Void

    func makeNSView(context: Context) -> ResizeView {
        let v = ResizeView()
        v.dividers = dividers
        v.onResize = onResize
        v.onCommit = onCommit
        v.onAutoFit = onAutoFit
        return v
    }

    func updateNSView(_ nsView: ResizeView, context: Context) {
        nsView.dividers = dividers
        nsView.onResize = onResize
        nsView.onCommit = onCommit
        nsView.onAutoFit = onAutoFit
    }

    @MainActor
    final class ResizeView: NSView {
        var dividers: [Divider] = [] {
            didSet { window?.invalidateCursorRects(for: self) }
        }
        var onResize: ((PanelColumn, CGFloat) -> Void)?
        var onCommit: (() -> Void)?
        var onAutoFit: ((PanelColumn) -> Void)?

        /// How close (points, each side) the pointer must be to a divider.
        private let tolerance: CGFloat = 4

        private var trackingArea: NSTrackingArea?
        private var dragColumn: PanelColumn?
        private var dragBaseWidth: CGFloat = 0
        private var dragStartX: CGFloat = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { super.init(coder: coder) }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let old = trackingArea { removeTrackingArea(old) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        /// Only claim the pointer when it's near a divider — everything else
        /// (sort-button clicks, right-clicks) passes through to the views below.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard nearestDivider(toLocalX: local.x) != nil else { return nil }
            // Let right-clicks reach the sort-bar context menu.
            if let e = NSApp.currentEvent, e.type == .rightMouseDown { return nil }
            return self
        }

        override func cursorUpdate(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            if nearestDivider(toLocalX: local.x) != nil {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }

        override func mouseMoved(with event: NSEvent) {
            cursorUpdate(with: event)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { NSCursor.arrow.set() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func mouseDown(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            guard let d = nearestDivider(toLocalX: local.x) else { return }
            // Double-click on a divider auto-fits the column to its content
            // (Excel/Finder behaviour) — don't start a drag.
            if event.clickCount == 2 {
                onAutoFit?(d.column)
                return
            }
            dragColumn = d.column
            dragBaseWidth = d.currentWidth
            dragStartX = event.locationInWindow.x
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let column = dragColumn else { return }
            let delta = event.locationInWindow.x - dragStartX
            onResize?(column, dragBaseWidth + delta)
        }

        override func mouseUp(with event: NSEvent) {
            guard dragColumn != nil else { return }
            dragColumn = nil
            onCommit?()
        }

        private func nearestDivider(toLocalX x: CGFloat) -> Divider? {
            dividers.first { abs($0.x - x) <= tolerance }
        }
    }
}
