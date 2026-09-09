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
    @MainActor
    func performUndo(of record: UndoJournal.Record) async throws {
        switch record {
        case .moved(let pairs):
            // The move, reversed: what went from→to comes to→from.
            try replay(pairs: pairs.map { (from: $0.to, to: $0.from) })

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
            try replay(pairs: pairs.map { (from: $0.trashURL.path, to: $0.original) })

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
    @MainActor
    func performRedo(of record: UndoJournal.Record) async throws -> UndoJournal.Record? {
        switch record {
        case .moved(let pairs):
            try replay(pairs: pairs.map { (from: $0.from, to: $0.to) })
            return nil

        case .copied(let sources, _, let created):
            // The same copies again, by their recorded names — clonefile on APFS, plain copy
            // elsewhere. A source gone missing fails that pair; a copy already present is done.
            var issues: [(String, String)] = []
            for (source, dest) in zip(sources, created) {
                if Self.lstatExists(dest) { continue }
                guard Self.lstatExists(source) else {
                    issues.append(((source as NSString).lastPathComponent,
                                   String(format: L("undo.reason.goneAt"),
                                          (source as NSString).abbreviatingWithTildeInPath)))
                    continue
                }
                do { try DarwinFileOperations.copy(from: source, to: dest, progress: nil, shouldCancel: nil) }
                catch { issues.append(((source as NSString).lastPathComponent,
                                       error.localizedDescription)) }
            }
            guard issues.isEmpty else { throw UndoReplayError.partial(issues) }
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
    private func replay(pairs: [(from: String, to: String)]) throws {
        var issues: [(String, String)] = []
        for pair in pairs {
            let name = (pair.to as NSString).lastPathComponent
            guard Self.lstatExists(pair.from) else {
                // Nothing at the source. If the destination already holds it, this pair was
                // done on an earlier, partially-failed attempt — done is done.
                if Self.lstatExists(pair.to) { continue }
                issues.append((name, String(format: L("undo.reason.goneAt"),
                                            (pair.from as NSString).abbreviatingWithTildeInPath)))
                continue
            }
            guard !Self.lstatExists(pair.to) else {
                issues.append((name, String(
                    format: L("undo.reason.occupiedAt"),
                    ((pair.to as NSString).deletingLastPathComponent as NSString)
                        .abbreviatingWithTildeInPath)))
                continue
            }
            do {
                let parent = (pair.to as NSString).deletingLastPathComponent
                if !FileManager.default.fileExists(atPath: parent) {
                    try FileManager.default.createDirectory(atPath: parent,
                                                            withIntermediateDirectories: true)
                }
                try DarwinFileOperations.move(from: pair.from, to: pair.to, progress: nil, shouldCancel: nil)
            } catch {
                issues.append((name, error.localizedDescription))
            }
        }
        guard issues.isEmpty else { throw UndoReplayError.partial(issues) }
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
