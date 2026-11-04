import AppKit

/// How the main window comes up at launch: the way it was left, as a plain window, or
/// maximized — filling the screen the way a double-click on the title bar does, as a WINDOW.
///
/// Not macOS full screen: that carries the program off to a Space of its own, and that is
/// exactly what was not wanted. The frame itself is remembered by AppKit's autosave, so
/// "as left" needs no memory of its own — a maximized window simply comes back maximized.
enum WindowLaunchMode: String, CaseIterable {
    case asLeft
    case normal
    case maximized

    static let defaultsKey = "fcxl.windowLaunch"

    var titleKey: String {
        switch self {
        case .asLeft:    return "settings.windowLaunch.asLeft"
        case .normal:    return "settings.windowLaunch.normal"
        case .maximized: return "settings.windowLaunch.maximized"
        }
    }

    /// What is chosen now; an unknown value means what the program always did — as left.
    static var chosen: WindowLaunchMode {
        WindowLaunchMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .asLeft
    }

    /// The frame the window gets at launch, from the one the autosave gave it (`current`)
    /// and the screen's usable area (`visible`, under the menu bar and above the Dock).
    /// - maximized: the whole usable area;
    /// - normal: a window that was left filling the screen shrinks to a plain one — four
    ///   fifths of the screen, centred — and any other stays as it was;
    /// - as left: untouched.
    func frame(current: NSRect, visible: NSRect, minimum: NSSize) -> NSRect {
        switch self {
        case .asLeft:
            return current
        case .maximized:
            return visible
        case .normal:
            return Self.fillsScreen(current, visible) ? Self.plainFrame(in: visible, minimum: minimum) : current
        }
    }

    /// A frame within a few points of the usable area counts as maximized — the autosave
    /// rounds, and a window stretched by hand to the edges is maximized to anyone looking.
    static func fillsScreen(_ frame: NSRect, _ visible: NSRect) -> Bool {
        frame.width >= visible.width - 4 && frame.height >= visible.height - 4
    }

    static func plainFrame(in visible: NSRect, minimum: NSSize) -> NSRect {
        let size = NSSize(width: min(max(floor(visible.width * 0.8), minimum.width), visible.width),
                          height: min(max(floor(visible.height * 0.8), minimum.height), visible.height))
        return NSRect(x: round(visible.midX - size.width / 2), y: round(visible.midY - size.height / 2),
                      width: size.width, height: size.height)
    }

    /// Apply the chosen mode to a window that has just been placed and shown.
    static func apply(to window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = chosen.frame(current: window.frame, visible: screen.visibleFrame, minimum: window.minSize)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }
}
