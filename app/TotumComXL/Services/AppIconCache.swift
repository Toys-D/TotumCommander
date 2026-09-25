import AppKit

/// Application icons, remembered.
///
/// Asking the system for a program's icon costs about a tenth of a millisecond: it opens the
/// bundle and goes through LaunchServices. An icon by file TYPE — what every ordinary file
/// uses — is free next to that. A folder of programs is therefore a folder where every single
/// row pays the expensive price, on every cursor move and every scroll tick, and it shows:
/// /Applications dragged while ordinary folders flew.
///
/// This lives apart from any one view because all three list modes draw the same icons, and
/// each of them had its own uncached copy of this code — which is why fixing the detailed list
/// alone left the brief one, where three times as many rows are on screen at once, still slow.
enum AppIconCache {

    private static var cache: [String: NSImage] = [:]

    /// The icon for a program at `path`, sized for the list.
    ///
    /// The bundle's modification time is part of the key, so a program replaced by an update
    /// gets its new icon with nothing to invalidate. A stat is free next to what it protects.
    ///
    /// The image is COPIED before being resized: the one the system hands back is shared, and
    /// setting its size in place changes the icon for everyone else holding it.
    @MainActor
    static func icon(path: String, size: CGFloat) -> NSImage {
        var info = stat()
        let stamp = lstat(path, &info) == 0 ? info.st_mtimespec.tv_sec : 0
        let key = "\(path)|\(Int(size))|\(stamp)"
        if let cached = cache[key] { return cached }

        let system = NSWorkspace.shared.icon(forFile: path)
        let icon = (system.copy() as? NSImage) ?? system
        icon.size = NSSize(width: size, height: size)
        // A folder of programs is a few dozen entries; clearing wholesale beats tracking
        // least-recently-used at this size.
        if cache.count > 512 { cache.removeAll() }
        cache[key] = icon
        return icon
    }

    /// Forget everything. Not needed in the ordinary way of things — the key carries the
    /// bundle's modification time — but tests want a clean slate.
    @MainActor
    static func forget() { cache.removeAll() }
}
