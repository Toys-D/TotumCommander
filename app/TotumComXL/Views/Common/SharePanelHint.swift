import AppKit
import OSLog

/// The note that stands beside Telegram's share panel while it is open.
///
/// The panel does not close by its own button — a fault of Telegram's macOS app, and the same
/// from Finder — so somebody who changes their mind is stuck with it on screen and no way out
/// that the panel itself offers. The note says what to press. It appears beside the panel, not
/// over it: the panel is another app's drawing and covering it would hide the chat list.
///
/// It goes when the panel goes. Whether that happened is watched rather than waited for: the
/// panel belongs to an extension, and there is no notification of it closing that can be relied
/// on.
@MainActor
final class SharePanelHint {

    static let shared = SharePanelHint()

    private static let log = Logger(subsystem: "com.fcxl", category: "Share")

    private var window: NSPanel?
    private var watchTimer: Timer?
    private weak var watched: NSWindow?

    private init() {}

    /// Put the note beside `panel` and keep it there for as long as the panel is up.
    func attach(to panel: NSWindow) {
        guard watched !== panel else { return }
        hide()
        watched = panel

        // Debug level: it did its job — the note stands where it should — and a line this long
        // has no business in the log of every share. `log show --debug` still has it if the
        // panel ever moves again.
        Self.log.debug("\(Self.diagnosis(of: panel), privacy: .public)")
        let note = makeWindow()
        // Above the panel's own level, or the note would slip behind what it is explaining.
        note.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        place(note, beside: panel)
        note.orderFront(nil)
        window = note
        // It comes on like a lamp over a doorway, the same way the filter's buttons do: a note
        // that simply appears in the corner of the eye is not read. The layer that flickers has
        // to be one that draws — an NSPanel's content view has no layer of its own unless asked
        // for one, so nothing happened at all.
        if let body = note.contentView?.subviews.first, let layer = body.layer {
            LampFlicker.light(layer, pattern: 1)
        }

        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let watched = self.watched, watched.isVisible else { self.hide(); return }
                if let window = self.window { self.place(window, beside: watched) }
            }
        }
    }

    func hide() {
        watchTimer?.invalidate()
        watchTimer = nil
        window?.orderOut(nil)
        window = nil
        watched = nil
    }

    // MARK: - The note itself

    private func makeWindow() -> NSPanel {
        let note = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 10),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        note.isReleasedWhenClosed = false
        note.isFloatingPanel = true
        note.hidesOnDeactivate = false
        note.backgroundColor = .clear
        note.isOpaque = false
        note.hasShadow = true
        // It explains; it is not to be clicked. Every click belongs to the panel beside it.
        note.ignoresMouseEvents = true

        let body = NSView(frame: .zero)
        body.wantsLayer = true
        body.layer?.cornerRadius = 10
        body.layer?.borderWidth = 1
        body.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextField(wrappingLabelWithString: L("share.stuckPanelHint"))
        text.font = .systemFont(ofSize: 11)
        text.textColor = .labelColor
        text.translatesAutoresizingMaskIntoConstraints = false
        text.preferredMaxLayoutWidth = 210

        body.addSubview(icon)
        body.addSubview(text)
        note.contentView?.addSubview(body)

        guard let content = note.contentView else { return note }
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.topAnchor.constraint(equalTo: content.topAnchor),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            icon.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: body.topAnchor, constant: 13),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: body.topAnchor, constant: 12),
            text.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -12),
        ])

        applyColours(to: body)
        content.layoutSubtreeIfNeeded()
        let height = content.fittingSize.height
        note.setContentSize(NSSize(width: 260, height: max(height, 44)))
        return note
    }

    private func applyColours(to body: NSView) {
        body.effectiveAppearance.performAsCurrentDrawingAppearance {
            body.layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(0.98).cgColor
            body.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.7).cgColor
        }
        // The glow follows the app's beauty switch, exactly as the filter's lit buttons do —
        // with it off the app draws flat, and one glowing thing on a matte screen looks wrong.
        guard UserDefaults.standard.bool(forKey: PanelAppearanceSettings.beautyModeEnabledKey),
              let layer = body.layer else { return }
        let dark = body.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer.masksToBounds = false
        layer.shadowColor = NSColor.systemOrange.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = dark ? 9 : 5
        layer.shadowOpacity = dark ? 0.85 : 0.45
    }

    /// Where the panel actually is on screen.
    ///
    /// Not the window's frame: the framework's window is spread over the whole screen and the
    /// panel is the remote view drawn somewhere inside it. Placing the note by the window put
    /// it in the corner of the screen, half a metre from what it was explaining.
    static func panelRect(of panel: NSWindow) -> NSRect {
        let screen = (NSScreen.screens.first { $0.frame.intersects(panel.frame) }
            ?? NSScreen.main)?.frame ?? panel.frame

        // Every window the share puts up is full-screen — the log says so plainly:
        //   SHKRemoteWindow, SHKDimAndShadowWindow, SHKBlurWindow, all 1728×1079.
        // The panel is drawn INSIDE them, so the answer is not in any window's frame.

        // The framework knows it as `blurFrame`: the rectangle it blurs behind the panel, which
        // is the panel. Its window controller is normally the window's delegate.
        if let fromController = panelRectFromController(of: panel) { return fromController }

        // Failing that, the drawing itself: inside a full-screen window, the layer that covers
        // only part of it is the panel.
        if let fromLayers = panelRectFromLayers(in: panel) { return fromLayers }

        // Or a view inside THIS window that is smaller than the window.
        //
        // Своё окно спрашивается раньше общесистемных списков намеренно: ответ про то самое
        // окно, которое нам дали, надёжнее найденного среди чужих. Заодно это делает
        // поведение предсказуемым — раньше сюда мог попасть подходящий по размеру кусок
        // соседней программы, и тесты падали в зависимости от того, что открыто на экране.
        if let content = panel.contentView,
           let view = remoteView(in: content, windowSize: panel.frame.size) {
            return panel.convertToScreen(view.convert(view.bounds, to: nil))
        }

        // Дальше — общесистемные списки: панель бывает и в чужом окне.
        for window in frameworkNSWindows() where window !== panel {
            if let fromLayers = panelRectFromLayers(in: window) { return fromLayers }
        }
        // A window of panel size, should some macOS give the panel one of its own.
        if let fromBlur = panelRect(amongFrameworkWindows: frameworkWindows(), screen: screen) {
            return fromBlur
        }
        // Or a window of the extension's own process, should it ever have one.
        if let fromServer = panelRectFromWindowServer() { return fromServer }
        // Nothing left to go on: the panel is put up in the middle of the screen, so the note
        // stands beside the middle. Beside roughly the right place beats the corner of the
        // screen, which is where the window's own frame would send it.
        return assumedPanelRect(on: screen)
    }

    /// What the framework itself says the panel's rectangle is.
    ///
    /// `SHKRemoteWindowController.blurFrame` is the rectangle blurred behind the panel — the
    /// panel, in screen coordinates. Not in any header, so it is asked for and skipped if the
    /// answer is not there.
    static func panelRectFromController(of window: NSWindow) -> NSRect? {
        let selector = NSSelectorFromString("blurFrame")
        for candidate in [window.delegate as AnyObject?, window.windowController as AnyObject?] {
            guard let object = candidate as? NSObject, object.responds(to: selector) else { continue }
            typealias FrameGetter = @convention(c) (AnyObject, Selector) -> NSRect
            let rect = unsafeBitCast(object.method(for: selector), to: FrameGetter.self)(
                object, selector)
            // It answers with the whole screen while the panel is coming in, and the whole
            // screen is not a panel — taking that answer is what kept the note in the corner.
            if looksLikeAPanel(rect, inside: window.frame) { return rect }
        }
        return nil
    }

    /// Is this rectangle a share panel? Big enough to be one, and well short of the screen it is
    /// on: a panel is a small thing in the middle, never the whole width or height.
    static func looksLikeAPanel(_ rect: NSRect, inside container: NSRect) -> Bool {
        rect.width >= 150 && rect.height >= 150
            && rect.width <= container.width * 0.7 && rect.height <= container.height * 0.7
    }

    /// The panel as drawn: inside a window spread over the whole screen, the layer that covers
    /// only part of it. The smallest such layer is the panel rather than its shadow or its
    /// backdrop.
    static func panelRectFromLayers(in window: NSWindow) -> NSRect? {
        guard let content = window.contentView, let root = content.layer else { return nil }
        let full = content.bounds
        var best: CGRect?

        func walk(_ layer: CALayer, depth: Int) {
            guard depth < 8 else { return }
            for sublayer in layer.sublayers ?? [] {
                let inRoot = sublayer.convert(sublayer.bounds, to: root)
                // The BIGGEST of the ones that could be a panel: what is drawn inside a panel —
                // its rows, its search field — is smaller than the panel, and the smallest of
                // those is a row, not the thing the note has to stand beside.
                if looksLikeAPanel(inRoot, inside: full),
                   best.map({ inRoot.width * inRoot.height > $0.width * $0.height }) ?? true {
                    best = inRoot
                }
                walk(sublayer, depth: depth + 1)
            }
        }
        walk(root, depth: 0)

        guard let best else { return nil }
        return window.convertToScreen(content.convert(best, to: nil))
    }

    /// Where a share panel goes when nothing will say: the middle of the screen, at about the
    /// size the framework gives one.
    static func assumedPanelRect(on screen: NSRect) -> NSRect {
        let size = NSSize(width: 440, height: 560)
        return NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func frameworkNSWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).hasPrefix("SHK") }
    }

    /// The sharing framework's own windows, by the prefix it names them all with:
    /// SHKRemoteWindow, SHKDimAndShadowWindow, SHKBlurWindow.
    static func frameworkWindows() -> [(name: String, frame: NSRect)] {
        frameworkNSWindows().map { (String(describing: type(of: $0)), $0.frame) }
    }

    /// Of those windows, which one IS the panel.
    ///
    /// The blur, by name: the framework keeps the panel's rectangle as its `blurFrame` and gives
    /// that window exactly the size of the panel. Failing the name, the smallest one that does
    /// not cover the whole screen. Nil when they all cover it — then the panel is drawn inside
    /// one of them, and its place has to be found some other way.
    static func panelRect(amongFrameworkWindows windows: [(name: String, frame: NSRect)],
                          screen: NSRect) -> NSRect? {
        let candidates = windows
            .filter { $0.frame.width > 120 && $0.frame.height > 120 }
            .filter { $0.frame.width < screen.width - 1 || $0.frame.height < screen.height - 1 }
        if let blur = candidates.first(where: { $0.name.contains("Blur") }) { return blur.frame }
        return candidates.min { $0.frame.width * $0.frame.height
            < $1.frame.width * $1.frame.height }?.frame
    }

    /// The share extension's own on-screen window, in AppKit coordinates.
    static func panelRectFromWindowServer() -> NSRect? {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return panelRect(inWindowList: entries,
                         ourProcess: ProcessInfo.processInfo.processIdentifier,
                         primaryTop: primaryTop)
    }

    /// Which of the windows on screen is the share panel: one belonging to a share extension —
    /// another process, with "Share" in its name — and big enough to be the panel rather than a
    /// shadow or a tooltip of one.
    static func panelRect(inWindowList entries: [[String: Any]], ourProcess: pid_t,
                          primaryTop: CGFloat) -> NSRect? {
        for entry in entries {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ourProcess,
                  let owner = entry[kCGWindowOwnerName as String] as? String,
                  owner.localizedCaseInsensitiveContains("share"),
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 200, rect.height > 200
            else { continue }
            return flipFromWindowServer(rect, primaryTop: primaryTop)
        }
        return nil
    }

    /// The window server measures from the top-left of the primary screen; AppKit from its
    /// bottom-left. Everything about placing the note is in AppKit's terms.
    static func flipFromWindowServer(_ rect: CGRect, primaryTop: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The view the other app draws into: named for what it is, and — the part that matters —
    /// smaller than the window it sits in.
    static func remoteView(in view: NSView, windowSize: NSSize) -> NSView? {
        let isSmallerThanTheWindow = view.bounds.width < windowSize.width - 1
            || view.bounds.height < windowSize.height - 1
        if String(describing: type(of: view)).contains("Remote"), isSmallerThanTheWindow,
           view.bounds.width > 80, view.bounds.height > 80 {
            return view
        }
        for subview in view.subviews {
            if let found = remoteView(in: subview, windowSize: windowSize) { return found }
        }
        return nil
    }

    /// Everything known about where the panel is, in one line — so a miss can be read off the
    /// log instead of guessed at a second time.
    static func diagnosis(of panel: NSWindow) -> String {
        let layers = frameworkNSWindows()
            .compactMap { panelRectFromLayers(in: $0).map(NSStringFromRect) }
            .joined(separator: " ")
        return "note beside panel:"
            + " host \(NSStringFromRect(panel.frame))"
            + " → chosen \(NSStringFromRect(panelRect(of: panel)))"
            + " | blurFrame \(panelRectFromController(of: panel).map(NSStringFromRect) ?? "none")"
            + " | layers [\(layers.isEmpty ? "none" : layers)]"
            + " | windows [\(frameworkWindowsDescription())]"
            + " | server \(panelRectFromWindowServer().map(NSStringFromRect) ?? "none")"
            + " | inside [\(describe(panel.contentView))]"
    }

    /// Every window the sharing framework has on screen, by name and frame — the line in the log
    /// that says which of them is the panel.
    static func frameworkWindowsDescription() -> String {
        frameworkWindows().map { "\($0.name)\(NSStringFromRect($0.frame))" }
            .joined(separator: " | ")
    }

    /// What the window holds, class and size, two levels deep — for the log, when the panel is
    /// somewhere other than where it was looked for.
    static func describe(_ view: NSView?, depth: Int = 0) -> String {
        guard let view, depth < 3 else { return "" }
        let own = "\(String(describing: type(of: view)))"
            + "(\(Int(view.bounds.width))×\(Int(view.bounds.height)))"
        let children = view.subviews.prefix(6).map { describe($0, depth: depth + 1) }
            .filter { !$0.isEmpty }
        return children.isEmpty ? own : own + " > " + children.joined(separator: " | ")
    }

    /// Beside the panel — to its right, or to its left when the right has no room.
    private func place(_ note: NSWindow, beside panel: NSWindow) {
        let panelFrame = Self.panelRect(of: panel)
        let screen = NSScreen.screens.first { $0.frame.intersects(panelFrame) } ?? NSScreen.main
        let origin = Self.noteOrigin(noteSize: note.frame.size, panelRect: panelFrame,
                                     screen: screen?.visibleFrame ?? panelFrame)
        if note.frame.origin != origin { note.setFrameOrigin(origin) }
    }

    /// Where the note goes: hard against the panel's right edge, its top level with the panel's,
    /// and on the left instead when the right side of the screen has no room. Kept on screen
    /// whatever happens — a note half off the edge explains nothing.
    static func noteOrigin(noteSize: NSSize, panelRect: NSRect, screen: NSRect) -> NSPoint {
        let gap: CGFloat = 12
        var x = panelRect.maxX + gap
        if x + noteSize.width > screen.maxX { x = panelRect.minX - gap - noteSize.width }
        x = min(max(x, screen.minX), max(screen.maxX - noteSize.width, screen.minX))

        // Level with the MIDDLE of the panel: the two then read as one thing side by side, and
        // the note is where the eye already is rather than up at the panel's shoulder.
        var y = panelRect.midY - noteSize.height / 2
        y = min(max(y, screen.minY), max(screen.maxY - noteSize.height, screen.minY))
        return NSPoint(x: x, y: y)
    }
}
