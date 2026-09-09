import Foundation
import NetFS

/// SMB remote filesystem implementation using macOS NetFS framework.
/// Strategy: mount the SMB share via NetFSMountURLSync (credentials passed as API parameters,
/// system-chosen mount point), then use local filesystem operations for everything. This gives
/// full Finder-compatible access without a custom SMB stack — and without exposing the password
/// on the command line or needing write access to /Volumes.
final class SMBRemoteFileSystem: RemoteFileSystemProtocol {
    private let connection: RemoteConnection
    private let password: String
    private(set) var isConnected: Bool = false
    private var mountPoint: String?

    var protocolDisplayName: String { "SMB" }
    var rootPath: String {
        mountPoint ?? "/"
    }

    init(connection: RemoteConnection, password: String) {
        self.connection = connection
        self.password = password
    }

    func connect() async throws {
        let host = connection.host
        let user = connection.username
        let pass = password
        let share = connection.initialPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !host.isEmpty else {
            throw RemoteFileSystemError.connectionFailed("Host is empty")
        }

        // Build the URL WITHOUT credentials — they go to NetFSMountURLSync as separate
        // parameters (never on the command line), and NetFS creates the mount point itself.
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host
        if !share.isEmpty { components.path = "/\(share)" }
        guard let shareURL = components.url else {
            throw RemoteFileSystemError.connectionFailed("Invalid SMB URL for \(host)")
        }

        // guest ⇒ nil credentials (NetFS uses guest/Keychain); otherwise pass user+password.
        let userCF: CFString? = user.isEmpty ? nil : (user as CFString)
        let passCF: CFString? = user.isEmpty ? nil : (pass as CFString)

        let mp: String = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var mountPoints: Unmanaged<CFArray>?
                let status = NetFSMountURLSync(
                    shareURL as CFURL,
                    nil,       // mount path (nil = system-chosen /Volumes/…)
                    userCF,    // user
                    passCF,    // password — separate parameter, not visible via `ps`
                    nil,       // open options
                    nil,       // mount options
                    &mountPoints
                )
                if status == 0,
                   let pts = mountPoints?.takeRetainedValue() as? [String],
                   let mp = pts.first {
                    continuation.resume(returning: mp)
                } else {
                    continuation.resume(throwing: RemoteFileSystemError.connectionFailed(
                        "SMB mount failed (status \(status))"))
                }
            }
        }

        mountPoint = mp
        isConnected = true
    }

    func disconnect() {
        guard let mp = mountPoint else { return }
        // Unmount
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["unmount", mp]
        try? proc.run()
        proc.waitUntilExit()
        mountPoint = nil
        isConnected = false
    }

    func listDirectory(at path: String) async throws -> [FileItem] {
        guard isConnected, let mp = mountPoint else { throw RemoteFileSystemError.notConnected }

        // Resolve path: if it's "/" or relative, use mount point
        let resolvedPath: String
        if path == "/" || path.isEmpty {
            resolvedPath = mp
        } else if path.hasPrefix(mp) {
            resolvedPath = path
        } else {
            resolvedPath = mp + (path.hasPrefix("/") ? path : "/\(path)")
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: resolvedPath) else {
            throw RemoteFileSystemError.pathNotFound(resolvedPath)
        }

        let contents = try fm.contentsOfDirectory(atPath: resolvedPath)
        var items: [FileItem] = []

        for name in contents {
            let fullPath = (resolvedPath as NSString).appendingPathComponent(name)
            if let item = FileItem.fromPath(fullPath) {
                items.append(item)
            }
        }

        return items
    }

    func createDirectory(at path: String, name: String) async throws {
        guard isConnected, let mp = mountPoint else { throw RemoteFileSystemError.notConnected }
        let resolved = resolvePath(path, mp: mp)
        let fullPath = (resolved as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: fullPath, withIntermediateDirectories: false)
    }

    func deleteItem(at path: String, isDirectory: Bool) async throws {
        guard isConnected, let mp = mountPoint else { throw RemoteFileSystemError.notConnected }
        let resolved = resolvePath(path, mp: mp)
        try FileManager.default.removeItem(atPath: resolved)
    }

    func rename(at path: String, to newName: String) async throws {
        guard isConnected, let mp = mountPoint else { throw RemoteFileSystemError.notConnected }
        let resolved = resolvePath(path, mp: mp)
        let parent = (resolved as NSString).deletingLastPathComponent
        let newPath = (parent as NSString).appendingPathComponent(newName)
        try FileManager.default.moveItem(atPath: resolved, toPath: newPath)
    }

    func moveItem(from sourcePath: String, to destinationPath: String) async throws {
        guard isConnected, let mp = mountPoint else { throw RemoteFileSystemError.notConnected }
        let resolvedSrc = resolvePath(sourcePath, mp: mp)
        let resolvedDst = resolvePath(destinationPath, mp: mp)
        try FileManager.default.moveItem(atPath: resolvedSrc, toPath: resolvedDst)
    }

    func download(remotePath: String, to localPath: String,
                  progress: @escaping (Int64, Int64) -> Bool) async throws {
        guard isConnected, let mp = mountPoint else { throw RemoteFileSystemError.notConnected }
        let resolved = resolvePath(remotePath, mp: mp)
        try Self.copyFileWithProgress(from: resolved, to: localPath, progress: progress)
    }

    func upload(localPath: String, to remotePath: String,
                progress: @escaping (Int64, Int64) -> Bool) async throws {
        guard isConnected, let mp = mountPoint else { throw RemoteFileSystemError.notConnected }
        let resolved = resolvePath(remotePath, mp: mp)
        try? FileManager.default.removeItem(atPath: resolved)
        try Self.copyFileWithProgress(from: localPath, to: resolved, progress: progress)
    }

    /// Copy a file in 1 MB chunks, reporting bytes copied after each chunk so the progress bar
    /// advances DURING a large file (a plain FileManager.copyItem gives no intermediate
    /// progress — the bar sits at ~1% until the whole file is done). `progress` returning true
    /// means "cancel": the partial destination is removed and transferCancelled is thrown.
    /// Falls back to a plain copyItem for directories or if the handles can't be opened.
    private static func copyFileWithProgress(from src: String, to dst: String,
                                             progress: (Int64, Int64) -> Bool) throws {
        let fm = FileManager.default
        let total = ((try? fm.attributesOfItem(atPath: src))?[.size] as? Int64) ?? 0

        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: src, isDirectory: &isDir)
        // Directories (or a missing source) — let copyItem handle it and report once.
        if !exists || isDir.boolValue {
            try fm.copyItem(atPath: src, toPath: dst)
            _ = progress(total, total)
            return
        }

        guard let input = FileHandle(forReadingAtPath: src) else {
            try fm.copyItem(atPath: src, toPath: dst)
            _ = progress(total, total)
            return
        }
        defer { try? input.close() }

        // Written to a temporary sibling and swapped in at the end. Two failure modes of the old
        // in-place write both lost data: the existing remote copy was deleted BEFORE knowing the
        // new write could succeed, and a failed write fell into `try?` — reported as success, after
        // which a move deleted the local source. The file then existed nowhere.
        let tmp = dst + ".fcxlpart-" + UUID().uuidString
        guard fm.createFile(atPath: tmp, contents: nil),
              let output = FileHandle(forWritingAtPath: tmp) else {
            // Could not even create a file here (no permission, share read-only): surface it.
            // copyItem throws a descriptive error for the same reason instead of swallowing it.
            if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
            try fm.copyItem(atPath: src, toPath: dst)
            _ = progress(total, total)
            return
        }
        var committed = false
        defer {
            try? output.close()
            // Never leave a half-written .fcxlpart behind, whatever threw above.
            if !committed { try? fm.removeItem(atPath: tmp) }
        }

        let chunkSize = 1 << 20   // 1 MB
        var copied: Int64 = 0
        while true {
            let chunk = (try input.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            copied += Int64(chunk.count)
            if progress(copied, total) {   // cancelled — the old dst is still intact
                throw RemoteFileSystemError.transferCancelled
            }
        }
        try output.close()

        // Only now does the previous remote copy give way to the fully written new one.
        if fm.fileExists(atPath: dst) {
            _ = try fm.replaceItemAt(URL(fileURLWithPath: dst),
                                     withItemAt: URL(fileURLWithPath: tmp))
        } else {
            try fm.moveItem(atPath: tmp, toPath: dst)
        }
        committed = true
        _ = progress(copied, total)
    }

    func parentPath(for path: String) -> String {
        guard let mp = mountPoint else {
            let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
            return (trimmed as NSString).deletingLastPathComponent
        }
        let resolved = resolvePath(path, mp: mp)
        let parent = (resolved as NSString).deletingLastPathComponent
        // Don't go above mount point
        if parent.count < mp.count { return mp }
        return parent
    }

    // MARK: - Helpers

    private func resolvePath(_ path: String, mp: String) -> String {
        if path == "/" || path.isEmpty { return mp }
        if path.hasPrefix(mp) { return path }
        return mp + (path.hasPrefix("/") ? path : "/\(path)")
    }
}
