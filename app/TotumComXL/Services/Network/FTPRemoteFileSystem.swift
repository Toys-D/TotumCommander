import Foundation
import FCXLBridgeObjC

/// FTP/FTPS remote filesystem implementation via libcurl (C++ bridge).
/// IMPORTANT: All libcurl operations go through a single serial queue because
/// a CURL* handle is NOT thread-safe — concurrent access causes memory corruption.
final class FTPRemoteFileSystem: RemoteFileSystemProtocol {
    private let connection: RemoteConnection
    private let password: String
    private let bridge = FCXLFTPBridge()
    private(set) var isConnected: Bool = false

    /// Serial queue for ALL curl operations — prevents concurrent access to the CURL* handle.
    private let ftpQueue = DispatchQueue(label: "com.fcxl.ftp-client", qos: .userInitiated)

    var protocolDisplayName: String { connection.proto == .ftps ? "FTPS" : "FTP" }
    var rootPath: String { connection.initialPath.isEmpty ? "/" : connection.initialPath }

    init(connection: RemoteConnection, password: String) {
        self.connection = connection
        self.password = password
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ftpQueue.async { [self] in
                do {
                    try bridge.connect(
                        toHost: connection.host,
                        port: connection.effectivePort,
                        username: connection.username,
                        password: password,
                        useTLS: connection.proto == .ftps,
                        passiveMode: connection.passiveMode,
                        timeout: 10
                    )
                    self.isConnected = true
                    continuation.resume()
                } catch {
                    // Отказ во входе — не то же, что недоступный сервер: на него окно
                    // спросит имя и пароль заново.
                    continuation.resume(throwing: RemoteLogin.error(from: error))
                }
            }
        }
    }

    func disconnect() {
        isConnected = false
        ftpQueue.async { [self] in
            bridge.disconnect()
        }
    }

    func listDirectory(at path: String) async throws -> [FileItem] {
        guard isConnected else { throw RemoteFileSystemError.notConnected }

        return try await withCheckedThrowingContinuation { continuation in
            ftpQueue.async { [self] in
                do {
                    let entries = try bridge.listDirectory(at: path)
                    let items: [FileItem] = entries.map { entry in
                        FileItem(
                            path: entry.path,
                            name: entry.name,
                            fileExtension: entry.fileExtension,
                            size: entry.size,
                            isDirectory: entry.isDirectory,
                            isHidden: entry.isHidden,
                            isSymlink: entry.isSymlink,
                            permissions: entry.permissions,
                            dateModified: entry.modificationDate ?? Date.distantPast,
                            dateCreated: nil,
                            owner: entry.owner
                        )
                    }
                    continuation.resume(returning: items)
                } catch {
                    continuation.resume(throwing: RemoteFileSystemError.operationFailed(
                        error.localizedDescription))
                }
            }
        }
    }

    func createDirectory(at path: String, name: String) async throws {
        guard isConnected else { throw RemoteFileSystemError.notConnected }
        let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
        try await runOnFTPQueue { [self] in try bridge.createDirectory(at: fullPath) }
    }

    func deleteItem(at path: String, isDirectory: Bool) async throws {
        guard isConnected else { throw RemoteFileSystemError.notConnected }
        try await runOnFTPQueue { [self] in
            if isDirectory { try bridge.deleteDirectory(at: path) }
            else { try bridge.deleteFile(at: path) }
        }
    }

    func rename(at path: String, to newName: String) async throws {
        guard isConnected else { throw RemoteFileSystemError.notConnected }
        let parent = parentPath(for: path)
        let newPath = parent.hasSuffix("/") ? parent + newName : parent + "/" + newName
        try await runOnFTPQueue { [self] in try bridge.rename(from: path, to: newPath) }
    }

    func moveItem(from sourcePath: String, to destinationPath: String) async throws {
        guard isConnected else { throw RemoteFileSystemError.notConnected }
        try await runOnFTPQueue { [self] in try bridge.rename(from: sourcePath, to: destinationPath) }
    }

    /// REST for downloads, APPE for uploads — both as old as FTP itself. Servers that lack
    /// them say so, and that answer arrives as `.resumeRefused`.
    var supportsResume: Bool { true }

    func download(remotePath: String, to localPath: String,
                  progress: @escaping (Int64, Int64) -> Bool) async throws {
        try await download(remotePath: remotePath, to: localPath, resumeFrom: 0,
                           progress: progress)
    }

    func upload(localPath: String, to remotePath: String,
                progress: @escaping (Int64, Int64) -> Bool) async throws {
        try await upload(localPath: localPath, to: remotePath, resumeFrom: 0, progress: progress)
    }

    func download(remotePath: String, to localPath: String, resumeFrom: Int64,
                  progress: @escaping (Int64, Int64) -> Bool) async throws {
        guard isConnected else { throw RemoteFileSystemError.notConnected }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ftpQueue.async { [self] in
                do {
                    // Fresh every time: a ceiling changed in Settings takes effect
                    // on the next file, not on the next launch.
                    bridge.setDownloadSpeedLimit(TransferSpeedLimit.bytesPerSecond,
                                                 uploadSpeedLimit: TransferSpeedLimit.bytesPerSecond)
                    try bridge.downloadFile(remotePath, to: localPath, resumeFrom: resumeFrom,
                                            progress: { done, total in
                        return progress(done, total)
                    })
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: RemoteFileSystemError.fromTransfer(error))
                }
            }
        }
    }

    func upload(localPath: String, to remotePath: String, resumeFrom: Int64,
                progress: @escaping (Int64, Int64) -> Bool) async throws {
        guard isConnected else { throw RemoteFileSystemError.notConnected }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ftpQueue.async { [self] in
                do {
                    // Fresh every time: a ceiling changed in Settings takes effect
                    // on the next file, not on the next launch.
                    bridge.setDownloadSpeedLimit(TransferSpeedLimit.bytesPerSecond,
                                                 uploadSpeedLimit: TransferSpeedLimit.bytesPerSecond)
                    try bridge.uploadFile(localPath, to: remotePath, resumeFrom: resumeFrom,
                                          progress: { done, total in
                        return progress(done, total)
                    })
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: RemoteFileSystemError.fromTransfer(error))
                }
            }
        }
    }


    // MARK: - Helper

    private func runOnFTPQueue(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ftpQueue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: RemoteFileSystemError.operationFailed(
                        error.localizedDescription))
                }
            }
        }
    }
}
