import AppKit
import Darwin
import FCXLBridgeObjC
import Foundation
import OSLog

/// TEMPORARY copy/conflict probe — file log (NSLog is invisible under `open`).
///
/// Serialised: this is called from several threads at once and the previous
/// unlocked seek-then-write raced, silently dropping lines. A diagnostic log
/// that loses entries is worse than none — it invents phantom bugs.
private let cplogLock = NSLock()

func cplog(_ m: String) {
    let line = "\(Date().timeIntervalSince1970) [t\(pthread_mach_thread_np(pthread_self()))] \(m)\n"
    // The per-user $TMPDIR (mode 0700), not the world-shared /tmp: a fixed name there let any
    // local user read the paths of every transfer — and pre-plant a symlink with that name to
    // make the app append into an arbitrary file the victim can write.
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("fcxl_copy.log").path
    cplogLock.lock()
    defer { cplogLock.unlock() }
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    guard let h = FileHandle(forWritingAtPath: path), let d = line.data(using: .utf8) else { return }
    h.seekToEndOfFile(); h.write(d); try? h.close()
}

enum ConflictResolution {
    case replace
    case copy
    case skip
    case cancel
}

enum ArchiveFormat: String, CaseIterable, Identifiable {
    case zip = "ZIP"
    case tar = "TAR"
    case tarGz = "GZIP"
    case sevenZip = "7Z"
    case tarBz2 = "BZIP2"
    case tarXz = "XZ"
    case tarZst = "ZSTD"
    case tarLz = "LZIP"
    case tarLz4 = "LZ4"
    case iso = "ISO"
    case dmg = "DMG"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .zip:      return ".zip"
        case .tar:      return ".tar"
        case .tarGz:    return ".tar.gz"
        case .sevenZip: return ".7z"
        case .tarBz2:   return ".tar.bz2"
        case .tarXz:    return ".tar.xz"
        case .tarZst:   return ".tar.zst"
        case .tarLz:    return ".tar.lz"
        case .tarLz4:   return ".tar.lz4"
        case .iso:      return ".iso"
        case .dmg:      return ".dmg"
        }
    }

    /// What the picker and the "Archive here" submenu print. The rawValue is the codec's own
    /// name, Keka-style; the tar family carries its real extension so nobody is surprised by
    /// the double suffix on disk.
    var displayName: String {
        switch self {
        case .zip, .tar, .sevenZip, .iso: return rawValue
        default: return "\(rawValue) (\(fileExtension.dropFirst()))"
        }
    }

    /// Containers with no compressor: the level slider means nothing for them.
    /// DMG keeps the slider — its zlib stream takes the same 1–9.
    var supportsCompressionLevel: Bool {
        switch self {
        case .tar, .iso: return false
        default: return true
        }
    }

    /// The same defaults the C++ core would pick on its own — one source of truth for the
    /// dialog's initial slider position and the "Archive here" path that shows no dialog.
    var defaultCompressionLevel: Int {
        switch self {
        case .tar, .iso:  return 0
        case .sevenZip:   return 5
        case .tarBz2:     return 9   // bzip2 levels are block sizes; 9 is its tool's default
        case .tarZst:     return 3   // zstd's design point: gzip-class ratio, several × faster
        case .tarLz4:     return 1   // lz4 is about speed — high levels defeat choosing it
        default:          return 6
        }
    }

    /// True for the one format that never goes through the C++ bridge: DMG is built by hdiutil,
    /// macOS's own tool — libarchive neither reads nor writes it.
    var isBuiltByHdiutil: Bool { self == .dmg }

    /// nil for DMG: it has no bridge representation, and both pack paths branch to hdiutil
    /// before ever asking for one.
    fileprivate var bridgeFormat: ArchiveCreationFormat? {
        switch self {
        case .zip:      return .zip
        case .tar:      return .tar
        case .tarGz:    return .tarGz
        case .sevenZip: return .sevenZip
        case .tarBz2:   return .tarBz2
        case .tarXz:    return .tarXz
        case .tarZst:   return .tarZst
        case .tarLz:    return .tarLz
        case .tarLz4:   return .tarLz4
        case .iso:      return .iso
        case .dmg:      return nil
        }
    }
}

/// Thread-safe wrapper ensuring a CheckedContinuation is resumed exactly once.
/// Used when multiple code paths (background completion, send-to-queue, cancel)
/// may attempt to resume the same continuation.
private final class ContinuationResumeOnce<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(throwing: error)
    }
}

final class FileOperationsService {

    /// File an operation with the undo journal — SYNCHRONOUSLY when already on the main
    /// thread. An async hop looked harmless and was not: the caller's very next line could ask
    /// "can undo?" before the hop landed, and the answer was wrong. Off the main thread the hop
    /// stays; those call sites make the landing awaitable themselves.
    nonisolated static func journal(_ record: UndoJournal.Record) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { UndoJournal.shared.record(record) }
        } else {
            Task { @MainActor in UndoJournal.shared.record(record) }
        }
    }

    private static let opsLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.fcxl.filecommander",
        category: "FileOperations"
    )
    private let bridgeService: CoreBridgeService
    var viewerOpenHandler: ((FileItem) -> Void)?
    private var archivePreviewTemporaryDirectories: [String] = []
    /// The single temp dir for the CURRENT F3/Space preview — kept to exactly one so arrowing
    /// through an archive never accumulates copies. Replaced on each preview, removed on leave.
    private var currentPreviewTempDirectory: String?
    private let archivePreviewDirectoriesLock = NSLock()

    struct ItemProperties {
        let name: String
        let path: String
        let isDirectory: Bool
        let isSymlink: Bool
        let symlinkTarget: String?
        let itemSizeBytes: Int64
        let totalSizeBytes: Int64
        let filesCount: Int
        let directoriesCount: Int
        let createdDate: Date?
        let modifiedDate: Date?
        let permissions: String
        /// The raw low-9 permission bits (what the properties grid edits). `permissions` above
        /// is the same value formatted for the read-only info line.
        var posixMode: Int = 0
        /// Whether the item carries the macOS hidden flag (UF_HIDDEN) — the "Hidden" checkbox.
        var isHidden: Bool = false
    }

    private struct PathStats {
        let bytes: Int64
        let fileCount: Int
    }

    struct DirectoryStats {
        var totalBytes: Int64 = 0
        var filesCount: Int = 0
        var directoriesCount: Int = 0
    }

    private enum ArchiveMutationMode {
        case zipFastPath
        case rebuild
    }

    init(bridgeService: CoreBridgeService) {
        self.bridgeService = bridgeService
    }

    @MainActor
    func operationTargets(from viewModel: PanelViewModel) -> [FileItem] {
        viewModel.operationTargets
    }

    func properties(for item: FileItem) throws -> ItemProperties {
        try properties(path: item.path, fallbackName: item.name)
    }

    /// - Parameter measuringContents: summing a folder's contents means walking the whole subtree,
    ///   which takes seconds on a big one. Pass `false` to get everything else immediately and
    ///   measure separately, so a window does not have to wait on it.
    func properties(path: String, fallbackName: String? = nil,
                    measuringContents: Bool = true) throws -> ItemProperties {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileNoSuchFileError,
                userInfo: [NSLocalizedDescriptionKey: L("error.fileOrFolderNotFound")]
            )
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let fileType = attributes[.type] as? FileAttributeType
        let isSymlink = fileType == .typeSymbolicLink
        var linkTarget: String?
        if isSymlink {
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                if dest.hasPrefix("/") {
                    linkTarget = dest
                } else {
                    linkTarget = URL(fileURLWithPath: dest,
                                     relativeTo: URL(fileURLWithPath: path).deletingLastPathComponent())
                        .standardized.path
                }
            }
        }
        let itemSizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let createdDate = attributes[.creationDate] as? Date
        let modifiedDate = attributes[.modificationDate] as? Date
        let permissionsMask = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let posixMode = permissionsMask & 0o777
        let permissions = String(format: "%03o", posixMode)
        let isHidden = (try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.isHiddenKey]).isHidden) ?? false

        let resolvedName: String
        if let fallbackName, !fallbackName.isEmpty {
            resolvedName = fallbackName
        } else {
            let lastComponent = URL(fileURLWithPath: path).lastPathComponent
            resolvedName = lastComponent.isEmpty ? path : lastComponent
        }

        if !isDirectory.boolValue {
            return ItemProperties(
                name: resolvedName,
                path: path,
                isDirectory: false,
                isSymlink: isSymlink,
                symlinkTarget: linkTarget,
                itemSizeBytes: itemSizeBytes,
                totalSizeBytes: itemSizeBytes,
                filesCount: 1,
                directoriesCount: 0,
                createdDate: createdDate,
                modifiedDate: modifiedDate,
                permissions: permissions,
                posixMode: posixMode,
                isHidden: isHidden
            )
        }

        let stats = measuringContents ? Self.directoryStats(path: path) : DirectoryStats()
        return ItemProperties(
            name: resolvedName,
            path: path,
            isDirectory: true,
            isSymlink: isSymlink,
            symlinkTarget: linkTarget,
            itemSizeBytes: itemSizeBytes,
            totalSizeBytes: stats.totalBytes,
            filesCount: stats.filesCount,
            directoriesCount: stats.directoriesCount,
            createdDate: createdDate,
            modifiedDate: modifiedDate,
            permissions: permissions,
            posixMode: posixMode,
            isHidden: isHidden
        )
    }

    // MARK: - Editing attributes (properties window)

    /// Apply a new permission mode. When `recursive` is true and the path is a folder, the same
    /// mode is applied to every enclosed item (best-effort: items that reject the change — e.g.
    /// ones owned by another user — are collected and reported, the rest still get updated).
    /// Returns the number of items that could NOT be changed.
    @discardableResult
    func setPermissions(mode: Int, atPath path: String, recursive: Bool) throws -> Int {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path)

        var isDir: ObjCBool = false
        guard recursive, fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return 0 }

        var failures = 0
        if let enumerator = fm.enumerator(atPath: path) {
            for case let rel as String in enumerator {
                let full = (path as NSString).appendingPathComponent(rel)
                // Don't chmod through symlinks — that would hit the target, not the link.
                if let type = try? fm.attributesOfItem(atPath: full)[.type] as? FileAttributeType,
                   type == .typeSymbolicLink { continue }
                do {
                    try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: full)
                } catch {
                    failures += 1
                }
            }
        }
        return failures
    }

    /// One batch of attribute edits, as the change-attributes dialog hands it over. A nil
    /// field means "leave that alone" — the dialog's switches map here one to one.
    struct AttributeChanges {
        var permissionsMode: Int?
        var modificationDate: Date?
        var creationDate: Date?
        /// nil = leave alone; true = hide, false = show (the Finder's UF_HIDDEN flag).
        var hidden: Bool?
        /// The com.apple.quarantine mark — the "downloaded from the internet" note that makes
        /// macOS ask "are you sure?". nil = leave alone; false = strip it (no more prompts);
        /// true = put it back (the prompt returns). A state, exactly like `hidden`.
        var quarantine: Bool?
        var recursive = false

        var isEmpty: Bool {
            permissionsMode == nil && modificationDate == nil && creationDate == nil
                && hidden == nil && quarantine == nil
        }
    }

    /// TC's Files ▸ Change Attributes: the same edits over the WHOLE selection, folders
    /// walked when asked. Best-effort — an item that refuses (owned by someone else, say)
    /// is collected and reported, the rest still get changed.
    ///
    /// Symlinks are skipped entirely: both chmod and date-setting go through the link and
    /// would hit the target, which the person never pointed at.
    nonisolated func changeAttributes(_ changes: AttributeChanges, items: [FileItem],
                                      progress: ((Int, Int, String) -> Void)? = nil,
                                      shouldCancel: (() -> Bool)? = nil)
        -> [(name: String, reason: String)] {
        var attributes: [FileAttributeKey: Any] = [:]
        if let mode = changes.permissionsMode { attributes[.posixPermissions] = NSNumber(value: mode) }
        if let date = changes.modificationDate { attributes[.modificationDate] = date }
        if let date = changes.creationDate { attributes[.creationDate] = date }
        guard !changes.isEmpty else { return [] }

        let fm = FileManager.default
        var failures: [(name: String, reason: String)] = []
        var done = 0
        let total = items.count

        func isSymlink(_ path: String) -> Bool {
            (try? fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
        }
        func apply(to path: String, name: String) {
            do {
                if !attributes.isEmpty {
                    try fm.setAttributes(attributes, ofItemAtPath: path)
                }
                if let hidden = changes.hidden {
                    var url = URL(fileURLWithPath: path)
                    var values = URLResourceValues()
                    values.isHidden = hidden
                    try url.setResourceValues(values)
                }
                if let quarantine = changes.quarantine {
                    if quarantine {
                        // Put the mark back — the prompt returns. A file that already has
                        // one keeps ITS mark: the original "who downloaded this" note is
                        // worth more than ours.
                        if getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) < 0 {
                            let mark = "0083;00000000;TotumCommander;"
                            if setxattr(path, "com.apple.quarantine", mark, mark.utf8.count,
                                        0, XATTR_NOFOLLOW) != 0 {
                                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                                              userInfo: [NSLocalizedDescriptionKey:
                                                            String(cString: strerror(errno))])
                            }
                        }
                    } else {
                        // A file that never had the mark is not a failure — the wish was
                        // "no quarantine", and that wish is already true.
                        if removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0,
                           errno != ENOATTR {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                                          userInfo: [NSLocalizedDescriptionKey:
                                                        String(cString: strerror(errno))])
                        }
                    }
                }
            } catch { failures.append((name, error.localizedDescription)) }
        }

        for item in items {
            if shouldCancel?() == true { break }
            done += 1
            progress?(done, total, item.name)
            guard !isSymlink(item.path) else { continue }
            apply(to: item.path, name: item.name)

            var isDir: ObjCBool = false
            guard changes.recursive, fm.fileExists(atPath: item.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            if let enumerator = fm.enumerator(atPath: item.path) {
                for case let rel as String in enumerator {
                    if shouldCancel?() == true { return failures }
                    let full = (item.path as NSString).appendingPathComponent(rel)
                    guard !isSymlink(full) else { continue }
                    apply(to: full, name: (rel as NSString).lastPathComponent)
                }
            }
        }
        return failures
    }


    func directoryTotalSize(at path: String, timeBudget: TimeInterval = 0) -> UInt64 {
        let stats = calculatePathStats(path: path, timeBudget: timeBudget)
        return UInt64(max(0, stats.bytes))
    }

    @MainActor
    func copyItems(_ items: [FileItem],
                   to destinationPath: String,
                   queueService: OperationQueueService? = nil,
                   reporter: OperationProgressReporter? = nil,
                   onCompletion: (() -> Void)? = nil,
                   onDialogsDone: (() -> Void)? = nil,
                   onProgress: ((Double, String) -> Void)? = nil,
                   shouldCancel: (() -> Bool)? = nil) async throws {
        try validateNotCopyingIntoSelf(items: items, destinationPath: destinationPath)
        let ntfsInfo = try preflightCheck(items: items, destinationPath: destinationPath, requireWriteAccess: false)
        let conflictLock = NSLock()
        var applyToAllResolution: ConflictResolution?
        try await transferItems(
            title: L("progress.copying"),
            items,
            to: destinationPath,
            move: false,
            queueService: queueService,
            externalReporter: reporter,
            onCompletion: onCompletion,
            onDialogsDone: onDialogsDone,
            ntfsInfo: ntfsInfo,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        ) { sourcePath, destination in
            // May be called from the main thread (top-level conflicts) OR a background
            // thread (folder-merge expansion). A remembered "apply to all" answer returns
            // instantly without touching the UI; a fresh conflict must show its modal
            // dialog on the main thread, so hop there when called from the background.
            conflictLock.lock()
            if let remembered = applyToAllResolution {
                conflictLock.unlock()
                return remembered
            }
            conflictLock.unlock()
            // Runloop-callout hop (not DispatchQueue.main.sync): keeps the main queue
            // free so the conflict dialog's open animation can run (FCXLDialogKit).
            let decision = DialogService.blockingDialogOnMain {
                DialogService.shared.showFileConflict(sourcePath: sourcePath, destinationPath: destination)
            }
            if decision.applyToAll {
                conflictLock.lock()
                applyToAllResolution = decision.resolution
                conflictLock.unlock()
            }
            return decision.resolution
        }
    }

    @MainActor
    func moveItems(_ items: [FileItem],
                   to destinationPath: String,
                   queueService: OperationQueueService? = nil,
                   reporter: OperationProgressReporter? = nil,
                   onCompletion: (() -> Void)? = nil,
                   onDialogsDone: (() -> Void)? = nil,
                   onConflict: ((String) -> ConflictResolution)? = nil,
                   onProgress: ((Double, String) -> Void)? = nil,
                   shouldCancel: (() -> Bool)? = nil) async throws {
        try validateNotCopyingIntoSelf(items: items, destinationPath: destinationPath)
        let ntfsInfo = try preflightCheck(items: items, destinationPath: destinationPath, requireWriteAccess: true)
        let conflictLock = NSLock()
        var applyToAllResolution: ConflictResolution?
        try await transferItems(
            title: L("progress.moving"),
            items,
            to: destinationPath,
            move: true,
            queueService: queueService,
            externalReporter: reporter,
            onCompletion: onCompletion,
            onDialogsDone: onDialogsDone,
            ntfsInfo: ntfsInfo,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        ) { sourcePath, destination in
            // May run on a background thread (folder-merge expansion) — see copyItems.
            conflictLock.lock()
            if let remembered = applyToAllResolution {
                conflictLock.unlock()
                return remembered
            }
            conflictLock.unlock()
            if let onConflict {
                return DialogService.blockingDialogOnMain { onConflict(destination) }
            }
            // Runloop-callout hop (not DispatchQueue.main.sync): keeps the main queue
            // free so the conflict dialog's open animation can run (FCXLDialogKit).
            let decision = DialogService.blockingDialogOnMain {
                DialogService.shared.showFileConflict(sourcePath: sourcePath, destinationPath: destination)
            }
            if decision.applyToAll {
                conflictLock.lock()
                applyToAllResolution = decision.resolution
                conflictLock.unlock()
            }
            return decision.resolution
        }
    }

    /// Run an archive operation, asking for the password when the archive turns out to want
    /// one, and running the operation again with the answer. The password that worked is
    /// remembered for the session — the bridge wrapper reads it by itself, so the retry needs
    /// no plumbing — and one that failed is forgotten rather than offered again.
    @MainActor
    func askingArchivePassword<T>(archivePath: String, _ body: () throws -> T) throws -> T {
        while true {
            do {
                return try body()
            } catch where ArchivePasswords.isPasswordFailure(error) {
                ArchivePasswords.forget(for: archivePath)
                guard let entered = ArchivePasswords.ask(
                    archiveName: (archivePath as NSString).lastPathComponent) else {
                    throw userCancelledError()
                }
                ArchivePasswords.remember(entered, for: archivePath)
            }
        }
    }

    @MainActor
    /// Extracts archive entries to a local folder. Returns the items that were
    /// ACTUALLY extracted — entries the user chose to Skip on conflict are not
    /// included. Callers that "move" out of an archive MUST delete only the
    /// returned subset, never the original request (else a skipped entry is
    /// deleted from the archive without ever being written to disk → data loss).
    ///
    /// A protected archive asks for its password and the copy runs again — the same
    /// conversation the full unpack has, because "copy out of" IS an unpack of a few.
    @discardableResult
    func copyItemsFromArchive(_ items: [FileItem],
                              archivePath: String,
                              to destinationPath: String,
                              onProgress: ((Double, String) -> Void)? = nil,
                              shouldCancel: (() -> Bool)? = nil) throws -> [FileItem] {
        try askingArchivePassword(archivePath: archivePath) {
            try copyItemsFromArchiveOnce(items, archivePath: archivePath, to: destinationPath,
                                         onProgress: onProgress, shouldCancel: shouldCancel)
        }
    }

    @MainActor
    @discardableResult
    private func copyItemsFromArchiveOnce(_ items: [FileItem],
                              archivePath: String,
                              to destinationPath: String,
                              onProgress: ((Double, String) -> Void)? = nil,
                              shouldCancel: (() -> Bool)? = nil) throws -> [FileItem] {
        // Sources are inside an archive (not regular files); only check destination.
        _ = try preflightCheck(items: [], destinationPath: destinationPath, requireWriteAccess: false)
        var extractedItems: [FileItem] = []
        // A folder's own size is nothing; what comes out is everything beneath it.
        var planned: [String: Int64] = [:]
        if items.contains(where: \.isDirectory),
           let listed = try? bridgeService.listArchiveEntries(archivePath: archivePath) {
            planned = Self.plannedArchiveBytes(
                for: items.map(\.path),
                files: listed.filter { !$0.isDirectory }
                    .map { (path: $0.path, size: Int64($0.uncompressedSize)) })
        }
        let weight: (FileItem) -> Int64 = { max(Int64($0.size), planned[$0.path] ?? 0) }
        let totalBytes = max(items.reduce(Int64(0)) { $0 + weight($1) }, 1)
        let totalFiles = max(items.count, 1)
        let progressController = DialogService.shared.showProgress(
            title: L("progress.copying"),
            message: L("progress.preparing"),
            cancelHandler: { [bridgeService] in
                bridgeService.cancelArchiveOperations()
            }
        )
        defer { progressController.close() }

        var applyToAllResolution: ConflictResolution?
        var bytesDone: Int64 = 0
        var filesDone = 0

        for item in items {
            if shouldCancel?() == true || progressController.isCancelled {
                throw userCancelledError()
            }

            var destination = (destinationPath as NSString).appendingPathComponent(item.name)
            if FileManager.default.fileExists(atPath: destination) {
                let decision: (resolution: ConflictResolution, applyToAll: Bool)
                if let applyToAllResolution {
                    decision = (applyToAllResolution, true)
                } else {
                    decision = DialogService.shared.showFileConflict(
                        sourcePath: "\(archivePath)::/\(item.path)",
                        destinationPath: destination
                    )
                    if decision.applyToAll {
                        applyToAllResolution = decision.resolution
                    }
                }

                switch decision.resolution {
                case .replace:
                    try FileManager.default.removeItem(atPath: destination)
                case .copy:
                    destination = uniqueCopyPath(from: destination)
                case .skip:
                    filesDone += 1
                    let filesProgress = Double(filesDone) / Double(totalFiles)
                    progressController.update(
                        currentFile: L("progress.skipped", item.name),
                        progress: filesProgress,
                        bytesDone: bytesDone,
                        bytesTotal: totalBytes,
                        filesDone: filesDone,
                        filesTotal: totalFiles
                    )
                    onProgress?(filesProgress, L("progress.skipped", item.name))
                    continue
                case .cancel:
                    throw userCancelledError()
                }
            }

            let temporaryBase = (NSTemporaryDirectory() as NSString).appendingPathComponent("fcxl_temp")
            let temporaryRoot = (temporaryBase as NSString).appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(atPath: temporaryRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

            let plannedBytes = max(weight(item), 1)
            try runBlockingOperation(progressController: progressController) {
                try self.bridgeService.extractArchiveEntry(
                    archivePath: archivePath,
                    entryPath: item.path,
                    destinationPath: temporaryRoot
                )
            } onPulse: { pulse in
                if progressController.isCancelled {
                    self.bridgeService.cancelArchiveOperations()
                    return
                }
                let inFlightBytes = bytesDone + Int64(Double(plannedBytes) * pulse * 0.5)
                let inFlightFiles = Double(filesDone) + (pulse * 0.5)
                let bytesProgress = Double(inFlightBytes) / Double(max(totalBytes, 1))
                let filesProgress = inFlightFiles / Double(totalFiles)
                progressController.update(
                    currentFile: item.name,
                    progress: max(bytesProgress, filesProgress),
                    bytesDone: inFlightBytes,
                    bytesTotal: totalBytes,
                    filesDone: Int(inFlightFiles.rounded(.down)),
                    filesTotal: totalFiles
                )
            }

            if shouldCancel?() == true || progressController.isCancelled {
                bridgeService.cancelArchiveOperations()
                throw userCancelledError()
            }

            let extractedPath = (temporaryRoot as NSString).appendingPathComponent(item.path)
            try runBlockingOperation(progressController: progressController) {
                try self.bridgeService.copyItem(from: extractedPath, to: destination)
            } onPulse: { pulse in
                if shouldCancel?() == true || progressController.isCancelled {
                    return
                }
                let inFlightBytes = bytesDone + Int64(Double(plannedBytes) * (0.5 + pulse * 0.5))
                let inFlightFiles = Double(filesDone) + (0.5 + pulse * 0.5)
                let bytesProgress = Double(inFlightBytes) / Double(max(totalBytes, 1))
                let filesProgress = inFlightFiles / Double(totalFiles)
                progressController.update(
                    currentFile: item.name,
                    progress: max(bytesProgress, filesProgress),
                    bytesDone: inFlightBytes,
                    bytesTotal: totalBytes,
                    filesDone: Int(inFlightFiles.rounded(.down)),
                    filesTotal: totalFiles
                )
            }

            if shouldCancel?() == true || progressController.isCancelled {
                throw userCancelledError()
            }

            filesDone += 1
            bytesDone += max(Int64(item.size), fileSize(atPath: extractedPath))
            let bytesProgress = Double(bytesDone) / Double(max(totalBytes, 1))
            let filesProgress = Double(filesDone) / Double(totalFiles)
            let progress = max(bytesProgress, filesProgress)
            progressController.update(
                currentFile: item.name,
                progress: progress,
                bytesDone: bytesDone,
                bytesTotal: totalBytes,
                filesDone: filesDone,
                filesTotal: totalFiles
            )
            onProgress?(progress, L("progress.copied", item.name))
            extractedItems.append(item)
        }

        progressController.update(
            currentFile: L("progress.done"),
            progress: 1.0,
            bytesDone: totalBytes,
            bytesTotal: totalBytes,
            filesDone: totalFiles,
            filesTotal: totalFiles
        )
        return extractedItems
    }

    @MainActor
    /// In-place archive edits (add/delete/rename entries) rewrite the archive
    /// file. That can't be done while the archive sits on a read-only NTFS mount,
    /// so we surface a clear message instead of a raw "failed to open output"
    /// error. (Creating a NEW archive on NTFS is supported — it stages via a temp
    /// file; editing an existing one in place is not, yet.)
    private func ensureArchiveIsEditable(_ archivePath: String) throws {
        guard isReadOnlyNTFSDestination(archivePath) else { return }
        throw NSError(
            domain: "FileOperationsService",
            code: -200,
            userInfo: [NSLocalizedDescriptionKey: L("archive.ntfs.editUnsupported")]
        )
    }

    @MainActor
    func addItemsToArchive(_ items: [FileItem],
                           archivePath: String,
                           destinationRelativePath: String,
                           replaceExistingSilently: Bool = false,
                           queueService: OperationQueueService? = nil,
                           onCompletion: (() -> Void)? = nil) async throws {
        guard !items.isEmpty else { return }
        try ensureArchiveIsEditable(archivePath)

        // `replaceExistingSilently` is the editor write-back path: the user already confirmed
        // "update archive?", so don't ask again about rebuild or per-file replacement.
        if !replaceExistingSilently, archiveMutationMode(for: archivePath) == .rebuild {
            guard await confirmArchiveRebuild(
                operationTitle: L("archive.operation.addFiles"),
                archivePath: archivePath
            ) else {
                throw userCancelledError()
            }
        }

        // The archive may already hold an entry with the same name — the rebuild would just
        // replace it without a word. Ask first, using the same dialog extraction uses, and
        // BEFORE the progress window goes up. In this async context the modal must go through
        // fcxlPresentModalAsync, or its buttons never receive input (parked main queue).
        let basePathForCheck = normalizeArchiveEntryPath(destinationRelativePath)
        let existingEntries = Set(
            ((try? bridgeService.listArchiveEntries(archivePath: archivePath)) ?? [])
                .map { normalizeArchiveEntryPath($0.path) }
        )
        var itemsToAdd: [FileItem] = []
        var blanketChoice: ConflictDialogChoice?
        for item in items {
            let entryName = basePathForCheck.isEmpty
                ? item.name
                : (basePathForCheck as NSString).appendingPathComponent(item.name)
            guard existingEntries.contains(normalizeArchiveEntryPath(entryName)) else {
                itemsToAdd.append(item)
                continue
            }
            if replaceExistingSilently {
                itemsToAdd.append(item)   // caller already confirmed the replacement
                continue
            }
            let choice: ConflictDialogChoice
            if let blanket = blanketChoice {
                choice = blanket
            } else {
                let itemName = item.name
                guard let answer = await fcxlPresentModalAsync({
                    DialogService.shared.showArchiveConflictDialog(fileName: itemName)
                }) else {
                    throw userCancelledError()
                }
                choice = answer
                if answer == .replaceAll || answer == .skipAll { blanketChoice = answer }
            }
            switch choice {
            case .replace, .replaceAll: itemsToAdd.append(item)
            case .skip, .skipAll, .createCopy: break   // dropped from the list below
            }
        }
        guard !itemsToAdd.isEmpty else { return }

        let progressController = DialogService.shared.showProgress(
            title: L("archive.progress.adding"),
            message: L("progress.preparing"),
            cancelHandler: { [bridgeService] in
                bridgeService.cancelArchiveOperations()
            }
        )
        let swappable = SwappableProgressReporter(progressController)

        progressController.update(
            currentFile: L("progress.preparing"),
            progress: 0.01,
            bytesDone: 0,
            bytesTotal: 1,
            filesDone: 0,
            filesTotal: max(items.count, 1)
        )

        let sourcePaths = itemsToAdd.map(\.path)   // conflicts already resolved above
        let normalizedBasePath = normalizeArchiveEntryPath(destinationRelativePath)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeOnce = ContinuationResumeOnce(continuation)

            if let queueService {
                progressController.onSendToQueue = {
                    let params = ArchiveOperationParams(archivePath: archivePath)
                    let (_, queueReporter) = queueService.adoptRunningOperation(
                        kind: .pack,
                        items: items,
                        destination: nil,
                        archiveParams: params,
                        currentProgress: progressController.lastProgressValue,
                        currentFile: "",
                        bytesDone: progressController.lastBytesDoneValue,
                        bytesTotal: progressController.lastBytesTotalValue,
                        filesDone: progressController.lastFilesDoneValue,
                        filesTotal: progressController.lastFilesTotalValue,
                        onCompletion: onCompletion
                    )
                    swappable.swap(to: queueReporter)
                    resumeOnce.resume(returning: ())
                    return true
                }
                progressController.showSendToQueueButton()
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.bridgeService.addFilesToArchive(
                        archivePath: archivePath,
                        filePaths: sourcePaths,
                        basePath: normalizedBasePath,
                        progress: self.makeArchiveProgressHandler(progressController: swappable)
                    )

                    DispatchQueue.main.async {
                        if progressController.isSentToQueue {
                            if let id = queueService?.operations.first(where: {
                                $0.kind == .pack && $0.status == .running
                            })?.id {
                                queueService?.markOperationCompleted(id)
                            }
                            // onCompletion is called by fireCompletion inside markOperationCompleted
                        } else {
                            progressController.close()
                            onCompletion?()
                        }
                        resumeOnce.resume(returning: ())
                    }
                } catch {
                    DispatchQueue.main.async {
                        if progressController.isSentToQueue {
                            if let id = queueService?.operations.first(where: {
                                $0.kind == .pack && $0.status == .running
                            })?.id {
                                queueService?.markOperationCompleted(id, error: error)
                            }
                        } else {
                            progressController.close()
                        }
                        resumeOnce.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Total Commander-style write-back: put a temp file that was extracted for F4-editing
    /// back into its archive, replacing the existing entry without extra prompts (the editor
    /// already asked "update archive?"). Reuses addItemsToArchive so the rebuild/progress
    /// path stays shared and single-sourced.
    @MainActor
    func updateArchiveEntry(editedFilePath: String, archivePath: String, entryPath: String) async throws {
        guard let item = FileItem.fromPath(editedFilePath) else {
            throw NSError(
                domain: "FileOperationsService",
                code: NSFileNoSuchFileError,
                userInfo: [NSLocalizedDescriptionKey: L("error.archivePrepareEdit")]
            )
        }
        let normalizedEntry = normalizeArchiveEntryPath(entryPath)
        let destinationRelativePath = (normalizedEntry as NSString).deletingLastPathComponent
        try await addItemsToArchive(
            [item],
            archivePath: archivePath,
            destinationRelativePath: destinationRelativePath,
            replaceExistingSilently: true
        )
    }

    @MainActor
    func deleteEntriesFromArchive(_ items: [FileItem], archivePath: String,
                                    queueService: OperationQueueService? = nil,
                                    onCompletion: (() -> Void)? = nil) async throws {
        guard !items.isEmpty else { return }
        try ensureArchiveIsEditable(archivePath)

        // Runs inside a Task (parked main queue) → enter the FCXLDialog via the async
        // runloop bridge so its buttons work.
        let confirmed = await fcxlPresentModalAsync {
            DialogService.shared.showDeleteConfirmation(items: items)
        }
        guard confirmed else { return }

        if archiveMutationMode(for: archivePath) == .rebuild {
            guard await confirmArchiveRebuild(
                operationTitle: L("archive.operation.deleteFiles"),
                archivePath: archivePath
            ) else {
                throw userCancelledError()
            }
        }

        let progressController = DialogService.shared.showProgress(
            title: L("archive.progress.deleting"),
            message: L("progress.preparing"),
            cancelHandler: { [bridgeService] in
                bridgeService.cancelArchiveOperations()
            }
        )
        let swappable = SwappableProgressReporter(progressController)

        progressController.update(
            currentFile: L("progress.preparing"),
            progress: 0.01,
            bytesDone: 0,
            bytesTotal: 1,
            filesDone: 0,
            filesTotal: max(items.count, 1)
        )

        let entryPaths = items.map { normalizeArchiveEntryPath($0.path) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeOnce = ContinuationResumeOnce(continuation)

            if let queueService {
                progressController.onSendToQueue = {
                    let params = ArchiveOperationParams(archivePath: archivePath)
                    let (_, queueReporter) = queueService.adoptRunningOperation(
                        kind: .archiveDelete,
                        items: items,
                        destination: nil,
                        archiveParams: params,
                        currentProgress: progressController.lastProgressValue,
                        currentFile: "",
                        bytesDone: progressController.lastBytesDoneValue,
                        bytesTotal: progressController.lastBytesTotalValue,
                        filesDone: progressController.lastFilesDoneValue,
                        filesTotal: progressController.lastFilesTotalValue,
                        onCompletion: onCompletion
                    )
                    swappable.swap(to: queueReporter)
                    resumeOnce.resume(returning: ())
                    return true
                }
                progressController.showSendToQueueButton()
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.bridgeService.deleteEntriesFromArchive(
                        archivePath: archivePath,
                        entryPaths: entryPaths,
                        progress: self.makeArchiveProgressHandler(progressController: swappable)
                    )

                    DispatchQueue.main.async {
                        if progressController.isSentToQueue {
                            if let id = queueService?.operations.first(where: {
                                $0.kind == .archiveDelete && $0.status == .running
                            })?.id {
                                queueService?.markOperationCompleted(id)
                            }
                            // onCompletion is called by fireCompletion inside markOperationCompleted
                        } else {
                            progressController.close()
                            onCompletion?()
                        }
                        resumeOnce.resume(returning: ())
                    }
                } catch {
                    DispatchQueue.main.async {
                        if progressController.isSentToQueue {
                            if let id = queueService?.operations.first(where: {
                                $0.kind == .archiveDelete && $0.status == .running
                            })?.id {
                                queueService?.markOperationCompleted(id, error: error)
                            }
                        } else {
                            progressController.close()
                        }
                        resumeOnce.resume(throwing: error)
                    }
                }
            }
        }
    }

    @MainActor
    func renameEntryInArchive(_ item: FileItem,
                              archivePath: String,
                              to newName: String,
                              queueService: OperationQueueService? = nil,
                              onCompletion: (() -> Void)? = nil) async throws {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        guard !trimmedName.contains("/") else {
            throw NSError(
                domain: "FileOperationsService",
                code: NSFileWriteInvalidFileNameError,
                userInfo: [NSLocalizedDescriptionKey: L("rename.slashError")]
            )
        }
        try ensureArchiveIsEditable(archivePath)

        let oldEntryPath = normalizeArchiveEntryPath(item.path)
        let parentPath = (oldEntryPath as NSString).deletingLastPathComponent
        let newEntryPath = parentPath.isEmpty ? trimmedName : "\(parentPath)/\(trimmedName)"
        guard oldEntryPath != newEntryPath else { return }

        let existingEntries = try bridgeService.listArchiveEntries(archivePath: archivePath)
        let normalizedNew = normalizeArchiveEntryPath(newEntryPath)
        if existingEntries.contains(where: { normalizeArchiveEntryPath($0.path) == normalizedNew }) {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: L("rename.exists")]
            )
        }

        if archiveMutationMode(for: archivePath) == .rebuild {
            guard await confirmArchiveRebuild(
                operationTitle: L("archive.operation.renameFile"),
                archivePath: archivePath
            ) else {
                throw userCancelledError()
            }
        }

        let progressController = DialogService.shared.showProgress(
            title: L("archive.progress.renaming"),
            message: L("progress.preparing"),
            cancelHandler: { [bridgeService] in
                bridgeService.cancelArchiveOperations()
            }
        )
        let swappable = SwappableProgressReporter(progressController)

        progressController.update(
            currentFile: item.name,
            progress: 0.01,
            bytesDone: 0,
            bytesTotal: 1,
            filesDone: 0,
            filesTotal: 1
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeOnce = ContinuationResumeOnce(continuation)

            if let queueService {
                progressController.onSendToQueue = {
                    var params = ArchiveOperationParams(archivePath: archivePath)
                    params.newEntryName = trimmedName
                    let (_, queueReporter) = queueService.adoptRunningOperation(
                        kind: .archiveRename,
                        items: [item],
                        destination: nil,
                        archiveParams: params,
                        currentProgress: progressController.lastProgressValue,
                        currentFile: item.name,
                        bytesDone: 0,
                        bytesTotal: 1,
                        filesDone: 0,
                        filesTotal: 1,
                        onCompletion: onCompletion
                    )
                    swappable.swap(to: queueReporter)
                    resumeOnce.resume(returning: ())
                    return true
                }
                progressController.showSendToQueueButton()
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.bridgeService.renameEntryInArchive(
                        archivePath: archivePath,
                        oldEntryPath: oldEntryPath,
                        newEntryPath: newEntryPath,
                        progress: self.makeArchiveProgressHandler(progressController: swappable)
                    )

                    DispatchQueue.main.async {
                        if progressController.isSentToQueue {
                            if let id = queueService?.operations.first(where: {
                                $0.kind == .archiveRename && $0.status == .running
                            })?.id {
                                queueService?.markOperationCompleted(id)
                            }
                        } else {
                            progressController.close()
                        }
                        resumeOnce.resume(returning: ())
                    }
                } catch {
                    DispatchQueue.main.async {
                        if progressController.isSentToQueue {
                            if let id = queueService?.operations.first(where: {
                                $0.kind == .archiveRename && $0.status == .running
                            })?.id {
                                queueService?.markOperationCompleted(id, error: error)
                            }
                        } else {
                            progressController.close()
                        }
                        resumeOnce.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Handles items sitting on a read-only NTFS volume, where macOS offers no Trash: deletion
    /// there is permanent by nature and goes through libntfs-3g. Returns true when the items were
    /// on NTFS and the work (or the user's refusal) already happened.
    @MainActor
    private func deleteViaNTFSIfNeeded(_ items: [FileItem]) async throws -> Bool {
        guard let firstPath = items.first?.path,
              let vol = volumeInfo(for: firstPath),
              vol.fsType.lowercased() == "ntfs" && vol.isReadOnly else { return false }
        let decision = handleNTFSReadOnly(vol)
        switch decision {
        case .cancelled:
            throw userCancelledError()
        case .useLibntfs(let devicePath, let mountPoint):
            let restorePath = (firstPath as NSString).deletingLastPathComponent
            FileOperationsService.ntfsRestorePath = restorePath
            FileOperationsService.ntfsWritingVolumes.insert(mountPoint)

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let bridge = FCXLNTFSBridge()
                        try bridge.openVolume(withDevice: devicePath, mountPoint: mountPoint)
                        defer {
                            try? bridge.closeVolume()
                            DispatchQueue.main.async {
                                FileOperationsService.ntfsWritingVolumes.remove(mountPoint)
                            }
                        }
                        for item in items {
                            let relPath: String
                            if item.path.count > mountPoint.count {
                                relPath = String(item.path[item.path.index(item.path.startIndex, offsetBy: mountPoint.count)...])
                            } else {
                                continue
                            }
                            try bridge.remove(atPath: relPath)
                        }
                        continuation.resume()
                    } catch {
                        DispatchQueue.main.async {
                            FileOperationsService.ntfsWritingVolumes.remove(mountPoint)
                        }
                        continuation.resume(throwing: error)
                    }
                }
            }
            return true
        }
    }

    /// Shift+Del: delete bypassing the Trash. The caller has already shown the always-on red
    /// confirmation — this only does the work.
    ///
    /// Cancellation stops BETWEEN items and is not an error: what was already removed stays
    /// removed (there is nowhere to bring it back from), the rest is untouched, and the panel
    /// refresh shows exactly that state.
    @MainActor
    func deleteItemsPermanently(_ items: [FileItem]) async throws {
        guard !items.isEmpty else { return }
        if try await deleteViaNTFSIfNeeded(items) { return }

        _ = try preflightCheck(items: items, destinationPath: nil, requireWriteAccess: true)

        let startedAt = Date()
        Self.opsLog.info("erase.start items=\(items.count, privacy: .public)")

        // The dialog appears only if the work outlives half a second — same manners as trash.
        var progressController: ProgressController?
        var cancelled = false
        let showTask = Task { @MainActor in
            try await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let pc = DialogService.shared.showProgress(
                title: L("progress.deleting"),
                message: L("progress.preparing"),
                cancelHandler: { cancelled = true }
            )
            progressController = pc
        }
        defer {
            showTask.cancel()
            progressController?.close()
        }

        let total = items.count
        for (index, item) in items.enumerated() {
            if cancelled || progressController?.isCancelled == true {
                Self.opsLog.info("erase.cancelled done=\(index, privacy: .public) of=\(total, privacy: .public)")
                return
            }
            progressController?.update(
                currentFile: item.name,
                progress: Double(index) / Double(total),
                bytesDone: 0, bytesTotal: 0,
                filesDone: index, filesTotal: total)
            do {
                // Off the main thread: a big folder tree takes a while to unlink, and the
                // Cancel button must stay alive while it happens.
                let path = item.path
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try FileManager.default.removeItem(atPath: path)
                            cont.resume()
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
            } catch {
                let nsError = error as NSError
                Self.opsLog.error("erase.fail item=\(item.name, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
                throw error
            }
        }
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
        Self.opsLog.info("erase.done items=\(total, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)")
    }

    // MARK: - Trash view

    /// Вернуть из корзины на прежние места — с прогрессом и отменой, как всякое перемещение.
    /// Запись возврата у каждого своя, поэтому по одному: что не вернулось, то и названо.
    /// - Returns: куда легли возвращённые.
    @MainActor
    @discardableResult
    func restoreFromTrash(_ items: [FileItem]) async throws -> [String] {
        guard !items.isEmpty else { return [] }
        let wanted = Set(items.map(\.path))
        let entries = TrashService.entries().filter { wanted.contains($0.url.path) }

        // Окно прогресса — только если работа затянулась дольше полусекунды, как и у стирания.
        var progressController: ProgressController?
        var cancelled = false
        let showTask = Task { @MainActor in
            try await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            progressController = DialogService.shared.showProgress(
                title: L("trash.restore"),
                message: L("progress.preparing"),
                cancelHandler: { cancelled = true })
        }
        defer {
            showTask.cancel()
            progressController?.close()
        }

        var restored: [String] = []
        let total = entries.count
        for (index, entry) in entries.enumerated() {
            if cancelled || progressController?.isCancelled == true { return restored }
            progressController?.update(
                currentFile: entry.displayName,
                progress: Double(index) / Double(total),
                bytesDone: 0, bytesTotal: 0,
                filesDone: index, filesTotal: total)
            // В стороне от главного потока: большая папка едет долго, а кнопка отмены
            // должна жить.
            let placed = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<[String], Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        cont.resume(returning: try TrashService.restore([entry]))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
            restored += placed
        }
        return restored
    }

    /// Очистить корзину: стирание — той же дорогой, что «стереть насовсем», с прогрессом и
    /// отменой. Скрытые остатки вместе с `.DS_Store` уходят только когда видимое стёрто
    /// целиком: после отмены индекс возврата ещё нужен оставшимся.
    @MainActor
    func emptyTrash() async throws {
        try await deleteItemsPermanently(TrashService.items())
        guard TrashService.items().isEmpty else { return }
        try TrashService.removeLeftovers()
    }

    @MainActor
    func trashItems(_ items: [FileItem]) async throws {
        guard !items.isEmpty else { return }

        // NTFS has no Trash at all, so both delete flavours land on the same libntfs path.
        if try await deleteViaNTFSIfNeeded(items) { return }

        // Standard macOS trash
        _ = try preflightCheck(items: items, destinationPath: nil, requireWriteAccess: true)

        let urls = items.map { URL(fileURLWithPath: $0.path) }
        let filesCount = items.reduce(0) { $0 + ($1.isDirectory ? 0 : 1) }
        let directoriesCount = items.count - filesCount
        let directBytes = items.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + Int64($1.size) }
        let startedAt = Date()

        Self.opsLog.info(
            "trash.start items=\(items.count, privacy: .public) files=\(filesCount, privacy: .public) dirs=\(directoriesCount, privacy: .public) directBytes=\(directBytes, privacy: .public)"
        )

        var progressController: ProgressController?
        let showTask = Task { @MainActor in
            try await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let pc = DialogService.shared.showProgress(
                title: L("progress.deleting"),
                message: L("progress.preparing"),
                cancelHandler: nil
            )
            pc.setIndeterminate(true)
            progressController = pc
        }
        defer {
            showTask.cancel()
            progressController?.close()
        }

        do {
            let recycled = try await recycleWithWorkspace(urls)
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
            Self.opsLog.info(
                "trash.done elapsedMs=\(elapsedMs, privacy: .public) recycledCount=\(recycled.count, privacy: .public)"
            )
            // Every original with the URL macOS gave it inside the bin — putting them back
            // needs no guessing. Items macOS silently declined stay out of the record.
            // Awaited, not fired off: when trashItems returns, Cmd+Z must already know.
            let pairs = recycled.map { ($0.key.path, $0.value) }
            if !pairs.isEmpty {
                await MainActor.run { UndoJournal.shared.record(.trashed(pairs: pairs)) }
            }
        } catch {
            let nsError = error as NSError
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
            Self.opsLog.error(
                // The message carries the file's NAME — private, so it stays out of a log
                // anyone can read; domain and code are enough to diagnose from.
                "trash.fail elapsedMs=\(elapsedMs, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) message=\(nsError.localizedDescription)"
            )
            throw error
        }
    }

    /// Perform a batch of already-planned rename steps (absolute from -> to paths, temp-name
    /// staging already resolved by RenameExecutionPlanner) on a background queue. Missing parent
    /// folders are created (TC's subfolder-move feature). Per-step failures are collected and, if
    /// any occurred, surfaced as a single error after the whole batch runs. Progress and cancel go
    /// through the reporter. Local filesystem only; the remote path is a separate service.
    func executeRenameSteps(_ steps: [RenameExecutionPlanner.Step],
                            reporter: OperationProgressReporter) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var errors: [String] = []
                let total = steps.count
                var done = 0
                for step in steps {
                    if reporter.waitWhilePaused() { break }   // returns true when cancelled
                    let parent = (step.to as NSString).deletingLastPathComponent
                    try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                    if Darwin.rename(step.from, step.to) != 0 {
                        let reason = String(cString: strerror(errno))
                        errors.append("\((step.from as NSString).lastPathComponent): \(reason)")
                    }
                    done += 1
                    let d = done
                    let label = (step.to as NSString).lastPathComponent
                    DispatchQueue.main.async {
                        reporter.update(currentFile: label,
                                        progress: Double(d) / Double(max(1, total)),
                                        bytesDone: 0, bytesTotal: 0, filesDone: d, filesTotal: total)
                    }
                }
                DispatchQueue.main.async {
                    if errors.isEmpty {
                        cont.resume(returning: ())
                    } else {
                        cont.resume(throwing: NSError(
                            domain: "FileOperationsService.multiRename", code: -2,
                            userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "\n")]))
                    }
                }
            }
        }
    }

    func renameItem(_ item: FileItem, to newName: String) throws {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return
        }
        guard !trimmedName.contains("/") else {
            throw NSError(
                domain: "FileOperationsService",
                code: NSFileWriteInvalidFileNameError,
                userInfo: [NSLocalizedDescriptionKey: L("rename.slashError")]
            )
        }

        let sourceURL = URL(fileURLWithPath: item.path)
        let destinationPath = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(trimmedName)
            .path
        if destinationPath == item.path {
            return
        }
        if FileManager.default.fileExists(atPath: destinationPath) {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: L("rename.exists")]
            )
        }

        // Check if this is an NTFS volume — need special handling
        if let vol = volumeInfo(for: item.path),
           vol.fsType.lowercased() == "ntfs" && vol.isReadOnly {
            throw NSError(
                domain: "FileOperationsService",
                code: -100,
                userInfo: [NSLocalizedDescriptionKey: "NTFS_RENAME_NEEDED"]
            )
        }

        // rename() is O(1) — instant metadata update, no data movement.
        guard Darwin.rename(item.path, destinationPath) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [
                    NSLocalizedDescriptionKey: String(cString: strerror(errno)),
                    NSFilePathErrorKey: item.path
                ]
            )
        }
        Self.journal(.renamed(from: item.path, to: destinationPath))
    }

    /// Async rename for NTFS volumes — unmounts, renames via libntfs-3g, remounts.
    @MainActor
    func renameItemOnNTFS(_ item: FileItem, to newName: String) async throws {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let sourceURL = URL(fileURLWithPath: item.path)
        let newPath = sourceURL.deletingLastPathComponent().appendingPathComponent(trimmedName).path

        try await performNTFSOperation(path: item.path, operationName: "rename") { bridge, relPath in
            let newRelPath = (relPath as NSString).deletingLastPathComponent + "/" + trimmedName
            try bridge.rename(atPath: relPath, toPath: newRelPath)
        }
    }

    /// Hand a real file on disk to the system, reporting a failed launch.
    ///
    /// The single funnel: call sites used to reach for `ExternalOpenService` directly, which meant a
    /// launch that failed said nothing at all — this method's error dialog was unreachable.
    @MainActor
    func openWithSystem(_ path: String, onLaunchStateChanged: ((Bool) -> Void)? = nil) {
        onLaunchStateChanged?(true)
        ExternalOpenService.open(URL(fileURLWithPath: path)) { error in
            onLaunchStateChanged?(false)
            if let error {
                DialogService.shared.showError(
                    title: L("error.openFile"),
                    message: error.localizedDescription
                )
            }
        }
    }

    @MainActor
    func openWithSystem(_ item: FileItem, onLaunchStateChanged: ((Bool) -> Void)? = nil) {
        openWithSystem(item.path, onLaunchStateChanged: onLaunchStateChanged)
    }

    @MainActor
    func openWithApp(path: String, bundleID: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        ExternalOpenService.open([URL(fileURLWithPath: path)], withApplicationAt: appURL)
    }

    /// Trash items and report what could not be trashed, without throwing.
    ///
    /// For the "after a successful transfer, remove the sources" step of a move: the transfer has
    /// already finished, so a failure here is not an operation to abort but a fact the user must
    /// hear — the alternative (four hand-rolled `try?` loops) let a "moved" file quietly survive in
    /// the source folder while the panel claimed the move was done.
    @MainActor
    func trashMovedSources(_ items: [FileItem]) async {
        guard !items.isEmpty else { return }
        do {
            try await trashItems(items)
        } catch {
            DialogService.shared.showError(title: L("delete.errorTitle"),
                                          message: error.localizedDescription)
        }
    }

    /// Create `path` and any missing parents, going through this service for every component so
    /// NTFS volumes take the libntfs route instead of failing outright.
    @MainActor
    func ensureDirectoryTree(at path: String) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                              userInfo: [NSLocalizedDescriptionKey: L("mkdir.exists")])
            }
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, parent != path else { return }
        try ensureDirectoryTree(at: parent)
        try createDirectory(at: parent, name: name)
    }

    @discardableResult
    @MainActor
    /// Extract ONE entry into a fresh temp directory and hand back its on-disk path — the
    /// mechanism behind both "open with the system app" and browsing a NESTED archive: an
    /// archive inside an archive cannot be read in place, it must exist as a real file first.
    /// The temp directory is registered for the same cleanup every preview temp gets, when the
    /// user finally leaves archives altogether.
    func extractArchiveEntryToTemp(archivePath: String, entryPath: String) throws -> String {
        let normalizedEntryPath = normalizeArchiveEntryPath(entryPath)
        guard !normalizedEntryPath.isEmpty else {
            throw NSError(
                domain: "FileOperationsService",
                code: NSFileNoSuchFileError,
                userInfo: [NSLocalizedDescriptionKey: L("error.archiveEntryEmpty")]
            )
        }

        let temporaryRoot = try Self.createTemporaryDirectory(prefix: "fcxl_archive_open")
        do {
            try bridgeService.extractArchiveEntry(
                archivePath: archivePath,
                entryPath: normalizedEntryPath,
                destinationPath: temporaryRoot
            )

            let extractedFilePath = (temporaryRoot as NSString).appendingPathComponent(normalizedEntryPath)
            guard FileManager.default.fileExists(atPath: extractedFilePath) else {
                throw NSError(
                    domain: "FileOperationsService",
                    code: NSFileNoSuchFileError,
                    userInfo: [NSLocalizedDescriptionKey: L("error.extractedNotFound")]
                )
            }

            archivePreviewDirectoriesLock.lock()
            archivePreviewTemporaryDirectories.append(temporaryRoot)
            archivePreviewDirectoriesLock.unlock()
            return extractedFilePath
        } catch {
            Self.cleanupTemporaryDirectory(temporaryRoot)
            throw error
        }
    }

    @MainActor
    func openExtractedArchiveEntry(at archivePath: String, entryPath: String) throws -> String {
        try askingArchivePassword(archivePath: archivePath) {
            try openExtractedArchiveEntryOnce(at: archivePath, entryPath: entryPath)
        }
    }

    @MainActor
    private func openExtractedArchiveEntryOnce(at archivePath: String, entryPath: String) throws -> String {
        let extractedFilePath = try extractArchiveEntryToTemp(
            archivePath: archivePath, entryPath: entryPath)
        let extractedURL = URL(fileURLWithPath: extractedFilePath)
        // The launch is asynchronous (the cooperative-activation handshake needs the completion
        // handler), so a failure cannot be thrown from here — it is reported the same way every
        // other open failure is. The temp dir stays registered either way and is cleaned up when
        // the user leaves the archive.
        ExternalOpenService.open(extractedURL) { error in
            guard error != nil else { return }
            DialogService.shared.showError(
                title: L("error.openFile"),
                message: L("error.openExtracted")
            )
        }
        return (extractedFilePath as NSString).deletingLastPathComponent
    }

    /// Extract one archive entry to a temp file for the built-in viewer (F3/Space) — returns
    /// the on-disk temp path, or nil on failure. Keeps only the LATEST preview temp (drops the
    /// previous one), and the last one is removed when the user leaves the archive
    /// (`cleanupArchivePreviewTemporaryDirectories`), so callers don't clean up themselves.
    @MainActor
    func extractArchiveEntryForPreview(archivePath: String, entryPath: String) -> String? {
        let normalizedEntryPath = normalizeArchiveEntryPath(entryPath)
        guard !normalizedEntryPath.isEmpty else { return nil }
        guard let temporaryRoot = try? Self.createTemporaryDirectory(prefix: "fcxl_archive_view") else {
            return nil
        }
        do {
            try bridgeService.extractArchiveEntry(
                archivePath: archivePath,
                entryPath: normalizedEntryPath,
                destinationPath: temporaryRoot
            )
            let extractedFilePath = (temporaryRoot as NSString).appendingPathComponent(normalizedEntryPath)
            guard FileManager.default.fileExists(atPath: extractedFilePath) else {
                Self.cleanupTemporaryDirectory(temporaryRoot)
                return nil
            }
            // Keep only the latest preview temp — drop the previous one so temp copies don't
            // pile up while the user arrows through the archive.
            archivePreviewDirectoriesLock.lock()
            let previousPreview = currentPreviewTempDirectory
            currentPreviewTempDirectory = temporaryRoot
            archivePreviewDirectoriesLock.unlock()
            if let previousPreview { Self.cleanupTemporaryDirectory(previousPreview) }
            return extractedFilePath
        } catch {
            Self.cleanupTemporaryDirectory(temporaryRoot)
            return nil
        }
    }

    func cleanupArchivePreviewTemporaryDirectories() {
        archivePreviewDirectoriesLock.lock()
        let directories = archivePreviewTemporaryDirectories
        archivePreviewTemporaryDirectories.removeAll()
        let preview = currentPreviewTempDirectory
        currentPreviewTempDirectory = nil
        archivePreviewDirectoriesLock.unlock()
        for path in directories {
            Self.cleanupTemporaryDirectory(path)
        }
        if let preview { Self.cleanupTemporaryDirectory(preview) }
    }

    /// Pack one file into a zip made only to be sent, and hand back the archive's path.
    ///
    /// For the receiving app that cannot take the file as it is — Telegram and an SVG, say,
    /// which its share extension takes for a picture, fails to draw, and then never uploads.
    /// The archive is named after the file (`drawing.svg` → `drawing.zip`) so the person on the
    /// other end sees what they were sent, and it is built by the same writer as the Pack
    /// command, at the format's own default level.
    ///
    /// It lands in a temporary directory of its own: the caller owns that directory and can
    /// throw it away once the sending is over.
    func zipForSending(path: String) throws -> String {
        let directory = try Self.createTemporaryDirectory(prefix: "fcxl_send")
        let name = (path as NSString).lastPathComponent
        let archive = (directory as NSString)
            .appendingPathComponent(((name as NSString).deletingPathExtension) + ".zip")
        do {
            try bridgeService.createArchive(
                archivePath: archive,
                format: .zip,
                sources: [path],
                includeSubfolders: true,
                preservePaths: false,
                compressionLevel: ArchiveFormat.zip.defaultCompressionLevel
            )
        } catch {
            Self.cleanupTemporaryDirectory(directory)
            throw error
        }
        Self.sendDirectories.append(directory)
        return archive
    }

    /// Where those archives went. They are NOT thrown away when the share panel closes: the
    /// receiving app may still be reading one — Telegram's extension hands the upload to
    /// Telegram itself and closes — so they live until the app quits, in the system's own
    /// temporary directory, which clears them anyway if the app never gets to.
    private static var sendDirectories: [String] = []

    static func cleanupSendDirectories() {
        for directory in sendDirectories { cleanupTemporaryDirectory(directory) }
        sendDirectories.removeAll()
    }

    static func createTemporaryDirectory(prefix: String) throws -> String {
        let temporaryRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(prefix)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: temporaryRoot,
            withIntermediateDirectories: true
        )
        return temporaryRoot
    }

    static func cleanupTemporaryDirectory(_ path: String) {
        guard !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    func totalSize(for items: [FileItem]) -> Int64 {
        items.reduce(Int64(0)) { $0 + calculatePathStats(path: $1.path).bytes }
    }

    // MARK: – NTFS volume helpers

    private struct VolumeInfo {
        let fsType: String
        let mountPoint: String
        let devicePath: String
        let isReadOnly: Bool
    }

    private func volumeInfo(for path: String) -> VolumeInfo? {
        let buf = UnsafeMutablePointer<statfs>.allocate(capacity: 1)
        defer { buf.deallocate() }
        guard statfs(path, buf) == 0 else { return nil }
        let s = buf.pointee

        let fsType = withUnsafePointer(to: s.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }
        let mountPoint = withUnsafePointer(to: s.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        let devicePath = withUnsafePointer(to: s.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        let isReadOnly = (s.f_flags & UInt32(MNT_RDONLY)) != 0
        return VolumeInfo(fsType: fsType, mountPoint: mountPoint,
                          devicePath: devicePath, isReadOnly: isReadOnly)
    }

    /// Tracks NTFS volumes where user approved writing via libntfs-3g.
    private var ntfsApprovedVolumes: Set<String> = []

    /// Volumes currently unmounted for NTFS writing — suppress "disk disconnected" alerts.
    /// Accessed from main thread only (set before dispatch, read in notification handler).
    @MainActor static var ntfsWritingVolumes: Set<String> = []

    /// After NTFS operation completes and volume remounts, navigate the target panel to this path.
    /// Set before the operation starts, consumed by the volume-mount handler.
    @MainActor static var ntfsRestorePath: String?

    /// Result of NTFS dialog: user allowed writing via built-in libntfs-3g, or cancelled.
    enum NtfsWriteDecision {
        case useLibntfs(devicePath: String, mountPoint: String)
        case cancelled
    }

    /// Shows NTFS info dialog and returns user's decision.
    @MainActor
    private func handleNTFSReadOnly(_ vol: VolumeInfo) -> NtfsWriteDecision {
        // If already approved this volume in this session, skip the dialog.
        if ntfsApprovedVolumes.contains(vol.mountPoint) {
            return .useLibntfs(devicePath: vol.devicePath, mountPoint: vol.mountPoint)
        }

        // Password already saved → write silently, no confirmation needed.
        if NTFSPasswordStore.hasPassword {
            ntfsApprovedVolumes.insert(vol.mountPoint)
            return .useLibntfs(devicePath: vol.devicePath, mountPoint: vol.mountPoint)
        }

        let volumeName = (vol.mountPoint as NSString).lastPathComponent

        // First write this session with no saved password: offer to save it now
        // (so the user never has to open Settings for this).
        switch DialogService.shared.showNTFSSavePasswordDialog(volumeName: volumeName) {
        case .cancelled:
            return .cancelled
        case .enterEachTime, .savedPassword:
            ntfsApprovedVolumes.insert(vol.mountPoint)
            Self.opsLog.info("NTFS write approved for \(volumeName) — will use libntfs-3g")
            return .useLibntfs(devicePath: vol.devicePath, mountPoint: vol.mountPoint)
        }
    }

    // MARK: – Preflight validation

    /// Info about NTFS write session if destination is NTFS.
    struct NtfsWriteInfo {
        let devicePath: String
        let mountPoint: String
    }

    /// Runs before any copy / move / delete operation.
    /// Checks source file accessibility and, for write operations, destination writability.
    /// Shows a single error dialog and throws (as userCancelled) if any issue is found.
    /// Returns NtfsWriteInfo if destination is a read-only NTFS volume and user approved libntfs-3g.
    @MainActor
    private func preflightCheck(
        items: [FileItem],
        destinationPath: String?,
        requireWriteAccess: Bool
    ) throws -> NtfsWriteInfo? {
        let fm = FileManager.default
        var ntfsInfo: NtfsWriteInfo?

        // ── Destination check ───────────────────────────────────────────────
        if let dest = destinationPath {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dest, isDirectory: &isDir), isDir.boolValue else {
                DialogService.shared.showError(
                    title: L("preflight.errorTitle"),
                    message: L("preflight.destNotFound", dest)
                )
                throw userCancelledError()
            }

            if !fm.isWritableFile(atPath: dest) {
                if let vol = volumeInfo(for: dest),
                   vol.fsType.lowercased() == "ntfs" && vol.isReadOnly {
                    // NTFS volume is read-only — show info dialog and request permission
                    let decision = handleNTFSReadOnly(vol)
                    switch decision {
                    case .useLibntfs(let devicePath, let mountPoint):
                        ntfsInfo = NtfsWriteInfo(devicePath: devicePath, mountPoint: mountPoint)
                    case .cancelled:
                        throw userCancelledError()
                    }
                } else {
                    DialogService.shared.showError(
                        title: L("preflight.errorTitle"),
                        message: L("preflight.destNotWritable", (dest as NSString).lastPathComponent)
                    )
                    throw userCancelledError()
                }
            }
        }

        // ── Source items check ───────────────────────────────────────────────
        var issues: [(name: String, reason: String)] = []
        for item in items {
            // attributesOfItem, never fileExists: fileExists FOLLOWS a symlink, so a link whose
            // target is gone read as "file not found" — and a broken symlink became the one
            // thing in the file manager that could not be deleted. The link itself is the item
            // being operated on, and lstat semantics see it.
            guard let attrs = try? fm.attributesOfItem(atPath: item.path) else {
                issues.append((item.name, L("preflight.notFound")))
                continue
            }
            let isSymlink = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
            // Readability is asked of the TARGET for real files; a symlink is copied/deleted as
            // itself and only needs its parent, so the question does not apply.
            if !isSymlink, !fm.isReadableFile(atPath: item.path) {
                issues.append((item.name, L("preflight.noReadPermission")))
                continue
            }
            if requireWriteAccess {
                // isDeletableFile also follows the link; for a symlink the right question is
                // whether the folder holding it lets go of entries.
                let deletable = isSymlink
                    ? fm.isWritableFile(atPath: (item.path as NSString).deletingLastPathComponent)
                    : fm.isDeletableFile(atPath: item.path)
                if !deletable {
                    issues.append((item.name, L("preflight.noWritePermission")))
                    continue
                }
                if (attrs[.immutable] as? Bool) == true {
                    issues.append((item.name, L("preflight.locked")))
                }
            }
        }

        guard issues.isEmpty else {
            let details = issues.map { "• \($0.name): \($0.reason)" }.joined(separator: "\n")
            DialogService.shared.showError(
                title: L("preflight.errorTitle"),
                message: details
            )
            throw userCancelledError()
        }
        return ntfsInfo
    }

    private func validateNotCopyingIntoSelf(items: [FileItem], destinationPath: String) throws {
        let normalizedDest = destinationPath.hasSuffix("/") ? destinationPath : destinationPath + "/"
        for item in items where item.isDirectory {
            let normalizedSrc = item.path.hasSuffix("/") ? item.path : item.path + "/"
            if normalizedDest.hasPrefix(normalizedSrc) {
                throw NSError(
                    domain: "FileOperationsService",
                    code: NSFileWriteInvalidFileNameError,
                    userInfo: [NSLocalizedDescriptionKey: L("error.copyIntoSelf", item.name)]
                )
            }
        }
    }

    // MARK: – NTFS transfer helper

    /// Performs a single file/directory copy (or move) to an NTFS volume via libntfs-3g.
    /// Opens a per-operation bridge: unmount → write → remount.
    /// Called from the background DispatchQueue inside transferItems.
    private static func performNTFSTransfer(
        sourcePath: String,
        destPath: String,
        ntfsInfo: NtfsWriteInfo,
        move: Bool,
        bytesDone: Int64,
        totalBytes: Int64,
        filesDone: Int,
        totalFiles: Int,
        stateLock: NSLock,
        sharedProgressPtr: UnsafeMutablePointer<Double>,
        sharedBytesDonePtr: UnsafeMutablePointer<Int64>,
        cancelled: @escaping () -> Bool
    ) throws {
        // Same-volume transfer: the source lives on the very NTFS volume that
        // openVolume is about to UNMOUNT, which makes it unreadable mid-copy
        // ("cannot open source"). Stage it to a temp dir on another volume FIRST,
        // while it's still mounted read-only and readable, then copy from there.
        let mountPoint = ntfsInfo.mountPoint
        let mountPrefix = mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/"
        let sourceOnSameVolume = sourcePath == mountPoint || sourcePath.hasPrefix(mountPrefix)
        var effectiveSource = sourcePath
        var stagedTemp: String?
        if sourceOnSameVolume {
            let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "fcxlxfer-" + UUID().uuidString + "-" + (sourcePath as NSString).lastPathComponent)
            try FileManager.default.copyItem(atPath: sourcePath, toPath: tmp)
            effectiveSource = tmp
            stagedTemp = tmp
        }

        let bridge = FCXLNTFSBridge()
        try bridge.openVolume(withDevice: ntfsInfo.devicePath,
                              mountPoint: ntfsInfo.mountPoint)

        defer {
            try? bridge.closeVolume()
            if let stagedTemp { try? FileManager.default.removeItem(atPath: stagedTemp) }
            DispatchQueue.main.async {
                FileOperationsService.ntfsWritingVolumes.remove(ntfsInfo.mountPoint)
            }
        }

        // Compute relative path on NTFS volume
        let mountLen = ntfsInfo.mountPoint.count
        let relPath: String
        if destPath.count > mountLen {
            relPath = String(destPath[destPath.index(destPath.startIndex, offsetBy: mountLen)...])
        } else {
            relPath = "/"
        }

        var srcIsDir: ObjCBool = false
        FileManager.default.fileExists(atPath: effectiveSource, isDirectory: &srcIsDir)
        let baseBytesDone = bytesDone

        let progressBlock: (Int64, Int64, String) -> Void = { copied, _, _ in
            stateLock.lock()
            let currentBytesDone = baseBytesDone + copied
            let p = totalBytes > 0
                ? Double(currentBytesDone) / Double(totalBytes)
                : Double(filesDone) / Double(max(totalFiles, 1))
            sharedProgressPtr.pointee = min(max(p, 0.01), 0.99)
            sharedBytesDonePtr.pointee = currentBytesDone
            stateLock.unlock()
        }

        if srcIsDir.boolValue {
            try bridge.copyTree(from: effectiveSource, to: relPath,
                                progress: progressBlock, cancel: cancelled)
        } else {
            try bridge.copyFile(from: effectiveSource, to: relPath,
                                progress: progressBlock, cancel: cancelled)
        }

        if move {
            if sourceOnSameVolume {
                // The original is on the NTFS volume we have open — delete it via
                // libntfs-3g (FileManager can't write the read-only macOS mount).
                // Guard against a "/" relative path (source == volume root): never
                // remove the volume root.
                if sourcePath.count > mountPoint.count {
                    try bridge.remove(atPath: String(sourcePath.dropFirst(mountPoint.count)))
                }
            } else {
                try FileManager.default.removeItem(atPath: sourcePath)
            }
        }
    }

    // MARK: – NTFS single-operation helper (delete, rename, mkdir)

    /// Performs a quick NTFS operation: unmount → operation → remount → navigate back.
    /// Shows NTFS confirmation dialog if not yet approved for this volume.
    /// @param path The absolute path on the NTFS volume (used for volume detection and restore)
    /// @param operationName Human-readable operation name for error messages
    /// @param operation Closure that receives (bridge, relPath) and performs the NTFS operation
    @MainActor
    func performNTFSOperation(
        path: String,
        operationName: String,
        operation: @escaping (FCXLNTFSBridge, String) throws -> Void
    ) async throws {
        // Detect NTFS volume (try path itself first, fall back to parent directory
        // for paths that don't exist yet, e.g. new files/folders being created)
        let checkPath = FileManager.default.fileExists(atPath: path)
            ? path
            : (path as NSString).deletingLastPathComponent
        guard let vol = volumeInfo(for: checkPath),
              vol.fsType.lowercased() == "ntfs" && vol.isReadOnly else {
            throw NSError(domain: "FileOperationsService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Not an NTFS volume"])
        }

        // Ask for permission (shows dialog first time, remembers for session)
        let decision = handleNTFSReadOnly(vol)
        switch decision {
        case .cancelled:
            throw userCancelledError()
        case .useLibntfs(let devicePath, let mountPoint):
            // Remember path to restore after remount
            let restorePath = (path as NSString).deletingLastPathComponent
            FileOperationsService.ntfsRestorePath = restorePath
            FileOperationsService.ntfsWritingVolumes.insert(mountPoint)

            // Compute relative path
            let mountLen = mountPoint.count
            let relPath: String
            if path.count > mountLen {
                relPath = String(path[path.index(path.startIndex, offsetBy: mountLen)...])
            } else {
                relPath = "/"
            }

            // Run on background: open bridge → operation → close bridge (remounts)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let bridge = FCXLNTFSBridge()
                        try bridge.openVolume(withDevice: devicePath, mountPoint: mountPoint)
                        defer {
                            try? bridge.closeVolume()
                            DispatchQueue.main.async {
                                FileOperationsService.ntfsWritingVolumes.remove(mountPoint)
                            }
                        }
                        try operation(bridge, relPath)
                        continuation.resume()
                    } catch {
                        DispatchQueue.main.async {
                            FileOperationsService.ntfsWritingVolumes.remove(mountPoint)
                        }
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func openViewer(for item: FileItem) {
        viewerOpenHandler?(item)
    }

    @MainActor
    func openEditor(for item: FileItem) {
        openEditor(for: item, archivePath: nil, insideArchive: false)
    }

    /// Куда F4 поведёт файл — одно решение на все двери.
    enum EditorRoad: Equatable {
        /// Чужая программа, которую человек назначил в настройках.
        case external
        /// Наш редактор в соседней панели.
        case embedded
        /// Наш редактор в своём окне.
        case window
    }

    static let externalEditorKey = "fcxl.externalEditor"

    /// Путь к назначенному внешнему редактору; nil — не назначен.
    static var externalEditorPath: String? {
        guard let path = UserDefaults.standard.string(forKey: externalEditorKey),
              !path.isEmpty else { return nil }
        return path
    }

    /// Внешний редактор, если он назначен, важнее места встроенного: настройка «редактор в
    /// панели» говорит, где открывать НАШ редактор, а человек попросил чужую программу.
    /// Раньше при включённом редакторе в панели внешний не спрашивали вовсе. Внутри архива
    /// чужой программе отдавать нечего — там остаётся наш редактор с временной копией.
    nonisolated static func editorRoad(externalConfigured: Bool, editorInPanel: Bool,
                                       insideArchive: Bool) -> EditorRoad {
        if externalConfigured, !insideArchive { return .external }
        return editorInPanel ? .embedded : .window
    }

    @MainActor
    func openEditor(for item: FileItem, archivePath: String?, insideArchive: Bool) {
        guard item.name != "..", !item.isDirectory else { return }

        // External editor: if configured, open with it
        if let externalEditor = Self.externalEditorPath,
           !insideArchive {
            let url = URL(fileURLWithPath: item.path)
            let editorURL = URL(fileURLWithPath: externalEditor)
            ExternalOpenService.open([url], withApplicationAt: editorURL)
            return
        }

        guard let target = prepareEditorTarget(
            for: item, archivePath: archivePath, insideArchive: insideArchive
        ) else { return }
        EditorWindowManager.shared.openDocument(
            at: target.path,
            source: target.source,
            operations: self
        )
    }

    /// Prepare a file for editing: extract it from the archive if needed, verify it's a text
    /// file, and return the on-disk path + document source. Shows a dialog and returns nil if
    /// it can't be edited. Shared by the standalone editor window and the embedded panel.
    @MainActor
    func prepareEditorTarget(for item: FileItem, archivePath: String?, insideArchive: Bool)
        -> (path: String, source: EditorDocumentSource)? {
        do {
            let target = try resolveEditorTarget(
                for: item, archivePath: archivePath, insideArchive: insideArchive
            )
            guard isEditableTextFile(name: target.displayName, fileExtension: target.fileExtension) else {
                DialogService.shared.showWarning(
                    title: L("error.editUnavailable"),
                    message: L("error.binaryEdit")
                )
                return nil
            }
            return (target.path, target.source)
        } catch {
            DialogService.shared.showError(
                title: L("error.openEditor"),
                message: error.localizedDescription
            )
            return nil
        }
    }

    /// Имя папки может быть и дорогой — «toys/alsde/dk», как в Total Commander: тогда
    /// создаётся вся цепочка, а недостающие звенья — по одному, каждое со своей записью в
    /// журнале отката. Уже существующие звенья не трогаются.
    func createDirectory(at path: String, name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let components = Self.folderComponents(of: trimmedName)
        if components.count > 1 {
            let destinationPath = components.reduce(path) { ($0 as NSString).appendingPathComponent($1) }
            guard !FileManager.default.fileExists(atPath: destinationPath) else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                              userInfo: [NSLocalizedDescriptionKey: L("mkdir.exists")])
            }
            var current = path
            for component in components {
                let next = (current as NSString).appendingPathComponent(component)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: next, isDirectory: &isDir) {
                    // Звено есть, но это файл — дорога через него не пройдёт.
                    guard isDir.boolValue else {
                        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                                      userInfo: [NSLocalizedDescriptionKey: L("mkdir.exists")])
                    }
                } else {
                    try createDirectory(at: current, name: component)
                }
                current = next
            }
            return
        }
        let destinationPath = (path as NSString).appendingPathComponent(trimmedName)
        if FileManager.default.fileExists(atPath: destinationPath) {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: L("mkdir.exists")]
            )
        }

        // Check if this is NTFS — need special handling
        if let vol = volumeInfo(for: path),
           vol.fsType.lowercased() == "ntfs" && vol.isReadOnly {
            throw NSError(
                domain: "FileOperationsService",
                code: -100,
                userInfo: [NSLocalizedDescriptionKey: "NTFS_MKDIR_NEEDED"]
            )
        }

        try bridgeService.createDirectory(path: destinationPath)
        Self.journal(.created(path: destinationPath, isDirectory: true))
    }

    /// Звенья имени-дороги: «toys/alsde/dk» → три; пустые (двойная черта, черта с краю)
    /// отбрасываются. Одно звено — обычное имя.
    nonisolated static func folderComponents(of name: String) -> [String] {
        name.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Async mkdir for NTFS volumes — unmounts, creates dir via libntfs-3g, remounts.
    @MainActor
    func createDirectoryOnNTFS(at path: String, name: String) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let fullPath = (path as NSString).appendingPathComponent(trimmedName)

        try await performNTFSOperation(path: fullPath, operationName: "mkdir") { bridge, relPath in
            try bridge.mkdir(atPath: relPath)
        }
    }

    /// The name a typed one becomes: trimmed, and ".txt" when no extension was given — the
    /// one rule the panel also uses to put the cursor on the file and open it afterwards.
    nonisolated static func textFileName(for typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).pathExtension.isEmpty ? trimmed + ".txt" : trimmed
    }

    func createTextFile(at path: String, name: String, contents: String = "") throws {
        let fileName = Self.textFileName(for: name)
        guard !fileName.isEmpty else { return }

        let destinationPath = (path as NSString).appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destinationPath) {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: L("file.exists")]
            )
        }

        // Check if this is NTFS — need special handling
        if let vol = volumeInfo(for: path),
           vol.fsType.lowercased() == "ntfs" && vol.isReadOnly {
            throw NSError(
                domain: "FileOperationsService",
                code: -100,
                userInfo: [NSLocalizedDescriptionKey: "NTFS_CREATE_FILE_NEEDED"]
            )
        }

        let data = Data(contents.utf8)
        let created = FileManager.default.createFile(
            atPath: destinationPath,
            contents: data,
            attributes: nil
        )
        if !created {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: L("file.create.error")]
            )
        }
    }

    // MARK: - Symlinks & Hardlinks

    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        if FileManager.default.fileExists(atPath: linkPath) {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: L("symlink.error.exists")]
            )
        }
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: targetPath)
    }

    /// A Finder ALIAS — the third kind of link, and the only one that survives its target being
    /// renamed or moved: it stores the file's identity alongside the path, and can even ask the
    /// system to mount the volume the target lives on. The price is that only Finder and Mac
    /// apps understand it — to the shell and to git it is an opaque file of about a kilobyte.
    func createAlias(at linkPath: String, pointingTo targetPath: String) throws {
        if FileManager.default.fileExists(atPath: linkPath) {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: L("symlink.error.exists")]
            )
        }
        let target = URL(fileURLWithPath: targetPath)
        let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: URL(fileURLWithPath: linkPath))
    }

    func createHardlink(at linkPath: String, pointingTo targetPath: String) throws {
        // Hardlinks cannot be created for directories (POSIX limitation)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: targetPath, isDirectory: &isDir)
        if isDir.boolValue {
            throw NSError(
                domain: "FileOperationsService",
                code: -200,
                userInfo: [NSLocalizedDescriptionKey: L("hardlink.error.directory")]
            )
        }
        if FileManager.default.fileExists(atPath: linkPath) {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: L("symlink.error.exists")]
            )
        }
        let result = link(targetPath, linkPath)
        if result != 0 {
            let errMsg = String(cString: strerror(errno))
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: errMsg]
            )
        }
    }

    /// Async file creation for NTFS volumes — writes to temp, copies via libntfs-3g.
    @MainActor
    func createTextFileOnNTFS(at path: String, name: String, contents: String = "") async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        var fileName = trimmedName
        if (fileName as NSString).pathExtension.isEmpty {
            fileName += ".txt"
        }

        let fullPath = (path as NSString).appendingPathComponent(fileName)

        try await performNTFSOperation(path: fullPath, operationName: "create file") { bridge, relPath in
            // Write contents to a temp file, then copy to NTFS
            let tmpPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("fcxl_newfile_\(UUID().uuidString)")
            let data = Data(contents.utf8)
            FileManager.default.createFile(atPath: tmpPath, contents: data, attributes: nil)
            defer { try? FileManager.default.removeItem(atPath: tmpPath) }
            try bridge.copyFile(from: tmpPath, to: relPath, progress: nil, cancel: nil)
        }
    }

    @MainActor
    func packItems(_ items: [FileItem],
                   to archivePath: String,
                   format: ArchiveFormat,
                   compressionLevel: Int = 6,
                   preservePaths: Bool = true,
                   includeSubfolders: Bool = true,
                   deleteAfterPack: Bool = false,
                   separateArchives: Bool = false,
                   password: String = "",
                   queueService: OperationQueueService? = nil,
                   onCompletion: (() -> Void)? = nil) async throws {
        guard !items.isEmpty else { return }
        let normalizedLevel = min(max(compressionLevel, 0), 9)

        var sentToQueue = false
        var deletedInSession = false
        // What "delete after pack" should trash. For separate archives this is
        // narrowed to the items actually packed (skipped ones must survive).
        var itemsToTrash = items

        if separateArchives {
            itemsToTrash = try await packItemsSeparately(
                items,
                archivePath: archivePath,
                format: format,
                compressionLevel: normalizedLevel,
                preservePaths: preservePaths,
                includeSubfolders: includeSubfolders
            )
        } else {
            guard let destinationArchivePath = try resolveSingleArchiveDestination(
                initialArchivePath: archivePath,
                sourcePath: items.first?.path ?? archivePath
            ) else {
                return
            }
            // If we're deleting the sources afterwards AND they sit on the same
            // read-only NTFS volume as the archive, delete them inside the
            // archive's libntfs-3g session — opening that volume twice (write
            // then delete) is what was failing. FileManager/Trash can't touch a
            // read-only NTFS mount anyway.
            let ntfsDeleteSources = deleteAfterPack
                ? (sameReadOnlyNTFSMount(archive: destinationArchivePath,
                                         sources: items.map(\.path)) != nil
                    ? items.map(\.path) : [])
                : []
            sentToQueue = try await packSingleArchive(
                items,
                to: destinationArchivePath,
                format: format,
                compressionLevel: normalizedLevel,
                preservePaths: preservePaths,
                includeSubfolders: includeSubfolders,
                password: password,
                queueService: queueService,
                onCompletion: onCompletion,
                ntfsDeleteSources: ntfsDeleteSources
            )
            deletedInSession = !ntfsDeleteSources.isEmpty && !sentToQueue
        }

        if deleteAfterPack && !sentToQueue && !deletedInSession && !itemsToTrash.isEmpty {
            try await trashItems(itemsToTrash)
        }
    }

    /// Packs each item into its own archive. Returns the items that were
    /// actually packed (entries skipped on conflict are excluded) so the caller
    /// can "delete after pack" only those — never a source whose archive the
    /// user skipped.
    @MainActor
    private func packItemsSeparately(_ items: [FileItem],
                                     archivePath: String,
                                     format: ArchiveFormat,
                                     compressionLevel: Int,
                                     preservePaths: Bool,
                                     includeSubfolders: Bool) async throws -> [FileItem] {
        let destinationDirectoryRaw = (archivePath as NSString).deletingLastPathComponent
        let destinationDirectory = destinationDirectoryRaw.isEmpty
            ? FileManager.default.currentDirectoryPath
            : destinationDirectoryRaw
        var applyToAllResolution: ConflictResolution?
        var packedItems: [FileItem] = []

        for item in items {
            var itemArchivePath = (destinationDirectory as NSString)
                .appendingPathComponent(archiveBaseName(from: item.name) + format.fileExtension)
            if FileManager.default.fileExists(atPath: itemArchivePath) {
                let decision: (resolution: ConflictResolution, applyToAll: Bool)
                if let applyToAllResolution {
                    decision = (applyToAllResolution, true)
                } else {
                    decision = DialogService.shared.showFileConflict(
                        sourcePath: item.path,
                        destinationPath: itemArchivePath
                    )
                    if decision.applyToAll {
                        applyToAllResolution = decision.resolution
                    }
                }

                switch decision.resolution {
                case .replace:
                    // Read-only NTFS: libntfs-3g overwrites in place, skip removal.
                    if !isReadOnlyNTFSDestination(itemArchivePath) {
                        try FileManager.default.removeItem(atPath: itemArchivePath)
                    }
                case .copy:
                    itemArchivePath = uniqueCopyPath(from: itemArchivePath)
                case .skip:
                    continue
                case .cancel:
                    throw userCancelledError()
                }
            }

            _ = try await packSingleArchive(
                [item],
                to: itemArchivePath,
                format: format,
                compressionLevel: compressionLevel,
                preservePaths: preservePaths,
                includeSubfolders: includeSubfolders
            )
            packedItems.append(item)
        }
        return packedItems
    }

    /// True if the file's destination directory is a read-only NTFS volume —
    /// libarchive / FileManager can't write there, so the archive must be built
    /// in a temp dir and pushed across via libntfs-3g.
    private func isReadOnlyNTFSDestination(_ path: String) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        guard let vol = volumeInfo(for: dir) else { return false }
        return vol.fsType.lowercased() == "ntfs" && vol.isReadOnly
    }

    /// Returns the NTFS mount point when the archive AND every source live on the
    /// same read-only NTFS volume. In that case the post-pack source deletion can
    /// run inside the archive's own libntfs-3g session (one unmount/remount),
    /// instead of opening the volume a second time. Returns nil otherwise.
    private func sameReadOnlyNTFSMount(archive: String, sources: [String]) -> String? {
        guard let av = volumeInfo(for: (archive as NSString).deletingLastPathComponent),
              av.fsType.lowercased() == "ntfs", av.isReadOnly else { return nil }
        for s in sources {
            guard let sv = volumeInfo(for: s), sv.mountPoint == av.mountPoint else { return nil }
        }
        return av.mountPoint
    }

    @MainActor
    private func resolveSingleArchiveDestination(initialArchivePath: String,
                                                 sourcePath: String) throws -> String? {
        var resolvedArchivePath = initialArchivePath
        guard FileManager.default.fileExists(atPath: resolvedArchivePath) else {
            return resolvedArchivePath
        }

        let decision = DialogService.shared.showFileConflict(
            sourcePath: sourcePath,
            destinationPath: resolvedArchivePath
        )
        switch decision.resolution {
        case .replace:
            // On read-only NTFS we can't delete via FileManager; the libntfs-3g
            // write overwrites the existing archive in place, so skip removal.
            if !isReadOnlyNTFSDestination(resolvedArchivePath) {
                try FileManager.default.removeItem(atPath: resolvedArchivePath)
            }
            return resolvedArchivePath
        case .copy:
            resolvedArchivePath = uniqueCopyPath(from: resolvedArchivePath)
            return resolvedArchivePath
        case .skip:
            return nil
        case .cancel:
            throw userCancelledError()
        }
    }

    /// Packs items into a single archive on a background thread.
    /// Returns `true` if the operation was sent to the queue (caller should skip post-processing).
    @MainActor
    private func packSingleArchive(_ items: [FileItem],
                                   to archivePath: String,
                                   format: ArchiveFormat,
                                   compressionLevel: Int,
                                   preservePaths: Bool,
                                   includeSubfolders: Bool,
                                   password: String = "",
                                   queueService: OperationQueueService? = nil,
                                   onCompletion: (() -> Void)? = nil,
                                   ntfsDeleteSources: [String] = []) async throws -> Bool {
        // libarchive writes the output file directly, which fails on a read-only
        // NTFS mount ("Failed to open output archive"). For NTFS we build the
        // archive in a writable temp file, then push it onto the volume via
        // libntfs-3g (same path copy/mkdir use). The queue button is disabled in
        // that case — the final transfer must run here on the main actor.
        let ntfsDestination = isReadOnlyNTFSDestination(archivePath)
        let buildPath: String = ntfsDestination
            ? (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "fcxlpack-" + UUID().uuidString + "-" + (archivePath as NSString).lastPathComponent)
            : archivePath
        let effectiveQueue = ntfsDestination ? nil : queueService

        let progressController = DialogService.shared.showProgress(
            title: L("progress.packing"),
            message: L("progress.preparing"),
            cancelHandler: { [bridgeService] in
                bridgeService.cancelArchiveOperations()
            }
        )
        let swappable = SwappableProgressReporter(progressController)
        progressController.setIndeterminate(true)
        // The format and level are known before the totals are — show them while "preparing".
        progressController.setDetail(Self.packProgressDetail(
            format: format, compressionLevel: compressionLevel,
            compressedBytes: 0, uncompressedDone: 0, uncompressedTotal: 0))

        let sentToQueue: Bool = try await withCheckedThrowingContinuation { continuation in
            let resumeOnce = ContinuationResumeOnce(continuation)

            // Setup "Send to queue" button (disabled for NTFS — see above)
            if let queueService = effectiveQueue {
                progressController.onSendToQueue = {
                    let params = ArchiveOperationParams(
                        archivePath: archivePath,
                        format: format,
                        compressionLevel: compressionLevel,
                        preservePaths: preservePaths,
                        includeSubfolders: includeSubfolders,
                        password: password
                    )
                    let (_, queueReporter) = queueService.adoptRunningOperation(
                        kind: .pack,
                        items: items,
                        destination: (archivePath as NSString).deletingLastPathComponent,
                        archiveParams: params,
                        currentProgress: progressController.lastProgressValue,
                        currentFile: "",
                        bytesDone: progressController.lastBytesDoneValue,
                        bytesTotal: progressController.lastBytesTotalValue,
                        filesDone: progressController.lastFilesDoneValue,
                        filesTotal: progressController.lastFilesTotalValue,
                        onCompletion: onCompletion
                    )
                    swappable.swap(to: queueReporter)
                    resumeOnce.resume(returning: true)
                    return true
                }
                progressController.showSendToQueueButton()
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Calculate stats
                    let sourceStats = items.map { self.calculatePathStats(path: $0.path) }
                    let totalBytes = max(sourceStats.reduce(Int64(0)) { $0 + $1.bytes }, 1)
                    let totalFiles = max(sourceStats.reduce(0) { $0 + max(1, $1.fileCount) }, 1)

                    if swappable.isCancelled {
                        DispatchQueue.main.async { progressController.close() }
                        resumeOnce.resume(throwing: self.userCancelledError())
                        return
                    }

                    DispatchQueue.main.async {
                        progressController.setIndeterminate(false)
                        let currentFile = URL(fileURLWithPath: archivePath).lastPathComponent
                        progressController.update(
                            currentFile: currentFile,
                            progress: 0.01,
                            bytesDone: 0,
                            bytesTotal: totalBytes,
                            filesDone: 0,
                            filesTotal: totalFiles
                        )
                    }

                    let monotonic = MonotonicProgress()

                    if format.isBuiltByHdiutil {
                        try self.createDMGImage(
                            sources: items.map(\.path), to: buildPath,
                            compressionLevel: compressionLevel,
                            totalBytes: totalBytes, totalFiles: totalFiles,
                            password: password,
                            reporter: swappable)
                    } else if let bridgeFormat = format.bridgeFormat {
                        try self.bridgeService.createArchive(
                            archivePath: buildPath,
                            format: bridgeFormat,
                            sources: items.map(\.path),
                            includeSubfolders: includeSubfolders,
                            preservePaths: preservePaths,
                            compressionLevel: compressionLevel,
                            password: password,
                            progress: self.makeArchiveProgressHandler(
                                progressController: swappable,
                                overrideTotalBytes: totalBytes,
                                overrideTotalFiles: totalFiles,
                                monotonicProgress: monotonic,
                                packDetail: (format: format, level: compressionLevel)
                            )
                        )
                    }

                    DispatchQueue.main.async {
                        if progressController.isSentToQueue {
                            if let id = queueService?.operations.first(where: {
                                $0.archiveParams?.archivePath == archivePath && $0.status == .running
                            })?.id {
                                queueService?.markOperationCompleted(id)
                            }
                        } else {
                            progressController.update(
                                currentFile: L("progress.done"),
                                progress: 1.0,
                                bytesDone: totalBytes,
                                bytesTotal: totalBytes,
                                filesDone: totalFiles,
                                filesTotal: totalFiles
                            )
                            progressController.close()
                        }
                        resumeOnce.resume(returning: false)
                    }
                } catch {
                    DispatchQueue.main.async {
                        if progressController.isSentToQueue {
                            if let id = queueService?.operations.first(where: {
                                $0.archiveParams?.archivePath == archivePath && $0.status == .running
                            })?.id {
                                queueService?.markOperationCompleted(id, error: error)
                            }
                        } else {
                            progressController.close()
                        }
                        resumeOnce.resume(throwing: error)
                    }
                }
            }
        }

        // NTFS: the archive now sits in a temp file — push it onto the volume
        // via libntfs-3g (overwriting any previous version in place), then drop
        // the temp file. Never reached when sent to the queue (disabled for NTFS).
        if ntfsDestination && !sentToQueue {
            // Mount point of the archive's volume — used to delete the sources in
            // this same session (see ntfsDeleteSources / packItems).
            let mountPoint = volumeInfo(
                for: (archivePath as NSString).deletingLastPathComponent)?.mountPoint
            // The build dialog has closed; for a large archive the temp→NTFS
            // transfer is the slow part. Show a real progress with a working
            // Cancel instead of freezing with a dead button.
            let transfer = DialogService.shared.showProgress(
                title: L("progress.packing"),
                message: L("ntfs.transferring"),
                cancelHandler: {}
            )
            transfer.setIndeterminate(true)
            defer { transfer.close() }
            do {
                try await performNTFSOperation(path: archivePath,
                                               operationName: "pack archive") { bridge, relPath in
                    try bridge.copyFile(from: buildPath, to: relPath,
                                        progress: { _, _, _ in },
                                        cancel: { transfer.isCancelled })
                    // "Delete after pack": remove the originals while the volume
                    // is already open, so we don't unmount/remount it twice.
                    // `where src.count > mountPoint.count` guards against a "/"
                    // relative path (a source equal to the volume root) — we must
                    // never ask libntfs-3g to delete the volume root.
                    if let mountPoint {
                        for src in ntfsDeleteSources where src.count > mountPoint.count {
                            try bridge.remove(atPath: String(src.dropFirst(mountPoint.count)))
                        }
                    }
                }
                try? FileManager.default.removeItem(atPath: buildPath)
            } catch {
                try? FileManager.default.removeItem(atPath: buildPath)
                throw error
            }
        }

        return sentToQueue
    }

    /// Extract specific entries out of an archive into a plain folder — what dragging items
    /// OUT of an archive means. Whole-archive unpack is a different operation; here the user
    /// picked individual entries, and the bridge can address them one by one.
    /// Stop whatever the archive engine is doing right now. The progress window's Cancel
    /// button needs this from outside the service.
    func cancelArchiveOperations() {
        bridgeService.cancelArchiveOperations()
    }

    /// Extract chosen entries, saying how far along it is.
    ///
    /// The sizes come from the archive's own index, so the bar moves by bytes rather than by
    /// file count — pulling one big video out of ten small ones otherwise showed a bar frozen at
    /// a tenth for the whole minute it took.
    func extractEntries(_ entryPaths: [String],
                        fromArchive archivePath: String,
                        to destination: String,
                        onProgress: ((_ name: String, _ fraction: Double,
                                      _ bytesDone: Int64, _ bytesTotal: Int64,
                                      _ filesDone: Int, _ filesTotal: Int) -> Void)? = nil,
                        shouldCancel: (() -> Bool)? = nil) throws {
        var files: [(path: String, size: Int64)] = []
        if onProgress != nil, let listed = try? bridgeService.listArchiveEntries(archivePath: archivePath) {
            files = listed.filter { !$0.isDirectory }
                .map { (path: $0.path, size: Int64($0.uncompressedSize)) }
        }
        let planned = Self.plannedArchiveBytes(for: entryPaths, files: files)
        let total = max(planned.values.reduce(Int64(0), +), 1)
        var done: Int64 = 0

        // The reader lays an entry out under its whole archive path, so one dragged out of a
        // folder deep inside the archive landed at destination/that/whole/path — while the
        // conflict question had been asked about destination/<name>. Entries come out into a
        // staging folder beside their target and move in by name: the same place F5 puts them,
        // and a rename on the same volume rather than a second pass over the bytes.
        let staging = (destination as NSString)
            .appendingPathComponent(".fcxl_extract_\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: staging) }

        for (index, entry) in entryPaths.enumerated() {
            if shouldCancel?() == true {
                bridgeService.cancelArchiveOperations()
                throw userCancelledError()
            }
            let name = (entry as NSString).lastPathComponent
            // Announced BEFORE the entry is pulled out: the name in the window has to be the
            // one being worked on, not the one just finished.
            onProgress?(name, Double(done) / Double(total), done, total, index, entryPaths.count)
            try bridgeService.extractArchiveEntry(archivePath: archivePath,
                                                  entryPath: entry,
                                                  destinationPath: staging)
            let extracted = (staging as NSString)
                .appendingPathComponent(Self.normalizedArchiveEntryPath(entry))
            let target = (destination as NSString).appendingPathComponent(name)
            // Replace-or-skip was settled by the caller; whatever is still in the way is to go.
            if FileManager.default.fileExists(atPath: target) {
                try FileManager.default.removeItem(atPath: target)
            }
            try FileManager.default.moveItem(atPath: extracted, toPath: target)
            done += planned[entry] ?? 0
            onProgress?(name, Double(done) / Double(total), done, total,
                        index + 1, entryPaths.count)
        }
    }

    /// Absolute destination paths that already exist and would be clobbered by unpacking
    /// `archivePath`. libarchive takes its overwrite-or-skip decision from a single flag at
    /// start-up, so per-file answers have to be collected BEFORE extraction begins — this is
    /// what lets the caller ask instead of silently overwriting.
    func existingDestinationPaths(forUnpacking archivePath: String,
                                  to destinationPath: String,
                                  createSubfolder: Bool) -> [String] {
        let root = createSubfolder
            ? (destinationPath as NSString).appendingPathComponent(archiveBaseName(for: archivePath))
            : destinationPath
        guard let entries = try? bridgeService.listArchiveEntries(archivePath: archivePath) else {
            return []
        }
        var conflicts: [String] = []
        for entry in entries where !entry.isDirectory {
            let candidate = (root as NSString).appendingPathComponent(entry.path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue {
                conflicts.append(candidate)
            }
        }
        return conflicts
    }

    @MainActor
    func unpackArchive(at path: String,
                       to destinationPath: String,
                       createSubfolder: Bool,
                       overwriteExisting: Bool,
                       password: String = "",
                       queueService: OperationQueueService? = nil,
                       completion: @escaping (Error?) -> Void) {
        let destinationRoot = createSubfolder
            ? (destinationPath as NSString).appendingPathComponent(archiveBaseName(for: path))
            : destinationPath

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destinationRoot, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                completion(
                    NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileWriteFileExistsError,
                        userInfo: [NSLocalizedDescriptionKey: L("error.destinationOccupied", destinationRoot)]
                    )
                )
                return
            }
        } else {
            do {
                try bridgeService.createDirectory(path: destinationRoot)
            } catch {
                completion(error)
                return
            }
        }

        let progressController = DialogService.shared.showProgress(
            title: L("progress.unpacking"),
            message: L("progress.preparing"),
            cancelHandler: { [bridgeService] in
                bridgeService.cancelArchiveOperations()
            }
        )
        let swappable = SwappableProgressReporter(progressController)

        // Setup "Send to queue" button for unpack
        if let queueService {
            let archiveURL = URL(fileURLWithPath: path)
            let archiveItem = FileItem(
                path: path,
                name: archiveURL.lastPathComponent,
                fileExtension: archiveURL.pathExtension,
                size: 0,
                isDirectory: false,
                isHidden: false,
                isSymlink: false,
                permissions: "",
                dateModified: Date()
            )
            progressController.onSendToQueue = {
                let params = ArchiveOperationParams(
                    createSubfolder: createSubfolder,
                    overwriteExisting: overwriteExisting
                )
                let (_, queueReporter) = queueService.adoptRunningOperation(
                    kind: .unpack,
                    items: [archiveItem],
                    destination: destinationPath,
                    archiveParams: params,
                    currentProgress: progressController.lastProgressValue,
                    currentFile: "",
                    bytesDone: progressController.lastBytesDoneValue,
                    bytesTotal: progressController.lastBytesTotalValue,
                    filesDone: progressController.lastFilesDoneValue,
                    filesTotal: progressController.lastFilesTotalValue,
                    onCompletion: { completion(nil) }
                )
                swappable.swap(to: queueReporter)
                return true
            }
            progressController.showSendToQueueButton()
        }

        progressController.update(
            currentFile: URL(fileURLWithPath: path).lastPathComponent,
            progress: 0.01,
            bytesDone: 0,
            bytesTotal: 1,
            filesDone: 0,
            filesTotal: 1
        )

        DispatchQueue.global(qos: .userInitiated).async { [bridgeService] in
            let workerBridgeService = bridgeService
            do {
                let archiveEntries = try workerBridgeService.listArchiveEntries(archivePath: path,
                                                                                password: password)
                let plannedBytesRaw = archiveEntries.reduce(Int64(0)) { partial, entry in
                    partial + (entry.isDirectory ? 0 : Int64(entry.uncompressedSize))
                }
                let plannedFilesRaw = archiveEntries.reduce(0) { partial, entry in
                    partial + (entry.isDirectory ? 0 : 1)
                }
                let plannedBytes = max(plannedBytesRaw, 1)
                let plannedFiles = max(plannedFilesRaw, 1)

                DispatchQueue.main.async {
                    swappable.update(
                        currentFile: URL(fileURLWithPath: path).lastPathComponent,
                        progress: 0.01,
                        bytesDone: 0,
                        bytesTotal: plannedBytes,
                        filesDone: 0,
                        filesTotal: plannedFiles
                    )
                }

                var lastProgress: Double = 0.01
                var lastBytesDone: Int64 = 0
                var lastFilesDone = 0

                try workerBridgeService.extractArchiveAll(
                    archivePath: path,
                    destinationPath: destinationRoot,
                    overwriteExisting: overwriteExisting,
                    password: password
                ) { currentFile, _, bytesDone, _, filesDone, _ in
                    DispatchQueue.main.async {
                        if swappable.isCancelled {
                            workerBridgeService.cancelArchiveOperations()
                        }

                        lastBytesDone = min(max(0, bytesDone), plannedBytes)
                        lastFilesDone = min(max(0, filesDone), plannedFiles)
                        let bytesProgress = Double(lastBytesDone) / Double(plannedBytes)
                        let filesProgress = Double(lastFilesDone) / Double(plannedFiles)
                        lastProgress = max(lastProgress, max(bytesProgress, filesProgress))

                        swappable.update(
                            currentFile: (currentFile as NSString).lastPathComponent,
                            progress: lastProgress,
                            bytesDone: lastBytesDone,
                            bytesTotal: plannedBytes,
                            filesDone: lastFilesDone,
                            filesTotal: plannedFiles
                        )
                    }
                }

                DispatchQueue.main.async {
                    swappable.update(
                        currentFile: L("progress.done"),
                        progress: 1.0,
                        bytesDone: plannedBytes,
                        bytesTotal: plannedBytes,
                        filesDone: plannedFiles,
                        filesTotal: plannedFiles
                    )
                    // If sent to queue, mark completed there; otherwise close dialog
                    if progressController.isSentToQueue {
                        if let id = queueService?.operations.first(where: {
                            $0.kind == .unpack && $0.status == .running
                                && $0.items.first?.path == path
                        })?.id {
                            queueService?.markOperationCompleted(id)
                        }
                    } else {
                        progressController.close()
                        completion(nil)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if progressController.isSentToQueue {
                        if let id = queueService?.operations.first(where: {
                            $0.kind == .unpack && $0.status == .running
                                && $0.items.first?.path == path
                        })?.id {
                            queueService?.markOperationCompleted(id, error: error)
                        }
                    } else {
                        progressController.close()
                        completion(error)
                    }
                }
            }
        }
    }

    // MARK: - Background archive methods (for queue / send-to-queue)

    /// Pack items into an archive on a background thread, reporting progress to the given reporter.
    /// This is the queue-friendly version of `packSingleArchive` — no dialogs, no RunLoop pumping.
    func packSingleArchiveBackground(_ items: [FileItem],
                                     to archivePath: String,
                                     format: ArchiveFormat,
                                     compressionLevel: Int,
                                     preservePaths: Bool,
                                     includeSubfolders: Bool,
                                     password: String = "",
                                     reporter: OperationProgressReporter) throws {
        let sourceStats = items.map { self.calculatePathStats(path: $0.path) }
        let totalBytes = max(sourceStats.reduce(Int64(0)) { $0 + $1.bytes }, 1)
        let totalFiles = max(sourceStats.reduce(0) { $0 + max(1, $1.fileCount) }, 1)

        if reporter.isCancelled { throw userCancelledError() }

        DispatchQueue.main.async {
            reporter.update(
                currentFile: URL(fileURLWithPath: archivePath).lastPathComponent,
                progress: 0.01,
                bytesDone: 0,
                bytesTotal: totalBytes,
                filesDone: 0,
                filesTotal: totalFiles
            )
        }

        let monotonic = MonotonicProgress()

        if format.isBuiltByHdiutil {
            try createDMGImage(sources: items.map(\.path), to: archivePath,
                               compressionLevel: compressionLevel,
                               totalBytes: totalBytes, totalFiles: totalFiles,
                               password: password,
                               reporter: reporter)
        } else if let bridgeFormat = format.bridgeFormat {
            try bridgeService.createArchive(
                archivePath: archivePath,
                format: bridgeFormat,
                sources: items.map(\.path),
                includeSubfolders: includeSubfolders,
                preservePaths: preservePaths,
                compressionLevel: compressionLevel,
                password: password,
                progress: makeArchiveProgressHandler(
                    progressController: reporter,
                    overrideTotalBytes: totalBytes,
                    overrideTotalFiles: totalFiles,
                    monotonicProgress: monotonic,
                    packDetail: (format: format, level: compressionLevel)
                )
            )
        }

        if reporter.isCancelled { throw userCancelledError() }

        DispatchQueue.main.async {
            reporter.update(
                currentFile: L("progress.done"),
                progress: 1.0,
                bytesDone: totalBytes,
                bytesTotal: totalBytes,
                filesDone: totalFiles,
                filesTotal: totalFiles
            )
        }
    }

    /// Unpack an archive on the current thread, reporting progress to the given reporter.
    func unpackArchiveBackground(at path: String,
                                 to destinationPath: String,
                                 createSubfolder: Bool,
                                 overwriteExisting: Bool,
                                 reporter: OperationProgressReporter) throws {
        let destinationRoot = createSubfolder
            ? (destinationPath as NSString).appendingPathComponent(archiveBaseName(for: path))
            : destinationPath

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destinationRoot, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteFileExistsError,
                    userInfo: [NSLocalizedDescriptionKey: L("error.destinationOccupied", destinationRoot)]
                )
            }
        } else {
            try bridgeService.createDirectory(path: destinationRoot)
        }

        let archiveEntries = try bridgeService.listArchiveEntries(archivePath: path)
        let plannedBytes = max(archiveEntries.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : Int64($1.uncompressedSize)) }, 1)
        let plannedFiles = max(archiveEntries.reduce(0) { $0 + ($1.isDirectory ? 0 : 1) }, 1)

        if reporter.isCancelled { throw userCancelledError() }

        DispatchQueue.main.async {
            reporter.update(
                currentFile: URL(fileURLWithPath: path).lastPathComponent,
                progress: 0.01,
                bytesDone: 0,
                bytesTotal: plannedBytes,
                filesDone: 0,
                filesTotal: plannedFiles
            )
        }

        var lastProgress: Double = 0.01

        try bridgeService.extractArchiveAll(
            archivePath: path,
            destinationPath: destinationRoot,
            overwriteExisting: overwriteExisting
        ) { currentFile, _, bytesDone, _, filesDone, _ in
            if reporter.isCancelled {
                self.bridgeService.cancelArchiveOperations()
            }
            let clampedBytesDone = min(max(0, bytesDone), plannedBytes)
            let clampedFilesDone = min(max(0, filesDone), plannedFiles)
            let bytesProgress = Double(clampedBytesDone) / Double(plannedBytes)
            let filesProgress = Double(clampedFilesDone) / Double(plannedFiles)
            lastProgress = max(lastProgress, max(bytesProgress, filesProgress))

            DispatchQueue.main.async {
                reporter.update(
                    currentFile: (currentFile as NSString).lastPathComponent,
                    progress: lastProgress,
                    bytesDone: clampedBytesDone,
                    bytesTotal: plannedBytes,
                    filesDone: clampedFilesDone,
                    filesTotal: plannedFiles
                )
            }
        }

        if reporter.isCancelled { throw userCancelledError() }

        DispatchQueue.main.async {
            reporter.update(
                currentFile: L("progress.done"),
                progress: 1.0,
                bytesDone: plannedBytes,
                bytesTotal: plannedBytes,
                filesDone: plannedFiles,
                filesTotal: plannedFiles
            )
        }
    }

    /// Delete entries from archive on the current thread.
    func deleteEntriesFromArchiveBackground(_ items: [FileItem],
                                            archivePath: String,
                                            reporter: OperationProgressReporter) throws {
        let entryPaths = items.map { normalizeArchiveEntryPath($0.path) }

        DispatchQueue.main.async {
            reporter.update(
                currentFile: L("progress.preparing"),
                progress: 0.01,
                bytesDone: 0,
                bytesTotal: 1,
                filesDone: 0,
                filesTotal: max(items.count, 1)
            )
        }

        try bridgeService.deleteEntriesFromArchive(
            archivePath: archivePath,
            entryPaths: entryPaths,
            progress: makeArchiveProgressHandler(progressController: reporter)
        )

        if reporter.isCancelled { throw userCancelledError() }
    }

    /// Rename entry in archive on the current thread.
    func renameEntryInArchiveBackground(_ item: FileItem,
                                        archivePath: String,
                                        to newName: String,
                                        reporter: OperationProgressReporter) throws {
        // Same validation as the foreground path — a queued rename must not be
        // able to smuggle "/" or ".." into the new entry name (path traversal:
        // the rebuild path would write outside the temp dir).
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedName.contains("/"), trimmedName != ".." else {
            throw NSError(
                domain: "FileOperationsService",
                code: NSFileWriteInvalidFileNameError,
                userInfo: [NSLocalizedDescriptionKey: L("rename.slashError")]
            )
        }
        let oldEntryPath = normalizeArchiveEntryPath(item.path)
        let parentPath = (oldEntryPath as NSString).deletingLastPathComponent
        let newEntryPath = parentPath.isEmpty ? trimmedName : "\(parentPath)/\(trimmedName)"

        DispatchQueue.main.async {
            reporter.update(
                currentFile: item.name,
                progress: 0.01,
                bytesDone: 0,
                bytesTotal: 1,
                filesDone: 0,
                filesTotal: 1
            )
        }

        try bridgeService.renameEntryInArchive(
            archivePath: archivePath,
            oldEntryPath: oldEntryPath,
            newEntryPath: newEntryPath,
            progress: makeArchiveProgressHandler(progressController: reporter)
        )

        if reporter.isCancelled { throw userCancelledError() }
    }

    func uniqueCopyPathForDestination(_ path: String) -> String {
        uniqueCopyPath(from: path)
    }

    @MainActor
    private func transferItems(title: String,
                               _ items: [FileItem],
                               to destinationPath: String,
                               move: Bool,
                               queueService: OperationQueueService? = nil,
                               externalReporter: OperationProgressReporter? = nil,
                               onCompletion: (() -> Void)? = nil,
                               onDialogsDone: (() -> Void)? = nil,
                               ntfsInfo: NtfsWriteInfo? = nil,
                               onProgress: ((Double, String) -> Void)? = nil,
                               shouldCancel: (() -> Bool)? = nil,
                               onConflict rawOnConflict: @escaping (String, String) -> ConflictResolution) async throws {
        // Undo watches from the side: an operation is honestly reversible only if nobody was
        // asked about a conflict — a replace destroyed something, a skip made the record lie,
        // a merge mixed new content into an existing folder. One flag, set on ANY consultation
        // (top-level on the main thread or merge expansion in the background), decides it.
        let conflictConsulted = OSAllocatedUnfairLock(initialState: false)
        let pendingUndoRecord = OSAllocatedUnfairLock<UndoJournal.Record?>(initialState: nil)
        let onConflict: (String, String) -> ConflictResolution = { source, dest in
            conflictConsulted.withLock { $0 = true }
            return rawOnConflict(source, dest)
        }
        // Phase 1 (main thread, FAST): resolve top-level conflicts and flag folder
        // merges. When a source folder lands on an EXISTING folder we DON'T walk it here
        // — we tag it `isMerge` and expand it into per-file transfers later, on a
        // background thread (Phase 1.5), so a huge tree never freezes the UI. Files and
        // brand-new folders resolve their conflict right here.
        var transfers: [(sourcePath: String, destPath: String, displayName: String, isMerge: Bool)] = []

        cplog("[XFER] transferItems START move=\(move) destinationPath=\(destinationPath) items=\(items.map(\.name))")
        for item in items {
            var dest = (destinationPath as NSString).appendingPathComponent(item.name)
            if dest == item.path {
                cplog("[XFER] item=\(item.name) dest==source (same dir) → uniqueCopyPath")
                if move { continue }  // Can't move file onto itself
                // Copy to same directory → create duplicate with unique name
                dest = uniqueCopyPath(from: dest)
            } else {
                // Resolve existence by exact bytes, NOT FileManager.fileExists — the
                // latter re-normalizes the path (NFD) and a normalization-sensitive SMB
                // server then misses a name it stored precomposed (NFC). Missing that
                // would wrongly treat an existing folder as new (silent duplicate) or an
                // existing folder-vs-folder as a plain conflict (Replace = delete it all).
                let destForm = DarwinFileOperations.existingPathForm(dest)
                cplog("[XFER] item=\(item.name) dest=\(dest) exists=\(destForm.exists) destIsDir=\(destForm.isDir)")
                if destForm.exists {
                    let itemIsDir = DarwinFileOperations.existingPathForm(item.path).isDir
                    if itemIsDir && destForm.isDir {
                        // Two existing folders → merge contents (Phase 1.5 recurses in
                        // the background). Use the dest's real on-disk name form.
                        cplog("[XFER] item=\(item.name) folder-merge (both dirs) → no dialog")
                        transfers.append((item.path, destForm.path, item.name, true))
                        continue
                    }
                    cplog("[XFER] item=\(item.name) CONFLICT → asking onConflict")
                    switch onConflict(item.path, destForm.path) {
                    case .replace:
                        // On a read-only NTFS destination we can't delete via
                        // FileManager (the macOS mount is read-only). The libntfs-3g
                        // copy overwrites by itself — copy_file deletes any existing
                        // file before creating the new one — so skip the removal here.
                        if ntfsInfo == nil {
                            try FileManager.default.removeItem(atPath: destForm.path)
                        }
                    case .copy:
                        dest = uniqueCopyPath(from: dest)
                    case .skip:
                        continue
                    case .cancel:
                        throw userCancelledError()
                    }
                }
            }
            transfers.append((item.path, dest, item.name, false))
        }
        guard !transfers.isEmpty else { return }
        let startedAt = Date()
        Self.opsLog.info(
            "transfer.start mode=\(move ? "move" : "copy", privacy: .public) topLevelItems=\(transfers.count, privacy: .public) destination=\(destinationPath, privacy: .public)"
        )

        // Dock tile progress
        DockProgressManager.shared.beginOperation()

        // Show progress dialog immediately — no stats pre-calculation on main thread.
        // Unless the QUEUE is running this: it handed in its own reporter, its row is the
        // progress surface, and a modal window on top of it is exactly what pressing
        // "В очередь" asked to avoid.
        let progressController: ProgressController?
        if externalReporter == nil {
            let pc = DialogService.shared.showProgress(
                title: title,
                message: L("progress.preparing"),
                cancelHandler: nil
            )
            pc.update(
                currentFile: L("progress.preparing"),
                progress: 0,
                bytesDone: 0,
                bytesTotal: 0,
                filesDone: 0,
                filesTotal: transfers.count
            )
            progressController = pc
        } else {
            progressController = nil
        }
        defer {
            if let progressController, !progressController.isSentToQueue {
                progressController.close()
            }
        }

        // Shared progress state — written by background thread, read by timer on main thread.
        // NSLock protects concurrent access.
        let stateLock = NSLock()
        var sharedFile = L("progress.preparing")
        var sharedProgress: Double = 0
        var sharedBytesDone: Int64 = 0
        var sharedBytesTotal: Int64 = 0
        var sharedFilesDone = 0
        var sharedFilesTotal = transfers.count
        // Target reporter: the queue's own when it runs this; otherwise the window,
        // swapped to a queue reporter if "В очередь" is pressed mid-flight.
        var activeReporter: OperationProgressReporter = externalReporter ?? progressController!

        // Timer fires on main thread every 50ms — reads shared state, updates UI.
        // Runs in .common mode so it works inside modal session.
        let uiTimer = Timer(timeInterval: 0.05, repeats: true) { _ in
            stateLock.lock()
            let f = sharedFile; let p = sharedProgress
            let bd = sharedBytesDone; let bt = sharedBytesTotal
            let fd = sharedFilesDone; let ft = sharedFilesTotal
            let reporter = activeReporter
            stateLock.unlock()
            Task { @MainActor in
                reporter.update(
                    currentFile: f, progress: p,
                    bytesDone: bd, bytesTotal: bt,
                    filesDone: fd, filesTotal: ft
                )
                DockProgressManager.shared.updateProgress(p)
            }
        }
        RunLoop.main.add(uiTimer, forMode: .common)
        // Timer is NOT invalidated in defer — it continues for queue operations.
        // It self-invalidates when the background work finishes (see finish closure).

        // Thread-safe cancel flag — set by main thread (timer), read by background thread.
        // Avoids DispatchQueue.main.sync from background which could deadlock.
        let cancelLock = NSLock()
        var cancelFlag = false

        let cancelCheckTimer = Timer(timeInterval: 0.05, repeats: true) { _ in
            let isCancelled = (progressController?.isCancelled ?? false) || shouldCancel?() == true
            if isCancelled {
                cancelLock.lock()
                cancelFlag = true
                cancelLock.unlock()
            }
        }
        RunLoop.main.add(cancelCheckTimer, forMode: .common)

        defer {
            // Success is the only road here with a stashed record — every failure path threw
            // out of the continuation above and the stash stayed empty.
            if let record = pendingUndoRecord.withLock({ $0 }) {
                if Thread.isMainThread {
                    MainActor.assumeIsolated { UndoJournal.shared.record(record) }
                } else {
                    Task { @MainActor in UndoJournal.shared.record(record) }
                }
            }
        }
        // A NAMED function, not a closure: with the window now optional this body crossed
        // the compiler's type-checking budget as one expression and the build died of
        // "unable to type-check in reasonable time". Naming it splits the work.
        func startTransferWork(_ continuation: CheckedContinuation<Void, Error>) {
            let resumeOnce = ContinuationResumeOnce(continuation)

            // "В очередь" button
            if let queueService, let progressController {
                progressController.onSendToQueue = {
                    let kind: OperationKind = move ? .move : .copy
                    let (_, queueReporter) = queueService.adoptRunningOperation(
                        kind: kind,
                        items: items,
                        destination: destinationPath,
                        archiveParams: nil,
                        currentProgress: progressController.lastProgressValue,
                        currentFile: "",
                        bytesDone: progressController.lastBytesDoneValue,
                        bytesTotal: progressController.lastBytesTotalValue,
                        filesDone: progressController.lastFilesDoneValue,
                        filesTotal: progressController.lastFilesTotalValue,
                        onCompletion: onCompletion
                    )
                    // Swap timer target to queue reporter
                    stateLock.lock()
                    activeReporter = queueReporter
                    stateLock.unlock()
                    // Also listen for cancel/pause from queue reporter
                    cancelCheckTimer.invalidate()
                    resumeOnce.resume(returning: ())
                    return true
                }
                progressController.showSendToQueueButton()
            }

            // Mark NTFS volume as being written — suppresses "disk removed" alerts during operation.
            // Remember destination path so we can navigate back after remount.
            if let ntfsInfo = ntfsInfo {
                FileOperationsService.ntfsWritingVolumes.insert(ntfsInfo.mountPoint)
                FileOperationsService.ntfsRestorePath = destinationPath
            }

            // Named for the same reason as startTransferWork: one expression, too much type
            // inference. The dispatch call at the end is now trivially checkable.
            func transferInBackground() {
                let finish: (Error?) -> Void = { error in
                    DispatchQueue.main.async {
                        uiTimer.invalidate()
                        cancelCheckTimer.invalidate()
                        DockProgressManager.shared.endOperation()

                        let opName = move ? L("operation.move") : L("operation.copy")
                        let elapsed = Date().timeIntervalSince(startedAt)
                        OperationLogService.shared.log(
                            operationType: opName,
                            itemCount: items.count,
                            sourcePath: items.first?.path ?? "",
                            destinationPath: destinationPath,
                            success: error == nil,
                            errorMessage: error?.localizedDescription,
                            duration: elapsed
                        )
                        if error == nil {
                            NotificationService.shared.notifyCopyMoveCompleted(
                                operationName: opName,
                                itemCount: items.count,
                                destination: destinationPath
                            )
                        }

                        let wasAdopted: Bool = progressController?.isSentToQueue ?? false
                        if wasAdopted {
                            let kind: OperationKind = move ? .move : .copy
                            if let id = queueService?.operations.first(where: {
                                $0.kind == kind && $0.status == .running
                            })?.id {
                                if let error {
                                    queueService?.markOperationCompleted(id, error: error)
                                } else {
                                    queueService?.markOperationCompleted(id)
                                }
                            }
                        } else {
                            onCompletion?()
                        }
                        if let error {
                            resumeOnce.resume(throwing: error)
                        } else {
                            resumeOnce.resume(returning: ())
                        }
                    }
                }

                let cancelled = {
                    cancelLock.lock()
                    let val = cancelFlag
                    cancelLock.unlock()
                    // Also check queue reporter cancel
                    if !val {
                        stateLock.lock()
                        let r = activeReporter
                        stateLock.unlock()
                        return r.isCancelled
                    }
                    return val
                }

                // Blocks THIS background thread while the operation is paused, then
                // reports cancellation. Passed to copyfile's callback so pause takes
                // effect MID-file (the copy stalls at the next progress tick) rather than
                // only between files. Returns true only when actually cancelled.
                let pausableCancel: () -> Bool = {
                    stateLock.lock()
                    let r = activeReporter
                    stateLock.unlock()
                    if r.waitWhilePaused() { return true }
                    return cancelled()
                }

                // ── Phase 1.5 (background): expand any folder-merge markers into a flat
                // list of per-file transfers. Walking the tree here (off the main thread)
                // keeps the progress window responsive; each overlapping file's conflict is
                // resolved by `onConflict`, which hops to the main thread for its modal
                // dialog and remembers an "apply to all" answer (see copyItems/moveItems).
                var work: [(sourcePath: String, destPath: String, displayName: String)] = []
                func expandMerge(_ src: String, into dst: String) throws {
                    for child in (try? FileManager.default.contentsOfDirectory(atPath: src)) ?? [] {
                        if cancelled() { throw self.userCancelledError() }
                        // Resolve each side to the Unicode-normalization form that
                        // actually exists — SMB servers are normalization-sensitive, so
                        // the name a listing returned can still fail a by-name lookup
                        // (e.g. "й" precomposed vs decomposed). Also gives correct
                        // isDirectory answers, which drive the merge recursion.
                        let (cs, _, csIsDir) = DarwinFileOperations.existingPathForm(
                            (src as NSString).appendingPathComponent(child))
                        let (cd, cdExists, cdIsDir) = DarwinFileOperations.existingPathForm(
                            (dst as NSString).appendingPathComponent(child))
                        if csIsDir && cdExists && cdIsDir {
                            try expandMerge(cs, into: cd)            // two folders → keep merging
                        } else if cdExists {
                            switch onConflict(cs, cd) {
                            case .replace:
                                if ntfsInfo == nil { try? FileManager.default.removeItem(atPath: cd) }
                                work.append((cs, cd, child))
                            case .copy:
                                work.append((cs, self.uniqueCopyPath(from: cd), child))
                            case .skip:
                                continue
                            case .cancel:
                                throw self.userCancelledError()
                            }
                        } else {
                            work.append((cs, cd, child))            // missing at dest → copy in
                        }
                    }
                }
                do {
                    for t in transfers {
                        if t.isMerge {
                            try expandMerge(t.sourcePath, into: t.destPath)
                        } else {
                            work.append((t.sourcePath, t.destPath, t.displayName))
                        }
                    }
                } catch {
                    finish(error)
                    return
                }
                // Every question that could be asked HAS been asked: top-level conflicts in
                // Phase 1, merge conflicts just above. From here on it is pure byte moving,
                // and the queue may safely start the next operation alongside this one.
                DispatchQueue.main.async { onDialogsDone?() }
                guard !work.isEmpty else { finish(nil); return }

                // --- Optimized: skip stats for same-volume operations (they are instant). ---
                var itemStats: [(bytes: Int64, files: Int)] = []
                var totalBytes: Int64 = 0
                var totalFiles = 0

                // Pre-check which transfers are same-volume (instant) vs cross-volume.
                var isSameVolume: [Bool] = []
                for transfer in work {
                    isSameVolume.append(
                        DarwinFileOperations.sameVolume(
                            source: transfer.sourcePath,
                            destination: transfer.destPath
                        )
                    )
                }

                let hasCrossVolume = isSameVolume.contains(false)

                if hasCrossVolume {
                    // Only calculate stats for cross-volume transfers (need progress tracking).
                    for (index, transfer) in work.enumerated() {
                        if cancelled() {
                            finish(self.userCancelledError())
                            return
                        }
                        if isSameVolume[index] {
                            // Same-volume: instant, use placeholder stats.
                            itemStats.append((bytes: 0, files: 1))
                        } else {
                            let s = self.calculatePathStats(path: transfer.sourcePath)
                            itemStats.append((bytes: s.bytes, files: max(s.fileCount, 1)))
                        }
                    }
                    totalBytes = itemStats.reduce(Int64(0)) { $0 + $1.bytes }
                    totalFiles = itemStats.reduce(0) { $0 + $1.files }
                } else {
                    // All same-volume: no stats needed, operations are instant.
                    for _ in work {
                        itemStats.append((bytes: 0, files: 1))
                    }
                    totalFiles = work.count
                }

                Self.opsLog.info(
                    "transfer.scan mode=\(move ? "move" : "copy", privacy: .public) totalBytes=\(totalBytes, privacy: .public) totalFiles=\(totalFiles, privacy: .public) crossVolume=\(hasCrossVolume, privacy: .public)"
                )

                stateLock.lock()
                sharedBytesTotal = totalBytes
                sharedFilesTotal = totalFiles
                stateLock.unlock()

                var bytesDone: Int64 = 0
                var filesDone = 0
                // A single unreadable file must not abort the whole operation (e.g. SMB
                // files whose names macOS lists but cannot open by name). Collect the
                // failures, keep copying, report them together at the end.
                var failedItems: [(name: String, reason: String)] = []

                for (index, transfer) in work.enumerated() {
                    // Honor PAUSE/cancel on this background worker before each file.
                    if pausableCancel() {
                        finish(self.userCancelledError())
                        return
                    }

                    let progress = totalBytes > 0
                        ? Double(bytesDone) / Double(totalBytes)
                        : Double(filesDone) / Double(max(totalFiles, 1))
                    let label = move
                        ? L("progress.movingItem", transfer.displayName)
                        : L("progress.copyingItem", transfer.displayName)
                    stateLock.lock()
                    sharedFile = transfer.displayName
                    sharedProgress = max(progress, 0.01)
                    sharedBytesDone = bytesDone
                    sharedFilesDone = filesDone
                    stateLock.unlock()
                    DispatchQueue.main.async {
                        onProgress?(progress, label)
                    }

                    // When merging into an existing folder we copy files/subfolders one by
                    // one; the destination's parent folder must exist first (a single
                    // whole-tree copyfile used to create intermediates for us). Create it if
                    // it's missing — otherwise copyfile fails with ENOENT.
                    if ntfsInfo == nil {
                        let destParent = (transfer.destPath as NSString).deletingLastPathComponent
                        if !FileManager.default.fileExists(atPath: destParent) {
                            try? FileManager.default.createDirectory(
                                atPath: destParent, withIntermediateDirectories: true)
                        }
                    }

                    do {
                        if let ntfsInfo = ntfsInfo {
                            // ── NTFS write via libntfs-3g ───────────────────────────
                            try Self.performNTFSTransfer(
                                sourcePath: transfer.sourcePath,
                                destPath: transfer.destPath,
                                ntfsInfo: ntfsInfo,
                                move: move,
                                bytesDone: bytesDone,
                                totalBytes: totalBytes,
                                filesDone: filesDone,
                                totalFiles: totalFiles,
                                stateLock: stateLock,
                                sharedProgressPtr: &sharedProgress,
                                sharedBytesDonePtr: &sharedBytesDone,
                                cancelled: cancelled
                            )
                        } else if move {
                            // DarwinFileOperations.move: rename() for same-volume (instant O(1)),
                            // copyfile + removefile for cross-volume. Cross-volume needs the
                            // same byte-level progress the copy path uses — otherwise a big
                            // file's bar sits at ~1% until the whole copy finishes.
                            let baseBytesDone = bytesDone
                            try DarwinFileOperations.move(
                                from: transfer.sourcePath,
                                to: transfer.destPath,
                                progress: hasCrossVolume ? { copiedBytes, _, _ in
                                    stateLock.lock()
                                    let currentBytesDone = baseBytesDone + copiedBytes
                                    let p = totalBytes > 0
                                        ? Double(currentBytesDone) / Double(totalBytes)
                                        : Double(filesDone) / Double(max(totalFiles, 1))
                                    sharedProgress = min(max(p, 0.01), 0.99)
                                    sharedBytesDone = currentBytesDone
                                    stateLock.unlock()
                                } : nil,
                                shouldCancel: pausableCancel
                            )
                        } else {
                            // DarwinFileOperations.copy: clonefile() for APFS (instant CoW),
                            // copyfile() with progress for non-APFS/cross-volume.
                            let baseBytesDone = bytesDone
                            try DarwinFileOperations.copy(
                                from: transfer.sourcePath,
                                to: transfer.destPath,
                                progress: hasCrossVolume ? { copiedBytes, _, _ in
                                    stateLock.lock()
                                    let currentBytesDone = baseBytesDone + copiedBytes
                                    let p = totalBytes > 0
                                        ? Double(currentBytesDone) / Double(totalBytes)
                                        : Double(filesDone) / Double(max(totalFiles, 1))
                                    sharedProgress = min(max(p, 0.01), 0.99)
                                    sharedBytesDone = currentBytesDone
                                    stateLock.unlock()
                                } : nil,
                                shouldCancel: pausableCancel
                            )
                        }
                        bytesDone += itemStats[index].bytes
                        filesDone += itemStats[index].files
                    } catch {
                        let nsError = error as NSError
                        if nsError.domain == NSCocoaErrorDomain,
                           nsError.code == CocoaError.userCancelled.rawValue {
                            finish(self.userCancelledError())
                            return
                        }
                        Self.opsLog.error(
                            // Paths and the message name the user's files — private.
                            "transfer.fail mode=\(move ? "move" : "copy", privacy: .public) source=\(transfer.sourcePath) destination=\(transfer.destPath) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) message=\(nsError.localizedDescription)"
                        )
                        failedItems.append((transfer.displayName, nsError.localizedDescription))
                        // Count the skipped item so overall progress still reaches 100%.
                        bytesDone += itemStats[index].bytes
                        filesDone += itemStats[index].files
                    }
                }

                // Merge-MOVE aftermath: the per-file expansion moved the folder's
                // CONTENTS, so the (now empty) source directory tree stays behind —
                // remove empty dirs bottom-up. Only empty ones are touched: files the
                // user skipped (or that failed) keep their parent folders alive.
                if move {
                    for t in transfers where t.isMerge {
                        self.removeEmptyDirectoryTree(t.sourcePath)
                    }
                }

                if !failedItems.isEmpty {
                    let shown = failedItems.prefix(5).map(\.name).joined(separator: "\n")
                    let more = failedItems.count > 5 ? "\n…" : ""
                    let message = String(format: L("transfer.partialFailure"), failedItems.count)
                        + "\n" + shown + more
                        + "\n\n" + (failedItems.first?.reason ?? "")
                    finish(NSError(
                        domain: "com.fcxl.fileops", code: 1001,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    ))
                    return
                }
                stateLock.lock()
                sharedFile = L("progress.done")
                sharedProgress = 1.0
                sharedBytesDone = totalBytes
                sharedFilesDone = totalFiles
                stateLock.unlock()
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
                Self.opsLog.info(
                    "transfer.done mode=\(move ? "move" : "copy", privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) totalBytes=\(totalBytes, privacy: .public) totalFiles=\(totalFiles, privacy: .public)"
                )

                // Cmd+Z learns of this operation only when walking it back is honest: every
                // file went where the plan said (no failures — checked above), nothing asked
                // about conflicts, nothing merged into an existing folder, nothing went through
                // the NTFS side door, and the operation was not handed to the background queue
                // (a queued transfer finishes long after this code has returned). The record is
                // STASHED here and filed after the continuation lands, so that when the caller's
                // await returns, the journal already knows.
                // A queue-run transfer (externalReporter != nil) is out for the same reason
                // an adopted one is: it finishes long after the caller's await returned.
                if ntfsInfo == nil,
                   externalReporter == nil,
                   !conflictConsulted.withLock({ $0 }),
                   !transfers.contains(where: \.isMerge),
                   progressController?.isSentToQueue != true {
                    let record: UndoJournal.Record = move
                        ? .moved(pairs: transfers.map { ($0.sourcePath, $0.destPath) })
                        : .copied(sources: transfers.map(\.sourcePath),
                                  destinationDir: destinationPath,
                                  created: transfers.map(\.destPath))
                    pendingUndoRecord.withLock { $0 = record }
                }

                finish(nil)
            }
            DispatchQueue.global(qos: .userInitiated).async { transferInBackground() }
        }
        try await withCheckedThrowingContinuation { startTransferWork($0) }
    }

    /// Recursively removes EMPTY directories bottom-up. Directories that still have
    /// any content are left untouched (so files the user skipped — or that failed to
    /// move — keep their parent folders). Symlinked directories are treated as
    /// content and never followed.
    private func removeEmptyDirectoryTree(_ path: String) {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        for child in children {
            let childPath = (path as NSString).appendingPathComponent(child)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: childPath, isDirectory: &isDir),
                  isDir.boolValue,
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: childPath)) == nil
            else { continue }
            removeEmptyDirectoryTree(childPath)
        }
        if let remaining = try? FileManager.default.contentsOfDirectory(atPath: path), remaining.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func fileSize(atPath path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func calculatePathStats(path: String, timeBudget: TimeInterval = 0) -> PathStats {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return PathStats(bytes: 0, fileCount: 0)
        }
        if !isDirectory.boolValue {
            return PathStats(bytes: fileSize(atPath: path), fileCount: 1)
        }

        var totalBytes: Int64 = 0
        var totalFiles = 0
        var entryCount = 0
        let deadline = timeBudget > 0 ? CFAbsoluteTimeGetCurrent() + timeBudget : 0
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        if let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: nil
        ) {
            for case let entryURL as URL in enumerator {
                entryCount += 1
                if Task.isCancelled { break }
                if deadline > 0, entryCount & 0x3F == 0, CFAbsoluteTimeGetCurrent() > deadline { break }
                let values = try? entryURL.resourceValues(forKeys: keys)
                let isRegular = values?.isRegularFile ?? false
                let isDirectory = values?.isDirectory ?? false
                let isSymlink = values?.isSymbolicLink ?? false

                if isDirectory && isSymlink {
                    enumerator.skipDescendants()
                    continue
                }
                if !isRegular {
                    continue
                }
                totalFiles += 1
                totalBytes += Int64(values?.fileSize ?? 0)
            }
        }
        return PathStats(bytes: totalBytes, fileCount: totalFiles)
    }

    /// Recursive size and counts of a folder.
    ///
    /// A POSIX `fts` walk rather than `FileManager.enumerator`: the enumerator hands back URLs and
    /// a resource-value lookup per entry, while `fts` already carries the `stat` it had to do
    /// anyway. Measured over a 293 061-file tree: 3.9 s against 5.3 s.
    ///
    /// `isCancelled` is consulted as it goes, so closing the window stops the syscalls instead of
    /// leaving them running for a result nobody will read. `progress` is called every so often with
    /// the running total, which is what lets a window count up while it works.
    static func directoryStats(path: String,
                               isCancelled: () -> Bool = { false },
                               progress: (DirectoryStats) -> Void = { _ in }) -> DirectoryStats {
        var stats = DirectoryStats()
        var seen = 0

        return path.withCString { cPath -> DirectoryStats in
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(cPath), nil]
            defer { free(argv[0]) }
            // FTS_PHYSICAL: never follow a symlink, so a link loop cannot make this run forever
            // and a linked folder is not counted twice.
            guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return stats }
            defer { fts_close(fts) }

            while let node = fts_read(fts) {
                switch Int32(node.pointee.fts_info) {
                case FTS_F:
                    stats.filesCount += 1
                    if let st = node.pointee.fts_statp { stats.totalBytes += Int64(st.pointee.st_size) }
                case FTS_D:
                    // Level 0 is the folder being measured, not something inside it.
                    if node.pointee.fts_level > 0 { stats.directoriesCount += 1 }
                default:
                    break   // symlinks, unreadable entries, devices — nothing to add
                }

                seen += 1
                if seen & 0x3FF == 0 {          // every 1024 entries
                    if isCancelled() { return stats }
                    progress(stats)
                }
            }
            return stats
        }
    }

    private func archiveBaseName(for path: String) -> String {
        archiveBaseName(from: URL(fileURLWithPath: path).lastPathComponent)
    }

    /// Strips a known archive extension from a file name (single source of truth;
    /// also used by the UI to suggest a default archive name).
    func archiveBaseName(from fileName: String) -> String {
        let lower = fileName.lowercased()
        let suffixes = [
            ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz",
            ".tar.zst", ".tzst", ".tar.lz4", ".tar.lz", ".tlz",
            ".zip", ".tar", ".gz", ".bz2", ".xz", ".7z",
            ".zst", ".lz4", ".lz", ".iso", ".dmg"
        ]
        for suffix in suffixes where lower.hasSuffix(suffix) && lower.count > suffix.count {
            return String(fileName.dropLast(suffix.count))
        }
        let nsName = fileName as NSString
        if nsName.pathExtension.isEmpty {
            return fileName
        }
        return nsName.deletingPathExtension
    }

    private func archiveMutationMode(for archivePath: String) -> ArchiveMutationMode {
        let lowercased = archivePath.lowercased()
        if lowercased.hasSuffix(".zip") {
            return .zipFastPath
        }
        return .rebuild
    }

    @MainActor
    private func confirmArchiveRebuild(operationTitle: String, archivePath: String) async -> Bool {
        let archiveSize = max(fileSize(atPath: archivePath), 0)
        let sizeText = ByteText.file(archiveSize)
        let formatLabel = (archivePath as NSString).pathExtension.uppercased()
        let formatText = formatLabel.isEmpty ? L("archive.format.unknown") : formatLabel
        let message = L("archive.repackWarning.message", formatText, sizeText)

        // Called from async archive mutations (parked main queue) → async runloop bridge.
        return await fcxlPresentModalAsync {
            DialogService.shared.showConfirmation(
                title: L("archive.repackWarning.title"),
                message: message
            )
        }
    }

    @MainActor
    private func runBlockingOperation(progressController: ProgressController,
                                      work: @escaping () throws -> Void,
                                      onPulse: ((Double) -> Void)? = nil) throws {
        // Flush RunLoop so the progress panel renders before blocking work starts
        RunLoop.main.run(mode: .common, before: Date(timeIntervalSinceNow: 0.05))

        let operationGroup = DispatchGroup()
        let lock = NSLock()
        var result: Result<Void, Error>?

        operationGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { operationGroup.leave() }
            let workResult: Result<Void, Error>
            do {
                try work()
                workResult = .success(())
            } catch {
                workResult = .failure(error)
            }

            lock.lock()
            result = workResult
            lock.unlock()
        }

        var pulse: Double = 0.02
        while operationGroup.wait(timeout: .now()) == .timedOut {
            if let onPulse {
                onPulse(min(pulse, 0.95))
                pulse = min(pulse + 0.01, 0.95)
            }
            // .common mode ensures UI stays responsive during modal panels/sheets.
            RunLoop.main.run(mode: .common, before: Date(timeIntervalSinceNow: 0.02))
        }

        lock.lock()
        let finalResult = result
        lock.unlock()

        if case let .failure(error) = finalResult {
            throw error
        }
    }

    private func uniqueCopyPath(from path: String) -> String {
        let fileURL = URL(fileURLWithPath: path)
        let parentPath = fileURL.deletingLastPathComponent().path
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension
        var index = 1

        while true {
            let candidateName: String
            if ext.isEmpty {
                candidateName = "\(baseName) (\(index))"
            } else {
                candidateName = "\(baseName) (\(index)).\(ext)"
            }
            let candidatePath = (parentPath as NSString).appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidatePath) {
                return candidatePath
            }
            index += 1
        }
    }

    /// Shared archive progress callback factory.
    /// - Parameters:
    ///   - progressController: the progress reporter to update
    ///   - overrideTotalBytes: optional known total bytes (used by pack when pre-calculated)
    ///   - overrideTotalFiles: optional known total files
    ///   - progressStateLock: optional lock for monotonic progress (used by pack)
    ///   - lastProgress: optional pointer to monotonically-increasing progress value
    private final class MonotonicProgress {
        private let lock = NSLock()
        private var value: Double = 0.01
        func advance(to newValue: Double) -> Double {
            lock.lock()
            value = max(value, newValue)
            let result = value
            lock.unlock()
            return result
        }
    }

    /// The bar fraction for archive operations: bytes when the operation knows them, files only
    /// as a fallback — never the max of the two. libarchive counts the entry it is STILL WRITING
    /// as done, so packing one big file made the files fraction 1/1 from the first callback and
    /// the bar sat at 100% while gigabytes were still to go.
    nonisolated static func archiveBarFraction(bytesDone: Int64, bytesTotal: Int64,
                                               filesDone: Int, filesTotal: Int) -> Double {
        // A total of 1 is the core's "unknown" (it normalizes every total to at least 1) — and an
        // archive of empty files genuinely has no bytes to count. Both fall back to files.
        if bytesTotal > 1 {
            return Double(min(max(bytesDone, 0), bytesTotal)) / Double(bytesTotal)
        }
        let total = max(filesTotal, 1)
        return Double(min(max(filesDone, 0), total)) / Double(total)
    }

    /// The detail line of the pack progress dialog: what is being made, with what settings, and —
    /// once enough input has gone through for the ratio to mean anything — how big the result is
    /// shaping up to be. The compressed byte count comes straight from libarchive through the
    /// progress callback, so no file is ever statted for this.
    nonisolated static func packProgressDetail(format: ArchiveFormat, compressionLevel: Int,
                                               compressedBytes: Int64,
                                               uncompressedDone: Int64,
                                               uncompressedTotal: Int64) -> String {
        // Containers with no compressor (TAR, ISO) — showing a level would be a lie.
        var text = format.supportsCompressionLevel
            ? L("progress.pack.settings", format.rawValue, compressionLevel)
            : format.rawValue
        // Below this much input the ratio is mostly container-header noise, and an estimate
        // built on it would swing wildly before settling down.
        if compressedBytes > 0, uncompressedDone >= 8 * 1024 * 1024, uncompressedTotal > 1 {
            let ratio = Double(compressedBytes) / Double(uncompressedDone)
            let estimated = Int64((ratio * Double(uncompressedTotal)).rounded())
            let percent = Int((ratio * 100).rounded())
            text += " · " + L("progress.pack.estimate", percent,
                              ByteText.file(estimated))
        }
        return text
    }

    /// Emits once per bucket change. The archive callback fires per 64 KiB chunk with the C++
    /// writer BLOCKED until it returns, so per-tick string formatting is paid in pack throughput —
    /// ~31 000 times for a 2 GB file. The displayed estimate has no use for that granularity.
    private final class ChangeGate {
        private let lock = NSLock()
        private var last: Int64 = .min
        func passes(_ bucket: Int64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if bucket == last { return false }
            last = bucket
            return true
        }
    }

    private func makeArchiveProgressHandler(
        progressController: OperationProgressReporter,
        overrideTotalBytes: Int64 = 0,
        overrideTotalFiles: Int = 0,
        monotonicProgress: MonotonicProgress? = nil,
        packDetail: (format: ArchiveFormat, level: Int)? = nil
    ) -> (String, Int64, Int64, Int, Int, Int64) -> Void {
        let detailGate = ChangeGate()
        return { [weak self] currentFile, bytesDone, bytesTotal, filesDone, filesTotal, compressedBytes in
            // This runs on the archive worker thread: the C++ writer is blocked until the
            // callback returns, so blocking HERE is what actually pauses the operation —
            // exactly how copy/move pause inside their copyfile callback. Archive ops only
            // ever checked isCancelled, so the queue's Pause button did nothing for them
            // (Cancel worked, Pause was silently ignored). Cancellation while paused is
            // still handled by the isCancelled check below.
            _ = progressController.waitWhilePaused()

            let resolvedBytesTotal = max(max(bytesTotal, overrideTotalBytes), 1)
            let clampedBytesDone = min(max(bytesDone, 0), resolvedBytesTotal)
            let resolvedFilesTotal = max(max(filesTotal, overrideTotalFiles), 1)
            let clampedFilesDone = min(max(filesDone, 0), resolvedFilesTotal)
            let progressValue = Self.archiveBarFraction(
                bytesDone: clampedBytesDone, bytesTotal: resolvedBytesTotal,
                filesDone: clampedFilesDone, filesTotal: resolvedFilesTotal)
            // Once per 16 MB of input, not per 64 KB chunk — the writer is stalled while this
            // closure runs, and the estimate cannot usefully change faster anyway.
            var detail: String?
            if let packDetail, detailGate.passes(clampedBytesDone >> 24) {
                detail = Self.packProgressDetail(format: packDetail.format,
                                                 compressionLevel: packDetail.level,
                                                 compressedBytes: compressedBytes,
                                                 uncompressedDone: clampedBytesDone,
                                                 uncompressedTotal: resolvedBytesTotal)
            }

            DispatchQueue.main.async {
                if progressController.isCancelled {
                    self?.bridgeService.cancelArchiveOperations()
                }

                let stableProgress = monotonicProgress?.advance(to: progressValue) ?? progressValue

                if let detail { progressController.setDetail(detail) }
                progressController.update(
                    currentFile: (currentFile as NSString).lastPathComponent,
                    progress: max(stableProgress, 0.01),
                    bytesDone: clampedBytesDone,
                    bytesTotal: resolvedBytesTotal,
                    filesDone: clampedFilesDone,
                    filesTotal: resolvedFilesTotal
                )
            }
        }
    }

    /// Build a DMG with hdiutil — the disk-image tool macOS itself uses; libarchive neither
    /// reads nor writes the format. Called on a background queue from both pack paths, so one
    /// implementation carries the dialog and the queue alike.
    ///
    /// `-fs HFS+` is deliberate: with the APFS default hdiutil sizes the working volume so
    /// tightly that incompressible sources die with "no space left on device" — measured here
    /// with 120 MB of random bytes. `-puppetstrings` makes progress parseable: "PERCENT:n"
    /// lines, with -1 meaning "indeterminate".
    nonisolated func createDMGImage(sources: [String], to dmgPath: String,
                                    compressionLevel: Int,
                                    totalBytes: Int64, totalFiles: Int,
                                    password: String = "",
                                    reporter: OperationProgressReporter) throws {
        let volumeName = archiveBaseName(from: (dmgPath as NSString).lastPathComponent)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        var arguments = ["create", "-ov"]
        for source in sources { arguments += ["-srcfolder", source] }
        arguments += ["-volname", volumeName.isEmpty ? "Archive" : volumeName,
                      "-fs", "HFS+",
                      "-format", "UDZO",
                      // zlib has no level 0; the clamp mirrors what the core does for zstd.
                      "-imagekey", "zlib-level=\(min(max(compressionLevel, 1), 9))"]
        if !password.isEmpty {
            // Whole-image AES-256: contents AND names, unlike a zip. The passphrase goes in by
            // STDIN — on the command line it would sit in `ps` output for every process to read.
            arguments += ["-encryption", "AES-256", "-stdinpass"]
        }
        arguments += ["-puppetstrings", dmgPath]
        process.arguments = arguments

        if !password.isEmpty {
            let stdin = Pipe()
            process.standardInput = stdin
            // No trailing newline: hdiutil takes every byte on stdin as part of the passphrase,
            // and an invisible "\n" would make a password nobody can ever retype.
            stdin.fileHandleForWriting.write(Data(password.utf8))
            stdin.fileHandleForWriting.closeFile()
        }

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let dmgName = (dmgPath as NSString).lastPathComponent
        var stderrTail = Data()
        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak reporter] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
            // Cancellation lands here because hdiutil has no other place to hear it: killing
            // the process is the cancel, and the partial image is removed after the wait.
            if reporter?.isCancelled == true {
                process.terminate()
                return
            }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(data: buffer[buffer.startIndex..<newline], encoding: .utf8) ?? ""
                buffer.removeSubrange(buffer.startIndex...newline)
                guard line.hasPrefix("PERCENT:"),
                      let value = Double(line.dropFirst("PERCENT:".count)) else { continue }
                let fraction = value < 0 ? nil : min(max(value / 100.0, 0), 1)
                DispatchQueue.main.async {
                    guard let reporter else { return }
                    reporter.setDetail(Self.packProgressDetail(
                        format: .dmg, compressionLevel: compressionLevel,
                        compressedBytes: 0, uncompressedDone: 0, uncompressedTotal: 0))
                    if let fraction {
                        // hdiutil reports only a percentage — but the source total was measured
                        // before it launched, so the byte counter can be percent × total instead
                        // of the "Zero KB of —" the zeros produced. Files stay honest: none is
                        // COMPLETE until hdiutil is done with the lot, so the count estimates.
                        reporter.update(currentFile: dmgName, progress: max(fraction, 0.01),
                                        bytesDone: Int64(fraction * Double(totalBytes)),
                                        bytesTotal: totalBytes,
                                        filesDone: min(Int(fraction * Double(totalFiles)),
                                                       max(totalFiles - 1, 0)),
                                        filesTotal: totalFiles)
                    }
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            stderrTail.append(handle.availableData)
        }

        try process.run()
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil

        if reporter.isCancelled {
            try? FileManager.default.removeItem(atPath: dmgPath)
            throw userCancelledError()
        }
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(atPath: dmgPath)
            let message = String(data: stderrTail, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "FileOperationsService", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                              message.isEmpty ? L("pack.dmg.failed") : message])
        }
    }

    /// Mount a disk image and return its mount point. hdiutil, the same tool that creates our
    /// DMGs — but WITHOUT the system's DiskImageMounter route, whose side effect is a Finder
    /// window: the whole reason this exists is that the volume should open in the panel.
    /// -noautoopen also suppresses the image's own "auto-open" blessing, if it carries one.
    nonisolated func attachDiskImage(at dmgPath: String) throws -> String {
        // The image may ALREADY be attached — Quick Look attaches previewed images at a hidden
        // mountpoint and leaves them, and a volume ejected in Finder can leave the image itself
        // attached with no volume. A fresh attach then fails with "resource busy". Stale
        // attachments of THIS image are detached first, so Enter works whatever came before.
        for device in Self.attachedDevices(forImage: dmgPath, info: Self.hdiutilInfoPlist()) {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", "-quiet", device]
            try? detach.run()
            detach.waitUntilExit()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-plist", "-noautoopen", dmgPath]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read BEFORE waiting: a pipe holds ~64 KB, and hdiutil's plist can exceed it — waiting
        // first would deadlock with hdiutil blocked mid-write.
        let plistData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "FileOperationsService", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                              message.isEmpty ? L("dmg.mountFailed") : message])
        }
        guard let mountPoint = Self.mountPoint(fromAttachPlist: plistData) else {
            throw NSError(domain: "FileOperationsService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("dmg.mountFailed")])
        }
        return mountPoint
    }

    /// Everything hdiutil currently has attached, as a plist. Empty data on failure — the
    /// caller treats that as "nothing attached", which only costs a doomed attach attempt.
    nonisolated static func hdiutilInfoPlist() -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return Data() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : Data()
    }

    /// The whole-disk /dev entries of every current attachment of `imagePath` — what detach
    /// wants. One per attachment: detaching the whole disk takes its slices with it.
    nonisolated static func attachedDevices(forImage imagePath: String, info: Data) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: info, format: nil),
              let root = plist as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return [] }
        let wanted = (imagePath as NSString).standardizingPath
        var devices: [String] = []
        for image in images where ((image["image-path"] as? String) as NSString?)?
            .standardizingPath == wanted {
            let entries = (image["system-entities"] as? [[String: Any]]) ?? []
            // The shortest dev-entry is the whole disk ("/dev/disk25" before "/dev/disk25s1").
            if let device = entries.compactMap({ $0["dev-entry"] as? String })
                .min(by: { $0.count < $1.count }) {
                devices.append(device)
            }
        }
        return devices
    }

    /// The image file whose volume is mounted at `mountPoint`, or nil for a real disk.
    nonisolated static func imagePath(forMountPoint mountPoint: String, info: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: info, format: nil),
              let root = plist as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return nil }
        let wanted = (mountPoint as NSString).standardizingPath
        for image in images {
            guard let imagePath = image["image-path"] as? String else { continue }
            let entities = (image["system-entities"] as? [[String: Any]]) ?? []
            if entities.contains(where: {
                (($0["mount-point"] as? String) as NSString?)?.standardizingPath == wanted
            }) {
                return (imagePath as NSString).standardizingPath
            }
        }
        return nil
    }

    /// Detach an image whole — what Finder's eject does for a mounted image. NSWorkspace's
    /// eject takes only the VOLUME and leaves the image attached with nothing mounted, after
    /// which macOS quietly refuses to open that image again (measured: the second Enter did
    /// nothing until the stale attachment was gone). Throws hdiutil's words when something
    /// inside is still open; `force` tears it away regardless.
    nonisolated static func detachImage(at imagePath: String, force: Bool = false) throws {
        for device in attachedDevices(forImage: imagePath, info: hdiutilInfoPlist()) {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", "-quiet", device] + (force ? ["-force"] : [])
            let err = Pipe()
            detach.standardOutput = Pipe()
            detach.standardError = err
            try detach.run()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            detach.waitUntilExit()
            guard detach.terminationStatus == 0 else {
                let message = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw NSError(domain: "FileOperationsService", code: Int(detach.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey:
                                  message.isEmpty ? L("volume.eject.failed.title") : message])
            }
        }
    }

    /// The first mount point in hdiutil's -plist output. An image can carry several system
    /// entities (partition map, EFI, the volume) — only the one that actually mounted has a
    /// "mount-point" key.
    nonisolated static func mountPoint(fromAttachPlist data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first
    }

    private func userCancelledError() -> NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: L("error.cancelledByUser")]
        )
    }

    private func recycleWithWorkspace(_ urls: [URL]) async throws -> [URL: URL] {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { recycledURLs, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: recycledURLs)
            }
        }
    }

    private struct EditorTarget {
        let path: String
        let displayName: String
        let fileExtension: String
        let source: EditorDocumentSource
    }

    private func resolveEditorTarget(for item: FileItem,
                                     archivePath: String?,
                                     insideArchive: Bool) throws -> EditorTarget {
        if insideArchive {
            guard let archivePath else {
                throw NSError(
                    domain: "FileOperationsService",
                    code: NSFileNoSuchFileError,
                    userInfo: [NSLocalizedDescriptionKey: L("error.archivePathUnknown")]
                )
            }
            let temporaryRoot = try Self.createTemporaryDirectory(prefix: "fcxl_archive_edit")

            do {
                try bridgeService.extractArchiveEntry(
                    archivePath: archivePath,
                    entryPath: item.path,
                    destinationPath: temporaryRoot
                )
            } catch {
                Self.cleanupTemporaryDirectory(temporaryRoot)
                throw error
            }

            let extractedPath = (temporaryRoot as NSString).appendingPathComponent(item.path)
            guard FileManager.default.fileExists(atPath: extractedPath) else {
                Self.cleanupTemporaryDirectory(temporaryRoot)
                throw NSError(
                    domain: "FileOperationsService",
                    code: NSFileNoSuchFileError,
                    userInfo: [NSLocalizedDescriptionKey: L("error.archivePrepareEdit")]
                )
            }

            return EditorTarget(
                path: extractedPath,
                displayName: item.name,
                fileExtension: item.fileExtension,
                source: .archive(
                    archivePath: archivePath,
                    entryPath: item.path,
                    temporaryRoot: temporaryRoot
                )
            )
        }

        return EditorTarget(
            path: item.path,
            displayName: item.name,
            fileExtension: item.fileExtension,
            source: .fileSystem
        )
    }

    private func isEditableTextFile(name: String, fileExtension: String) -> Bool {
        let normalizedExtension = fileExtension
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        // Known binary formats — refuse editing
        let binaryExtensions: Set<String> = [
            // Executables & libraries
            "exe", "dll", "so", "dylib", "a", "o", "obj", "lib", "bin", "com",
            "app", "framework", "bundle", "kext", "class", "pyc", "pyo",
            // Archives
            "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg", "iso",
            "jar", "war", "ear", "deb", "rpm", "pkg", "cab", "lzma", "zst",
            // Images (raster)
            "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic",
            "heif", "ico", "icns", "raw", "cr2", "nef", "arw", "psd", "ai", "eps",
            // Video
            "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm", "mpg", "mpeg",
            "3gp", "vob", "mts", "m2ts",
            // Audio
            "mp3", "wav", "m4a", "flac", "aac", "ogg", "wma", "aiff", "opus", "mid", "midi",
            // Documents (binary)
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp",
            "pages", "numbers", "keynote", "rtfd",
            // Databases
            "db", "sqlite", "sqlite3", "mdb", "accdb",
            // Fonts
            "ttf", "otf", "woff", "woff2", "eot",
            // Other binary
            "swf", "fla", "blend", "fbx", "glb", "gltf", "usdz",
            "dat", "pak", "res", "nib", "xib", "storyboard",
            "car", "momd", "mom", "omo",
        ]

        if binaryExtensions.contains(normalizedExtension) {
            return false
        }

        // Everything else — try to open as text
        return true
    }

    private func normalizeArchiveEntryPath(_ value: String) -> String {
        Self.normalizedArchiveEntryPath(value)
    }

    nonisolated static func normalizedArchiveEntryPath(_ value: String) -> String {
        var normalized = value
        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }
        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    /// Bytes each requested entry brings out: a file its own size, a folder everything
    /// beneath it. Weighed by the exact path alone, a folder counted as nothing and the bar
    /// stood still for the whole minute the folder took.
    nonisolated static func plannedArchiveBytes(
        for entries: [String],
        files: [(path: String, size: Int64)]
    ) -> [String: Int64] {
        var planned: [String: Int64] = [:]
        for entry in entries {
            let root = normalizedArchiveEntryPath(entry)
            var sum: Int64 = 0
            if !root.isEmpty {
                for file in files {
                    let path = normalizedArchiveEntryPath(file.path)
                    if path == root || path.hasPrefix(root + "/") { sum += file.size }
                }
            }
            planned[entry] = sum
        }
        return planned
    }
}
