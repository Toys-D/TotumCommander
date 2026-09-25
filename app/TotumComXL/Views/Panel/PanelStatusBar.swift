import Darwin
import SwiftUI

/// Status bar at the bottom of each panel, showing file count, selection, free space.
struct PanelStatusBar: View {
    @ObservedObject var viewModel: PanelViewModel
    /// Observed so the bar re-renders when a background free-space query lands.
    @ObservedObject private var freeSpace = FreeSpaceCache.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(statusText)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .interfaceBackground()
        .overlay(alignment: .top) { Divider() }
    }

    private var statusText: String {
        // READY numbers from the view model — no filtering here. This body runs on every
        // cursor tick, and three passes over a 100k-row list per keystroke was the Big
        // Stutter (see PanelViewModel.rebuildStatusNumbers).
        let visibleCount = viewModel.statusVisibleCount
        let selectedCount = viewModel.statusSelectedCount
        let selectedBytes = viewModel.statusSelectedBytes
        let selectedText = selectedBytes == 0
            ? "0 \(L("status.bytes"))"
            : ByteText.file(Int64(selectedBytes))

        if viewModel.isActivelyRemote {
            return "\(L("status.items")): \(visibleCount)   \(L("status.selected")): \(selectedCount) / \(selectedText)"
        }

        let freeText = FreeSpaceCache.shared.formattedFreeSpace(for: viewModel.currentPath)

        var base = "\(L("status.items")): \(visibleCount)   \(L("status.selected")): \(selectedCount) / \(selectedText)   \(L("status.free")): \(freeText)"

        // Show symlink target when cursor is on a symlink
        if let cursorItem = viewModel.cursorItem, cursorItem.isSymlink, let target = cursorItem.symlinkTarget {
            base += "   → \(target)"
        }

        return base
    }
}

/// Caches free-space lookups so SwiftUI body re-evaluations never block the main thread.
///
/// The body getter reads ONLY the in-memory cache — it never touches the filesystem. When a
/// value is missing or stale, a refresh is dispatched to a background queue and the last-known
/// value is shown meanwhile; when the query lands, `version` bumps and the observing status bar
/// re-renders with the fresh number.
///
/// The query itself uses `statfs` (one syscall, microseconds) instead of the URL resource key
/// `volumeAvailableCapacityForImportantUsage`, which routes through the CacheDelete framework to
/// compute purgeable space — that call takes tens of milliseconds to SECONDS on a nearly-full
/// APFS volume (and longer over the network), and running it in the body getter froze the UI.
final class FreeSpaceCache: ObservableObject {
    static let shared = FreeSpaceCache()

    /// Bumped on the main thread whenever a background query updates the cache, to drive a redraw.
    @Published private(set) var version = 0

    private var cache: [String: (bytes: UInt64, timestamp: TimeInterval)] = [:]
    private var inFlight: Set<String> = []
    private let ttl: TimeInterval = 5
    private let queryQueue = DispatchQueue(label: "com.fcxl.freeSpace", qos: .utility)

    func formattedFreeSpace(for path: String) -> String {
        // Keyed by the raw path — deliberately NO volume-root resolution here, because that
        // itself is a filesystem call. `statfs` in the background reports the same free space for
        // any path on the volume, so a few sibling-folder cache entries are the only cost.
        let now = ProcessInfo.processInfo.systemUptime
        let cached = cache[path]
        if cached == nil || now - cached!.timestamp >= ttl {
            scheduleRefresh(path)
        }
        // Never block: show the last value we have (or a placeholder until the first result).
        guard let cached else { return "…" }
        return Self.format(cached.bytes)
    }

    private func scheduleRefresh(_ path: String) {
        guard !inFlight.contains(path) else { return }   // don't pile up queries
        inFlight.insert(path)
        queryQueue.async { [weak self] in
            let bytes = Self.queryFreeSpace(at: path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cache[path] = (bytes, ProcessInfo.processInfo.systemUptime)
                self.inFlight.remove(path)
                self.version &+= 1
            }
        }
    }

    /// `statfs`: available blocks × block size. No CacheDelete, no purgeable-space math.
    private static func queryFreeSpace(at path: String) -> UInt64 {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return 0 }
        return UInt64(st.f_bavail) * UInt64(st.f_bsize)
    }

    private static func format(_ bytes: UInt64) -> String {
        bytes == 0
            ? "0 \(L("status.bytes"))"
            : ByteText.file(Int64(bytes))
    }
}
