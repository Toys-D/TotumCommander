import AppKit

extension Notification.Name {
    /// The shelf gained or lost something. Panels showing it repaint on this.
    static let fcxlDropStackChanged = Notification.Name("fcxlDropStackChanged")
}

/// The shelf: files gathered from anywhere, kept until they are used.
///
/// A commander moves things between two folders, which works right up until the things live in
/// six different folders. Then the choice is either six round trips or a temporary folder
/// nobody wants. The shelf is that temporary folder without the folder: put files on it as you
/// walk around, then open it in a panel and copy the lot in one gesture — every existing
/// operation works on it, because what the shelf holds are ordinary files at their real paths.
///
/// Nothing is moved or copied by putting something on the shelf; it remembers paths, not
/// contents. A file that is deleted or renamed behind its back simply stops appearing.
enum DropStackStore {

    /// The panel path that shows the shelf, in the manner of /TRASH and /NETWORK.
    static let stackRoot = "/STACK"
    static let defaultsKey = "fcxl.dropStack"

    nonisolated static func isStackPath(_ path: String) -> Bool {
        path == stackRoot || path.hasPrefix(stackRoot + "/")
    }

    /// What is on the shelf, in the order it was put there. Survives a restart: a shelf that
    /// forgot itself overnight would be a worse promise than no shelf.
    static var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: .fcxlDropStackChanged, object: nil)
        }
    }

    static var count: Int { paths.count }
    static var isEmpty: Bool { paths.isEmpty }

    static func contains(_ path: String) -> Bool { paths.contains(path) }

    /// Add paths, keeping the order they arrived in and ignoring ones already there.
    /// Answers how many were actually new, so the caller can say "3 added, 2 were already on it"
    /// instead of pretending everything happened.
    @discardableResult
    static func add(_ incoming: [String]) -> Int {
        let (merged, added) = Self.merge(existing: paths, incoming: incoming)
        guard added > 0 else { return 0 }
        paths = merged
        return added
    }

    @discardableResult
    static func remove(_ going: [String]) -> Int {
        let gone = Set(going)
        let kept = paths.filter { !gone.contains($0) }
        let removed = paths.count - kept.count
        guard removed > 0 else { return 0 }
        paths = kept
        return removed
    }

    static func clear() {
        guard !paths.isEmpty else { return }
        paths = []
    }

    /// The merge itself, without the defaults — the part worth testing.
    /// ".." is never a thing to carry, and a duplicate is silently the same entry.
    nonisolated static func merge(existing: [String], incoming: [String]) -> (paths: [String], added: Int) {
        var seen = Set(existing)
        var merged = existing
        var added = 0
        for path in incoming where !path.isEmpty {
            guard (path as NSString).lastPathComponent != "..", seen.insert(path).inserted else { continue }
            merged.append(path)
            added += 1
        }
        return (merged, added)
    }

    /// What the panel shows. Paths that no longer exist are dropped — and dropped from the
    /// shelf too, so it cannot fill up with ghosts of files moved away weeks ago.
    static func items() -> [FileItem] {
        let remembered = paths
        var alive: [String] = []
        var listed: [FileItem] = []
        for path in remembered {
            guard let item = FileItem.fromPath(path) else { continue }
            alive.append(path)
            listed.append(item)
        }
        if alive.count != remembered.count { paths = alive }
        return listed
    }
}
