import Foundation

/// The folders the user keeps coming back to — Total Commander's hotlist, on Cmd+D.
///
/// One list for the whole app, read from the defaults on every use rather than held in memory:
/// both panels see an addition at once, and there is no copy to go stale. The list is small and
/// the read is nothing.
enum FavoriteFolders {

    /// The key predates this file: the panels loaded it at startup into a per-panel copy that
    /// nothing displayed, so whatever a user managed to save back then is honoured, not lost.
    static let key = "fcxl.bookmarks"

    static var paths: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func contains(_ path: String) -> Bool {
        paths.contains(path)
    }

    /// Newest at the BOTTOM: a list of places re-ordered on every addition cannot be learned,
    /// and a hotlist is used by remembered position.
    static func add(_ path: String) {
        var list = paths
        guard !list.contains(path) else { return }
        list.append(path)
        UserDefaults.standard.set(list, forKey: key)
    }

    static func remove(_ path: String) {
        UserDefaults.standard.set(paths.filter { $0 != path }, forKey: key)
    }
}
