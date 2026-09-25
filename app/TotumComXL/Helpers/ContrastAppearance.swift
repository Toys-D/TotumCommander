import AppKit

/// Which appearance reads on a given background.
///
/// A dark interface colour chosen under the light theme left the toolbar black on slate:
/// labels, icons, all of it unreadable. The rule here is WCAG's: text goes white where white
/// contrasts with the background better than black — from the point where the background's
/// relative luminance drops below 0.179, the crossing of the two contrast ratios.
enum ContrastAppearance {

    /// Relative luminance, 0 (black) … 1 (white), with the sRGB curve undone first.
    static func luminance(of color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 1 }
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
             + 0.7152 * linear(rgb.greenComponent)
             + 0.0722 * linear(rgb.blueComponent)
    }

    /// Below this luminance white text beats black: (L + 0.05)² = 0.05 · 1.05.
    static let darkBelow: CGFloat = 0.179

    static func isDark(_ color: NSColor) -> Bool { luminance(of: color) < darkBelow }

    /// The appearance for controls standing on `background`: dark (light text and icons) on a
    /// dark colour, light on a light one. nil for no custom colour — the controls then follow
    /// the window, as they always did.
    static func appearance(on background: NSColor?) -> NSAppearance? {
        guard let background else { return nil }
        return NSAppearance(named: isDark(background) ? .darkAqua : .aqua)
    }
}
