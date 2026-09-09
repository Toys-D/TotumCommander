import Foundation

/// Folder sizes remembered across launches, so a folder you visited yesterday shows its size the
/// instant you come back — while the adaptive walker re-verifies it quietly in the background.
///
/// The cache is deliberately trusted-then-verified rather than validated up front: there is no
/// cheap way to ask "did anything under this tree change?" (a folder's mtime moves only for its
/// DIRECT children), and walking the tree to validate would cost exactly what the cache exists to
/// avoid. So a stale number can appear for a few seconds — and is then corrected by the same walk
/// that would have produced it anyway.
final class FolderSizeCache: @unchecked Sendable {

    static let shared = FolderSizeCache()

    /// One remembered folder. `verifiedAt` orders eviction: the least recently confirmed entry
    /// goes first.
    private struct Entry: Codable {
        var size: UInt64
        var verifiedAt: Date
    }

    /// Plenty for years of browsing, small enough that the file stays in single-digit megabytes.
    private let capacity = 50_000
    /// One pending write at a time, two seconds after the last change: the walker updates entries
    /// in bursts, and writing the whole file per folder would turn a cache into an I/O source.
    private let saveDelay: TimeInterval = 2.0

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var savePending = false
    private let saveQueue = DispatchQueue(label: "com.fcxl.foldersize-cache", qos: .utility)

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TotumCommander", isDirectory: true)
            .appendingPathComponent("folder-sizes.json")
    }

    // MARK: - Reading

    /// The remembered size, or nil if this folder was never computed.
    func size(for path: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        return entries[path]?.size
    }

    // MARK: - Writing

    /// Called by the walker after a REAL computation — this is what "verified" means.
    func store(size: UInt64, for path: String) {
        lock.lock()
        loadIfNeededLocked()
        entries[path] = Entry(size: size, verifiedAt: Date())
        evictIfNeededLocked()
        let shouldSchedule = !savePending
        savePending = true
        lock.unlock()
        if shouldSchedule {
            saveQueue.asyncAfter(deadline: .now() + saveDelay) { [weak self] in self?.saveNow() }
        }
    }

    /// The folder is gone (deleted, renamed away): remembering it would resurrect a ghost.
    func forget(path: String) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        entries[path] = nil
        entries = entries.filter { !$0.key.hasPrefix(path + "/") }
    }

    // MARK: - Persistence

    private func loadIfNeededLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = stored
    }

    private func saveNow() {
        lock.lock()
        savePending = false
        let snapshot = entries
        lock.unlock()
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A cache that fails to persist costs a recomputation, not correctness — not worth
            // a dialog. It will try again on the next store.
        }
    }

    /// Tests need the write on disk NOW, not two seconds from now.
    func flush() {
        saveQueue.sync { }
        saveNow()
    }

    // MARK: - Eviction

    private func evictIfNeededLocked() {
        guard entries.count > capacity else { return }
        // Drop the tenth of entries whose verification is oldest — folders not seen in ages.
        let toRemove = entries.count - capacity + capacity / 10
        let victims = entries.sorted { $0.value.verifiedAt < $1.value.verifiedAt }
            .prefix(toRemove).map(\.key)
        for key in victims { entries[key] = nil }
    }

    // MARK: - Adaptive walker math (pure, testable)

    /// How many parallel workers a load percentage buys on this machine. 100% = every core, the
    /// old behaviour; the floor is one worker — zero would mean the feature silently off.
    nonisolated static func workerCount(loadPercent: Int,
                                        coreCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        let percent = min(max(loadPercent, 10), 100)
        return min(max(1, Int((Double(coreCount) * Double(percent) / 100.0).rounded())), coreCount)
    }

    /// The priority those workers run at. Low percentages promise "quietly in the background",
    /// and QoS is how that promise is kept — a background thread yields to everything the user
    /// actually does.
    nonisolated static func workerPriority(loadPercent: Int) -> TaskPriority {
        switch loadPercent {
        case ..<35:  return .background
        case ..<70:  return .utility
        default:     return .userInitiated
        }
    }

    /// The order folders get their sizes: from the cursor outward. The cursor is on screen in
    /// every view mode, so the rows the user is looking at fill in first without the renderers
    /// having to report their scroll positions.
    nonisolated static func walkOrder(count: Int, cursorIndex: Int) -> [Int] {
        guard count > 0 else { return [] }
        let anchor = min(max(cursorIndex, 0), count - 1)
        var order: [Int] = [anchor]
        var step = 1
        while order.count < count {
            let below = anchor + step
            let above = anchor - step
            // Below first: reading direction — the next thing the user looks at is usually lower.
            if below < count { order.append(below) }
            if above >= 0 { order.append(above) }
            step += 1
        }
        return order
    }
}
