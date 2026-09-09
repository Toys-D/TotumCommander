import AppKit
import OSLog

// MARK: - PanelActionDelegate

/// Protocol for PanelViewController to request actions from its parent controller.
protocol PanelActionDelegate: AnyObject {
    func panelDidRequestCopy(_ panel: PanelViewController, items: [FileItem])
    func panelDidRequestMove(_ panel: PanelViewController, items: [FileItem])
    func panelDidRequestCopy(_ panel: PanelViewController, items: [FileItem], to destination: String)
    func panelDidRequestMove(_ panel: PanelViewController, items: [FileItem], to destination: String)
    func panelDidRequestDelete(_ panel: PanelViewController, items: [FileItem])
    /// Shift+Del / Shift+F8 — delete bypassing the Trash, after its own red confirmation.
    func panelDidRequestDeletePermanently(_ panel: PanelViewController, items: [FileItem])
    /// Put items back where they were deleted from.
    func panelDidRequestRestoreFromTrash(_ panel: PanelViewController, items: [FileItem])
    /// Empty the Trash completely.
    func panelDidRequestEmptyTrash(_ panel: PanelViewController)
    func panelDidRequestMkdir(_ panel: PanelViewController)
    func panelDidRequestRename(_ panel: PanelViewController, item: FileItem)
    func panelDidRequestInlineRename(_ panel: PanelViewController, item: FileItem, newName: String)
    func panelDidRequestMultiRename(_ panel: PanelViewController)
    func panelDidRequestCreateTextFile(_ panel: PanelViewController)
    func panelDidRequestView(_ panel: PanelViewController, item: FileItem)
    func panelDidRequestEdit(_ panel: PanelViewController, item: FileItem)
    func panelDidRequestProperties(_ panel: PanelViewController, item: FileItem)
    /// TC's Files ▸ Change Attributes: permissions and dates over the whole selection.
    func panelDidRequestChangeAttributes(_ panel: PanelViewController, items: [FileItem])
    /// Open a folder in the user's EXTERNAL terminal (see ExternalTerminal.chosen).
    func panelDidRequestOpenInTerminal(_ panel: PanelViewController, path: String)
    func panelDidRequestPack(_ panel: PanelViewController, items: [FileItem])
    /// "Archive here" — pack into the folder the cursor is already in. The format comes from
    /// the submenu the user picked, so there is nothing left to ask.
    func panelDidRequestPackInPlace(_ panel: PanelViewController, items: [FileItem],
                                    format: ArchiveFormat)
    func panelDidRequestExtract(_ panel: PanelViewController, items: [FileItem])
    /// Entries dragged OUT of an archive and dropped on a plain folder — extract them there.
    func panelDidRequestExtractEntries(_ panel: PanelViewController, entries: [String],
                                       fromArchive archivePath: String, to destination: String)
    func panelDidRequestPasteFromClipboard(_ panel: PanelViewController)
    func panelDidRequestNetwork(_ panel: PanelViewController)
    /// Чип подключения другой панели: открыть то же место в этой панели.
    func panelDidRequestOpenRemote(_ panel: PanelViewController, connection: RemoteConnection)
    /// Извлечение чужого чипа: закрыть сессию там, где она живёт.
    func panelDidRequestDisconnectRemote(_ panel: PanelViewController, session: RemoteSession)
    func panelDidRequestCreateSymlink(_ panel: PanelViewController, item: FileItem)
    func panelDidRequestCreateAlias(_ panel: PanelViewController, item: FileItem)
    func panelDidRequestCreateHardlink(_ panel: PanelViewController, item: FileItem)
}

// MARK: - Menu Item Action Target

/// Generic closure-based target for NSMenuItem actions.
final class MenuItemActionTarget: NSObject {
    let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
        super.init()
    }

    @objc func invoke(_ sender: NSMenuItem) {
        callback()
    }
}

// MARK: - Open With App Target

/// A menu item that runs a closure. Named for what it was first written for — "Open With" —
/// and used wherever a click has to do something the item itself cannot hold, such as packing a
/// file before handing it to a share panel.
final class OpenWithAppMenuTarget: NSObject {
    let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
        super.init()
    }

    @objc func open(_ sender: NSMenuItem) {
        callback()
    }
}

// MARK: - Sharing Service Target

/// One "send this to Telegram" click, held for as long as the share panel is up.
///
/// Two things the sharing framework needs that a menu item cannot give it:
///
/// * **A source window.** Without one the framework logs "Source window not provided" and puts
///   the panel up owned by nothing — it belongs to no window of ours, which is what makes it
///   behave like a stray: it does not close with the window it came from and does not come
///   forward with it either.
/// * **An owner that outlives the menu.** The click tears the menu down, and with it every
///   strong reference to this object; the panel meanwhile stays up while the person searches
///   for a chat and types a comment. So the session is held here until the service reports it
///   over — either way. It used to be held for thirty seconds, which is less than it takes to
///   find a chat: the panel then went dead in the user's hands, with nothing to click and
///   nothing sent.
final class SharingServiceMenuTarget: NSObject, NSSharingServiceDelegate {
    let service: NSSharingService
    let items: [Any]
    /// Weak: the window may go while the panel is up, and that must not keep it alive.
    private weak var sourceWindow: NSWindow?

    /// Every window the app had before the panel went up. What appears after it is the panel —
    /// the only handle there is on a window drawn by somebody else's extension.
    private var windowsBeforePanel: Set<ObjectIdentifier> = []

    /// The sessions on screen right now.
    private static var liveSessions: [SharingServiceMenuTarget] = []
    /// A service that never reports back would sit in that list for ever. Nobody has eight
    /// share panels open at once, so keeping the newest few puts a ceiling on it without ever
    /// cutting a session that is still being used.
    private static let maximumLiveSessions = 8

    static var liveSessionCount: Int { liveSessions.count }

    /// Telegram's panel does not close by its own button, so it — and only it — gets a note
    /// beside it saying which keys do.
    private let warnsAboutStuckPanel: Bool

    init(service: NSSharingService, items: [Any], sourceWindow: NSWindow? = nil,
         warnsAboutStuckPanel: Bool = false) {
        self.service = service
        self.items = items
        self.sourceWindow = sourceWindow
        self.warnsAboutStuckPanel = warnsAboutStuckPanel
        super.init()
    }

    @objc func performSharingAction(_ sender: Any?) {
        beginSession()
        service.perform(withItems: items)
        if warnsAboutStuckPanel { showHintWhenPanelAppears() }
    }

    /// Watch for the panel and put the note beside it. The panel is built by an extension in
    /// another process and takes a moment to appear; there is no notification of it, so it is
    /// looked for a few times and then given up on.
    private func showHintWhenPanelAppears() {
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                attempts += 1
                guard let self else { timer.invalidate(); return }
                if let panel = Self.panelWindows(in: NSApp.windows,
                                                 excluding: self.windowsBeforePanel)
                    .first(where: Self.isPanelWindow) {
                    timer.invalidate()
                    SharePanelHint.shared.attach(to: panel)
                } else if attempts >= 12 {
                    timer.invalidate()
                }
            }
        }
    }

    /// Split out from the click so the lifetime can be watched without a panel on screen.
    func beginSession() {
        service.delegate = self
        windowsBeforePanel = Set(NSApp.windows.map(ObjectIdentifier.init))
        installEscapeHatch()
        Self.liveSessions.append(self)
        if Self.liveSessions.count > Self.maximumLiveSessions {
            Self.liveSessions.removeFirst().service.delegate = nil
        }
    }

    /// Let the session go — but not this instant.
    ///
    /// An NSSharingService keeps its delegate alive (whatever the header says about that
    /// property being weak), so this object and its service hold each other, and letting go
    /// means breaking that pair as well as leaving the list. Both are done a turn later,
    /// because this is normally called from inside a delegate callback: dropping the last
    /// reference there would deallocate the very object AppKit is in the middle of calling.
    func endSession() {
        if Self.watchedSession === self { Self.removeEscapeHatch() }
        DispatchQueue.main.async { [self] in
            service.delegate = nil
            Self.liveSessions.removeAll { $0 === self }
        }
    }

    // MARK: - A way out

    /// Esc — or Cmd+. , the other old way of saying "stop" — closes the share panel.
    ///
    /// The panel is another app's extension drawn inside a window of OURS, and whether its own
    /// close button answers the mouse is not ours to decide: on this Mac it does not, and not
    /// from Finder either. The window itself, though, is in our list, and closing it ends the
    /// request — so there is always a way back out of a share nobody wants to finish.
    private func installEscapeHatch() {
        // ONE watcher for the whole app, pointed at the newest share — never one per session.
        // A session whose service never reports back keeps its place in the list, and its
        // watcher would go on judging clicks by the windows of a share that is long gone. It
        // must also be a single owner: a monitor taken away from one session and released
        // again by another is a double free, and that is a crash, not a leak.
        Self.removeEscapeHatch()
        Self.watchedSession = self
        Self.currentEscapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { event in
            guard let self = Self.watchedSession else {
                Self.removeEscapeHatch()
                return event
            }
            guard Self.isCancelKey(event) else { return event }
            return self.closeSharePanel() ? nil : event
        }
    }

    /// Ask the sharing service to take its own panel down. False when it will not answer —
    /// then there is nothing to do but close the windows.
    private func dismissThroughFramework() -> Bool {
        guard !Self.panelWindows(in: NSApp.windows, excluding: windowsBeforePanel).isEmpty
        else { return false }
        return Self.askFrameworkToDismiss(service)
    }

    /// The call itself, apart from the panel it applies to, so a test can prove it is made the
    /// way the framework expects.
    ///
    /// The completion is handed over as a block held in a variable — a real object with a life
    /// of its own. Written as a bare closure through a C function pointer it is a NON-escaping
    /// closure, and the framework, which keeps it until the panel has finished closing, trips
    /// Swift's own check: "non-escaping closure has escaped", which is a crash, not a warning.
    @discardableResult
    static func askFrameworkToDismiss(_ service: NSSharingService) -> Bool {
        guard hasFrameworkDismiss(service) else { return false }
        let completion: @convention(block) () -> Void = {}
        log.notice("dismissing the share panel through the framework")
        _ = service.perform(dismissSelector, with: completion)
        return true
    }

    static let dismissSelector = NSSelectorFromString("dismissWithCompletion:")

    static func hasFrameworkDismiss(_ service: NSSharingService) -> Bool {
        service.responds(to: dismissSelector)
    }

    private static var currentEscapeMonitor: Any?
    /// Weak: the watcher must never be the reason a finished session is still here.
    private static weak var watchedSession: SharingServiceMenuTarget?

    private static func removeEscapeHatch() {
        if let monitor = currentEscapeMonitor { NSEvent.removeMonitor(monitor) }
        currentEscapeMonitor = nil
        watchedSession = nil
    }

    /// The panel is the framework's remote window — the one the other app draws into
    /// (`SHKRemoteWindow`). The darkening beside it (`SHKDimAndShadowWindow`, `SHKBlurWindow`)
    /// is not.
    static func isPanelWindow(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("Remote")
    }

    static func isCancelKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { return true }                        // Esc
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 47 && modifiers == [.command]         // Cmd+.
    }

    /// Closes what this session put up — and that is more than the panel: the framework also
    /// darkens the window behind it, and the darkening is a window of its own. Closing only the
    /// panel left the app greyed out and unusable, which is worse than the panel that would not
    /// go. So everything that appeared for this share goes together, and the window it was
    /// started from comes back to the front.
    ///
    /// False when there is nothing of the sort on screen — then the key belongs to whoever else
    /// wants it.
    @discardableResult
    func closeSharePanel() -> Bool {
        // The framework's own way of taking the panel down, and the only one that leaves it
        // able to open another. Closing the windows by hand looks the same on screen but the
        // framework never learns the share is over: it keeps the service registered and every
        // later send does nothing at all — the panel simply never appears again.
        //
        // `dismissWithCompletion:` is not in the headers, so it is asked for rather than
        // assumed, and the windows are closed by hand only if it is ever taken away.
        if dismissThroughFramework() {
            MainActor.assumeIsolated { SharePanelHint.shared.hide() }
            endSession()
            return true
        }

        let panels = Self.panelWindows(in: NSApp.windows, excluding: windowsBeforePanel)
        guard !panels.isEmpty else {
            // Nothing matched: say what WAS on screen, so a panel the framework names
            // differently on some macOS can be recognised without guessing twice.
            let inventory = NSApp.windows
                .filter { $0.isVisible && !windowsBeforePanel.contains(ObjectIdentifier($0)) }
                .map { String(describing: type(of: $0)) }
                .joined(separator: ", ")
            Self.log.notice("nothing to close; new windows: [\(inventory, privacy: .public)]")
            return false
        }
        for panel in panels {
            Self.log.notice("closing \(String(describing: type(of: panel)), privacy: .public)")
            panel.close()
        }
        // The share left the app dimmed and without a key window; give it back its own.
        MainActor.assumeIsolated { SharePanelHint.shared.hide() }
        sourceWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        endSession()
        return true
    }

    /// Which windows belong to the share: those that were not there before it began and are on
    /// screen now. Ours are ruled out by the module they come from — everything else that
    /// appeared was put up by the sharing framework, panel and darkening alike, and picking
    /// only the one that LOOKS like the panel is exactly what left the darkening behind.
    static func panelWindows(in windows: [NSWindow],
                             excluding known: Set<ObjectIdentifier>,
                             isOwn: (NSWindow) -> Bool = isOwnWindow) -> [NSWindow] {
        windows.filter {
            $0.isVisible && !known.contains(ObjectIdentifier($0)) && !isOwn($0)
        }
    }

    static func isOwnWindow(_ window: NSWindow) -> Bool {
        String(reflecting: type(of: window)).hasPrefix("TotumComXLApp.")
    }

    static let log = Logger(subsystem: "com.fcxl", category: "Share")

    // MARK: - NSSharingServiceDelegate

    func sharingService(_ sharingService: NSSharingService,
                        sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>)
        -> NSWindow? {
        // .item: what is being shared is one thing in the window, not the window itself — that
        // is what keeps the panel from dimming the whole app behind it.
        sharingContentScope.pointee = .item
        return sourceWindow
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated { SharePanelHint.shared.hide() }
        endSession()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any],
                        error: Error) {
        MainActor.assumeIsolated { SharePanelHint.shared.hide() }
        endSession()
    }
}

// MARK: - NSMenu Extension

extension NSMenu {
    /// Adds a styled menu item with an SF Symbol icon and closure action.
    /// - `isDestructive`: red, for destructive commands.
    /// - `tint`: any other colour, for items worth spotting without reading them.
    /// - id: устойчивое имя пункта — ключ строки, по которому человек раскладывает меню
    ///   на основную и дополнительную части. Устойчивое к смене языка, в отличие от подписи.
    func addStyledItem(title: String,
                       symbolName: String,
                       isDestructive: Bool = false,
                       tint: NSColor? = nil,
                       id: String? = nil,
                       action: @escaping () -> Void) {
        let target = MenuItemActionTarget(callback: action)
        let item = NSMenuItem(
            title: title,
            action: #selector(MenuItemActionTarget.invoke(_:)),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = target
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            image.isTemplate = true
            item.image = image
        }
        if let color = isDestructive ? NSColor.systemRed : tint {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: color]
            )
        }
        if let id { item.identifier = NSUserInterfaceItemIdentifier(id) }
        addItem(item)
    }

    /// Wrap EVERY item (recursively through submenus) in a custom view so the
    /// highlight uses the app ACCENT instead of the macOS system colour. Preserves
    /// each item's icon, title colour, action and submenu. Call ONCE after the
    /// menu is fully built — native behaviour (keyboard, submenus) is kept.
    func applyAccentStyle() {
        var rows: [AccentMenuItemView] = []
        for item in items {
            item.submenu?.applyAccentStyle()
            guard !item.isSeparatorItem, item.view == nil else { continue }

            let baseColor: NSColor = {
                guard let attr = item.attributedTitle, attr.length > 0,
                      let color = attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                else { return .labelColor }
                return color
            }()
            let hasSub = item.submenu != nil
            let onTap: (() -> Void)? = hasSub ? nil : { [weak item] in
                guard let item else { return }
                MenuActionDispatch.run(item)
            }
            let view = AccentMenuItemView(title: item.title, image: item.image,
                                          baseTextColor: baseColor, hasSubmenu: hasSub, onTap: onTap)
            item.view = view
            rows.append(view)
        }
        // Auto-size: every row gets the width of the LONGEST item (so no title is
        // clipped), but never narrower than the configured minimum width — that's
        // what widens narrow submenus. Applied per menu and per submenu.
        if !rows.isEmpty {
            let target = max(rows.map(\.naturalWidth).max() ?? 0, ContextMenuSettings.minWidth)
            rows.forEach { $0.setRowWidth(target) }
        }
    }
}

/// Исполнить действие пункта меню — одинаково всюду, где меню рисуем мы сами.
enum MenuActionDispatch {

    /// Своя цель — прямой вызов. Так это работало всегда, и только так действие доходит,
    /// когда открыто модальное окно настроек: `sendAction` в модальном сеансе разбирает
    /// действия по цепочке ответственности модального окна, а обычный объект-приёмник в
    /// неё не входит — и щелчок по строке списка молча пропадал.
    ///
    /// Цели нет — это команда строки меню, попавшая в собранное человеком контекстное
    /// меню: у пунктов строки меню цели не бывает, её ищут по цепочке ответственности.
    ///
    /// `NSApplication.shared`, а не `NSApp`: глобальная `NSApp` — неявно развёрнутый ноль,
    /// пока приложение не создано, и первое же обращение из проверки роняет её насмерть.
    @discardableResult
    static func run(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        if let target = item.target as? NSObject {
            target.perform(action, with: item)
            return true
        }
        return NSApplication.shared.sendAction(action, to: nil, from: item)
    }
}

// MARK: - Context Menu Settings

/// User-configurable sizing for the custom context-menu rows (Settings → Context menu).
enum ContextMenuSettings {
    static let fontSizeKey = "fcxl.ctxMenuFontSize"
    static let rowHeightKey = "fcxl.ctxMenuRowHeight"
    static let iconSizeKey = "fcxl.ctxMenuIconSize"
    static let paddingKey = "fcxl.ctxMenuPadding"
    static let cornerRadiusKey = "fcxl.ctxMenuCornerRadius"
    static let minWidthKey = "fcxl.ctxMenuMinWidth"

    static let defaultFontSize: Double = 13
    static let defaultRowHeight: Double = 22
    static let defaultIconSize: Double = 15
    static let defaultPadding: Double = 13
    static let defaultCornerRadius: Double = 4
    static let defaultMinWidth: Double = 180

    private static func value(_ key: String, _ fallback: Double) -> CGFloat {
        CGFloat((UserDefaults.standard.object(forKey: key) as? Double) ?? fallback)
    }

    static var fontSize: CGFloat { value(fontSizeKey, defaultFontSize) }
    static var rowHeight: CGFloat { value(rowHeightKey, defaultRowHeight) }
    static var iconSize: CGFloat { value(iconSizeKey, defaultIconSize) }
    static var padding: CGFloat { value(paddingKey, defaultPadding) }
    static var cornerRadius: CGFloat { value(cornerRadiusKey, defaultCornerRadius) }
    static var minWidth: CGFloat { value(minWidthKey, defaultMinWidth) }
}

/// A context-menu row drawn by us so the highlight uses the app accent. The
/// enclosing NSMenu keeps native behaviour (keyboard, submenus, positioning);
/// only the appearance is custom.
final class AccentMenuItemView: NSView {
    private let titleText: String
    private let iconImage: NSImage?
    private let baseTextColor: NSColor
    private let hasSubmenu: Bool
    private let onTap: (() -> Void)?

    private let iconGap: CGFloat = 7
    private let hPad: CGFloat
    private let iconSize: CGFloat
    private let rowHeight: CGFloat
    private let cornerRadius: CGFloat
    private let font: NSFont
    private var fixedWidth: CGFloat?

    init(title: String, image: NSImage?, baseTextColor: NSColor, hasSubmenu: Bool, onTap: (() -> Void)?) {
        self.titleText = title
        self.iconImage = image
        self.baseTextColor = baseTextColor
        self.hasSubmenu = hasSubmenu
        self.onTap = onTap
        // Sizes are user-configurable (Settings → Context menu).
        self.hPad = ContextMenuSettings.padding
        self.iconSize = ContextMenuSettings.iconSize
        self.rowHeight = ContextMenuSettings.rowHeight
        self.cornerRadius = ContextMenuSettings.cornerRadius
        self.font = NSFont.menuFont(ofSize: ContextMenuSettings.fontSize)
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: ContextMenuSettings.rowHeight))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Hover is tracked by the row itself, not taken from AppKit. The menu machinery only
    /// updates a custom view's isHighlighted while ITS tracking loop drives events — a menu
    /// popped inside a modal dialog (the pack dialog's format chip) never gets those updates,
    /// and the row under the mouse stayed unpainted. A tracking area answers everywhere,
    /// whatever run loop is in charge; .activeAlways because a menu window is never key.
    private var hovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    /// Natural width needed to show the icon + full title + chevron without clipping.
    var naturalWidth: CGFloat {
        let textW = (titleText as NSString).size(withAttributes: [.font: font]).width
        return hPad + iconSize + iconGap + ceil(textW) + hPad + (hasSubmenu ? 16 : 6)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: fixedWidth ?? naturalWidth, height: rowHeight)
    }

    /// Pin this row to a fixed width (the menu's widest item) so no title clips.
    func setRowWidth(_ width: CGFloat) {
        fixedWidth = width
        setFrameSize(NSSize(width: width, height: rowHeight))
        invalidateIntrinsicContentSize()
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = hovered || (enclosingMenuItem?.isHighlighted ?? false)
        let accent = PanelAppearanceSettings.accentNSColor
        let textColor: NSColor = highlighted
            ? PanelAppearanceSettings.contrastingTextColor(on: accent)
            : baseTextColor

        if highlighted {
            accent.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }

        // Icon column is always reserved so titles align. Template images are
        // tinted to the text colour; real icons (app/swatch) are drawn as-is.
        if let icon = iconImage {
            let box = NSRect(x: hPad, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            // Fit the symbol into the box keeping its aspect ratio — otherwise wide
            // symbols (e.g. "eye") get stretched to a square.
            drawImage(icon, in: Self.aspectFitRect(for: icon.size, in: box), tint: icon.isTemplate ? textColor : nil)
        }

        // Title.
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let size = (titleText as NSString).size(withAttributes: attrs)
        let x = hPad + iconSize + iconGap
        (titleText as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attrs)

        // Submenu chevron.
        if hasSubmenu, let base = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            let chevron = base.withSymbolConfiguration(cfg) ?? base
            let cs: CGFloat = 10
            let r = NSRect(x: bounds.width - hPad - cs + 6, y: (bounds.height - cs) / 2, width: cs, height: cs)
            drawImage(chevron, in: r, tint: textColor)
        }
    }

    /// Rect that fits `imageSize` inside `box` preserving aspect ratio, centred — so a
    /// non-square symbol (e.g. the wide "eye") isn't stretched to fill a square.
    private static func aspectFitRect(for imageSize: NSSize, in box: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return box }
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    private func drawImage(_ image: NSImage, in rect: NSRect, tint: NSColor?) {
        guard let tint else { image.draw(in: rect); return }
        let tinted = NSImage(size: rect.size)
        tinted.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: rect.size))
        tint.set()
        NSRect(origin: .zero, size: rect.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: rect)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { super.mouseUp(with: event); return }

        // Submenu parent → open the submenu IMMEDIATELY on click (instead of the
        // native hover-and-wait, which the user finds slow).
        if hasSubmenu, let submenu = enclosingMenuItem?.submenu {
            let rectInWindow = convert(bounds, to: nil)
            let screenRect = window?.convertToScreen(rectInWindow) ?? rectInWindow
            let point = NSPoint(x: screenRect.maxX - 3, y: screenRect.maxY)
            enclosingMenuItem?.menu?.cancelTracking()
            DispatchQueue.main.async {
                submenu.popUp(positioning: nil, at: point, in: nil)
            }
            return
        }

        if let onTap {
            enclosingMenuItem?.menu?.cancelTracking()
            onTap()
        }
    }
}

// MARK: - Messenger Detection

struct MessengerAppInfo {
    let name: String
    let bundleID: String
    let icon: NSImage?
}

enum MessengerDetection {
    private static let knownMessengers: [(name: String, bundleIDs: [String])] = [
        ("Telegram", ["ru.keepcoder.Telegram", "org.telegram.desktop"]),
        ("WhatsApp", ["net.whatsapp.WhatsApp", "WhatsApp"]),
        ("Viber", ["com.viber.osx"]),
        ("Skype", ["com.skype.skype"]),
        ("Discord", ["com.hnc.Discord"]),
        ("Signal", ["org.whispersystems.signal-desktop"]),
        ("Slack", ["com.tinyspeck.slackmacgap"]),
    ]

    static func installedMessengers() -> [MessengerAppInfo] {
        var result: [MessengerAppInfo] = []
        let workspace = NSWorkspace.shared
        for messenger in knownMessengers {
            for bundleID in messenger.bundleIDs {
                if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                    let icon = workspace.icon(forFile: appURL.path)
                    icon.size = NSSize(width: 16, height: 16)
                    result.append(MessengerAppInfo(name: messenger.name, bundleID: bundleID, icon: icon))
                    break
                }
            }
        }
        return result
    }
}

// MARK: - NSSharingService Helper

extension NSSharingService {
    @available(macOS, deprecated: 13.0)
    static func availableSharingServices(forItems items: [Any]) -> [NSSharingService] {
        sharingServices(forItems: items)
    }
}

