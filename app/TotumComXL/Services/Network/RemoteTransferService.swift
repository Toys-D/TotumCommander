import Foundation

/// Serializes app-modal conflict dialogs. With parallel remote transfers two of them can hit a
/// file conflict at the same moment, and two app-modal sessions at once do not nest cleanly — the
/// second transfer waits here until the first dialog has been answered.
@MainActor
enum ConflictDialogGate {
    private static var busy = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    static func release() {
        if waiters.isEmpty {
            busy = false          // nobody waiting — gate is free
        } else {
            waiters.removeFirst().resume()   // hand the gate straight to the next waiter
        }
    }
}

/// Handles file transfers between local and remote filesystems with progress reporting
/// and conflict resolution dialogs.
@MainActor
final class RemoteTransferService {

    private let dialogService = DialogService.shared

    /// Conflict resolution for the entire batch (when user checks "Apply to all").
    private enum BatchConflictPolicy {
        case askEach
        case replaceAll
        case skipAll
    }

    /// Tracks errors during batch operations.
    private struct TransferStats {
        var filesTransferred = 0
        var errors: [(name: String, message: String)] = []
        /// Files the user chose to SKIP on a conflict. A skipped file was NOT transferred,
        /// so on a MOVE its source must NOT be deleted — see the onSuccess gates. Skips are
        /// silent (no error), so without counting them a skipped file would be deleted from
        /// the source while never arriving at the destination: data loss.
        var filesSkipped = 0
    }

    // MARK: - Download (remote → local)

    /// What the QUEUE has to be told, as opposed to what the person is told.
    ///
    /// A transfer that lost some files still walks through the rest and shows one summary at
    /// the end — that is right for the person watching. But the operation behind it must not
    /// then report itself finished: it ends as failed, keeps its place in the queue, and
    /// offers to be continued. Without this the row wore a green tick over a file that never
    /// arrived, and there was nothing to press.
    struct TransferIncomplete: LocalizedError {
        let issues: [(name: String, message: String)]

        var errorDescription: String? {
            let shown = issues.prefix(3).map { "\($0.name): \($0.message)" }.joined(separator: "\n")
            return String(format: L("network.error.transferErrors", issues.count)) + "\n" + shown
                + (issues.count > 3 ? "\n…" : "")
        }
    }

    func downloadItems(_ items: [FileItem], from session: RemoteSession,
                       to localDestination: String,
                       reporter: OperationProgressReporter? = nil,
                       onCompletion: (() -> Void)? = nil,
                       onSuccess: (() -> Void)? = nil,
                       onFailure: ((Error) -> Void)? = nil) {
        let totalFiles = items.count
        let title = totalFiles == 1
            ? L("queue.downloadSingle", items[0].name)
            : L("queue.downloadMultiple", totalFiles)

        let progress: OperationProgressReporter = reporter
            ?? dialogService.showProgress(title: title, message: "", cancelHandler: nil)

        Task {
            var totalBytes: Int64 = items.reduce(0) { $0 + Int64($1.size) }
            if totalBytes == 0 { totalBytes = 1 }
            var bytesDone: Int64 = 0
            var filesDone = 0
            var batchPolicy: BatchConflictPolicy = .askEach
            var stats = TransferStats()

            for item in items {
                if progress.isCancelled { break }

                let localPath = (localDestination as NSString).appendingPathComponent(item.name)

                if item.isDirectory {
                    await downloadDirectoryRecursive(
                        remotePath: item.path, localPath: localPath,
                        session: session, progress: progress,
                        bytesDone: &bytesDone, totalBytes: &totalBytes,
                        filesDone: &filesDone, totalFiles: totalFiles,
                        batchPolicy: &batchPolicy, stats: &stats)
                } else {
                    let resolved = await resolveDownloadConflict(
                        localPath: localPath, fileName: item.name,
                        directory: localDestination, batchPolicy: &batchPolicy)
                    if let destPath = resolved {
                        do {
                            try await downloadSingleFile(
                                item, to: destPath, session: session, progress: progress,
                                bytesDone: &bytesDone, totalBytes: totalBytes,
                                filesDone: filesDone, totalFiles: totalFiles)
                            stats.filesTransferred += 1
                        } catch {
                            note(error, for: item.name, in: &stats)
                        }
                    } else {
                        stats.filesSkipped += 1   // conflict → user skipped; source must stay
                    }
                }
                filesDone += 1
            }
            progress.close()
            // Whoever gave us onFailure OWNS the reporting: the queue paints its row red
            // with the reason and a continue button, and a modal on top of that is the
            // program shouting over its own answer. The summary here is only for callers
            // with nobody else to tell.
            if onFailure == nil { showTransferSummaryIfNeeded(stats: stats, operation: "download") }
            // Only signal success (→ source deletion for a move) when nothing was cancelled
            // and no file errored. Otherwise the source must stay put.
            if !progress.isCancelled && stats.errors.isEmpty && stats.filesSkipped == 0 { onSuccess?() }
            // …and the operation behind this transfer must not wear a green tick over a file
            // that never arrived: it ends as failed, so it can be continued.
            if !stats.errors.isEmpty { onFailure?(TransferIncomplete(issues: stats.errors)) }
            onCompletion?()
        }
    }

    /// Recursively download a remote directory to local filesystem.
    private func downloadDirectoryRecursive(
        remotePath: String, localPath: String,
        session: RemoteSession, progress: OperationProgressReporter,
        bytesDone: inout Int64, totalBytes: inout Int64,
        filesDone: inout Int, totalFiles: Int,
        batchPolicy: inout BatchConflictPolicy, stats: inout TransferStats
    ) async {
        // Create local directory
        do {
            try FileManager.default.createDirectory(
                atPath: localPath, withIntermediateDirectories: true)
        } catch {
            stats.errors.append((name: (remotePath as NSString).lastPathComponent,
                                 message: error.localizedDescription))
            return
        }

        // List remote directory contents
        guard let children = try? await session.fileSystem.listDirectory(at: remotePath) else {
            stats.errors.append((name: (remotePath as NSString).lastPathComponent,
                                 message: "Failed to list directory"))
            return
        }

        for child in children {
            if progress.isCancelled { break }

            let childLocalPath = (localPath as NSString).appendingPathComponent(child.name)

            if child.isDirectory {
                // Recurse into subdirectory
                await downloadDirectoryRecursive(
                    remotePath: child.path, localPath: childLocalPath,
                    session: session, progress: progress,
                    bytesDone: &bytesDone, totalBytes: &totalBytes,
                    filesDone: &filesDone, totalFiles: totalFiles,
                    batchPolicy: &batchPolicy, stats: &stats)
            } else {
                let resolved = await resolveDownloadConflict(
                    localPath: childLocalPath, fileName: child.name,
                    directory: localPath, batchPolicy: &batchPolicy)
                guard let destPath = resolved else { stats.filesSkipped += 1; continue }
                do {
                    try await downloadSingleFile(
                        child, to: destPath, session: session, progress: progress,
                        bytesDone: &bytesDone, totalBytes: totalBytes,
                        filesDone: filesDone, totalFiles: totalFiles)
                    stats.filesTransferred += 1
                } catch {
                    note(error, for: child.name, in: &stats)
                }
            }
        }
    }

    private func downloadSingleFile(
        _ item: FileItem, to localPath: String, session: RemoteSession,
        progress: OperationProgressReporter,
        bytesDone: inout Int64, totalBytes: Int64,
        filesDone: Int, totalFiles: Int
    ) async throws {
        let itemSize = Int64(item.size)
        let captured = bytesDone
        progress.update(
            currentFile: item.name,
            progress: Double(captured) / Double(totalBytes),
            bytesDone: captured, bytesTotal: totalBytes,
            filesDone: filesDone, filesTotal: totalFiles
        )
        try await downloadResumably(
            remotePath: item.path, to: localPath, size: itemSize,
            session: session, progress: progress
        ) { done in
            Task { @MainActor in
                progress.update(
                    currentFile: item.name,
                    progress: Double(captured + done) / Double(totalBytes),
                    bytesDone: captured + done, bytesTotal: totalBytes,
                    filesDone: filesDone, filesTotal: totalFiles
                )
            }
        }
        bytesDone += itemSize
    }

    // MARK: - One file, survivably

    /// Download into a `.part` twin and give it the real name only when it is whole.
    ///
    /// Two things follow from that. A break leaves an obvious leftover instead of a file that
    /// LOOKS finished, and the next attempt continues from it rather than from zero. The
    /// `report` closure is each caller's own progress arithmetic — the batch bar counts
    /// differently for a plain download and for a remote-to-remote copy.
    private func downloadResumably(remotePath: String, to localPath: String, size: Int64,
                                   session: RemoteSession,
                                   progress: OperationProgressReporter,
                                   report: @escaping (Int64) -> Void) async throws {
        let part = ResumableTransfer.partPath(for: localPath)
        let stall = ResumableTransfer.StallWatch()
        // Plain values for the knock: it runs in a child task, which must not drag the whole
        // session across threads just to learn an address.
        let host = session.connection.host
        let port = session.connection.effectivePort
        try await ResumableTransfer.run(
            totalSize: size,
            canResume: session.fileSystem.supportsResume,
            sizeSoFar: { ResumableTransfer.sizeOnDisk(part) },
            discard: { try? FileManager.default.removeItem(atPath: part) },
            isCancelled: { progress.isCancelled },
            announce: { progress.setTrouble($0) },
            linkIsBack: { await ResumableTransfer.serverAnswers(host: host, port: port) },
            revive: { await Self.rebuildLink(session) }
        ) { offset in
            try await session.fileSystem.download(remotePath: remotePath, to: part,
                                                  resumeFrom: offset) { done, _ in
                Self.speak(stall.note(bytes: done), to: progress)
                report(done)
                // Block this transfer thread while the operation is paused (queue Pause or the
                // cancel-confirmation freeze), then report the real cancel state. Just returning
                // isCancelled would ignore Pause entirely.
                _ = progress.waitWhilePaused()
                return progress.isCancelled
            }
        }

        // Anything already at the destination was agreed to be replaced by the conflict
        // dialog long before this line — otherwise the caller handed us a free name.
        if (try? FileManager.default.attributesOfItem(atPath: localPath)) != nil {
            try FileManager.default.removeItem(atPath: localPath)
        }
        try FileManager.default.moveItem(atPath: part, toPath: localPath)
    }

    /// The same idea pointing the other way: the half-sent twin lives on the SERVER and is
    /// renamed there once the last byte is across.
    private func uploadResumably(localPath: String, to remotePath: String, size: Int64,
                                 session: RemoteSession,
                                 progress: OperationProgressReporter,
                                 report: @escaping (Int64) -> Void) async throws {
        // S3 и подобные ему продолжают отправку сами: у них незавершённая заливка лежит
        // на сервере. Черновик под чужим именем им не нужен, а переименование в конце
        // обернулось бы копированием всего объекта в хранилище.
        let direct = session.fileSystem.uploadResumesItself
        let part = direct ? remotePath : ResumableTransfer.partPath(for: remotePath)
        let stall = ResumableTransfer.StallWatch()
        // Plain values for the knock: it runs in a child task, which must not drag the whole
        // session across threads just to learn an address.
        let host = session.connection.host
        let port = session.connection.effectivePort
        try await ResumableTransfer.run(
            totalSize: size,
            canResume: session.fileSystem.supportsResume,
            sizeSoFar: { direct ? 0 : await self.remoteSize(of: part, session: session) },
            discard: {
                guard !direct else { return }
                try? await session.fileSystem.deleteItem(at: part, isDirectory: false)
            },
            isCancelled: { progress.isCancelled },
            announce: { progress.setTrouble($0) },
            linkIsBack: { await ResumableTransfer.serverAnswers(host: host, port: port) },
            revive: { await Self.rebuildLink(session) }
        ) { offset in
            try await session.fileSystem.upload(localPath: localPath, to: part,
                                                resumeFrom: offset) { done, _ in
                Self.speak(stall.note(bytes: done), to: progress)
                report(done)
                _ = progress.waitWhilePaused()
                return progress.isCancelled
            }
        }

        guard !direct else { return }

        // FTP will not rename onto an occupied name, so a file the user chose to replace goes
        // first. Its removal is deliberate and already answered for.
        if await remoteSize(of: remotePath, session: session) > 0 {
            try? await session.fileSystem.deleteItem(at: remotePath, isDirectory: false)
        }
        try await session.fileSystem.rename(at: part,
                                            to: (remotePath as NSString).lastPathComponent)
    }

    /// A link that dropped leaves the session dead, and NOTHING else revives it: the connect
    /// happens once, when the operation starts. Without this a retry talks to a dead handle,
    /// gets "not connected" instantly, and burns every attempt in a blink.
    ///
    /// Torn down and rebuilt UNCONDITIONALLY between attempts. Asking "am I connected?"
    /// first does not work: after a break the C++ core knows the socket is dead while the
    /// Swift wrapper still says connected, and a revive that trusted the wrapper did
    /// nothing — which is exactly how a restored network changed nothing.
    private static func rebuildLink(_ session: RemoteSession) async {
        session.fileSystem.disconnect()
        try? await session.fileSystem.connect()
        // A connect that failed (the network is still down) is not reported from here: the
        // next transfer attempt will meet the dead session, fail, and take the next wait.
    }


    /// Raise or lower the stall line. Called from the transfer thread, so the words cross to
    /// the main actor here — and only on a CHANGE, not once a second.
    private static func speak(_ word: ResumableTransfer.StallWatch.Word,
                              to progress: OperationProgressReporter) {
        switch word {
        case .nothing:
            break
        case .say(let text):
            Task { @MainActor in progress.setTrouble(text) }
        case .quiet:
            Task { @MainActor in progress.setTrouble(nil) }
        }
    }

    /// How much of a file is already on the server. The protocol has no stat of its own, so
    /// the parent listing answers it — once per attempt, never per byte.
    private func remoteSize(of path: String, session: RemoteSession) async -> Int64 {
        let parent = session.fileSystem.parentPath(for: path)
        let name = (path as NSString).lastPathComponent
        let items = try? await session.fileSystem.listDirectory(at: parent)
        guard let match = items?.first(where: { $0.name == name }) else { return 0 }
        return Int64(match.size)
    }

    /// Check if local file exists; show conflict dialog if needed.
    /// Returns resolved path (may be renamed), or nil to skip.
    private func resolveDownloadConflict(
        localPath: String, fileName: String, directory: String,
        batchPolicy: inout BatchConflictPolicy
    ) async -> String? {
        guard FileManager.default.fileExists(atPath: localPath) else { return localPath }

        switch batchPolicy {
        case .replaceAll:
            try? FileManager.default.removeItem(atPath: localPath)
            return localPath
        case .skipAll:
            return nil
        case .askEach:
            // One conflict dialog at a time — parallel transfers must not stack modals.
            // `defer` so any exit below (including the early returns) frees the gate.
            await ConflictDialogGate.acquire()
            defer { ConflictDialogGate.release() }
            let result = await fcxlPresentModalAsync {
                self.dialogService.showFileConflictDialog(
                    fileName: fileName, allowReplace: true, showApplyToAll: true)
            }
            if result.applyToAll {
                switch result.choice {
                case .replace: batchPolicy = .replaceAll
                case .makeCopy: break // each copy gets unique name
                case .cancel: batchPolicy = .skipAll; return nil
                }
            }
            switch result.choice {
            case .replace:
                try? FileManager.default.removeItem(atPath: localPath)
                return localPath
            case .makeCopy:
                let newName = DialogService.generateCopyName(for: fileName, in: directory)
                return (directory as NSString).appendingPathComponent(newName)
            case .cancel:
                return nil
            }
        }
    }

    // MARK: - Upload (local → remote)

    func uploadItems(_ items: [FileItem], to session: RemoteSession,
                     remoteDestination: String,
                     reporter: OperationProgressReporter? = nil,
                     onCompletion: (() -> Void)? = nil,
                     onSuccess: (() -> Void)? = nil,
                     onFailure: ((Error) -> Void)? = nil) {
        let totalFiles = items.count
        let title = totalFiles == 1
            ? L("queue.uploadSingle", items[0].name)
            : L("queue.uploadMultiple", totalFiles)

        let progress: OperationProgressReporter = reporter
            ?? dialogService.showProgress(title: title, message: "", cancelHandler: nil)

        Task {
            // Pre-fetch remote listing for conflict detection
            var existingNames: Set<String>
            if let remoteItems = try? await session.fileSystem.listDirectory(at: remoteDestination) {
                existingNames = Set(remoteItems.map(\.name))
            } else {
                existingNames = []
            }

            var filesDone = 0
            var totalBytes: Int64 = 0
            // Calculate total size including subdirectories
            for item in items {
                totalBytes += calculateLocalSize(at: item.path)
            }
            if totalBytes == 0 { totalBytes = 1 }
            var bytesDone: Int64 = 0
            var batchPolicy: BatchConflictPolicy = .askEach
            var stats = TransferStats()

            for item in items {
                if progress.isCancelled { break }

                var remoteName = item.name
                let remoteExists = existingNames.contains(remoteName)

                if item.isDirectory {
                    // Recursive upload of directory
                    let remoteDir = remoteDestination.hasSuffix("/")
                        ? remoteDestination + remoteName
                        : remoteDestination + "/" + remoteName
                    await uploadDirectoryRecursive(
                        localPath: item.path, remotePath: remoteDir,
                        session: session, progress: progress,
                        bytesDone: &bytesDone, totalBytes: totalBytes,
                        filesDone: &filesDone, totalFiles: totalFiles,
                        batchPolicy: &batchPolicy, stats: &stats)
                } else {
                    if remoteExists {
                        let resolved = await resolveUploadConflict(
                            fileName: remoteName, existingNames: existingNames,
                            batchPolicy: &batchPolicy)
                        switch resolved {
                        case .skip: stats.filesSkipped += 1; filesDone += 1; continue
                        case .replace: break // overwrite — just upload
                        case .rename(let newName):
                            remoteName = newName
                            existingNames.insert(newName) // Track for next conflict
                        }
                    }

                    let remotePath = remoteDestination.hasSuffix("/")
                        ? remoteDestination + remoteName
                        : remoteDestination + "/" + remoteName
                    let itemSize = Int64(item.size)
                    let captured = bytesDone
                    progress.update(
                        currentFile: item.name,
                        progress: Double(captured) / Double(totalBytes),
                        bytesDone: captured, bytesTotal: totalBytes,
                        filesDone: filesDone, filesTotal: totalFiles
                    )

                    do {
                        try await uploadResumably(
                            localPath: item.path, to: remotePath, size: itemSize,
                            session: session, progress: progress
                        ) { done in
                            Task { @MainActor in
                                progress.update(
                                    currentFile: item.name,
                                    progress: Double(captured + done) / Double(totalBytes),
                                    bytesDone: captured + done, bytesTotal: totalBytes,
                                    filesDone: filesDone, filesTotal: totalFiles
                                )
                            }
                        }
                        bytesDone += itemSize
                        stats.filesTransferred += 1
                    } catch {
                        note(error, for: item.name, in: &stats)
                    }
                }
                filesDone += 1
            }
            progress.close()
            // Whoever gave us onFailure OWNS the reporting: the queue paints its row red
            // with the reason and a continue button, and a modal on top of that is the
            // program shouting over its own answer. The summary here is only for callers
            // with nobody else to tell.
            if onFailure == nil { showTransferSummaryIfNeeded(stats: stats, operation: "upload") }
            // Only signal success (→ source deletion for a move) when nothing was cancelled
            // and no file errored.
            if !progress.isCancelled && stats.errors.isEmpty && stats.filesSkipped == 0 { onSuccess?() }
            if !stats.errors.isEmpty { onFailure?(TransferIncomplete(issues: stats.errors)) }
            onCompletion?()
        }
    }

    /// Recursively upload a local directory to remote server.
    private func uploadDirectoryRecursive(
        localPath: String, remotePath: String,
        session: RemoteSession, progress: OperationProgressReporter,
        bytesDone: inout Int64, totalBytes: Int64,
        filesDone: inout Int, totalFiles: Int,
        batchPolicy: inout BatchConflictPolicy, stats: inout TransferStats
    ) async {
        // Create remote directory
        let dirName = (remotePath as NSString).lastPathComponent
        let parentPath = (remotePath as NSString).deletingLastPathComponent
        do {
            try await session.fileSystem.createDirectory(at: parentPath, name: dirName)
        } catch {
            // Directory might already exist — continue
        }

        // Pre-fetch remote listing for conflict detection
        let existingNames: Set<String>
        if let remoteItems = try? await session.fileSystem.listDirectory(at: remotePath) {
            existingNames = Set(remoteItems.map(\.name))
        } else {
            existingNames = []
        }

        // List local directory
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: localPath) else {
            stats.errors.append((name: dirName, message: "Cannot read local directory"))
            return
        }

        for childName in contents {
            if progress.isCancelled { break }

            let childLocalPath = (localPath as NSString).appendingPathComponent(childName)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: childLocalPath, isDirectory: &isDir) else {
                continue
            }

            if isDir.boolValue {
                let childRemotePath = remotePath.hasSuffix("/")
                    ? remotePath + childName
                    : remotePath + "/" + childName
                await uploadDirectoryRecursive(
                    localPath: childLocalPath, remotePath: childRemotePath,
                    session: session, progress: progress,
                    bytesDone: &bytesDone, totalBytes: totalBytes,
                    filesDone: &filesDone, totalFiles: totalFiles,
                    batchPolicy: &batchPolicy, stats: &stats)
            } else {
                var remoteName = childName
                if existingNames.contains(remoteName) {
                    let resolved = await resolveUploadConflict(
                        fileName: remoteName, existingNames: existingNames,
                        batchPolicy: &batchPolicy)
                    switch resolved {
                    case .skip: stats.filesSkipped += 1; continue
                    case .replace: break
                    case .rename(let newName): remoteName = newName
                    }
                }

                let childRemotePath = remotePath.hasSuffix("/")
                    ? remotePath + remoteName
                    : remotePath + "/" + remoteName
                let captured = bytesDone
                let capturedFilesDone = filesDone
                progress.update(
                    currentFile: childName,
                    progress: Double(captured) / Double(totalBytes),
                    bytesDone: captured, bytesTotal: totalBytes,
                    filesDone: capturedFilesDone, filesTotal: totalFiles
                )

                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: childLocalPath)
                    let fileSize = (attrs[.size] as? Int64) ?? 0

                    try await uploadResumably(
                        localPath: childLocalPath, to: childRemotePath, size: fileSize,
                        session: session, progress: progress
                    ) { done in
                        Task { @MainActor in
                            progress.update(
                                currentFile: childName,
                                progress: Double(captured + done) / Double(totalBytes),
                                bytesDone: captured + done, bytesTotal: totalBytes,
                                filesDone: capturedFilesDone, filesTotal: totalFiles
                            )
                        }
                    }
                    bytesDone += fileSize
                    stats.filesTransferred += 1
                } catch {
                    note(error, for: childName, in: &stats)
                }
            }
        }
    }

    /// Calculate total size of a local path (file or directory, recursively).
    private func calculateLocalSize(at path: String) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }

        if !isDir.boolValue {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            return (attrs?[.size] as? Int64) ?? 0
        }

        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        while let child = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(child)
            let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath)
            total += (attrs?[.size] as? Int64) ?? 0
        }
        return total
    }

    private enum UploadConflictAction {
        case replace, skip, rename(String)
    }

    private func resolveUploadConflict(
        fileName: String, existingNames: Set<String>,
        batchPolicy: inout BatchConflictPolicy
    ) async -> UploadConflictAction {
        switch batchPolicy {
        case .replaceAll: return .replace
        case .skipAll: return .skip
        case .askEach:
            // One conflict dialog at a time — parallel transfers must not stack modals.
            // `defer` so any exit below (including the early returns) frees the gate.
            await ConflictDialogGate.acquire()
            defer { ConflictDialogGate.release() }
            let result = await fcxlPresentModalAsync {
                self.dialogService.showFileConflictDialog(
                    fileName: fileName, allowReplace: true, showApplyToAll: true)
            }
            if result.applyToAll {
                switch result.choice {
                case .replace: batchPolicy = .replaceAll
                case .cancel: batchPolicy = .skipAll
                case .makeCopy: break
                }
            }
            switch result.choice {
            case .replace: return .replace
            case .cancel: return .skip
            case .makeCopy:
                return .rename(generateRemoteCopyName(for: fileName, existingNames: existingNames))
            }
        }
    }

    /// Generate unique copy name checking against existing remote files.
    private func generateRemoteCopyName(for originalName: String, existingNames: Set<String>) -> String {
        let ext = (originalName as NSString).pathExtension
        let baseName = ext.isEmpty ? originalName : (originalName as NSString).deletingPathExtension

        var candidate = ext.isEmpty ? "\(baseName) \(L("file.copySuffix"))" : "\(baseName) \(L("file.copySuffix")).\(ext)"
        var counter = 2
        while existingNames.contains(candidate) {
            candidate = ext.isEmpty
                ? "\(baseName) \(L("file.copySuffixNumbered", counter))"
                : "\(baseName) \(L("file.copySuffixNumbered", counter)).\(ext)"
            counter += 1
        }
        return candidate
    }

    // MARK: - Delete on remote server

    func deleteRemoteItems(_ items: [FileItem], from session: RemoteSession,
                           onCompletion: (() -> Void)? = nil) {
        let totalFiles = items.count
        let title = totalFiles == 1
            ? L("queue.remoteDeleteSingle", items[0].name)
            : L("queue.remoteDeleteMultiple", totalFiles)

        let progress = dialogService.showProgress(title: title, message: "", cancelHandler: nil)
        // Server-side deletion has no byte-level progress, and files/totalFiles stalls at 0%
        // for a single file — show a live spinner instead of a bar frozen at ~1%.
        progress.setIndeterminate(true)

        Task {
            var filesDone = 0
            var stats = TransferStats()
            for item in items {
                if progress.isCancelled { break }
                progress.update(
                    currentFile: item.name,
                    progress: Double(filesDone) / Double(totalFiles),
                    bytesDone: 0, bytesTotal: 0,
                    filesDone: filesDone, filesTotal: totalFiles
                )
                do {
                    // Хранилище, умеющее снести папку целиком, делает это одним обращением.
                    // Наш обход дерева слал запрос на каждый файл: на папке в двести файлов
                    // это были минуты, и по окну нельзя было понять, идёт ли дело вообще.
                    if item.isDirectory, session.fileSystem.deletesTreesItself {
                        try await session.fileSystem.deleteItem(at: item.path, isDirectory: true)
                    } else if item.isDirectory {
                        try await deleteDirectoryRecursively(at: item.path, session: session)
                    } else {
                        try await session.fileSystem.deleteItem(at: item.path, isDirectory: false)
                    }
                    stats.filesTransferred += 1
                } catch {
                    note(error, for: item.name, in: &stats)
                }
                filesDone += 1
            }
            progress.close()
            showTransferSummaryIfNeeded(stats: stats, operation: "delete")
            onCompletion?()
        }
    }

    /// Recursively delete a remote directory: first delete all contents, then the empty directory.
    private func deleteDirectoryRecursively(at path: String, session: RemoteSession) async throws {
        let contents = try await session.fileSystem.listDirectory(at: path)
        for item in contents {
            if item.name == ".." { continue }
            if item.isDirectory {
                try await deleteDirectoryRecursively(at: item.path, session: session)
            } else {
                try await session.fileSystem.deleteItem(at: item.path, isDirectory: false)
            }
        }
        try await session.fileSystem.deleteItem(at: path, isDirectory: true)
    }

    // MARK: - Mkdir on remote server

    func createRemoteDirectory(name: String, at path: String, session: RemoteSession) async throws {
        try await session.fileSystem.createDirectory(at: path, name: name)
    }

    // MARK: - Remote → Remote move (server-side RNFR/RNTO, instant)

    func moveRemoteItems(_ items: [FileItem], on session: RemoteSession,
                         to remoteDest: String,
                         onCompletion: (() -> Void)? = nil) {
        let totalFiles = items.count
        let title = totalFiles == 1
            ? L("button.move") + ": " + items[0].name
            : L("button.move") + ": \(totalFiles)"

        let progress = dialogService.showProgress(title: title, message: "", cancelHandler: nil)

        Task {
            // Pre-fetch destination listing for conflict detection
            var existingNames: Set<String>
            if let destItems = try? await session.fileSystem.listDirectory(at: remoteDest) {
                existingNames = Set(destItems.map(\.name))
            } else {
                existingNames = []
            }

            var filesDone = 0
            var stats = TransferStats()
            var batchPolicy: BatchConflictPolicy = .askEach

            for item in items {
                if progress.isCancelled { break }
                progress.update(
                    currentFile: item.name,
                    progress: Double(filesDone) / Double(totalFiles),
                    bytesDone: 0, bytesTotal: 0,
                    filesDone: filesDone, filesTotal: totalFiles
                )

                var destName = item.name
                // Moving a file onto ITSELF (same directory) is a no-op — and must be caught
                // here, because otherwise the Replace branch below would delete the existing
                // file (which IS the source), then the move would fail with the source already
                // gone: data loss. This guards F6 same-folder moves and paste-into-own-folder.
                let selfDest = remoteDest.hasSuffix("/")
                    ? remoteDest + destName
                    : remoteDest + "/" + destName
                if selfDest == item.path {
                    filesDone += 1
                    continue
                }
                if existingNames.contains(destName) {
                    let resolved = await resolveUploadConflict(
                        fileName: destName, existingNames: existingNames,
                        batchPolicy: &batchPolicy)
                    switch resolved {
                    case .skip: filesDone += 1; continue
                    case .replace:
                        // Delete existing before move
                        let existingPath = remoteDest.hasSuffix("/")
                            ? remoteDest + destName
                            : remoteDest + "/" + destName
                        try? await session.fileSystem.deleteItem(at: existingPath, isDirectory: false)
                    case .rename(let newName):
                        destName = newName
                        existingNames.insert(newName)
                    }
                }

                let destPath = remoteDest.hasSuffix("/")
                    ? remoteDest + destName
                    : remoteDest + "/" + destName
                do {
                    try await session.fileSystem.moveItem(from: item.path, to: destPath)
                    stats.filesTransferred += 1
                } catch {
                    note(error, for: item.name, in: &stats)
                }
                filesDone += 1
            }
            progress.close()
            showTransferSummaryIfNeeded(stats: stats, operation: "move")
            onCompletion?()
        }
    }

    // MARK: - Remote → Remote copy (via temp file: download + upload)

    func copyRemoteItems(_ items: [FileItem], from sourceSession: RemoteSession,
                         to destSession: RemoteSession, remoteDest: String,
                         onCompletion: (() -> Void)? = nil) {
        let totalFiles = items.count
        let title = totalFiles == 1
            ? L("button.copy") + ": " + items[0].name
            : L("button.copy") + ": \(totalFiles)"

        let progress = dialogService.showProgress(title: title, message: "", cancelHandler: nil)

        Task {
            let tempDir = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("fcxl-remote-copy-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                atPath: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tempDir) }

            // Pre-fetch destination listing for conflict detection
            var existingNames: Set<String>
            if let destItems = try? await destSession.fileSystem.listDirectory(at: remoteDest) {
                existingNames = Set(destItems.map(\.name))
            } else {
                existingNames = []
            }

            var filesDone = 0
            var totalBytes: Int64 = items.reduce(0) { $0 + Int64($1.size) }
            if totalBytes == 0 { totalBytes = 1 }
            var bytesDone: Int64 = 0
            var stats = TransferStats()
            var batchPolicy: BatchConflictPolicy = .askEach

            for item in items {
                if progress.isCancelled { break }

                // Check for conflicts on destination
                var remoteName = item.name
                if existingNames.contains(remoteName) {
                    let resolved = await resolveUploadConflict(
                        fileName: remoteName, existingNames: existingNames,
                        batchPolicy: &batchPolicy)
                    switch resolved {
                    case .skip: filesDone += 1; continue
                    case .replace: break
                    case .rename(let newName):
                        remoteName = newName
                        existingNames.insert(newName)
                    }
                }

                let tempPath = (tempDir as NSString).appendingPathComponent(item.name)
                let itemSize = Int64(item.size)
                let captured = bytesDone

                // Phase 1: Download from source
                progress.update(
                    currentFile: "↓ " + item.name,
                    progress: Double(captured) / Double(totalBytes),
                    bytesDone: captured, bytesTotal: totalBytes,
                    filesDone: filesDone, filesTotal: totalFiles
                )

                do {
                    try await downloadResumably(
                        remotePath: item.path, to: tempPath, size: itemSize,
                        session: sourceSession, progress: progress
                    ) { done in
                        Task { @MainActor in
                            progress.update(
                                currentFile: "↓ " + item.name,
                                progress: Double(captured + done / 2) / Double(totalBytes),
                                bytesDone: captured + done / 2, bytesTotal: totalBytes,
                                filesDone: filesDone, filesTotal: totalFiles
                            )
                        }
                    }

                    // Phase 2: Upload to destination (use remoteName which may be renamed for conflict)
                    let remotePath = remoteDest.hasSuffix("/")
                        ? remoteDest + remoteName
                        : remoteDest + "/" + remoteName

                    progress.update(
                        currentFile: "↑ " + item.name,
                        progress: Double(captured + itemSize / 2) / Double(totalBytes),
                        bytesDone: captured + itemSize / 2, bytesTotal: totalBytes,
                        filesDone: filesDone, filesTotal: totalFiles
                    )

                    try await uploadResumably(
                        localPath: tempPath, to: remotePath, size: itemSize,
                        session: destSession, progress: progress
                    ) { done in
                        Task { @MainActor in
                            progress.update(
                                currentFile: "↑ " + item.name,
                                progress: Double(captured + itemSize / 2 + done / 2) / Double(totalBytes),
                                bytesDone: captured + itemSize / 2 + done / 2, bytesTotal: totalBytes,
                                filesDone: filesDone, filesTotal: totalFiles
                            )
                        }
                    }

                    bytesDone += itemSize
                    stats.filesTransferred += 1
                } catch {
                    note(error, for: item.name, in: &stats)
                }

                // Cleanup temp file
                try? FileManager.default.removeItem(atPath: tempPath)
                filesDone += 1
            }
            progress.close()
            showTransferSummaryIfNeeded(stats: stats, operation: "copy")
            onCompletion?()
        }
    }

    // MARK: - Error summary

    /// A cancel is NOT an error. The person stopped the transfer on purpose; telling them
    /// afterwards that "the transfer finished with 1 error" is both wrong and rude, and it
    /// makes a deliberate stop look like a failure of the program. Everything else is kept.
    private func note(_ error: Error, for name: String, in stats: inout TransferStats) {
        guard !Self.isCancellation(error) else { return }
        stats.errors.append((name: name, message: error.localizedDescription))
    }

    static func isCancellation(_ error: Error) -> Bool {
        if let remote = error as? RemoteFileSystemError, case .transferCancelled = remote {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == CocoaError.userCancelled.rawValue
    }

    private func showTransferSummaryIfNeeded(stats: TransferStats, operation: String) {
        guard !stats.errors.isEmpty else { return }
        let errorList = stats.errors.prefix(5).map { "• \($0.name): \($0.message)" }.joined(separator: "\n")
        let suffix = stats.errors.count > 5
            ? "\n... \(L("network.error.andMore", stats.errors.count - 5))"
            : ""
        DialogService.shared.showWarning(
            title: L("network.error.transferErrors", stats.errors.count),
            message: "\(L("network.error.filesTransferred", stats.filesTransferred))\n\n\(errorList)\(suffix)"
        )
    }
}
