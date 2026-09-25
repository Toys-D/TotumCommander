import Combine
import Foundation
import os

@MainActor
final class OperationQueueService: ObservableObject {
    @Published private(set) var operations: [QueuedOperation] = []
    /// True while at least one operation is actually transferring. Computed rather than stored:
    /// a stored flag went stale (pausing the only running op left it reading "working", and
    /// pause/resume don't run the scheduler). Drives the queue badge's pulse.
    var isProcessing: Bool { operations.contains { $0.status == .running } }

    private let fileOps: FileOperationsService
    private var reporters: [UUID: QueueOperationReporter] = [:]
    private var onCompletionCallbacks: [UUID: () -> Void] = [:]
    /// Fired ONLY when the operation finished successfully (not failed/cancelled). Used for the
    /// irreversible "delete source after transfer" so a failed/cancelled move never loses it.
    private var onSuccessCallbacks: [UUID: () -> Void] = [:]
    /// The same closure, kept aside so a FAILED transfer can be continued later and still
    /// finish the job it was part of. Without this a retried move would carry the files over
    /// and quietly leave the originals behind — the operation would look done and not be.
    /// Dropped when the operation truly ends: completed, cancelled, or thrown out of the list.
    private var onSuccessForRetry: [UUID: () -> Void] = [:]
    /// Local copy/move operations that may still ASK something — a conflict dialog in their
    /// opening phase. While any is in here, no new local operation starts: two modal
    /// questions on one screen answer each other. Cleared by the operation itself the moment
    /// its last question is behind it (from there on it is pure byte moving), or by the
    /// completion path as a safety net.
    private var dialogPhaseOps: Set<UUID> = []
    private static let log = Logger(subsystem: "com.fcxl", category: "OperationQueue")

    init(fileOps: FileOperationsService) {
        self.fileOps = fileOps
    }

    var activeCount: Int {
        operations.filter(\.isActive).count
    }

    var hasOperations: Bool {
        !operations.isEmpty
    }

    // MARK: - Public API

    @discardableResult
    func enqueue(kind: OperationKind,
                 items: [FileItem],
                 destination: String?,
                 onCompletion: (() -> Void)? = nil) -> UUID {
        let op = QueuedOperation(
            id: UUID(),
            kind: kind,
            items: items,
            destinationPath: destination,
            createdAt: Date(),
            filesTotal: items.count
        )
        operations.append(op)
        if let onCompletion {
            onCompletionCallbacks[op.id] = onCompletion
        }
        Self.log.info("enqueue \(kind.rawValue) items=\(items.count) id=\(op.id)")
        processQueue()
        return op.id
    }

    /// Enqueue an archive operation (pack, unpack, archiveDelete, archiveRename).
    @discardableResult
    func enqueueArchive(kind: OperationKind,
                        items: [FileItem],
                        destination: String?,
                        archiveParams: ArchiveOperationParams,
                        onCompletion: (() -> Void)? = nil) -> UUID {
        var op = QueuedOperation(
            id: UUID(),
            kind: kind,
            items: items,
            destinationPath: destination,
            createdAt: Date(),
            filesTotal: items.count
        )
        op.archiveParams = archiveParams
        operations.append(op)
        if let onCompletion {
            onCompletionCallbacks[op.id] = onCompletion
        }
        Self.log.info("enqueue archive \(kind.rawValue) items=\(items.count) id=\(op.id)")
        processQueue()
        return op.id
    }

    /// Enqueue a batch multi-rename. `items` are the files being renamed (for the title/count);
    /// `params.steps` carry the actual absolute-path rename steps. onSuccess fires only when the
    /// whole batch renamed with no errors (used to capture undo and refresh the panel).
    @discardableResult
    func enqueueMultiRename(items: [FileItem],
                            params: MultiRenameParams,
                            onCompletion: (() -> Void)? = nil,
                            onSuccess: (() -> Void)? = nil) -> UUID {
        var op = QueuedOperation(
            id: UUID(),
            kind: .multiRename,
            items: items,
            destinationPath: nil,
            createdAt: Date(),
            filesTotal: items.count
        )
        op.renameParams = params
        operations.append(op)
        if let onCompletion { onCompletionCallbacks[op.id] = onCompletion }
        if let onSuccess { onSuccessCallbacks[op.id] = onSuccess }
        Self.log.info("enqueue multiRename items=\(items.count) id=\(op.id)")
        processQueue()
        return op.id
    }

    /// Enqueue a remote transfer operation (download, upload, remoteDelete).
    @discardableResult
    func enqueueRemote(kind: OperationKind,
                       items: [FileItem],
                       destination: String?,
                       remoteParams: RemoteTransferParams,
                       onCompletion: (() -> Void)? = nil,
                       onSuccess: (() -> Void)? = nil) -> UUID {
        var op = QueuedOperation(
            id: UUID(),
            kind: kind,
            items: items,
            destinationPath: destination,
            createdAt: Date(),
            filesTotal: items.count
        )
        op.remoteParams = remoteParams
        operations.append(op)
        if let onCompletion {
            onCompletionCallbacks[op.id] = onCompletion
        }
        if let onSuccess {
            onSuccessCallbacks[op.id] = onSuccess
            onSuccessForRetry[op.id] = onSuccess
        }
        Self.log.info("enqueue remote \(kind.rawValue) items=\(items.count) id=\(op.id)")
        processQueue()
        return op.id
    }

    /// Adopt an already-running background operation into the queue.
    /// Used when user clicks "Send to queue" on a progress dialog.
    @discardableResult
    func adoptRunningOperation(kind: OperationKind,
                               items: [FileItem],
                               destination: String?,
                               archiveParams: ArchiveOperationParams? = nil,
                               remoteParams: RemoteTransferParams? = nil,
                               currentProgress: Double,
                               currentFile: String,
                               bytesDone: Int64,
                               bytesTotal: Int64,
                               filesDone: Int,
                               filesTotal: Int,
                               onCompletion: (() -> Void)? = nil,
                               onSuccess: (() -> Void)? = nil) -> (UUID, QueueOperationReporter) {
        var op = QueuedOperation(
            id: UUID(),
            kind: kind,
            items: items,
            destinationPath: destination,
            createdAt: Date(),
            filesTotal: filesTotal
        )
        op.archiveParams = archiveParams
        op.remoteParams = remoteParams
        op.status = .running
        op.startedAt = Date()
        op.progress = currentProgress
        op.currentFile = currentFile
        op.bytesDone = bytesDone
        op.bytesTotal = bytesTotal
        op.filesDone = filesDone
        operations.append(op)

        let reporter = QueueOperationReporter(operationId: op.id, queueService: self)
        reporters[op.id] = reporter

        if let onCompletion {
            onCompletionCallbacks[op.id] = onCompletion
        }
        if let onSuccess {
            onSuccessCallbacks[op.id] = onSuccess
            // Adopted transfers break like any other, and "continue" has to finish the move
            // they belonged to — the same aside copy as the enqueued road keeps.
            onSuccessForRetry[op.id] = onSuccess
        }
        // isProcessing is computed — the op was appended as .running, so it already reads true.
        Self.log.info("adopt running \(kind.rawValue) id=\(op.id)")
        return (op.id, reporter)
    }

    func pause(_ id: UUID) {
        guard let idx = index(of: id), operations[idx].status == .running else { return }
        operations[idx].status = .paused
        reporters[id]?.markPaused(true)
        Self.log.info("pause id=\(id)")
    }

    func resume(_ id: UUID) {
        guard let idx = index(of: id), operations[idx].status == .paused else { return }
        operations[idx].status = .running
        reporters[id]?.markPaused(false)
        Self.log.info("resume id=\(id)")
    }

    func cancel(_ id: UUID) {
        guard let idx = index(of: id), operations[idx].isActive else { return }
        operations[idx].status = .cancelled
        operations[idx].completedAt = Date()
        reporters[id]?.markCancelled()
        // Drop the "delete source after transfer" callback — a cancelled move must NEVER
        // delete its source, and a stale closure would otherwise outlive the operation.
        onSuccessCallbacks.removeValue(forKey: id)
        // The aside copy survives a cancel of a TRANSFER: it may still be continued later, and
        // when it finally finishes, the move it belonged to has to finish too. Nothing fires
        // it before that — onSuccess only ever runs on a real success.
        if index(of: id).map({ !operations[$0].canBeResumed }) ?? true {
            onSuccessForRetry.removeValue(forKey: id)
        }
        Self.log.info("cancel id=\(id)")
        fireCompletion(id)
        processQueue()
    }

    func removeCompleted() {
        for op in operations where op.isFinished { onSuccessForRetry.removeValue(forKey: op.id) }
        operations.removeAll(where: \.isFinished)
    }

    func removeOperation(_ id: UUID) {
        if let idx = index(of: id), operations[idx].isFinished {
            operations.remove(at: idx)
            onSuccessForRetry.removeValue(forKey: id)
        }
    }

    /// Put an interrupted transfer back in line — one that failed, or one the person stopped
    /// on purpose. Thanks to the `.part` twin it continues where it stopped rather than
    /// starting the file over, which is why the button says "continue" and not "retry".
    ///
    /// Only remote transfers: a failed local copy or a half-written archive has no such
    /// leftover to build on, and re-running one blindly is a different promise entirely.
    func continueTransfer(_ id: UUID) {
        guard let idx = index(of: id), operations[idx].canBeResumed else { return }
        operations[idx].status = .queued
        operations[idx].error = nil
        operations[idx].completedAt = nil
        operations[idx].currentFile = ""
        // The bar starts from what is already across, not from zero — the first progress
        // report of the continued transfer sets it straight within a moment anyway.
        if let onSuccess = onSuccessForRetry[id] { onSuccessCallbacks[id] = onSuccess }
        Self.log.info("continue interrupted transfer id=\(id)")
        processQueue()
    }

    /// Mark an adopted operation as completed (called from background thread completion).
    func markOperationCompleted(_ id: UUID, error: Error? = nil) {
        guard let idx = index(of: id) else { return }
        if let error {
            let nsError = error as NSError
            let wasCancelled = nsError.domain == NSCocoaErrorDomain
                && nsError.code == CocoaError.userCancelled.rawValue
            if wasCancelled || operations[idx].status == .cancelled {
                operations[idx].status = .cancelled
            } else {
                operations[idx].status = .failed
                operations[idx].error = error.localizedDescription
            }
        } else {
            operations[idx].status = .completed
            operations[idx].progress = 1.0
        }
        operations[idx].completedAt = Date()
        reporters.removeValue(forKey: id)
        fireCompletion(id)
        // onSuccess is consumed by executeOperation (passed straight into the transfer service,
        // which fires it only on a real success). Drop any leftover so it never lingers.
        onSuccessCallbacks.removeValue(forKey: id)
        // …but a FAILED transfer keeps its copy: pressing "continue" has to be able to finish
        // the move it belonged to.
        if !operations[idx].canBeResumed { onSuccessForRetry.removeValue(forKey: id) }
        processQueue()
    }

    // MARK: - Progress Update (called by QueueOperationReporter)

    /// Raise (or lower) the "something is wrong" line on an operation's row.
    func updateOperationTrouble(id: UUID, text: String?) {
        guard let idx = index(of: id) else { return }
        operations[idx].trouble = text
    }

    func updateOperationProgress(id: UUID,
                                  currentFile: String,
                                  progress: Double,
                                  bytesDone: Int64,
                                  bytesTotal: Int64,
                                  filesDone: Int,
                                  filesTotal: Int) {
        guard let idx = index(of: id) else { return }
        operations[idx].currentFile = currentFile
        operations[idx].progress = progress
        operations[idx].bytesDone = bytesDone
        operations[idx].bytesTotal = bytesTotal
        operations[idx].filesDone = filesDone
        operations[idx].filesTotal = filesTotal
    }

    // MARK: - Private

    private func index(of id: UUID) -> Int? {
        operations.firstIndex(where: { $0.id == id })
    }

    /// How many remote transfers may run at once (each holds its own connection).
    private var maxConcurrentRemote: Int {
        let n = UserDefaults.standard.object(forKey: "fcxl.maxConcurrentTransfers") as? Int ?? 2
        return max(1, min(n, 8))
    }

    /// Fill every free slot. Remote transfers run up to `maxConcurrentRemote` at a time (each on
    /// its own connection); local ops stay strictly serial (they contend on the same disk and on
    /// the shared conflict dialogs). The WHOLE queue is scanned so a local op that cannot start
    /// yet does not block remote ops queued behind it (no head-of-line blocking).
    /// An op still OWNS its connection while paused — pause only parks the transfer thread inside
    /// waitWhilePaused(), it never disconnects. So a paused op must keep holding its slot.
    private func holdsSlot(_ op: QueuedOperation) -> Bool {
        // A cancelled op with a live reporter is still unwinding: the transfer only stops at the
        // next chunk boundary and disconnects in its own completion handler, so it still owns
        // the connection and must keep its slot until then.
        op.status == .running || op.status == .paused
            || (op.status == .cancelled && reporters[op.id] != nil)
    }

    private func processQueue() {
        var runningLocal = operations.filter { holdsSlot($0) && !$0.kind.isRemote }.count
        let userMax = maxConcurrentRemote
        let mgr = ConnectionManagerService.shared

        for idx in operations.indices where operations[idx].status == .queued {
            if operations[idx].kind.isRemote {
                guard let cid = operations[idx].remoteParams?.connectionID else { continue }
                // Budget PER SERVER against connections actually open to it (startOperation
                // claims one), so two different servers don't share one budget, a
                // single-connection server is capped at one, and direct non-queued transfers
                // — invisible in `operations` — are counted too.
                if operations[idx].forceSerial {
                    // Downgraded to serial: wait until nothing else is transferring to it.
                    guard mgr.activeTransferCount(for: cid) == 0 else { continue }
                } else {
                    guard mgr.activeTransferCount(for: cid)
                            < mgr.concurrencyLimit(for: cid, userMax: userMax) else { continue }
                }
                startOperation(at: idx)
            } else {
                // The queue IS the background: local operations run side by side up to the
                // same "how many at once" the user set for transfers — waiting only while
                // an earlier one may still ask about conflicts. One idea, one setting.
                guard runningLocal < userMax, dialogPhaseOps.isEmpty else { continue }
                startOperation(at: idx)
                runningLocal += 1
            }
        }
    }

    /// Mark the queued op at `idx` as running and launch it. A remote op claims its server's
    /// connection slot HERE, before connecting, so a processQueue running while the connect is
    /// still in flight cannot hand the same slot out twice.
    private func startOperation(at idx: Int) {
        let id = operations[idx].id
        operations[idx].status = .running
        operations[idx].startedAt = Date()
        if operations[idx].kind.isRemote, let cid = operations[idx].remoteParams?.connectionID {
            ConnectionManagerService.shared.retainTransferConnection(for: cid)
        }
        // Only copy/move can raise conflict dialogs; they hold the question gate until
        // their opening phase is over. Everything else asks nothing mid-run.
        if operations[idx].kind == .copy || operations[idx].kind == .move {
            dialogPhaseOps.insert(id)
        }

        let reporter = QueueOperationReporter(operationId: id, queueService: self)
        reporters[id] = reporter

        Task { @MainActor in
            await executeOperation(id: id, reporter: reporter)
        }
    }

    /// Open a queued remote op's own connection. If the server refuses it WHILE another remote op
    /// is already live on the SAME server, treat it as a per-server connection cap rather than a
    /// failure: put the op back in the queue marked `forceSerial` (it reruns once nothing else is
    /// transferring) and return false so the caller bails out quietly. Returns true when connected.
    /// Any other error (bad credentials, host down, or an op already downgraded once) is rethrown.
    /// Perform a batch of already-planned rename steps against a live remote session. Uses the
    /// server-side move (RNFR/RNTO for FTP, etc.), creating any missing target directories for a
    /// subfolder move. Reports progress and stops on cancel; per-step failures are collected and
    /// surfaced as one error at the end (so the whole batch reports a clean success/fail).
    private func runRemoteMultiRename(session: RemoteSession,
                                      steps: [RenameExecutionPlanner.Step],
                                      reporter: QueueOperationReporter) async throws {
        let fs = session.fileSystem
        let total = steps.count
        var done = 0
        var errors: [String] = []
        for step in steps {
            if reporter.isCancelled { break }
            let srcParent = fs.parentPath(for: step.from)
            let dstParent = fs.parentPath(for: step.to)
            if dstParent != srcParent {
                await ensureRemoteDirectory(fs: fs, path: dstParent)
            }
            do {
                try await fs.moveItem(from: step.from, to: step.to)
            } catch {
                errors.append((step.from as NSString).lastPathComponent + ": " + error.localizedDescription)
            }
            done += 1
            reporter.update(currentFile: (step.to as NSString).lastPathComponent,
                            progress: Double(done) / Double(max(1, total)),
                            bytesDone: 0, bytesTotal: 0, filesDone: done, filesTotal: total)
        }
        if !errors.isEmpty {
            throw NSError(domain: "com.fcxl.queue.remoteRename", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "\n")])
        }
    }

    /// Best-effort create of a remote directory chain (each level ignores "already exists").
    private func ensureRemoteDirectory(fs: RemoteFileSystemProtocol, path: String) async {
        var current = ""
        for comp in path.split(separator: "/").map(String.init) {
            let parent = current.isEmpty ? "/" : current
            current += "/" + comp
            try? await fs.createDirectory(at: parent, name: comp)
        }
    }

    private func connectOrDowngrade(_ session: RemoteSession, opID: UUID,
                                    connectionID: UUID) async throws -> Bool {
        // "Someone else is on this server": our own slot was claimed in startOperation, so any
        // count above 1 is a sibling — INCLUDING a direct, non-queued transfer, which never
        // shows up in `operations`.
        func siblingLiveOnSameServer() -> Bool {
            ConnectionManagerService.shared.activeTransferCount(for: connectionID) > 1
        }
        // Snapshot BEFORE the await: a sibling may well finish while our connect is failing, and
        // that must not turn a connection-cap refusal into a hard failure.
        let hadSibling = siblingLiveOnSameServer()
        do {
            try await session.fileSystem.connect()
            return true
        } catch {
            // A throwing connect usually leaves nothing open, but a partially established
            // transport (FTP control socket, half-done mount) is not guaranteed to be torn down.
            session.fileSystem.disconnect()
            guard hadSibling || siblingLiveOnSameServer(),
                  let idx = index(of: opID),
                  // NEVER resurrect an op the user cancelled or paused while we were connecting —
                  // requeueing it would re-run a cancelled transfer (and delete a move's source).
                  operations[idx].status == .running,
                  !operations[idx].forceSerial else {
                throw error
            }
            operations[idx].status = .queued
            operations[idx].forceSerial = true
            operations[idx].startedAt = nil
            reporters.removeValue(forKey: opID)
            // Give the server slot back — the retry claims it again via startOperation.
            ConnectionManagerService.shared.releaseTransferConnection(for: connectionID)
            Self.log.info("remote connect refused while busy — will retry serially id=\(opID)")
            processQueue()
            return false
        }
    }

    private func executeOperation(id: UUID, reporter: QueueOperationReporter) async {
        guard let idx = index(of: id) else { return }
        let op = operations[idx]

        do {
            switch op.kind {
            case .copy:
                guard let dest = op.destinationPath else {
                    throw NSError(domain: "com.fcxl.queue", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "No destination for copy"])
                }
                try await fileOps.copyItems(
                    op.items,
                    to: dest,
                    reporter: reporter,
                    onDialogsDone: { [weak self] in self?.dialogPhaseFinished(id) },
                    onProgress: { [weak reporter] progress, label in
                        Task { @MainActor in
                            reporter?.update(
                                currentFile: label, progress: progress,
                                bytesDone: 0, bytesTotal: 0,
                                filesDone: 0, filesTotal: 0
                            )
                        }
                    },
                    // NON-blocking on purpose: transferItems polls this from a MAIN-thread
                    // timer, and waitWhilePaused() here parked the main thread on a semaphore
                    // the moment the row was paused — the beachball that cannot be unpaused,
                    // because unpausing needs the main thread. Pause still works: the transfer
                    // worker calls waitWhilePaused on ITS background thread via the reporter.
                    shouldCancel: { [weak reporter] in
                        reporter?.isCancelled ?? true
                    }
                )

            case .move:
                guard let dest = op.destinationPath else {
                    throw NSError(domain: "com.fcxl.queue", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "No destination for move"])
                }
                try await fileOps.moveItems(
                    op.items,
                    to: dest,
                    reporter: reporter,
                    onDialogsDone: { [weak self] in self?.dialogPhaseFinished(id) },
                    // Same rule as the copy above: polled from the main thread — never block.
                    shouldCancel: { [weak reporter] in
                        reporter?.isCancelled ?? true
                    }
                )

            case .delete:
                try await fileOps.trashItems(op.items)

            case .pack:
                guard let params = op.archiveParams else {
                    throw NSError(domain: "com.fcxl.queue", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing archive params for pack"])
                }
                try fileOps.packSingleArchiveBackground(
                    op.items,
                    to: params.archivePath,
                    format: params.format,
                    compressionLevel: params.compressionLevel,
                    preservePaths: params.preservePaths,
                    includeSubfolders: params.includeSubfolders,
                    password: params.password,
                    reporter: reporter
                )

            case .unpack:
                guard let dest = op.destinationPath,
                      let params = op.archiveParams else {
                    throw NSError(domain: "com.fcxl.queue", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing params for unpack"])
                }
                try fileOps.unpackArchiveBackground(
                    at: op.items.first?.path ?? "",
                    to: dest,
                    createSubfolder: params.createSubfolder,
                    overwriteExisting: params.overwriteExisting,
                    reporter: reporter
                )

            case .archiveExtract:
                guard let params = op.archiveParams, let dest = op.destinationPath else {
                    throw NSError(domain: "com.fcxl.queue", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey:
                                              "Missing params for archive extract"])
                }
                try fileOps.extractEntries(
                    params.entryPaths,
                    fromArchive: params.archivePath,
                    to: dest,
                    onProgress: { name, fraction, bytesDone, bytesTotal, filesDone, filesTotal in
                        Task { @MainActor in
                            reporter.update(currentFile: name, progress: fraction,
                                            bytesDone: bytesDone, bytesTotal: bytesTotal,
                                            filesDone: filesDone, filesTotal: filesTotal)
                        }
                    },
                    // Polled from the background walk — never block it on the main thread.
                    shouldCancel: { [weak reporter] in reporter?.isCancelled ?? true })

            case .archiveDelete:
                guard let params = op.archiveParams else {
                    throw NSError(domain: "com.fcxl.queue", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing archive params for delete"])
                }
                try fileOps.deleteEntriesFromArchiveBackground(
                    op.items,
                    archivePath: params.archivePath,
                    reporter: reporter
                )

            case .archiveRename:
                guard let params = op.archiveParams,
                      let item = op.items.first else {
                    throw NSError(domain: "com.fcxl.queue", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing params for rename"])
                }
                try fileOps.renameEntryInArchiveBackground(
                    item,
                    archivePath: params.archivePath,
                    to: params.newEntryName,
                    reporter: reporter
                )

            case .remoteDownload:
                guard let params = op.remoteParams else {
                    throw NSError(domain: "com.fcxl.queue", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing remote params for download"])
                }
                guard let connection = ConnectionManagerService.shared.connection(for: params.connectionID) else {
                    throw NSError(domain: "com.fcxl.queue", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Connection not found: \(params.connectionLabel)"])
                }
                let downloadSession = ConnectionManagerService.shared.createSession(for: connection)
                // Bails out (op requeued to run alone) if the server refused an extra connection.
                guard try await connectOrDowngrade(downloadSession, opID: id,
                                                   connectionID: params.connectionID) else { return }
                let downloadOnSuccess = takeOnSuccess(for: op.id)
                // A transfer that lost files reports it here; the throw below turns this
                // operation into a failed one, which is what puts "continue" on its row.
                var downloadFailure: Error?
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    RemoteTransferService().downloadItems(
                        op.items,
                        from: downloadSession,
                        to: params.localPath,
                        reporter: reporter,
                        onCompletion: {
                            downloadSession.fileSystem.disconnect()
                            continuation.resume()
                        },
                        onSuccess: downloadOnSuccess,
                        onFailure: { downloadFailure = $0 }
                    )
                }
                if let downloadFailure { throw downloadFailure }

            case .remoteUpload:
                guard let params = op.remoteParams else {
                    throw NSError(domain: "com.fcxl.queue", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing remote params for upload"])
                }
                guard let connection = ConnectionManagerService.shared.connection(for: params.connectionID) else {
                    throw NSError(domain: "com.fcxl.queue", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Connection not found: \(params.connectionLabel)"])
                }
                let uploadSession = ConnectionManagerService.shared.createSession(for: connection)
                // Bails out (op requeued to run alone) if the server refused an extra connection.
                guard try await connectOrDowngrade(uploadSession, opID: id,
                                                   connectionID: params.connectionID) else { return }
                let uploadOnSuccess = takeOnSuccess(for: op.id)
                var uploadFailure: Error?
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    RemoteTransferService().uploadItems(
                        op.items,
                        to: uploadSession,
                        remoteDestination: params.remotePath,
                        reporter: reporter,
                        onCompletion: {
                            uploadSession.fileSystem.disconnect()
                            continuation.resume()
                        },
                        onSuccess: uploadOnSuccess,
                        onFailure: { uploadFailure = $0 }
                    )
                }
                if let uploadFailure { throw uploadFailure }

            case .remoteDelete:
                guard let params = op.remoteParams else {
                    throw NSError(domain: "com.fcxl.queue", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing remote params for delete"])
                }
                guard let connection = ConnectionManagerService.shared.connection(for: params.connectionID) else {
                    throw NSError(domain: "com.fcxl.queue", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Connection not found: \(params.connectionLabel)"])
                }
                let deleteSession = ConnectionManagerService.shared.createSession(for: connection)
                // Bails out (op requeued to run alone) if the server refused an extra connection.
                guard try await connectOrDowngrade(deleteSession, opID: id,
                                                   connectionID: params.connectionID) else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    RemoteTransferService().deleteRemoteItems(
                        op.items,
                        from: deleteSession,
                        onCompletion: {
                            deleteSession.fileSystem.disconnect()
                            continuation.resume()
                        }
                    )
                }

            case .multiRename:
                guard let params = op.renameParams else {
                    throw NSError(domain: "com.fcxl.queue", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing rename params"])
                }
                if params.isRemote {
                    guard let cid = params.connectionID,
                          let connection = ConnectionManagerService.shared.connection(for: cid) else {
                        throw NSError(domain: "com.fcxl.queue", code: -1, userInfo: [
                            NSLocalizedDescriptionKey: "Connection not found: \(params.connectionLabel)"])
                    }
                    let session = ConnectionManagerService.shared.createSession(for: connection)
                    try await session.fileSystem.connect()
                    defer { session.fileSystem.disconnect() }
                    try await runRemoteMultiRename(session: session, steps: params.steps, reporter: reporter)
                } else {
                    try await fileOps.executeRenameSteps(params.steps, reporter: reporter)
                }
                // Full success (no throw): fire onSuccess so the VM captures undo + refreshes.
                takeOnSuccess(for: op.id)?()
            }

            if let idx = index(of: id) {
                // Nothing was thrown — but "nothing went wrong" is not the same as "it is
                // done". A transfer the person stopped ends quietly here too (a cancel is no
                // longer reported as an error), and a green tick over it would be a lie.
                if operations[idx].status == .cancelled || reporter.isCancelled {
                    operations[idx].status = .cancelled
                } else {
                    operations[idx].status = .completed
                    operations[idx].progress = 1.0
                }
                operations[idx].completedAt = Date()
            }
            Self.log.info("finished id=\(id)")

        } catch {
            let nsError = error as NSError
            let wasCancelled = nsError.domain == NSCocoaErrorDomain
                && nsError.code == CocoaError.userCancelled.rawValue

            if let idx = index(of: id) {
                if wasCancelled || operations[idx].status == .cancelled {
                    operations[idx].status = .cancelled
                } else {
                    operations[idx].status = .failed
                    operations[idx].error = error.localizedDescription
                }
                operations[idx].completedAt = Date()
            }

            if wasCancelled {
                Self.log.info("cancelled id=\(id)")
            } else {
                Self.log.error("failed id=\(id) error=\(error.localizedDescription)")
            }
        }

        reporters.removeValue(forKey: id)
        // Failed/cancelled ops never reach takeOnSuccess, so clear it here too (the downgrade
        // path returns earlier, so a requeued op keeps its callback for the serial retry).
        onSuccessCallbacks.removeValue(forKey: id)
        // A transfer that can still be continued keeps the aside copy, so that pressing
        // "continue" finishes the move it was part of instead of only half of it.
        if index(of: id).map({ !operations[$0].canBeResumed }) ?? true {
            onSuccessForRetry.removeValue(forKey: id)
        }
        // Release the server slot claimed in startOperation — every exit lands here except the
        // downgrade path, which releases it itself before requeueing.
        if op.kind.isRemote, let cid = op.remoteParams?.connectionID {
            ConnectionManagerService.shared.releaseTransferConnection(for: cid)
        }
        // Safety net for operations that never reached "questions over" — failed or
        // cancelled during their opening phase. Without this the gate stays shut forever.
        dialogPhaseOps.remove(id)
        fireCompletion(id)
        processQueue()
    }

    /// The operation's last possible question is behind it — the queue may start the next
    /// local operation next to it.
    private func dialogPhaseFinished(_ id: UUID) {
        guard dialogPhaseOps.remove(id) != nil else { return }
        processQueue()
    }

    private func fireCompletion(_ id: UUID) {
        if let callback = onCompletionCallbacks.removeValue(forKey: id) {
            callback()
        }
    }

    /// The queue-registered onSuccess for an operation it runs itself, handed to the transfer
    /// service so it fires only on a real success. Removed so it's consumed exactly once.
    func takeOnSuccess(for id: UUID) -> (() -> Void)? {
        onSuccessCallbacks.removeValue(forKey: id)
    }
}
