import Foundation
import Combine
import ImageIO

/// Drives the Multi-Rename window: holds the rule and the file list, produces a live preview
/// through RenameMaskEngine (debounced), lets the user pin individual names by hand, and runs the
/// batch through the operation queue. Local filesystem for now; the remote path is wired later.
@MainActor
final class MultiRenameViewModel: ObservableObject {

    @Published var rule: RenameRule { didSet { scheduleRecompute() } }
    @Published private(set) var plans: [RenamePlan] = []
    @Published private(set) var undoAvailable = false
    @Published private(set) var isExecuting = false
    @Published private(set) var presets: [RenamePreset] = []

    /// Files being renamed (".." already excluded), all in `rootPath`.
    let items: [FileItem]
    let rootPath: String
    let session: RemoteSession?          // nil = local
    /// Called after the batch finishes so the panel reloads.
    var onRenamed: (() -> Void)?

    private let engine = RenameMaskEngine()
    private let queue: OperationQueueService
    private var manualOverrides: [String: String] = [:]   // sourcePath -> user-typed name
    private var recomputeTask: Task<Void, Never>?
    private var lastUndoMoves: [RenameExecutionPlanner.Move] = []
    private let presetStore: RenamePresetStore
    private var dimensionsCache: [String: (w: Int, h: Int)] = [:]   // path -> image pixel size

    init(items: [FileItem], rootPath: String, session: RemoteSession?,
         queue: OperationQueueService, presetStore: RenamePresetStore = RenamePresetStore()) {
        self.items = items.filter { $0.name != ".." }
        self.rootPath = rootPath
        self.session = session
        self.queue = queue
        self.presetStore = presetStore
        self.rule = RenameRule()
        self.presets = presetStore.all()
        recomputeNow()
        Task { [weak self] in await self?.loadDimensions() }
    }

    // MARK: - Image dimensions (for [=tc.width] / [=tc.height])

    private static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "gif", "tiff", "tif", "heic", "heif", "bmp", "webp"]

    /// Read pixel dimensions of a local image from its header only (cheap, no full decode).
    nonisolated static func imageDimensions(path: String) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// Populate the dimensions cache off the main thread, then refresh the preview. Local only —
    /// reading a remote image's size would mean downloading it.
    func loadDimensions() async {
        guard session == nil else { return }
        let paths = items.filter { Self.imageExtensions.contains($0.fileExtension.lowercased()) }
            .map { $0.path }
        guard !paths.isEmpty else { return }
        let dims = await Task.detached(priority: .utility) { () -> [String: (w: Int, h: Int)] in
            var result: [String: (w: Int, h: Int)] = [:]
            for path in paths {
                if let (w, h) = MultiRenameViewModel.imageDimensions(path: path) { result[path] = (w, h) }
            }
            return result
        }.value
        dimensionsCache = dims
        recomputeNow()
    }

    // MARK: - Presets

    func reloadPresets() { presets = presetStore.all() }

    /// Save the current rule under a name (overwrites an existing preset with that name).
    func savePreset(name: String) {
        presetStore.save(name: name, rule: rule)
        reloadPresets()
    }

    /// Apply a saved preset's rule (recomputes the preview).
    func applyPreset(_ preset: RenamePreset) {
        rule = preset.rule
        recomputeNow()
    }

    func deletePreset(name: String) {
        presetStore.delete(name: name)
        reloadPresets()
    }

    var isRemote: Bool { session != nil }

    // MARK: - Preview

    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            self?.recomputeNow()
        }
    }

    /// Recompute the preview immediately (no debounce). Applies manual overrides, then classifies.
    func recomputeNow() {
        let inputs = items.map(engineInput)
        var computed = engine.preview(inputs, rule: rule)
        for i in computed.indices {
            if let manual = manualOverrides[computed[i].sourcePath] {
                computed[i].newName = manual
            }
        }
        plans = classify(computed)
    }

    /// Pin (or clear) a hand-edited new name for one row. An empty string clears the override.
    func setManualName(_ name: String, for sourcePath: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { manualOverrides.removeValue(forKey: sourcePath) }
        else { manualOverrides[sourcePath] = trimmed }
        recomputeNow()
    }

    /// Classify final names: unchanged / error / on-disk collision / duplicate / ok. Mirrors the
    /// engine's pure classification but adds the on-disk collision check (local only) and honors
    /// hand-edited overrides.
    private func classify(_ input: [RenamePlan]) -> [RenamePlan] {
        var plans = input
        let sourceLower = Set(items.map { $0.path.lowercased() })
        var seen: [String: Int] = [:]
        for i in plans.indices {
            // A regex error from the engine stands unless the row was overridden by hand.
            if case .error = plans[i].status, manualOverrides[plans[i].sourcePath] == nil { continue }
            let target = plans[i].newName
            if let reason = RenameMaskEngine.validate(target) { plans[i].status = .error(reason); continue }
            if target == plans[i].originalName { plans[i].status = .unchanged; continue }
            if session == nil {
                let abs = (rootPath as NSString).appendingPathComponent(target)
                if FileManager.default.fileExists(atPath: abs), !sourceLower.contains(abs.lowercased()) {
                    plans[i].status = .collidesOnDisk; continue
                }
            }
            plans[i].status = .ok
            seen[target.lowercased(), default: 0] += 1
        }
        for i in plans.indices {
            if case .ok = plans[i].status, (seen[plans[i].newName.lowercased()] ?? 0) > 1 {
                plans[i].status = .duplicate
            }
        }
        return plans
    }

    private func engineInput(_ item: FileItem) -> RenameMaskEngine.Input {
        let dims = dimensionsCache[item.path]
        return RenameMaskEngine.Input(path: item.path, name: item.name, isDirectory: item.isDirectory,
                                      modified: item.dateModified, created: item.dateCreated,
                                      size: item.size, width: dims?.w, height: dims?.h)
    }

    // MARK: - Gating

    /// Rows that will actually be renamed.
    var actionablePlans: [RenamePlan] { plans.filter { $0.status == .ok } }

    /// A hard problem that must be fixed before renaming: an error or a within-batch duplicate.
    var hasBlockingIssues: Bool {
        plans.contains { plan in
            if case .error = plan.status { return true }
            return plan.status == .duplicate
        }
    }

    var canExecute: Bool { !actionablePlans.isEmpty && !hasBlockingIssues && !isExecuting }

    var conflictCount: Int {
        plans.filter { plan in
            if case .error = plan.status { return true }
            return plan.status == .duplicate || plan.status == .collidesOnDisk
        }.count
    }

    // MARK: - Execute / undo

    /// The source -> final absolute-path renames for the currently actionable (`.ok`) rows.
    /// Pure; no disk. Exposed so tests can drive the real rename chain.
    func currentMoves() -> [RenameExecutionPlanner.Move] {
        actionablePlans.map { plan in
            RenameExecutionPlanner.Move(source: plan.sourcePath,
                                        final: (rootPath as NSString).appendingPathComponent(plan.newName))
        }
    }

    /// The ordered filesystem steps (with temp-name staging) that a Rename would perform. Pure.
    func plannedSteps() -> [RenameExecutionPlanner.Step] {
        let token = UUID().uuidString.prefix(8)
        return RenameExecutionPlanner().plan(currentMoves()) { i in ".fcxl-mrt-\(token)-\(i)" }
    }

    func execute() {
        recomputeNow()   // refresh so [Y][M][D][h][m][s] stamp the current moment, not dialog-open
        guard canExecute else { return }
        let actionable = actionablePlans
        let moves = currentMoves()
        let steps = plannedSteps()
        let undoMoves = moves.map { RenameExecutionPlanner.Move(source: $0.final, final: $0.source) }
        let renamedItems = actionable.compactMap { plan in items.first { $0.path == plan.sourcePath } }

        isExecuting = true
        queue.enqueueMultiRename(
            items: renamedItems,
            params: renameParams(steps: steps),
            onCompletion: { [weak self] in
                self?.isExecuting = false
                self?.onRenamed?()
            },
            onSuccess: { [weak self] in
                self?.lastUndoMoves = undoMoves
                self?.undoAvailable = true
            })
    }

    /// Build the queue params for a set of steps, tagging them remote when a session is present.
    private func renameParams(steps: [RenameExecutionPlanner.Step]) -> MultiRenameParams {
        if let session {
            return MultiRenameParams(steps: steps, isRemote: true,
                                     connectionID: session.connection.id,
                                     connectionLabel: session.connection.label)
        }
        return MultiRenameParams(steps: steps)
    }

    /// Reverse the last successful batch. Locally, skips any file no longer at its post-rename
    /// location; on a remote server we reverse them all (a cheap fileExists probe isn't available).
    func undo() {
        guard undoAvailable else { return }
        let moves = session == nil
            ? lastUndoMoves.filter { FileManager.default.fileExists(atPath: $0.source) }
            : lastUndoMoves
        undoAvailable = false
        guard !moves.isEmpty else { return }
        let planner = RenameExecutionPlanner()
        let token = UUID().uuidString.prefix(8)
        let steps = planner.plan(moves) { i in ".fcxl-mrt-undo-\(token)-\(i)" }
        let titleItems = Array(items.prefix(max(1, moves.count)))
        queue.enqueueMultiRename(
            items: titleItems,
            params: renameParams(steps: steps),
            onCompletion: { [weak self] in self?.onRenamed?() })
    }
}
