import Foundation

/// Searching through macOS's own index instead of walking the disk.
///
/// The walk in the C++ core reads every directory to answer a question; Spotlight answers from
/// what it already knows, which is why it can search a whole disk in under a second and can
/// look inside a PDF without opening it. The price is that it only knows what it indexed:
/// dot-files, package interiors, folders on the privacy list and volumes with indexing off are
/// simply not in there. This service never pretends otherwise — an empty answer is reported as
/// "the index said nothing", not as "there is nothing".
@MainActor
final class SpotlightSearchService {

    enum Scope {
        case folder(String)
        case wholeDisk
    }

    struct Outcome {
        let hits: [SearchHit]
        /// True when the cap cut the answer short — the dialog says so rather than lying.
        let truncated: Bool
    }

    /// Harvesting is a round trip per item, so the index gets its own, tighter ceiling than
    /// the dialog's: ten thousand rows arrive in well under a second, and a whole-disk mask
    /// like "*e*" that would otherwise return six figures stops there and says so.
    static let defaultCap = 10_000

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var finished = false

    /// Start a query. `onFinish` is called exactly once — on success, on failure, or never if
    /// the caller cancels first.
    func start(scope: Scope,
               predicate: NSPredicate,
               mask: String,
               postFilter: Bool,
               typeFilter: FileTypeOption,
               cap: Int = defaultCap,
               onFinish: @escaping (Result<Outcome, Error>) -> Void) {
        cancel()
        finished = false

        let query = NSMetadataQuery()
        // Before anything else: a query whose operationQueue is nil delivers its notifications
        // to whatever run loop started it, and a GCD queue has none — start() would answer
        // true and then nothing would ever arrive.
        query.operationQueue = .main
        query.notificationBatchingInterval = 0.5
        query.predicate = predicate
        switch scope {
        case .folder(let path):
            query.searchScopes = [URL(fileURLWithPath: (path as NSString).expandingTildeInPath)]
        case .wholeDisk:
            // The INDEXED variant on purpose: the plain one would quietly include volumes that
            // are not indexed, and their silence would read as "nothing found".
            query.searchScopes = [NSMetadataQueryIndexedLocalComputerScope]
        }

        let harvest: (Notification) -> Void = { [weak self] _ in
            guard let self, !self.finished else { return }
            self.finished = true
            let outcome = Self.harvest(query: query, mask: mask, postFilter: postFilter,
                                       typeFilter: typeFilter, cap: cap)
            self.cancel()
            onFinish(.success(outcome))
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query,
            queue: .main, using: harvest))

        self.query = query
        guard query.start() else {
            self.cancel()
            onFinish(.failure(NSError(
                domain: "SpotlightSearchService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("search.spot.startFailed")])))
            return
        }
    }

    /// Stop and forget everything. Safe to call twice, and safe to call from `onFinish`.
    func cancel() {
        if let query {
            query.stop()
            query.operationQueue = nil
        }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        query = nil
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Reading the answer

    /// Pull the paths out of a finished query and turn them into results.
    ///
    /// Only the path is read from each item: every other attribute costs a round trip to the
    /// metadata server, and the same numbers are a cheap `lstat` away. Updates are disabled
    /// for the duration — the result set is live otherwise, and it can shift under the loop.
    private static func harvest(query: NSMetadataQuery,
                                mask: String,
                                postFilter: Bool,
                                typeFilter: FileTypeOption,
                                cap: Int) -> Outcome {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var paths: [String] = []
        var seen = Set<String>()
        var truncated = false
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            // Spotlight can hand back the same file twice; the dialog must not.
            guard seen.insert(path).inserted else { continue }
            paths.append(path)
            if paths.count >= cap {
                truncated = index + 1 < query.resultCount
                break
            }
        }

        return Outcome(hits: hits(from: paths, mask: mask, postFilter: postFilter,
                                  typeFilter: typeFilter),
                       truncated: truncated)
    }

    /// Paths → results: drop what the index should not have offered, then fill in the numbers
    /// the list shows. Pure, so the sieve is testable without an index.
    nonisolated static func hits(from paths: [String],
                                 mask: String,
                                 postFilter: Bool,
                                 typeFilter: FileTypeOption) -> [SearchHit] {
        var out: [SearchHit] = []
        out.reserveCapacity(paths.count)
        for path in paths {
            let name = (path as NSString).lastPathComponent
            if SpotlightQueryBuilder.isHidden(path: path) { continue }
            if postFilter, !SpotlightQueryBuilder.nameMatches(mask: mask, name: name) { continue }

            var info = stat()
            guard lstat(path, &info) == 0 else { continue }   // indexed but since deleted
            let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
            switch typeFilter {
            case .filesOnly where isDirectory: continue
            case .dirsOnly where !isDirectory: continue
            default: break
            }

            out.append(SearchHit(
                path: path,
                name: name,
                lineNumber: nil, column: nil, lineContent: nil,
                dateModified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                size: isDirectory ? nil : UInt64(info.st_size),
                isDirectory: isDirectory))
        }
        // Same order the walk produces: folders first, then by name.
        return out.sorted {
            $0.isDirectory != $1.isDirectory
                ? $0.isDirectory
                : $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}

/// Is the volume holding this path indexed at all? Spotlight answers an unindexed volume with
/// silence, which is indistinguishable from "found nothing" — so the dialog asks first and can
/// say which of the two happened.
enum SpotlightIndexProbe {

    /// `mdutil -s` prints a volume header and then one line about the state.
    nonisolated static func parseStatus(_ output: String) -> Bool {
        output.lowercased().contains("indexing enabled")
    }

    /// Runs mdutil for the volume holding `path`. Anything unexpected — a missing tool, a
    /// timeout, an unreadable answer — counts as "indexed": refusing to search on a guess
    /// would be worse than a search that comes back empty.
    nonisolated static func indexingEnabled(forPath path: String) -> Bool {
        let volume = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeURLKey]))?
            .volume?.path ?? "/"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        process.arguments = ["-s", volume]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return true
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return true }
        return parseStatus(text)
    }
}
