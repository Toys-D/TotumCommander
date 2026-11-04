import Foundation
import FCXLBridgeObjC
import os.log

/// Manages long-lived NTFS write sessions via libntfs-3g.
/// When an NTFS volume is detected on mount, the manager:
///   1. Asks for admin password once (via osascript)
///   2. Unmounts macOS read-only NTFS driver
///   3. Opens raw device via libntfs-3g
///   4. Keeps the session alive for the entire connection
///
/// All directory listing and file operations for managed volumes
/// go through this manager instead of FileManager.
@MainActor
final class NTFSSessionManager {
    static let shared = NTFSSessionManager()

    private static let log = Logger(subsystem: "com.fcxl", category: "NTFSSession")

    struct ManagedVolume {
        let devicePath: String
        let mountPoint: String      // original macOS mount point, e.g. "/Volumes/Toshiba 1T USB"
        let volumeName: String
        let bridge: FCXLNTFSBridge  // long-lived session
    }

    /// Active NTFS sessions keyed by normalized mount point path.
    private(set) var managedVolumes: [String: ManagedVolume] = [:]

    /// Dedicated serial queue for all libntfs-3g I/O (thread safety — libntfs-3g is NOT thread-safe).
    private let ntfsQueue = DispatchQueue(label: "com.fcxl.ntfs-session", qos: .userInitiated)

    /// Set of mount points currently being activated (prevents double-activation).
    private var activating: Set<String> = []

    private init() {}

    // MARK: - Path matching

    /// Returns the managed volume for a given absolute path, or nil if not NTFS-managed.
    func managedVolume(for path: String) -> ManagedVolume? {
        let normalized = normalizePath(path)
        for (mountPoint, vol) in managedVolumes {
            if normalized == mountPoint || normalized.hasPrefix(mountPoint + "/") {
                return vol
            }
        }
        return nil
    }

    /// Check if a path is under an NTFS-managed volume.
    func isManaged(_ path: String) -> Bool {
        managedVolume(for: path) != nil
    }

    /// Convert an absolute path to a relative path within its NTFS volume.
    func relativePath(for absolutePath: String, in volume: ManagedVolume) -> String {
        let normalized = normalizePath(absolutePath)
        let mountLen = volume.mountPoint.count
        if normalized.count > mountLen {
            return String(normalized[normalized.index(normalized.startIndex, offsetBy: mountLen)...])
        }
        return "/"
    }

    // MARK: - Session lifecycle

    /// Activate NTFS session for a newly mounted volume.
    /// Shows ONE admin password prompt, unmounts macOS driver, opens libntfs-3g.
    /// Returns true if activation succeeded.
    @discardableResult
    func activateSession(devicePath: String, mountPoint: String) async -> Bool {
        let normalizedMount = normalizePath(mountPoint)

        // Already managed or being activated?
        guard managedVolumes[normalizedMount] == nil,
              !activating.contains(normalizedMount) else {
            return managedVolumes[normalizedMount] != nil
        }

        activating.insert(normalizedMount)
        defer { activating.remove(normalizedMount) }

        let volumeName = (mountPoint as NSString).lastPathComponent
        Self.log.info("Activating NTFS session for \(volumeName) — device: \(devicePath)")

        // Suppress "disk disconnected" alert for this mount point
        FileOperationsService.ntfsWritingVolumes.insert(normalizedMount)
        FileOperationsService.ntfsWritingVolumes.insert(mountPoint)

        // Run the bridge open on the NTFS queue (blocks for admin prompt + ntfs_mount)
        let bridge = FCXLNTFSBridge()
        let success: Bool = await withCheckedContinuation { continuation in
            ntfsQueue.async {
                do {
                    try bridge.openVolume(withDevice: devicePath, mountPoint: mountPoint)
                    continuation.resume(returning: true)
                } catch {
                    Self.log.error("NTFS activation failed for \(volumeName): \(error.localizedDescription)")
                    continuation.resume(returning: false)
                }
            }
        }

        if success {
            let managed = ManagedVolume(
                devicePath: devicePath,
                mountPoint: normalizedMount,
                volumeName: volumeName,
                bridge: bridge
            )
            managedVolumes[normalizedMount] = managed
            Self.log.info("NTFS session active for \(volumeName) — full read/write access")
            return true
        } else {
            // Activation failed (user cancelled or error) — remove suppression
            FileOperationsService.ntfsWritingVolumes.remove(normalizedMount)
            FileOperationsService.ntfsWritingVolumes.remove(mountPoint)
            return false
        }
    }

    /// Close session for a specific volume (eject or app quit).
    func deactivateSession(mountPoint: String) async {
        let normalizedMount = normalizePath(mountPoint)
        guard let managed = managedVolumes.removeValue(forKey: normalizedMount) else { return }

        Self.log.info("Deactivating NTFS session for \(managed.volumeName)")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ntfsQueue.async {
                try? managed.bridge.closeVolume()
                continuation.resume()
            }
        }

        FileOperationsService.ntfsWritingVolumes.remove(normalizedMount)
        FileOperationsService.ntfsWritingVolumes.remove(mountPoint)
        Self.log.info("NTFS session closed, volume restored: \(managed.volumeName)")
    }

    /// Close all sessions synchronously (app termination).
    nonisolated func deactivateAllSessions() {
        // Called from willTerminate — run synchronously on ntfs queue
        let volumes: [ManagedVolume]
        // We can't use MainActor here during termination, access directly
        volumes = Array(MainActor.assumeIsolated { managedVolumes.values })

        for vol in volumes {
            ntfsQueue.sync {
                try? vol.bridge.closeVolume()
            }
        }

        MainActor.assumeIsolated {
            managedVolumes.removeAll()
            FileOperationsService.ntfsWritingVolumes.removeAll()
        }
    }

    // MARK: - Directory listing

    /// List directory via libntfs-3g. Returns FileItem array.
    func listDirectory(at absolutePath: String, showHidden: Bool) async throws -> [FileItem] {
        guard let vol = managedVolume(for: absolutePath) else {
            throw NSError(domain: "NTFSSessionManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Path not under NTFS-managed volume"])
        }

        let relPath = relativePath(for: absolutePath, in: vol)
        let bridge = vol.bridge
        let normalizedAbsPath = normalizePath(absolutePath)

        return try await withCheckedThrowingContinuation { continuation in
            ntfsQueue.async {
                do {
                    let rawEntries = try bridge.listDirectory(atPath: relPath)

                    var items: [FileItem] = []
                    for dict in rawEntries {
                        guard let name = dict["name"] as? String else { continue }

                        let isHidden = (dict["isHidden"] as? Bool) ?? false
                        if isHidden && !showHidden { continue }

                        let isDir = (dict["isDirectory"] as? Bool) ?? false
                        let size = (dict["size"] as? Int64).map { UInt64($0) } ?? 0
                        let modTime = (dict["dateModified"] as? Double) ?? 0
                        let createTime = (dict["dateCreated"] as? Double) ?? 0

                        let ext = isDir ? "" : (name as NSString).pathExtension
                        let fullPath = normalizedAbsPath.hasSuffix("/")
                            ? normalizedAbsPath + name
                            : normalizedAbsPath + "/" + name

                        let item = FileItem(
                            path: fullPath,
                            name: name,
                            fileExtension: ext,
                            size: size,
                            isDirectory: isDir,
                            isHidden: isHidden,
                            isSymlink: false,
                            permissions: isDir ? "drwxr-xr-x" : "-rw-r--r--",
                            dateModified: Date(timeIntervalSince1970: modTime),
                            dateCreated: createTime > 0 ? Date(timeIntervalSince1970: createTime) : nil,
                            owner: ""
                        )
                        items.append(item)
                    }
                    continuation.resume(returning: items)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - File operations (using existing session)

    /// Copy a local file or directory to an NTFS volume.
    func copyToNTFS(
        sourcePath: String,
        destAbsolutePath: String,
        progress: ((Int64, Int64, String) -> Void)? = nil,
        cancel: (() -> Bool)? = nil
    ) async throws {
        guard let vol = managedVolume(for: destAbsolutePath) else {
            throw NSError(domain: "NTFSSessionManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Destination not under NTFS-managed volume"])
        }

        let relPath = relativePath(for: destAbsolutePath, in: vol)
        let bridge = vol.bridge

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            ntfsQueue.async {
                do {
                    var srcIsDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: sourcePath, isDirectory: &srcIsDir)

                    let progressBlock: ((Int64, Int64, String) -> Void)? = progress.map { p in
                        { copied, total, file in p(copied, total, file) }
                    }
                    let cancelBlock: (() -> Bool)? = cancel

                    if srcIsDir.boolValue {
                        try bridge.copyTree(from: sourcePath, to: relPath,
                                           progress: progressBlock, cancel: cancelBlock)
                    } else {
                        try bridge.copyFile(from: sourcePath, to: relPath,
                                           progress: progressBlock, cancel: cancelBlock)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Read a file from NTFS to local filesystem.
    func readFromNTFS(
        ntfsAbsolutePath: String,
        localDestPath: String,
        progress: ((Int64, Int64, String) -> Void)? = nil,
        cancel: (() -> Bool)? = nil
    ) async throws {
        guard let vol = managedVolume(for: ntfsAbsolutePath) else {
            throw NSError(domain: "NTFSSessionManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Source not under NTFS-managed volume"])
        }

        let relPath = relativePath(for: ntfsAbsolutePath, in: vol)
        let bridge = vol.bridge

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            ntfsQueue.async {
                do {
                    try bridge.readFile(from: relPath, toLocalPath: localDestPath,
                                       progress: progress, cancel: cancel)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Create a directory on NTFS.
    func mkdir(ntfsAbsolutePath: String) async throws {
        guard let vol = managedVolume(for: ntfsAbsolutePath) else {
            throw NSError(domain: "NTFSSessionManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Path not under NTFS-managed volume"])
        }

        let relPath = relativePath(for: ntfsAbsolutePath, in: vol)
        let bridge = vol.bridge

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            ntfsQueue.async {
                do {
                    try bridge.mkdir(atPath: relPath)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Delete a file or directory on NTFS.
    func remove(ntfsAbsolutePath: String) async throws {
        guard let vol = managedVolume(for: ntfsAbsolutePath) else {
            throw NSError(domain: "NTFSSessionManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Path not under NTFS-managed volume"])
        }

        let relPath = relativePath(for: ntfsAbsolutePath, in: vol)
        let bridge = vol.bridge

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            ntfsQueue.async {
                do {
                    try bridge.remove(atPath: relPath)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Synchronous queue access (for FileOperationsService background threads)

    /// Execute a block synchronously on the ntfsQueue. Use this from background threads
    /// that need to call bridge methods directly (e.g., performNTFSTransfer).
    /// MUST NOT be called from ntfsQueue itself (deadlock).
    nonisolated func executeOnQueue<T>(_ block: @escaping () throws -> T) throws -> T {
        var result: Result<T, Error>!
        ntfsQueue.sync {
            do {
                result = .success(try block())
            } catch {
                result = .failure(error)
            }
        }
        switch result! {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    // MARK: - Helpers

    private func normalizePath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.standardizedFileURL.path
    }
}
