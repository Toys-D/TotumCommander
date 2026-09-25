import AppKit
import UniformTypeIdentifiers

/// The picture under the cursor while several files are dragged at once.
///
/// A drag of twelve files that looks exactly like a drag of one is a lie the person only finds
/// out about after dropping. AppKit stacks the rows by itself when the drag carries one dragging
/// item per file — which is what the brief and thumbnail modes do — but the detailed list starts
/// its drag from the table, and the table makes ONE item for the row under the mouse however many
/// rows are selected. So the stack is drawn here instead: a few file icons fanned out, and the
/// count on a badge.
@MainActor
enum DragStackImage {
    /// How many icons are actually drawn. Past three the fan says "many" just as well, and each
    /// extra card only makes the picture heavier under the cursor.
    static let shownCards = 3
    private static let cardSize: CGFloat = 42
    private static let step: CGFloat = 7

    /// An icon for a path that may not exist on disk — an entry inside an archive, a file on a
    /// server. LaunchServices is asked about the TYPE in that case, which needs no file.
    static func icon(forPath path: String, isReal: Bool, isDirectory: Bool = false) -> NSImage {
        if isReal, FileManager.default.fileExists(atPath: path) {
            return AppIconCache.icon(path: path, size: cardSize)
        }
        if isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (path as NSString).pathExtension
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: cardSize, height: cardSize)
        return image
    }

    /// The stack itself. `count` is the WHOLE number of dragged files, which is what the badge
    /// says — the icons are only as many as fit.
    static func make(icons: [NSImage], count: Int, accent: NSColor) -> NSImage {
        let cards = min(max(icons.count, 1), shownCards)
        let spread = CGFloat(cards - 1) * step
        let size = NSSize(width: cardSize + spread + 10, height: cardSize + spread + 10)

        return NSImage(size: size, flipped: false) { _ in
            // Drawn back to front, so the first file chosen ends up on top of the pile.
            for index in stride(from: cards - 1, through: 0, by: -1) {
                let offset = CGFloat(index) * step
                let box = NSRect(x: offset, y: size.height - cardSize - offset,
                                 width: cardSize, height: cardSize)
                let icon = index < icons.count ? icons[index] : icons.last
                icon?.draw(in: box, from: .zero, operation: .sourceOver,
                           fraction: index == 0 ? 1.0 : 0.85)
            }
            guard count > 1 else { return true }

            // The badge sits on the bottom-right corner of the front card, where nothing else is.
            let text = count > 99 ? "99+" : String(count)
            let font = NSFont.systemFont(ofSize: 11, weight: .bold)
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            let diameter = max(18, textSize.width + 10)
            let badge = NSRect(x: size.width - diameter, y: 0, width: diameter, height: 18)
            let plate = NSBezierPath(roundedRect: badge, xRadius: 9, yRadius: 9)
            accent.setFill()
            plate.fill()
            NSColor.white.setStroke()
            plate.lineWidth = 1.5
            plate.stroke()
            (text as NSString).draw(
                at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
                withAttributes: [.font: font,
                                 .foregroundColor: PanelAppearanceSettings
                                     .contrastingTextColor(on: accent)])
            return true
        }
    }
}
