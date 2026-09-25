import AppKit
import Foundation
import OSLog

// MARK: - Darwin low-level file operations
// Uses clonefile/copyfile/removefile/rename directly for maximum performance.
// Finder-level speed: same-volume move = O(1) rename, APFS copy = instant CoW clone,
// delete = removefile() with recursive support and cancellation.

enum DarwinFileOperations {

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.fcxl.filecommander",
        category: "DarwinFileOps"
    )

    // MARK: - Unicode-normalization path resolution (SMB)

    /// stat() using the string's exact UTF-8 bytes. FileManager re-normalizes paths
    /// via fileSystemRepresentation, which can miss files on SMB mounts: Windows
    /// stores names precomposed (NFC, "й" = one code point) while macOS APIs often
    /// produce decomposed names (NFD, "и" + combining breve) — a normalization-
    /// sensitive server then reports ENOENT for a file its own listing returned.
    static func rawStat(_ path: String) -> (exists: Bool, isDir: Bool) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return (false, false) }
        return (true, (st.st_mode & S_IFMT) == S_IFDIR)
    }

    /// Returns the Unicode-normalization variant of `path` that actually exists on
    /// disk: the path as given, else its precomposed (NFC) form, else its decomposed
    /// (NFD) form. When nothing exists, returns the original path with exists=false.
    static func existingPathForm(_ path: String) -> (path: String, exists: Bool, isDir: Bool) {
        var r = rawStat(path)
        if r.exists { return (path, true, r.isDir) }
        // NOTE: compare by BYTES, not `!=`. Swift String equality is Unicode
        // canonical-equivalence, so `nfc != path` is false whenever normalization only
        // changed the byte layout — exactly the cases we need to retry. utf8 compare
        // sees the real byte difference.
        let nfc = path.precomposedStringWithCanonicalMapping
        if !nfc.utf8.elementsEqual(path.utf8) {
            r = rawStat(nfc)
            if r.exists { return (nfc, true, r.isDir) }
        }
        let nfd = path.decomposedStringWithCanonicalMapping
        if !nfd.utf8.elementsEqual(path.utf8) {
            r = rawStat(nfd)
            if r.exists { return (nfd, true, r.isDir) }
        }
        return (path, false, false)
    }

    // MARK: - Move (same volume = instant rename, cross-volume = copy + remove)

    /// Moves a file or directory. Same-volume = O(1) rename. Cross-volume = copyfile + removefile.
    /// Returns true if the operation was an instant rename (same volume).
    @discardableResult
    static func move(from source: String, to destination: String,
                     progress: ((Int64, Int64, String) -> Void)? = nil,
                     shouldCancel: (() -> Bool)? = nil) throws -> Bool {
        // SMB: swap in the Unicode-normalization form the server actually accepts.
        let source = existingPathForm(source).path
        // Try rename() first — instant if same volume.
        if Darwin.rename(source, destination) == 0 {
            return true
        }

        // EXDEV = cross-device link — need copy + delete.
        guard errno == EXDEV else {
            let err = errno
            throw posixError(err, operation: "rename", path: source)
        }

        // Cross-volume: copy with clonefile fallback, then remove source.
        // Progress/cancel are forwarded so a big cross-volume move advances the bar
        // by bytes instead of sitting at ~1% until the whole copy finishes.
        try copy(from: source, to: destination, progress: progress, shouldCancel: shouldCancel)
        do {
            try remove(path: source)
        } catch {
            // Remove destination to avoid leaving duplicates
            try? remove(path: destination)
            throw error
        }
        return false
    }

    // MARK: - Copy (APFS clone → copyfile fallback)

    /// Copies a file or directory using clonefile() for instant APFS CoW clone.
    /// Falls back to copyfile() with progress callback for non-APFS or cross-volume.
    static func copy(
        from source: String,
        to destination: String,
        progress: ((Int64, Int64, String) -> Void)?,
        shouldCancel: (() -> Bool)?
    ) throws {
        // SMB: swap in the Unicode-normalization form the server actually accepts.
        let source = existingPathForm(source).path

        // A folder holding two names of the SAME file is the one case neither clonefile nor
        // copyfile gets right: both write the bytes twice and hand back two independent files.
        // Measured on a 20 MB pair: 40 MB at the destination, and editing one name no longer
        // shows through the other. ditto is the only system tool that keeps them one file, so
        // that rare tree goes through it — everything else keeps the fast path.
        // Only for a destination that does not exist yet: ditto MERGES into an existing folder
        // while copyfile refuses it, and quietly changing which one happens would turn a
        // conflict into an overwrite. A merge keeps the old road.
        // Deliberately NOT on the same volume, where clonefile wins by too much to give up:
        // measured on Xcode.app (which does hold internal links, in Contents/Developer/usr/bin),
        // clonefile takes 3.1 s and 45 MB of real disk against ditto's 41.5 s and 4839 MB. On one
        // volume the clones share their blocks, so splitting the links costs no space at all —
        // only the "one file under two names" meaning, which is worth far less than 13x the time
        // and 107x the disk. Across volumes there is no sharing, and the bytes really do double.
        if !sameVolume(source: source, destination: destination),
           !existingPathForm(destination).exists,
           treeHasInternalHardlinks(source) {
            do {
                try dittoCopy(from: source, to: destination, shouldCancel: shouldCancel)
                return
            } catch let error as NSError where error.code != NSUserCancelledError {
                // ditto refuses trees the ordinary path handles — a locked file, a destination
                // that cannot hold hard links at all. Never end up worse than before it was
                // tried: clear the half-written tree and copy the ordinary way.
                try? FileManager.default.removeItem(atPath: destination)
            }
        }

        // First try instant APFS clone via clonefile(2).
        if clonefile(source, destination, UInt32(CLONE_NOOWNERCOPY)) == 0 {
            return
        }

        // clonefile failed — use copyfile() with progress support.
        try copyfileWithProgress(
            from: source,
            to: destination,
            progress: progress,
            shouldCancel: shouldCancel
        )
    }

    // MARK: - Hard links inside a copied tree

    /// Whether the tree holds the same file under two or more names INSIDE it.
    ///
    /// Only that case needs special handling: a file whose other names live outside the tree
    /// (a pnpm store, a Homebrew cellar) can only be copied as a full file, and rightly is.
    /// The walk stops the moment a pair is found, and files with a link count of one — every
    /// ordinary file — are skipped without a lookup.
    static func treeHasInternalHardlinks(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }

        return path.withCString { cPath -> Bool in
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(cPath), nil]
            defer { free(argv[0]) }
            // FTS_PHYSICAL: never follow a symlink — a link loop must not make this run forever.
            guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return false }
            defer { fts_close(fts) }

            var seen = Set<UInt64>()
            while let node = fts_read(fts) {
                guard Int32(node.pointee.fts_info) == FTS_F,
                      let st = node.pointee.fts_statp, st.pointee.st_nlink > 1 else { continue }
                if !seen.insert(st.pointee.st_ino).inserted { return true }
            }
            return false
        }
    }

    /// Copy through ditto, which keeps hard links inside the tree as links.
    ///
    /// No byte progress: ditto reports none. The outer loop still advances per item, and this
    /// path is only taken by the rare tree that needs it.
    private static func dittoCopy(from source: String, to destination: String,
                                  shouldCancel: (() -> Bool)?) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // --nonAtomicCopies: by default ditto writes each file as ".BC.T_xxxx" and renames it
        // into place, and a file carrying a "deny delete" ACL denies that rename to ditto
        // itself — the file then goes MISSING from the copy, with a hidden temp left in its
        // place. Writing straight to the final name has no such hole.
        task.arguments = ["--nonAtomicCopies", source, destination]
        task.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        task.standardError = errorPipe
        try task.run()

        // Drained on another queue WHILE ditto runs: a pipe holds about 64 KB, and a tree with
        // many complaints fills it — after which ditto blocks on the write and the copy hangs
        // for ever, because nothing read until the process exited.
        let collected = TransferBox(Data())
        let drain = DispatchQueue(label: "com.fcxl.ditto.stderr")
        drain.async { collected.value = errorPipe.fileHandleForReading.readDataToEndOfFile() }

        while task.isRunning {
            if shouldCancel?() == true {
                task.terminate()
                // A cancelled copy must not leave half a tree behind.
                try? FileManager.default.removeItem(atPath: destination)
                throw CocoaError(.userCancelled)
            }
            usleep(50_000)
        }
        task.waitUntilExit()
        drain.sync { }                      // the reader has finished by the time this returns

        guard task.terminationStatus == 0 else {
            let message = String(data: collected.value, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [
                NSLocalizedDescriptionKey: message.isEmpty ? "ditto failed" : message,
                NSFilePathErrorKey: source,
            ])
        }
    }

    /// Carries one value across a queue boundary without tripping Sendable checking.
    private final class TransferBox<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: - Remove

    /// Removes a file or directory tree.
    /// FileManager.removeItem internally uses removefile() with REMOVEFILE_RECURSIVE.
    static func remove(path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Trash (NSWorkspace.recycle — uses Finder's instant trash mechanism)

    /// Moves items to Trash using NSWorkspace.recycle (same as Finder).
    /// This is already well-implemented; kept here for API completeness.
    static func trash(urls: [URL]) async throws -> [URL: URL] {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { recycledURLs, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: recycledURLs)
                }
            }
        }
    }

    // MARK: - Atomic swap (renameatx_np with RENAME_SWAP)

    /// Atomically swaps two files/directories. macOS-exclusive via renameatx_np().
    static func atomicSwap(_ pathA: String, _ pathB: String) throws {
        let result = renameatx_np(AT_FDCWD, pathA, AT_FDCWD, pathB, UInt32(RENAME_SWAP))
        if result != 0 {
            throw posixError(errno, operation: "renameatx_np(RENAME_SWAP)", path: pathA)
        }
    }

    // MARK: - Volume check

    /// Returns true if source and destination are on the same APFS/HFS+ volume.
    static func sameVolume(source: String, destination: String) -> Bool {
        var srcStat = stat()
        var dstStat = stat()
        let dstParent = (destination as NSString).deletingLastPathComponent
        guard stat(source, &srcStat) == 0, stat(dstParent, &dstStat) == 0 else {
            return false
        }
        return srcStat.st_dev == dstStat.st_dev
    }

    /// Returns true if the volume at the given path supports APFS clonefile.
    static func supportsClone(at path: String) -> Bool {
        var attrList = attrlist()
        attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrList.volattr = attrgroup_t(ATTR_VOL_CAPABILITIES)

        var attrBuf = vol_capabilities_attr_t()
        let result = getattrlist(path, &attrList, &attrBuf, MemoryLayout<vol_capabilities_attr_t>.size, 0)
        if result != 0 { return false }

        // VOL_CAP_INT_CLONE is bit 17 in capabilities[1] (VOL_CAPABILITIES_INTERFACES)
        let cloneBit: UInt32 = 1 << 17 // VOL_CAP_INT_CLONE
        return (attrBuf.capabilities.1 & cloneBit) != 0
    }

    // MARK: - Private helpers

    private static func copyfileWithProgress(
        from source: String,
        to destination: String,
        progress: ((Int64, Int64, String) -> Void)?,
        shouldCancel: (() -> Bool)?
    ) throws {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }

        // Keep a strong reference to the context and guarantee release via defer.
        var retainedContextPtr: UnsafeMutableRawPointer?

        if progress != nil || shouldCancel != nil {
            // Pre-calculate total size for progress reporting
            var totalSize: Int64 = 0
            var srcStat = stat()
            if stat(source, &srcStat) == 0 {
                totalSize = Int64(srcStat.st_size)
            }

            let context = CopyfileContext(
                progress: progress,
                shouldCancel: shouldCancel,
                source: source,
                totalBytes: totalSize
            )
            let contextPtr = Unmanaged.passRetained(context).toOpaque()
            retainedContextPtr = contextPtr

            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), contextPtr)

            let callback: copyfile_callback_t = { what, stage, state, src, dst, ctx in
                guard let ctx else { return COPYFILE_CONTINUE }
                let context = Unmanaged<CopyfileContext>.fromOpaque(ctx).takeUnretainedValue()

                if context.shouldCancel?() == true {
                    return COPYFILE_QUIT
                }

                if stage == COPYFILE_PROGRESS, let progress = context.progress {
                    var bytesCopied: off_t = 0
                    copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &bytesCopied)
                    // COPYFILE_STATE_COPIED resets per file in recursive mode.
                    // Accumulate for monotonically increasing progress.
                    let totalCopied = context.accumulatedBytes + Int64(bytesCopied)
                    context.currentFileBytes = Int64(bytesCopied)
                    progress(totalCopied, context.totalBytes, context.source)
                }

                if stage == COPYFILE_FINISH {
                    // File/dir finished — add its bytes to accumulator
                    context.accumulatedBytes += context.currentFileBytes
                    context.currentFileBytes = 0
                }

                return COPYFILE_CONTINUE
            }

            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        }

        defer {
            // Guaranteed release of the retained context, regardless of error path.
            if let ptr = retainedContextPtr {
                Unmanaged<CopyfileContext>.fromOpaque(ptr).release()
            }
        }

        let flags: copyfile_flags_t = UInt32(COPYFILE_ALL) | UInt32(COPYFILE_CLONE) | UInt32(COPYFILE_RECURSIVE) | UInt32(COPYFILE_NOFOLLOW)
        let result = copyfile(source, destination, state, flags)

        if result != 0 {
            let err = errno
            if err == ECANCELED {
                throw CocoaError(.userCancelled)
            }
            throw posixError(err, operation: "copyfile", path: source)
        }
    }

    private static func posixError(_ err: Int32, operation: String, path: String) -> NSError {
        let message = String(cString: strerror(err))
        log.error("\(operation, privacy: .public) failed: \(message, privacy: .public) path=\(path, privacy: .public)")
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(err),
            userInfo: [
                NSLocalizedDescriptionKey: "\(operation) failed: \(message)",
                NSFilePathErrorKey: path
            ]
        )
    }
}

// MARK: - Callback contexts (prevent dangling closures)

private final class CopyfileContext {
    let progress: ((Int64, Int64, String) -> Void)?
    let shouldCancel: (() -> Bool)?
    let source: String
    let totalBytes: Int64
    /// Accumulated bytes from previously finished files (for recursive copies).
    var accumulatedBytes: Int64 = 0
    /// Bytes copied so far in the current file.
    var currentFileBytes: Int64 = 0

    init(progress: ((Int64, Int64, String) -> Void)?, shouldCancel: (() -> Bool)?, source: String, totalBytes: Int64 = 0) {
        self.progress = progress
        self.shouldCancel = shouldCancel
        self.source = source
        self.totalBytes = totalBytes
    }
}

