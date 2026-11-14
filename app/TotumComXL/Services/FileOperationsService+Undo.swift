import AppKit

/// Walking a journal record back (Cmd+Z) and forward again (Shift+Cmd+Z).
///
/// Undo of a move is a move, undo of a copy is a trash, undo of a trash is putting back — each
/// through this service, the same road the forward operation took. Nothing here invents a
/// second way to touch a file.
///
/// Replays are IDEMPOTENT per item: a pair that is already the way the replay would leave it is
/// skipped, not failed. That is what makes a half-finished undo safe — one file could not come
/// back because its name is taken, the record STAYS on the stack, and pressing Cmd+Z again
/// retries only what is still to do.
///
/// Files are carried AWAY from the main thread: a folder coming back from another disk takes as
/// long as the move that sent it there. A walk still going half a second later shows the
/// progress window with its Cancel button. A walk stopped half-way throws "cancelled", leaves
/// no half-carried item behind (`moveWhole`, `copyWhole`) and is finished by the next Cmd+Z.
extension FileOperationsService {

    enum UndoReplayError: LocalizedError {
        /// Some items could not be walked back; each with its reason, for one dialog.
        case partial([(name: String, reason: String)])

        var errorDescription: String? {
            guard case .partial(let issues) = self else { return nil }
            let shown = issues.prefix(5).map { "• \($0.name): \($0.reason)" }
                .joined(separator: "\n")
            return String(format: L("undo.partialFailure"), issues.count) + "\n" + shown
                + (issues.count > 5 ? "\n…" : "")
        }
    }

    /// Walk one record back. Throws with the record still on the stack (the journal only pops
    /// on success), so a failed undo can be retried after the obstacle is cleared.
    ///
    /// `shouldCancel` stops the walk the way the window's Cancel button does. It is asked on the
    /// working queue, not on the main thread.
    @MainActor
    func performUndo(of record: UndoJournal.Record,
                     shouldCancel: (@Sendable () -> Bool)? = nil) async throws {
        switch record {
        case .moved(let pairs):
            // The move, reversed: what went from→to comes to→from.
            try await replay(pairs: pairs.map { (from: $0.to, to: $0.from) },
                             title: L("undo.progress.back"), shouldCancel: shouldCancel)

        case .copied(_, _, let created):
            // The copies made — and only they — go to the bin, never erased outright: an undo
            // pressed by mistake must itself be recoverable.
            let existing = created.filter { Self.lstatExists($0) }
            guard !existing.isEmpty else { return }
            try await trashItems(existing.map(Self.itemStub(at:)))

        case .renamed(let from, let to):
            guard Self.lstatExists(to) else {
                // Already back — or gone. If the old name is there, the undo is done.
                if Self.lstatExists(from) { return }
                throw UndoReplayError.partial([((to as NSString).lastPathComponent,
                                                String(format: L("undo.reason.goneAt"),
                                                       (to as NSString).abbreviatingWithTildeInPath))])
            }
            try renameItem(Self.itemStub(at: to), to: (from as NSString).lastPathComponent)

        case .trashed(let pairs):
            try await replay(pairs: pairs.map { (from: $0.trashURL.path, to: $0.original) },
                             title: L("undo.progress.back"), shouldCancel: shouldCancel)

        case .created(let path, let isDirectory):
            guard Self.lstatExists(path) else { return }
            // Only while still empty: content the user has already put inside a new folder (or
            // typed into a new file) must never ride away on an undo of the CREATION.
            if isDirectory {
                let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
                guard children.isEmpty else {
                    throw UndoReplayError.partial([((path as NSString).lastPathComponent,
                                                    String(format: L("undo.reason.folderNotEmpty"),
                                                           children.count))])
                }
            } else {
                let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size]
                    as? UInt64 ?? 0
                guard size == 0 else {
                    throw UndoReplayError.partial([((path as NSString).lastPathComponent,
                                                    L("undo.reason.fileNotEmpty"))])
                }
            }
            try await trashItems([Self.itemStub(at: path)])
        }
    }

    /// Walk one record forward again. Returns a replacement record when the redo changed the
    /// facts the next undo will need — a re-trashed file lands under a NEW url in the bin.
    /// `shouldCancel` — as in `performUndo`.
    @MainActor
    func performRedo(of record: UndoJournal.Record,
                     shouldCancel: (@Sendable () -> Bool)? = nil) async throws -> UndoJournal.Record? {
        switch record {
        case .moved(let pairs):
            try await replay(pairs: pairs.map { (from: $0.from, to: $0.to) },
                             title: L("progress.moving"), shouldCancel: shouldCancel)
            return nil

        case .copied(let sources, _, let created):
            // The same copies again, by their recorded names — clonefile on APFS, plain copy
            // elsewhere. A source gone missing fails that pair; a copy already present is done.
            let pairs = zip(sources, created).map { (from: $0, to: $1) }
            try await walkOffMain(title: L("progress.copying"), shouldCancel: shouldCancel) {
                try Self.walk(pairs, as: .copy, progress: $0)
            }
            return nil

        case .renamed(let from, let to):
            guard Self.lstatExists(from) else {
                if Self.lstatExists(to) { return nil }
                throw UndoReplayError.partial([((from as NSString).lastPathComponent,
                                                String(format: L("undo.reason.goneAt"),
                                                       (from as NSString).abbreviatingWithTildeInPath))])
            }
            try renameItem(Self.itemStub(at: from), to: (to as NSString).lastPathComponent)
            return nil

        case .trashed(let pairs):
            // Trash again — macOS hands out fresh URLs inside the bin, and the record that goes
            // back onto the undo stack has to carry them.
            let originals = pairs.map(\.original).filter(Self.lstatExists)
            guard !originals.isEmpty else { return nil }
            let recycled = try await recycleForUndo(originals.map { URL(fileURLWithPath: $0) })
            return .trashed(pairs: recycled.map { ($0.key.path, $0.value) })

        case .created(let path, let isDirectory):
            guard !Self.lstatExists(path) else { return nil }
            if isDirectory {
                try createDirectory(at: (path as NSString).deletingLastPathComponent,
                                    name: (path as NSString).lastPathComponent)
            } else {
                try createTextFile(at: (path as NSString).deletingLastPathComponent,
                                   name: (path as NSString).lastPathComponent)
            }
            return nil
        }
    }

    // MARK: - The mechanics

    /// Move every pair from→to, skipping pairs that already look undone. All pairs are tried;
    /// the failures come back as one error.
    @MainActor
    private func replay(pairs: [(from: String, to: String)], title: String,
                        shouldCancel: (@Sendable () -> Bool)?) async throws {
        try await walkOffMain(title: title, shouldCancel: shouldCancel) {
            try Self.walk(pairs, as: .move, progress: $0)
        }
    }

    /// Runs `work` on a working queue and, if it is still going half a second later, puts up the
    /// progress window with its Cancel button — the way trashing and putting back do. A rename
    /// within one volume is over long before that and shows nothing.
    @MainActor
    private func walkOffMain(title: String, shouldCancel: (@Sendable () -> Bool)?,
                             _ work: @escaping @Sendable (ReplayProgress) throws -> Void) async throws {
        let progress = ReplayProgress(externalCancel: shouldCancel)
        var window: ProgressController?
        let watcher = Task { @MainActor in
            try await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let controller = DialogService.shared.showProgress(
                title: title,
                message: L("progress.preparing"),
                cancelHandler: { progress.cancel() })
            controller.setIndeterminate(true)
            window = controller
            progress.attach(controller)
            DockProgressManager.shared.beginOperation()
            // The work reports into `progress`; the window reads it from here, on its own beat.
            var shown: ReplayProgress.Snapshot?
            while !Task.isCancelled {
                let now = progress.snapshot()
                if now.isMeasured, now != shown {
                    if shown == nil { controller.setIndeterminate(false) }
                    controller.update(currentFile: now.name, progress: now.fraction,
                                      bytesDone: now.bytesDone, bytesTotal: now.bytesTotal,
                                      filesDone: now.itemsDone, filesTotal: now.itemsTotal)
                    DockProgressManager.shared.updateProgress(now.fraction)
                    shown = now
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer {
            watcher.cancel()
            if let window {
                window.close()
                DockProgressManager.shared.endOperation()
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try work(progress)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private enum Carry { case move, copy }

    /// The walk itself, on the working queue: every pair is tried and the failures come back as
    /// one error. A stop is not a failure — it is thrown at once, as "cancelled".
    private static func walk(_ pairs: [(from: String, to: String)], as kind: Carry,
                             progress: ReplayProgress) throws {
        // What has to be copied byte by byte is measured first, so that the bar shows the share
        // of the WHOLE walk and not of one item.
        var sizes: [Int64] = []
        for pair in pairs {
            try progress.checkpoint()
            sizes.append(bytesToCopy(pair, as: kind, progress: progress))
        }
        try progress.checkpoint()
        progress.begin(items: pairs.count, bytes: sizes.reduce(0, +))

        var issues: [(String, String)] = []
        for (pair, size) in zip(pairs, sizes) {
            try progress.checkpoint()
            let name = ((kind == .move ? pair.to : pair.from) as NSString).lastPathComponent
            progress.start(name)
            defer { progress.finish(bytes: size) }
            do {
                if let reason = try carry(pair, as: kind, progress: progress) {
                    issues.append((name, reason))
                }
            } catch {
                if isCancellation(error) { throw error }
                issues.append((name, error.localizedDescription))
            }
        }
        guard issues.isEmpty else { throw UndoReplayError.partial(issues) }
    }

    /// One pair. Returns why it could not be done, or nil — done, or already the way the walk
    /// would leave it.
    private static func carry(_ pair: (from: String, to: String), as kind: Carry,
                              progress: ReplayProgress) throws -> String? {
        let goneAtSource = String(format: L("undo.reason.goneAt"),
                                  (pair.from as NSString).abbreviatingWithTildeInPath)
        let report: (Int64, Int64, String) -> Void = { copied, _, _ in progress.advance(copied) }
        let stop: () -> Bool = { progress.shouldStop() }
        switch kind {
        case .move:
            guard lstatExists(pair.from) else {
                // Nothing at the source. If the destination already holds it, this pair was
                // done on an earlier, partially-failed attempt — done is done.
                return lstatExists(pair.to) ? nil : goneAtSource
            }
            let parent = (pair.to as NSString).deletingLastPathComponent
            guard !lstatExists(pair.to) else {
                return String(format: L("undo.reason.occupiedAt"),
                              (parent as NSString).abbreviatingWithTildeInPath)
            }
            if !FileManager.default.fileExists(atPath: parent) {
                try FileManager.default.createDirectory(atPath: parent,
                                                        withIntermediateDirectories: true)
            }
            try DarwinFileOperations.moveWhole(from: pair.from, to: pair.to,
                                               progress: report, shouldCancel: stop)
        case .copy:
            if lstatExists(pair.to) { return nil }
            guard lstatExists(pair.from) else { return goneAtSource }
            try DarwinFileOperations.copyWhole(from: pair.from, to: pair.to,
                                               progress: report, shouldCancel: stop)
        }
        return nil
    }

    /// The bytes a pair will copy one by one — the only part of a walk that takes time. A move
    /// within a volume is a rename and a copy on APFS is a clone: nothing to wait for.
    private static func bytesToCopy(_ pair: (from: String, to: String), as kind: Carry,
                                    progress: ReplayProgress) -> Int64 {
        guard lstatExists(pair.from), !lstatExists(pair.to) else { return 0 }
        if DarwinFileOperations.sameVolume(source: pair.from, destination: pair.to) {
            if kind == .move || DarwinFileOperations.supportsClone(at: pair.from) { return 0 }
        }
        return directoryStats(path: pair.from, isCancelled: { progress.shouldStop() }).totalBytes
    }

    private static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == CocoaError.userCancelled.rawValue
    }

    /// recycleWithWorkspace is private to the main file; this thin twin keeps the redo path on
    /// the same NSWorkspace road without widening the original's access.
    private func recycleForUndo(_ urls: [URL]) async throws -> [URL: URL] {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { recycledURLs, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: recycledURLs) }
            }
        }
    }

    /// Exists as ITSELF — a broken symlink counts, the same lesson the delete preflight learned.
    private static func lstatExists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    /// A FileItem for a path the journal remembered — enough of one for the service's own
    /// methods, which work by path.
    private static func itemStub(at path: String) -> FileItem {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let isDirectory = (attrs?[.type] as? FileAttributeType) == .typeDirectory
        let name = (path as NSString).lastPathComponent
        return FileItem(path: path, name: name,
                        fileExtension: (name as NSString).pathExtension,
                        size: (attrs?[.size] as? UInt64) ?? 0,
                        isDirectory: isDirectory, isHidden: false,
                        isSymlink: (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink,
                        permissions: "", dateModified: Date())
    }
}

/// What a walk on the working queue shares with the window that shows it: how far it has come
/// and whether it was asked to stop. The work writes and the main thread reads — hence the lock.
private final class ReplayProgress: @unchecked Sendable {
    struct Snapshot: Equatable {
        /// False while the sizes are still being added up — the window says "preparing".
        var isMeasured = false
        var name = ""
        var bytesDone: Int64 = 0
        var bytesTotal: Int64 = 0
        var itemsDone = 0
        var itemsTotal = 0

        /// The share of the WHOLE walk: the window works its "time left" out of it.
        var fraction: Double {
            if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
            return itemsTotal > 0 ? Double(itemsDone) / Double(itemsTotal) : 0
        }
    }

    private let lock = NSLock()
    private var state = Snapshot()
    /// Bytes of the items already finished; the item in hand reports on top of them.
    private var bytesBehind: Int64 = 0
    private var cancelled = false
    private var window: ProgressController?
    private let externalCancel: (@Sendable () -> Bool)?

    init(externalCancel: (@Sendable () -> Bool)?) {
        self.externalCancel = externalCancel
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: The window's side — main thread

    func cancel() { locked { cancelled = true } }
    func attach(_ controller: ProgressController) { locked { window = controller } }
    func snapshot() -> Snapshot { locked { state } }

    // MARK: The work's side — working queue

    func shouldStop() -> Bool {
        // The "really stop?" question holds the work: nothing moves while it is on screen, and
        // by the time it lets go the answer is already in `cancelled`.
        _ = locked { window }?.waitWhilePaused()
        return locked { cancelled } || externalCancel?() == true
    }

    func checkpoint() throws {
        if shouldStop() { throw CocoaError(.userCancelled) }
    }

    func begin(items: Int, bytes: Int64) {
        locked {
            state.isMeasured = true
            state.itemsTotal = items
            state.bytesTotal = bytes
        }
    }

    func start(_ name: String) { locked { state.name = name } }

    /// `bytesOfItem` — what the item in hand has copied so far.
    func advance(_ bytesOfItem: Int64) { locked { state.bytesDone = bytesBehind + bytesOfItem } }

    func finish(bytes: Int64) {
        locked {
            bytesBehind += bytes
            state.bytesDone = bytesBehind
            state.itemsDone += 1
        }
    }
}
