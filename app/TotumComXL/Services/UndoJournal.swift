import Foundation

/// The memory behind Cmd+Z: what the last file operations were, and how to walk each one back.
///
/// A record is pushed by `FileOperationsService` — the one road every operation already takes —
/// at the moment an operation SUCCEEDS, and only when walking it back is honest:
///
/// * a copy or move is recorded only when it met no conflicts, was not cancelled midway and was
///   not handed to the background queue. A merge into an existing folder, a "replace", a "skip"
///   — any of those makes "put it back" ambiguous at best and destructive at worst, so such an
///   operation simply is not undoable, and the menu says so by staying grey;
/// * a trash is recorded with the exact URLs macOS gave the items inside the bin, so putting
///   them back needs no guessing;
/// * everything is local files. Remote and archive operations never reach the journal.
///
/// The journal holds WHAT happened; walking it back is the service's job again — undo of a move
/// is a move, undo of a copy is a trash, each through the same code the forward operation used.
@MainActor
final class UndoJournal: ObservableObject {

    static let shared = UndoJournal()

    /// One operation, as the journal remembers it.
    enum Record {
        /// Items went from their old paths to new ones — one folder to another.
        case moved(pairs: [(from: String, to: String)])
        /// Copies were CREATED at these paths; the sources are kept so the copy can be redone.
        case copied(sources: [String], destinationDir: String, created: [String])
        case renamed(from: String, to: String)
        /// Items went into the bin, each to the URL macOS chose for it.
        case trashed(pairs: [(original: String, trashURL: URL)])
        /// A folder (or an empty file) was created.
        case created(path: String, isDirectory: Bool)

        /// "перемещение (3)" — the operation's name for the menu title.
        var menuDescription: String {
            switch self {
            case .moved(let pairs):   return L("undo.op.move", pairs.count)
            case .copied(_, _, let created): return L("undo.op.copy", created.count)
            case .renamed(_, let to): return L("undo.op.rename", (to as NSString).lastPathComponent)
            case .trashed(let pairs): return L("undo.op.trash", pairs.count)
            case .created(let path, _): return L("undo.op.create", (path as NSString).lastPathComponent)
            }
        }
    }

    /// Newest last. Bounded: nobody walks back further than this, and every record pins paths.
    private(set) var undoStack: [Record] = []
    private(set) var redoStack: [Record] = []
    private let limit = 20

    /// True while a record is being walked back or forward — the service's methods are the same
    /// ones users call, and the journal must not record its own footsteps.
    private(set) var isReplaying = false

    private init() {}

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoDescription: String? { undoStack.last?.menuDescription }
    var redoDescription: String? { redoStack.last?.menuDescription }

    /// Called by the operations service after a successful, honestly-reversible operation.
    func record(_ record: Record) {
        guard !isReplaying else { return }
        undoStack.append(record)
        if undoStack.count > limit { undoStack.removeFirst() }
        // A new operation forks history: what was undone before it can no longer be redone.
        redoStack.removeAll()
        objectWillChange.send()
    }

    /// Take the newest record off the undo stack, run `replay` over it, and file it for redo.
    /// The stack changes only when the replay SUCCEEDS — a failed undo keeps the record, so
    /// fixing whatever was in the way (a name now occupied, say) and pressing Cmd+Z again works.
    func undo(replay: (Record) async throws -> Void) async throws {
        guard let record = undoStack.last else { return }
        isReplaying = true
        defer { isReplaying = false }
        try await replay(record)
        undoStack.removeLast()
        redoStack.append(record)
        objectWillChange.send()
    }

    func redo(replay: (Record) async throws -> Void) async throws {
        guard let record = redoStack.last else { return }
        isReplaying = true
        defer { isReplaying = false }
        try await replay(record)
        redoStack.removeLast()
        undoStack.append(record)
        objectWillChange.send()
    }

    /// A trash redone lands under NEW urls; the record on the undo stack has to learn them or
    /// the next undo would look for the old ones.
    func replaceNewestUndo(with record: Record) {
        guard !undoStack.isEmpty else { return }
        undoStack[undoStack.count - 1] = record
        objectWillChange.send()
    }

    /// For tests: a journal that remembers a previous run remembers stale paths.
    func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
        objectWillChange.send()
    }
}
