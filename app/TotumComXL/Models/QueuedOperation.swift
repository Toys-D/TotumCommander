import Foundation

enum OperationKind: String {
    case copy
    case move
    case delete
    case pack
    case unpack
    case archiveDelete
    case archiveRename
    /// Pulling CHOSEN entries out of an archive — the drag-out road, which until now could not
    /// be handed to the queue at all.
    case archiveExtract
    case remoteDownload
    case remoteUpload
    case remoteDelete
    case multiRename

    /// Remote transfers each hold their own network connection, so several may run at once
    /// (see OperationQueueService.processQueue). Local ops stay strictly serial — they
    /// contend on the same disk and on the shared conflict dialogs.
    var isRemote: Bool {
        self == .remoteDownload || self == .remoteUpload || self == .remoteDelete
    }
}

enum OperationStatus: String {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled
}

/// Parameters specific to archive pack/unpack/delete/rename operations.
struct ArchiveOperationParams {
    var archivePath: String = ""
    var format: ArchiveFormat = .zip
    var compressionLevel: Int = 6
    var preservePaths: Bool = true
    var includeSubfolders: Bool = true
    var createSubfolder: Bool = false
    var overwriteExisting: Bool = false
    /// For archiveRename — the new entry name
    var newEntryName: String = ""
    /// For archiveExtract — the entries chosen inside the archive, by their paths in it.
    var entryPaths: [String] = []
    /// The archive's password, when it has one. This struct lives in MEMORY only — were the
    /// queue ever persisted to disk, this field must be excluded first.
    var password: String = ""
}

/// Parameters for remote file transfer operations.
struct RemoteTransferParams {
    var connectionID: UUID
    var connectionLabel: String
    var remotePath: String
    var localPath: String
}

/// Parameters for a batch multi-rename. `steps` are already planned (source -> target absolute
/// paths, incl. temp-name staging). Remote fields drive the network path (filled in a later task).
struct MultiRenameParams {
    var steps: [RenameExecutionPlanner.Step]
    var isRemote: Bool = false
    var connectionID: UUID?
    var connectionLabel: String = ""
}

struct QueuedOperation: Identifiable {
    let id: UUID
    let kind: OperationKind
    let items: [FileItem]
    let destinationPath: String?
    let createdAt: Date
    /// Non-nil for archive operations (pack, unpack, archiveDelete, archiveRename)
    var archiveParams: ArchiveOperationParams?
    /// Non-nil for remote transfer operations (remoteDownload, remoteUpload, remoteDelete)
    var remoteParams: RemoteTransferParams?
    /// Non-nil for a multiRename operation.
    var renameParams: MultiRenameParams?

    /// A transfer that stopped short and can be picked up rather than started over: the
    /// half-finished `.part` twin — on disk for a download, on the server for an upload — is
    /// what makes continuing possible, and only remote transfers leave one behind.
    ///
    /// Cancelled counts as well as failed: stopping a transfer on purpose and coming back to
    /// it later is the ordinary way to use a slow line, and the bytes are still there.
    var canBeResumed: Bool {
        (status == .failed || status == .cancelled)
            && (kind == .remoteDownload || kind == .remoteUpload)
    }

    /// What is going wrong right now — "связь оборвана, повтор через 3 с". Lives only while
    /// the operation is waiting instead of working; the next progress report clears it.
    var trouble: String?

    var status: OperationStatus = .queued
    /// Set when the server refused an extra connection: the op goes back to the queue and is
    /// then only started when no other remote op is running (graceful fallback to serial).
    var forceSerial: Bool = false
    var progress: Double = 0
    var currentFile: String = ""
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var filesDone: Int = 0
    var filesTotal: Int = 0
    var error: String?
    var startedAt: Date?
    var completedAt: Date?

    var isActive: Bool {
        status == .queued || status == .running || status == .paused
    }

    var isFinished: Bool {
        status == .completed || status == .failed || status == .cancelled
    }

    var displayTitle: String {
        let count = items.count
        switch kind {
        case .copy:
            return count == 1
                ? L("queue.copySingle", items[0].name)
                : L("queue.copyMultiple", count)
        case .move:
            return count == 1
                ? L("queue.moveSingle", items[0].name)
                : L("queue.moveMultiple", count)
        case .delete:
            return count == 1
                ? L("queue.deleteSingle", items[0].name)
                : L("queue.deleteMultiple", count)
        case .pack:
            let archiveName = archiveParams.map {
                URL(fileURLWithPath: $0.archivePath).lastPathComponent
            } ?? "archive"
            return L("queue.packSingle", archiveName)
        case .unpack:
            return count == 1
                ? L("queue.unpackSingle", items[0].name)
                : L("queue.unpackMultiple", count)
        case .archiveDelete:
            return count == 1
                ? L("queue.archiveDeleteSingle", items[0].name)
                : L("queue.archiveDeleteMultiple", count)
        case .archiveExtract:
            let entries = archiveParams?.entryPaths.count ?? count
            return entries == 1
                ? L("queue.extractSingle", (archiveParams?.entryPaths.first as NSString?)?
                    .lastPathComponent ?? items.first?.name ?? "")
                : L("queue.extractMultiple", entries)
        case .archiveRename:
            return L("queue.archiveRename", items.first?.name ?? "")
        case .remoteDownload:
            return count == 1
                ? L("queue.downloadSingle", items[0].name)
                : L("queue.downloadMultiple", count)
        case .remoteUpload:
            return count == 1
                ? L("queue.uploadSingle", items[0].name)
                : L("queue.uploadMultiple", count)
        case .remoteDelete:
            return count == 1
                ? L("queue.remoteDeleteSingle", items[0].name)
                : L("queue.remoteDeleteMultiple", count)
        case .multiRename:
            return count == 1
                ? L("queue.multiRenameSingle", items[0].name)
                : L("queue.multiRenameMultiple", count)
        }
    }

    var elapsedTime: TimeInterval {
        guard let started = startedAt else { return 0 }
        let end = completedAt ?? Date()
        return end.timeIntervalSince(started)
    }

    /// Estimated time LEFT, extrapolated linearly from elapsed time and progress.
    /// Returns nil while preparing (progress ~0), when paused, or when finished — the
    /// UI then falls back to showing elapsed time.
    var remainingTime: TimeInterval? {
        guard status == .running, progress > 0.02 else { return nil }
        let elapsed = elapsedTime
        guard elapsed > 0.5 else { return nil }
        let remaining = elapsed / progress - elapsed
        return remaining.isFinite && remaining > 0 ? remaining : nil
    }
}
