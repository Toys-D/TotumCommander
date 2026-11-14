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
        try removeMovedSource(source)
        return false
    }

    /// Removes the source of a move once its copy is in place on the other volume.
    private static func removeMovedSource(_ source: String) throws {
        do {
            try remove(path: source)
        } catch {
            // The copy is complete and it stays. It used to be taken back "to avoid leaving
            // duplicates" — but a remove that failed half way has already deleted part of the
            // source, so removing the copy as well left those files nowhere at all.
            let underlying = error as NSError
            log.error("move: source not fully removed after copy: \(underlying.localizedDescription, privacy: .public) path=\(source, privacy: .private)")
            throw redescribed(underlying, L("move.sourceNotRemoved", underlying.localizedDescription))
        }
    }

    /// The same error under a description the user can act on; the original stays as the cause.
    private static func redescribed(_ underlying: NSError, _ description: String) -> NSError {
        var info = underlying.userInfo
        info[NSLocalizedDescriptionKey] = description
        info[NSUnderlyingErrorKey] = underlying
        return NSError(domain: underlying.domain, code: underlying.code, userInfo: info)
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

    // MARK: - Exclusive rename (renamex_np with RENAME_EXCL)

    /// Переименовать, не заменяя того, что уже лежит под новым именем: занятое имя — `EEXIST`.
    /// Обычный `rename(2)` приёмник молча затирает. Возвращает 0 либо код errno.
    static func renameExclusive(from source: String, to destination: String) -> Int32 {
        if renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let code = errno
        // Том не умеет исключающее переименование (FAT, часть сетевых) — проверить самим.
        guard code == ENOTSUP || code == EINVAL else { return code }
        var info = stat()
        if lstat(destination, &info) == 0 { return EEXIST }
        return Darwin.rename(source, destination) == 0 ? 0 : errno
    }

    // MARK: - Replace (the new object first, the old one last)

    /// Prefix of the hidden names a replacement is prepared under, right next to its destination.
    static let stagingPrefix = ".fcxl-replace-"

    /// A free hidden name in the destination's own folder — the same volume as the destination,
    /// so putting the finished copy in place is a single rename. `pathExtension` is for tools
    /// that read the format off the name they write to (hdiutil adds ".dmg" to a bare one).
    static func stagingPath(for destination: String, pathExtension: String = "") -> String {
        let parent = (destination as NSString).deletingLastPathComponent
        let suffix = pathExtension.isEmpty ? "" : "." + pathExtension
        while true {
            let candidate = (parent as NSString).appendingPathComponent(
                stagingPrefix + UUID().uuidString.prefix(8).lowercased() + suffix)
            var info = stat()
            if lstat(candidate, &info) != 0 { return candidate }
        }
    }

    /// True when the two paths name the very same directory entry — one object reached by two
    /// spellings of its path (a symlinked folder on the way, another letter case, `/var` and
    /// `/private/var`). Two hard links of one file are two entries: false.
    static func sameDirectoryEntry(_ a: String, _ b: String) -> Bool {
        var first = stat(), second = stat()
        guard lstat(a, &first) == 0, lstat(b, &second) == 0,
              first.st_dev == second.st_dev, first.st_ino == second.st_ino else { return false }
        // One object. One entry of it — only in the same folder under the same name: a second
        // hard link is another entry, and the inode number alone is not proof either (volumes
        // without real inodes make the numbers up).
        let parentA = (a as NSString).deletingLastPathComponent
        let parentB = (b as NSString).deletingLastPathComponent
        var folderA = stat(), folderB = stat()
        guard stat(parentA, &folderA) == 0, stat(parentB, &folderB) == 0,
              folderA.st_dev == folderB.st_dev, folderA.st_ino == folderB.st_ino else { return false }
        let nameA = (a as NSString).lastPathComponent
        let nameB = (b as NSString).lastPathComponent
        // Swift `==` is canonical equivalence: an NFC and an NFD spelling are one name here.
        if nameA == nameB { return true }
        // Unsupported (-1) counts as case-sensitive — the cautious answer is "two entries".
        let caseInsensitive = pathconf(parentA, _PC_CASE_SENSITIVE) == 0
        return caseInsensitive && nameA.compare(nameB, options: .caseInsensitive) == .orderedSame
    }

    /// The name of an entry exactly as the volume stores it — letter case and Unicode form
    /// included. For a symlink, the name of the link itself.
    private static func onDiskName(_ path: String) -> String? {
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_NAME)
        // The reply: its own length (4 bytes), a reference to the name, then the name itself.
        var buffer = [UInt8](repeating: 0, count: 4 + MemoryLayout<attrreference_t>.size + 1024)
        let fetched = buffer.withUnsafeMutableBytes { raw -> Bool in
            getattrlist(path, &attrs, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW)) == 0
        }
        guard fetched else { return nil }
        return buffer.withUnsafeBytes { raw -> String? in
            let reference = raw.loadUnaligned(fromByteOffset: 4, as: attrreference_t.self)
            let start = 4 + Int(reference.attr_dataoffset)
            let length = Int(reference.attr_length)
            guard length > 0, start + length <= raw.count else { return nil }
            // The length counts the terminating NUL.
            return String(decoding: raw[start..<(start + length - 1)], as: UTF8.self)
        }
    }

    /// A rename over a name that differs only in letter case (or Unicode form) keeps the OLD
    /// spelling on APFS, while the old "remove, then copy" left the new object under its own.
    /// Give the entry the spelling that was asked for.
    private static func settleName(_ destination: String) {
        let wanted = (destination as NSString).lastPathComponent
        guard let actual = onDiskName(destination),
              !actual.utf8.elementsEqual(wanted.utf8),
              actual.compare(wanted, options: .caseInsensitive) == .orderedSame else { return }
        let stored = ((destination as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(actual)
        // Only ever rename the object onto itself: the stored name must lead to the same object.
        var one = stat(), other = stat()
        guard lstat(stored, &one) == 0, lstat(destination, &other) == 0,
              one.st_dev == other.st_dev, one.st_ino == other.st_ino else { return }
        _ = Darwin.rename(stored, destination)
    }

    private static let lockFlags = UInt32(UF_IMMUTABLE | UF_APPEND)

    /// What keeps an object from being renamed even by its owner: the lock flag and an access
    /// list that denies deleting. A copy inherits both from its source.
    private struct RenameGuards {
        let flags: UInt32?
        let accessList: acl_t?

        /// Lifts the guards off a staged copy so that it can be renamed into place.
        static func lift(from path: String) -> RenameGuards {
            var info = stat()
            var flags: UInt32?
            if lstat(path, &info) == 0, (info.st_flags & lockFlags) != 0 {
                flags = info.st_flags
                _ = lchflags(path, info.st_flags & ~lockFlags)
            }
            let accessList: acl_t? = acl_get_link_np(path, ACL_TYPE_EXTENDED)
            if accessList != nil { clearAccessList(path) }
            return RenameGuards(flags: flags, accessList: accessList)
        }

        /// Puts them back at the final place. The access list first: a locked object takes none.
        func apply(to path: String) {
            if let accessList { _ = acl_set_link_np(path, ACL_TYPE_EXTENDED, accessList) }
            if let flags { _ = lchflags(path, flags) }
        }

        func free() {
            if let accessList { acl_free(UnsafeMutableRawPointer(accessList)) }
        }
    }

    private static func clearAccessList(_ path: String) {
        guard let empty = acl_init(0) else { return }
        _ = acl_set_link_np(path, ACL_TYPE_EXTENDED, empty)
        acl_free(UnsafeMutableRawPointer(empty))
    }

    /// How far a failed `install` got — what is left for the caller to clean up or report.
    private enum InstallState {
        /// Nothing changed: the old object is where it was, the new one still under its own name.
        case untouched
        /// The old object sits under a hidden name and could not be put back.
        case oldSetAside
        /// The new object is in place; a remnant of the old one is left under a hidden name.
        case installed
    }

    private struct InstallFailure: Error {
        let state: InstallState
        let error: NSError
    }

    /// Puts `newPath` where `destination` is; both are on one volume. A file over a file (or over
    /// a symlink) is one rename(2), which swaps them atomically. Where rename refuses the pair —
    /// a file over a folder, a folder over a file — the old object first steps aside under a
    /// hidden name, and is removed only after the new one has taken its place.
    private static func install(_ newPath: String, over destination: String) throws {
        if Darwin.rename(newPath, destination) == 0 {
            settleName(destination)
            return
        }
        // Take errno at once: everything below makes system calls of its own.
        let refusal = errno
        guard refusal == EISDIR || refusal == ENOTDIR || refusal == ENOTEMPTY || refusal == EEXIST else {
            throw InstallFailure(state: .untouched,
                                 error: posixError(refusal, operation: "rename", path: destination))
        }
        let aside = stagingPath(for: destination)
        guard Darwin.rename(destination, aside) == 0 else {
            let code = errno
            throw InstallFailure(state: .untouched,
                                 error: posixError(code, operation: "rename", path: destination))
        }
        guard Darwin.rename(newPath, destination) == 0 else {
            let code = errno
            let failure = posixError(code, operation: "rename", path: destination)
            if Darwin.rename(aside, destination) == 0 {
                throw InstallFailure(state: .untouched, error: failure)
            }
            throw InstallFailure(state: .oldSetAside, error: redescribed(
                failure, L("replace.oldLeftAside",
                           (destination as NSString).lastPathComponent,
                           (aside as NSString).lastPathComponent,
                           failure.localizedDescription)))
        }
        do {
            try remove(path: aside)
        } catch {
            throw InstallFailure(state: .installed, error: redescribed(
                error as NSError, L("replace.oldNotRemoved",
                                    (destination as NSString).lastPathComponent,
                                    (aside as NSString).lastPathComponent,
                                    error.localizedDescription)))
        }
    }

    /// Removes a staged copy this code made itself — never a source, never anything it did not
    /// create. A copy inherits its source's locks and access lists, so a plain remove can be refused.
    private static func discard(_ staged: String) {
        if (try? remove(path: staged)) != nil { return }
        unlockTree(staged)
        try? remove(path: staged)
    }

    private static func unlockTree(_ root: String) {
        var pending = [root]
        while let path = pending.popLast() {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if (info.st_flags & lockFlags) != 0 { _ = lchflags(path, info.st_flags & ~lockFlags) }
            clearAccessList(path)
            guard (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            _ = chmod(path, 0o700)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                pending.append((path as NSString).appendingPathComponent(name))
            }
        }
    }

    /// The replacement did not happen and the old object is untouched — say so: "copy failed"
    /// alone leaves the user wondering what is left at the destination. A cancel stays a cancel.
    private static func keptOriginal(_ underlying: NSError) -> NSError {
        if underlying.domain == NSCocoaErrorDomain,
           underlying.code == CocoaError.userCancelled.rawValue { return underlying }
        return redescribed(underlying, L("replace.keptOriginal", underlying.localizedDescription))
    }

    /// Puts `source` in the place of an existing `destination`. The old object is never removed
    /// first: the new one is brought next to it under a hidden name, and only when it is whole
    /// does it take the old one's name. Whatever goes wrong before that — no space, no access,
    /// a cancel — leaves the old object exactly as it was. With `move`, the source is gone
    /// afterwards.
    ///
    /// The price is free space for the new copy while the old one still exists (none on a single
    /// APFS volume, where the copy is a clone).
    static func replace(from source: String, to destination: String, move: Bool,
                        progress: ((Int64, Int64, String) -> Void)? = nil,
                        shouldCancel: (() -> Bool)? = nil) throws {
        // SMB: swap in the Unicode-normalization form the server actually accepts.
        let source = existingPathForm(source).path
        if move {
            var from = stat(), to = stat()
            if lstat(source, &from) == 0, lstat(destination, &to) == 0,
               from.st_dev == to.st_dev, from.st_ino == to.st_ino, from.st_nlink > 1 {
                // Two hard links of one file: rename(2) reports success and does nothing, which
                // would leave the source behind. The content is already at the destination, so
                // the source name goes — unless both paths are one and the same entry.
                if !sameDirectoryEntry(source, destination) { try remove(path: source) }
                return
            }
            do {
                // Same volume: the source itself takes the destination's name.
                try install(source, over: destination)
                return
            } catch let failure as InstallFailure {
                let otherVolume = failure.state == .untouched
                    && failure.error.domain == NSPOSIXErrorDomain
                    && failure.error.code == Int(EXDEV)
                if !otherVolume {
                    throw failure.state == .untouched ? keptOriginal(failure.error) : failure.error
                }
                // Another volume: a copy next to the destination, then the source is removed.
            }
        }

        // A locked destination cannot be replaced — find that out before the copy, not after it.
        var old = stat()
        if lstat(destination, &old) == 0,
           (old.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)) != 0 {
            throw keptOriginal(posixError(EPERM, operation: "rename", path: destination))
        }
        let stage = stagingPath(for: destination)
        do {
            try copy(from: source, to: stage, progress: progress, shouldCancel: shouldCancel)
        } catch {
            discard(stage)
            throw keptOriginal(error as NSError)
        }
        // The copy carries its source's lock and access list, and either can forbid the rename:
        // lift them for the rename and put them back once the copy stands in place.
        let guards = RenameGuards.lift(from: stage)
        defer { guards.free() }
        do {
            try install(stage, over: destination)
        } catch let failure as InstallFailure {
            switch failure.state {
            case .untouched:
                discard(stage)
                throw keptOriginal(failure.error)
            case .oldSetAside:
                discard(stage)
                throw failure.error
            case .installed:
                // In place, with a remnant of the old object beside it. A moved source stays
                // where it is: after a failure nothing more gets deleted.
                guards.apply(to: destination)
                throw failure.error
            }
        }
        guards.apply(to: destination)
        if move { try removeMovedSource(source) }
    }

    // MARK: - Whole or nothing, onto a free name

    /// A copy onto a FREE name that is either whole or not there at all: it is prepared next to
    /// its place under a hidden name and takes its own name by a single rename that replaces
    /// nothing. A stop or a failure half-way leaves no part of it behind, so the same copy can
    /// simply be asked for again. A taken name is `EEXIST`, and nothing is touched.
    static func copyWhole(from source: String, to destination: String,
                          progress: ((Int64, Int64, String) -> Void)? = nil,
                          shouldCancel: (() -> Bool)? = nil) throws {
        // Before the copy, not after it: nobody waits through a whole folder to hear "taken".
        var taken = stat()
        if lstat(destination, &taken) == 0 {
            throw posixError(EEXIST, operation: "copy", path: destination)
        }
        let stage = stagingPath(for: destination)
        do {
            try copy(from: source, to: stage, progress: progress, shouldCancel: shouldCancel)
        } catch {
            discard(stage)
            throw error
        }
        // The copy carries its source's lock and access list, and either can forbid the rename.
        let guards = RenameGuards.lift(from: stage)
        defer { guards.free() }
        let code = renameExclusive(from: stage, to: destination)
        guard code == 0 else {
            discard(stage)
            throw posixError(code, operation: "rename", path: destination)
        }
        guards.apply(to: destination)
    }

    /// A move onto a FREE name: one rename on the same volume, `copyWhole` and the removal of
    /// the source across volumes. Unlike `move`, it never replaces what already holds the name
    /// (`EEXIST`) and never leaves half a tree at the destination.
    /// - Returns: `true` if it was a rename, `false` if a copy had to be made.
    @discardableResult
    static func moveWhole(from source: String, to destination: String,
                          progress: ((Int64, Int64, String) -> Void)? = nil,
                          shouldCancel: (() -> Bool)? = nil) throws -> Bool {
        // SMB: swap in the Unicode-normalization form the server actually accepts.
        let source = existingPathForm(source).path
        let code = renameExclusive(from: source, to: destination)
        if code == 0 { return true }
        guard code == EXDEV else { throw posixError(code, operation: "rename", path: source) }
        try copyWhole(from: source, to: destination, progress: progress, shouldCancel: shouldCancel)
        try removeMovedSource(source)
        return false
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

    /// Paths (up to `CopyfileContext.keptFailures`) of the objects a copy could not bring over —
    /// in `userInfo` of the error `copy` throws when the tree arrived incomplete.
    static let failedPathsKey = "FCXLFailedPaths"

    private static func copyfileWithProgress(
        from source: String,
        to destination: String,
        progress: ((Int64, Int64, String) -> Void)?,
        shouldCancel: (() -> Bool)?
    ) throws {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }

        // Pre-calculate total size for progress reporting
        var totalSize: Int64 = 0
        var srcStat = stat()
        if progress != nil, stat(source, &srcStat) == 0 {
            totalSize = Int64(srcStat.st_size)
        }

        // The observer is installed ALWAYS, not only when somebody wants progress or a way to
        // cancel: it is the one place that learns which objects copyfile could not copy. With an
        // observer copyfile does not stop at an error — it ASKS, and the answer decides whether
        // a lost file is reported or silently forgotten.
        let context = CopyfileContext(
            progress: progress,
            shouldCancel: shouldCancel,
            source: source,
            totalBytes: totalSize
        )
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX),
                           Unmanaged.passUnretained(context).toOpaque())

        let callback: copyfile_callback_t = { what, stage, state, src, dst, ctx in
            // errno of the failure being reported — read it before anything else can change it.
            let reported = errno
            guard let ctx else { return COPYFILE_CONTINUE }
            let context = Unmanaged<CopyfileContext>.fromOpaque(ctx).takeUnretainedValue()

            if context.stopped { return COPYFILE_QUIT }
            if context.shouldCancel?() == true {
                context.cancelled = true
                context.stopped = true
                return COPYFILE_QUIT
            }

            if stage == COPYFILE_ERR {
                return context.failed(
                    what: what, code: reported,
                    source: src.map { String(cString: $0) } ?? context.source,
                    destination: dst.map { String(cString: $0) })
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
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB),
                           unsafeBitCast(callback, to: UnsafeRawPointer.self))

        // No COPYFILE_CLONE: across volumes nothing can be cloned anyway (one volume is served
        // by clonefile() in `copy`), and with it a folder is created with the source's mode at
        // once — a read-only folder (555) then refuses its own contents. Without the flag the
        // folder is made writable and receives its real mode after the contents are in.
        // COPYFILE_EXCL is what COPYFILE_CLONE implied and what the callers rely on: an existing
        // destination is a conflict for them to resolve, never something to write over.
        let flags: copyfile_flags_t = UInt32(COPYFILE_ALL) | UInt32(COPYFILE_EXCL)
            | UInt32(COPYFILE_RECURSIVE) | UInt32(COPYFILE_NOFOLLOW)
        let (result, err) = withExtendedLifetime(context) { () -> (Int32, Int32) in
            let result = copyfile(source, destination, state, flags)
            return (result, errno)
        }

        // A file whose bytes stopped half way is not a copy. It looks like one, so it goes.
        // These paths were created by this very call (COPYFILE_EXCL) — nothing older is removed.
        for stump in context.stumps {
            unlink(stump)
        }

        if context.cancelled {
            throw CocoaError(.userCancelled)
        }
        if let first = context.failures.first {
            throw incompleteCopyError(first: first, count: context.failureCount,
                                      paths: context.failures.map(\.path))
        }
        if result != 0 {
            if err == ECANCELED {
                throw CocoaError(.userCancelled)
            }
            throw posixError(err, operation: "copyfile", path: source)
        }
    }

    /// The tree arrived, but not all of it: names the first object left behind and the reason.
    private static func incompleteCopyError(
        first: (path: String, code: Int32), count: Int, paths: [String]
    ) -> NSError {
        let name = (first.path as NSString).lastPathComponent
        let reason = String(cString: strerror(first.code))
        log.error("copyfile: \(count, privacy: .public) object(s) not copied, first: \(reason, privacy: .public) path=\(first.path, privacy: .private)")
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(first.code),
            userInfo: [
                NSLocalizedDescriptionKey: count == 1
                    ? L("copy.notCopiedOne", name, reason)
                    : L("copy.notCopiedMany", count, name, reason),
                NSFilePathErrorKey: first.path,
                failedPathsKey: paths
            ]
        )
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
    /// How many failed paths are kept for the report; the rest are only counted.
    static let keptFailures = 20

    let progress: ((Int64, Int64, String) -> Void)?
    let shouldCancel: (() -> Bool)?
    let source: String
    let totalBytes: Int64
    /// Accumulated bytes from previously finished files (for recursive copies).
    var accumulatedBytes: Int64 = 0
    /// Bytes copied so far in the current file.
    var currentFileBytes: Int64 = 0

    /// The user asked to stop.
    var cancelled = false
    /// Nothing more is to be copied: the user cancelled or the destination takes no more.
    var stopped = false
    /// Objects that did not make it, first come first (at most `keptFailures`).
    private(set) var failures: [(path: String, code: Int32)] = []
    /// How many objects did not make it in all.
    private(set) var failureCount = 0
    /// Destination files whose bytes stopped half way — to be removed after the copy.
    private(set) var stumps: [String] = []

    init(progress: ((Int64, Int64, String) -> Void)?, shouldCancel: (() -> Bool)?, source: String, totalBytes: Int64 = 0) {
        self.progress = progress
        self.shouldCancel = shouldCancel
        self.source = source
        self.totalBytes = totalBytes
    }

    /// The answer to copyfile reporting an object it could not copy.
    ///
    /// Never `COPYFILE_CONTINUE` for the object itself: for a file that means "forget it and go
    /// on" (the file is lost without a word), for a failed write it means "try again" (an
    /// endless loop on a full disk). The object is written down and skipped, the rest of the
    /// tree keeps copying; a destination that takes no more stops the whole copy.
    func failed(what: Int32, code: Int32, source: String, destination: String?) -> Int32 {
        switch what {
        case COPYFILE_COPY_DATA:
            if let destination { stumps.append(destination) }
        case COPYFILE_RECURSE_FILE, COPYFILE_RECURSE_DIR, COPYFILE_RECURSE_ERROR:
            break
        default:
            // Extended attributes and a folder's closing metadata pass: the bytes are in place.
            return COPYFILE_CONTINUE
        }
        let code = code == 0 ? EIO : code
        failureCount += 1
        if failures.count < Self.keptFailures {
            failures.append((source, code))
        }
        if code == ENOSPC || code == EDQUOT || code == EROFS {
            stopped = true
            return COPYFILE_QUIT
        }
        return COPYFILE_SKIP
    }
}
