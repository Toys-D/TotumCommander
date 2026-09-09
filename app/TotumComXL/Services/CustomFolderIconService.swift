import AppKit

/// Folder icons the user assigned by hand in Finder (Get Info → paste a picture).
///
/// Those icons belong to a PATH, while the panel picks its icons by kind — a folder gets the
/// configured folder style, a file gets the icon for its extension — so a hand-assigned picture
/// could never reach the screen no matter how it was stored. This looks it up per folder.
///
/// Only folders that really carry one are overridden. macOS decorates plenty of folders with its
/// own artwork (home, Downloads, Applications), and taking those over would quietly cancel the
/// folder style and tint the user chose in Settings for every one of them.
@MainActor
enum CustomFolderIconService {

    /// Off by default: the panel's own folder style is what most people expect to see.
    static let enabledKey = "showCustomFolderIcons"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// macOS keeps a hand-assigned folder icon in a hidden `Icon\r` file inside the folder itself.
    /// `URLResourceKey.customIconKey` looks like the official answer but is unimplemented — it
    /// returns nil even for a folder that visibly has one, measured on this system.
    private static let iconFileName = "Icon\r"

    /// Keyed by path AND modification date: assigning or removing an icon writes the `Icon\r` file
    /// inside the folder, which moves its mtime, so a stale entry cannot outlive the change.
    private static var cache: [String: NSImage?] = [:]

    // MARK: - Telling a picture from a picture of a folder

    /// Installers (Adobe, Autodesk, Topaz) and folder-colouring utilities routinely assign an icon
    /// that is just artwork of an ordinary folder. Those are real custom icons as far as the file
    /// system is concerned, but showing them means a handful of folders quietly stop obeying the
    /// style and colour chosen in Settings while their neighbours keep it — the panel goes ragged
    /// for no reason the user can see. Such an icon is treated as "no picture at all".
    ///
    /// The test is SHAPE, not colour: those pictures are folder-coloured, so comparing colours
    /// would match nothing, while the folder silhouette is unmistakable. Measured on this machine:
    /// eight installer icons all scored 0.080, a real picture scored 0.253 — the threshold sits in
    /// the wide gap between them.
    ///
    /// The trade-off is deliberate: a picture deliberately drawn in the outline of a folder counts
    /// as folder artwork and is skipped.
    private static let plainFolderTolerance = 0.15
    private static let silhouetteSide = 16

    private static let plainFolderSilhouette: [Double] = silhouette(of: NSWorkspace.shared.icon(for: .folder))

    /// Per-pixel opacity of the icon at a small fixed size — its outline, with colour discarded.
    private static func silhouette(of image: NSImage) -> [Double] {
        let n = silhouetteSide
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: n * 4, bitsPerPixel: 32)
        else { return [] }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(n), height: CGFloat(n)).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(n), height: CGFloat(n)))
        NSGraphicsContext.restoreGraphicsState()

        var out: [Double] = []
        out.reserveCapacity(n * n)
        for y in 0..<n {
            for x in 0..<n { out.append(Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)) }
        }
        return out
    }

    private static func isFolderArtwork(_ icon: NSImage) -> Bool {
        let shape = silhouette(of: icon)
        guard shape.count == plainFolderSilhouette.count, !shape.isEmpty else { return false }
        let difference = zip(shape, plainFolderSilhouette)
            .reduce(0.0) { $0 + abs($1.0 - $1.1) } / Double(shape.count)
        return difference < plainFolderTolerance
    }

    /// The user's own icon for this folder, or nil to leave the panel's folder style alone.
    ///
    /// Cheap enough to call while drawing: the common answer — no custom icon — costs one `stat`
    /// per folder, once, and only for the rows actually on screen.
    static func icon(for item: FileItem, size: CGFloat) -> NSImage? {
        guard isEnabled, item.isDirectory, item.name != ".." else { return nil }

        let key = "\(item.path)|\(item.dateModified.timeIntervalSince1970)"
        let found: NSImage?
        if let cached = cache[key] {
            found = cached
        } else {
            let iconFile = (item.path as NSString).appendingPathComponent(iconFileName)
            if FileManager.default.fileExists(atPath: iconFile) {
                let assigned = NSWorkspace.shared.icon(forFile: item.path)
                // Artwork of a plain folder is not a picture — let the configured style win.
                found = isFolderArtwork(assigned) ? nil : assigned
            } else {
                found = nil
            }
            // Bounded so browsing a huge tree cannot grow it without limit.
            if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
            cache[key] = found
        }

        guard let found else { return nil }
        // Copy before resizing: the cached image is shared between the three panel modes, which
        // ask for different sizes.
        let sized = (found.copy() as? NSImage) ?? found
        sized.size = NSSize(width: size, height: size)
        return sized
    }

    /// Called when the setting is switched, so turning it back on re-reads the folders rather than
    /// replaying whatever was cached while it was off.
    static func clearCache() {
        cache.removeAll(keepingCapacity: false)
    }
}
