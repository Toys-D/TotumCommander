import AppKit
import SwiftUI

/// Shows an `NSMenu` as a CUSTOM borderless popover (not a native menu) so that
/// submenus open on CLICK (a second panel to the right), and the whole thing is
/// drawn by us with the app accent + the configurable context-menu sizes.
///
/// We reuse the existing menu-building code: it still produces an `NSMenu`, and
/// this controller renders that menu's items (title / image / action / submenu).
@MainActor
final class ContextPopupMenuController {
    static let shared = ContextPopupMenuController()

    private var panels: [NSPanel] = []
    private var monitors: [Any] = []
    /// Строка меню открылась или программа ушла на задний план — наше меню гаснет, как
    /// погасло бы системное. Щелчок по строке меню до мониторов не доходит: его забирает
    /// слежение за меню, поэтому слушаем само начало слежения.
    private var outsideObservers: [NSObjectProtocol] = []
    /// The submenu parent each open child panel belongs to, so a hover that lands on the row
    /// whose submenu is ALREADY up does not tear it down and build it again.
    private var openedFor: [ObjectIdentifier?] = []

    /// Строки открытого меню и его размер вместе со спрятанной частью: этого хватает,
    /// чтобы «Ещё» дописало список прямо в это окно.
    private var rootRows: ContextPopupRows?
    private var expandedSize: NSSize?

    /// Что сейчас показано в открытом меню и в каком оно окне. Этим же смотрят проверки:
    /// «Ещё» обязано менять список, не меняя окна.
    var openMenuRows: [NSMenuItem] { rootRows?.items ?? [] }
    var openMenuWindow: NSWindow? { panels.first }

    /// Show `menu` with its top-left near `screenPoint` (AppKit screen coords).
    func show(_ menu: NSMenu, at screenPoint: NSPoint) {
        dismiss()
        let panel = makePanel(for: menu, level: 0)
        position(panel, preferredTopLeft: screenPoint)
        panel.orderFront(nil)
        panels.append(panel)
        installMonitors()
    }

    func dismiss() {
        isPreview = false
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        for observer in outsideObservers { NotificationCenter.default.removeObserver(observer) }
        outsideObservers.removeAll()
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
        openedFor.removeAll()
        rootRows = nil
        expandedSize = nil
    }

    // MARK: - Preview

    /// Whether what is on screen is the settings preview, not a menu anybody opened.
    private(set) var isPreview = false

    /// Show a menu as a PICTURE: for the settings page, where the person turns the blur knobs
    /// and wants to see a real menu over the real file panel while turning them. It takes no
    /// clicks — a preview that could delete files is not a preview — and installs none of the
    /// dismiss monitors, so working the sliders in the settings window does not blow it away.
    func showPreview(_ menu: NSMenu, at screenPoint: NSPoint) {
        dismiss()
        isPreview = true
        let panel = makePanel(for: menu, level: 0)
        panel.ignoresMouseEvents = true
        position(panel, preferredTopLeft: screenPoint)
        panel.orderFront(nil)
        panels.append(panel)
    }

    /// Take the preview down — and only the preview: a real menu the person opened stays.
    func dismissPreview() {
        guard isPreview else { return }
        dismiss()
    }

    // MARK: - Panels

    private func makePanel(for menu: NSMenu, level: Int) -> NSPanel {
        // Ширину меряем сразу по ПОЛНОМУ списку — вместе со спрятанным под «Ещё». Тогда
        // раскрытие только удлиняет меню вниз: ни одна строка не съезжает вбок.
        let full = expandedItems(of: menu.items).map { measure($0, minWidth: ContextMenuSettings.minWidth) }
        let minWidth = max(ContextMenuSettings.minWidth, full?.width ?? 0)
        let rows = ContextPopupRows(menu.items)
        let host = NSHostingController(rootView: ContextPopupMenuView(
            rows: rows,
            minWidth: minWidth,
            onLeaf: { [weak self] item in self?.invoke(item) },
            onSubmenu: { [weak self] item, rowTopInPanel in
                self?.openSubmenu(item, fromLevel: level, rowTopInPanel: rowTopInPanel)
            },
            onHoverSettledOnLeaf: { [weak self] in self?.closeDeeper(than: level) }
        ))
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // ARC owns this window (a strong reference is kept) — without this flag
        // close() ALSO releases it and the second release crashes (SearchWindow bug).
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.contentViewController = host
        panel.setContentSize(size)
        if level == 0 {
            rootRows = rows
            expandedSize = full
        }
        return panel
    }

    /// Полный список строк меню: показанное плюс спрятанное под «Ещё». Нет «Ещё» —
    /// нет и списка: обычное меню мерить второй раз незачем.
    private func expandedItems(of items: [NSMenuItem]) -> [NSMenuItem]? {
        guard let more = items.last as? ContextMoreMenuItem, !more.hiddenRows.isEmpty else { return nil }
        return items.dropLast() + more.hiddenRows
    }

    /// Размер, который займут эти строки. Меряем настоящим вью — той же вёрсткой, что
    /// потом и покажем, — а не арифметикой по высоте строки: разделители и отступы
    /// живут в вёрстке, и считать их вторым способом значит однажды разойтись с ней.
    private func measure(_ items: [NSMenuItem], minWidth: CGFloat) -> NSSize {
        let host = NSHostingController(rootView: ContextPopupMenuView(
            rows: ContextPopupRows(items), minWidth: minWidth,
            onLeaf: { _ in }, onSubmenu: { _, _ in }, onHoverSettledOnLeaf: {}))
        host.view.layoutSubtreeIfNeeded()
        return host.view.fittingSize
    }

    private func openSubmenu(_ item: NSMenuItem, fromLevel level: Int, rowTopInPanel: CGFloat) {
        guard let submenu = item.submenu else { return }
        // Already showing this very submenu — a second call (hover after a click, say) must
        // leave it alone rather than blink it off and on.
        if panels.count > level + 1, openedFor[safe: level + 1] == ObjectIdentifier(item) { return }
        closeDeeper(than: level)
        guard let parentPanel = panels[safe: level] else { return }

        let child = makePanel(for: submenu, level: level + 1)
        let pf = parentPanel.frame
        // Top-left of the child: to the right of the parent, aligned to the row.
        let topLeft = NSPoint(x: pf.maxX - 4, y: pf.maxY - rowTopInPanel)
        position(child, preferredTopLeft: topLeft, leftAlternative: pf.minX - child.frame.width + 4)
        child.orderFront(nil)
        panels.append(child)
        while openedFor.count < panels.count { openedFor.append(nil) }
        openedFor[panels.count - 1] = ObjectIdentifier(item)
    }

    /// Drop every panel deeper than `level` — what happens when the pointer settles on a row
    /// that has no submenu of its own.
    private func closeDeeper(than level: Int) {
        while panels.count > level + 1 {
            panels.removeLast().orderOut(nil)
            if openedFor.count > panels.count { openedFor.removeLast() }
        }
    }

    /// Place a panel so its top-left is at `topLeft`, nudged to stay on screen.
    private func position(_ panel: NSPanel, preferredTopLeft topLeft: NSPoint, leftAlternative: CGFloat? = nil) {
        let size = panel.frame.size
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(topLeft) }) ?? NSScreen.main else {
            panel.setFrameTopLeftPoint(topLeft); return
        }
        let vf = screen.visibleFrame
        var x = topLeft.x
        if x + size.width > vf.maxX, let alt = leftAlternative { x = alt }
        x = min(max(x, vf.minX), vf.maxX - size.width)
        var top = topLeft.y
        top = min(top, vf.maxY)                 // not above the top
        if top - size.height < vf.minY { top = vf.minY + size.height }   // not below the bottom
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
    }

    // MARK: - Actions

    private func invoke(_ item: NSMenuItem) {
        // «Ещё» ничего не выполняет: его дело — дописать спрятанную часть в это же окно.
        // Меню остаётся ровно там, где человек его открыл, и уже прочитанные строки
        // остаются на своих местах.
        if let more = item as? ContextMoreMenuItem { expandOpenMenu(more); return }
        dismiss()
        MenuActionDispatch.run(item)
    }

    /// Раскрыть меню на месте: строка «Ещё» уходит, на её месте продолжается список,
    /// окно подрастает вниз ровно на столько, сколько померили при открытии.
    func expandOpenMenu(_ more: ContextMoreMenuItem) {
        guard let rows = rootRows, let panel = panels.first, !more.hiddenRows.isEmpty else { return }
        closeDeeper(than: 0)
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        rows.items = rows.items.filter { $0 !== more } + more.hiddenRows
        if let expandedSize {
            panel.setContentSize(expandedSize)
            // Не поместилось вниз — окно приподнимется, но не уйдёт за край экрана.
            position(panel, preferredTopLeft: topLeft)
        }
    }

    // MARK: - Dismiss monitors

    private func installMonitors() {
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.dismiss(); return nil }   // Esc
                return event
            }
            // Decide by SCREEN LOCATION — event.window is unreliable for a
            // borderless, non-key panel. A click inside any panel is SwiftUI's.
            let loc = NSEvent.mouseLocation
            if self.panels.contains(where: { $0.frame.contains(loc) }) {
                return event
            }
            self.dismiss()
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        if let local { monitors.append(local) }
        if let global { monitors.append(global) }
        for name in [NSMenu.didBeginTrackingNotification, NSApplication.didResignActiveNotification] {
            outsideObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - SwiftUI rendering

/// Строки одного окна меню. Меняются на месте — на этом и держится «Ещё»: список
/// дописывается в уже открытое окно, а не собирается заново.
private final class ContextPopupRows: ObservableObject {
    @Published var items: [NSMenuItem]
    init(_ items: [NSMenuItem]) { self.items = items }
}

private struct ContextPopupMenuView: View {
    @ObservedObject var rows: ContextPopupRows
    /// Ширина по полному списку, спрятанное включая: «Ещё» тогда только удлиняет меню.
    let minWidth: CGFloat
    let onLeaf: (NSMenuItem) -> Void
    /// rowTopInPanel = distance from the panel's TOP to the row's top (for submenu alignment).
    let onSubmenu: (NSMenuItem, CGFloat) -> Void
    /// The pointer has rested on a row that opens nothing — an open submenu should go.
    let onHoverSettledOnLeaf: () -> Void

    private var items: [NSMenuItem] { rows.items }

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    /// Drives the opening moment: the border traces itself around the menu and the rows
    /// flutter in behind it. Fast on purpose — the whole thing is over in a third of a second,
    /// an effect the eye catches without the hand ever waiting for it.
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Group {
                    if item.isSeparatorItem {
                        Divider().padding(.vertical, 3)
                    } else {
                        ContextPopupRow(item: item, accent: accent,
                                        rowHeight: ContextMenuSettings.rowHeight,
                                        action: {
                            if item.submenu != nil {
                                onSubmenu(item, rowTop(forIndex: index))
                            } else {
                                onLeaf(item)
                            }
                        },
                                        onHoverSettled: {
                            // Hovering opens a submenu too, after a beat — some people expect
                            // the click, some expect the hover, and waiting a moment lets a
                            // pointer travelling ACROSS the menu pass without dragging panels
                            // open behind it.
                            if item.submenu != nil {
                                onSubmenu(item, rowTop(forIndex: index))
                            } else {
                                onHoverSettledOnLeaf()
                            }
                        })
                    }
                }
                // Each row a breath after the one above: reading order, at reading speed.
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : -4)
                .animation(.easeOut(duration: 0.14).delay(Double(index) * 0.016),
                           value: appeared)
            }
        }
        .padding(6)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        // The accent border DRAWS itself around the menu, starting at the corner facing the
        // file the menu was opened for — the same accent the cursor bar wears, so the eye
        // reads one thread: the row, and the menu growing out of it.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .trim(from: 0, to: appeared ? 1 : 0)
                .stroke(accent.opacity(0.55), lineWidth: 1.5)
                .animation(.easeOut(duration: 0.3), value: appeared)
        )
        .onAppear {
            // One runloop later, AFTER the first layout has settled. Flipped in the same
            // frame, the reveal animation also caught the menu's own widths resolving — and
            // every submenu chevron drifted to the right edge on its own schedule.
            DispatchQueue.main.async { appeared = true }
        }
    }

    /// Approximate row-top within the panel for submenu alignment.
    private func rowTop(forIndex index: Int) -> CGFloat {
        var y: CGFloat = 6   // top padding
        for i in 0..<index {
            y += items[i].isSeparatorItem ? (1 + 6) : (ContextMenuSettings.rowHeight + 1)
        }
        return y
    }
}

private struct ContextPopupRow: View {
    let item: NSMenuItem
    let accent: Color
    let rowHeight: CGFloat
    let action: () -> Void
    /// Called once the pointer has rested here long enough to mean it.
    let onHoverSettled: () -> Void
    @State private var hovering = false
    @State private var hoverWork: DispatchWorkItem?

    /// How long the pointer must rest before a submenu opens by itself. Long enough that
    /// crossing the menu on the way somewhere else opens nothing, short enough that waiting
    /// for it does not feel like waiting.
    private static let hoverDelay: TimeInterval = 0.2

    var body: some View {
        let baseColor = (item.attributedTitle?.length ?? 0) > 0
            ? Color(nsColor: (item.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) ?? .labelColor)
            : Color.primary
        // A row that cannot act says so by looking spent: no highlight follows the pointer,
        // and the click does nothing. Hiding it instead would leave the user hunting for a
        // command that was there a moment ago on another file.
        let enabled = item.isEnabled
        let textColor = !enabled ? Color.secondary.opacity(0.55)
                                 : (hovering ? PanelAppearanceSettings.contrastingTextColor(on: accent)
                                             : baseColor)

        Button(action: { if enabled { action() } }) {
            HStack(spacing: 7) {
                if let image = item.image {
                    Image(nsImage: tinted(image, to: hovering ? NSColor(textColor) : nil))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: ContextMenuSettings.iconSize, height: ContextMenuSettings.iconSize)
                }
                Text(item.title)
                    .font(.system(size: ContextMenuSettings.fontSize))
                Spacer(minLength: 12)
                // These rows are drawn by hand, so AppKit's state column does not exist here — an
                // item that sets .state = .on (a set tag, the active tab) would look identical to
                // an unset one without this.
                if item.state == .on {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                }
                if item.submenu != nil {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, ContextMenuSettings.padding)
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && enabled ? accent : Color.clear,
                        in: RoundedRectangle(cornerRadius: ContextMenuSettings.cornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside && enabled
            hoverWork?.cancel()
            guard inside, enabled, !item.isSeparatorItem else { return }
            let work = DispatchWorkItem { onHoverSettled() }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
        }
        .onDisappear { hoverWork?.cancel() }
        .help(enabled ? "" : (item.toolTip ?? ""))
    }

    private func tinted(_ image: NSImage, to color: NSColor?) -> NSImage {
        guard image.isTemplate, let color else { return image }
        let out = NSImage(size: image.size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }
}
