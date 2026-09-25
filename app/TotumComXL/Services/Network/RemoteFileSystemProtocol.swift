import Foundation

/// Unified protocol for all remote filesystem backends (FTP, SFTP, WebDAV, SMB).
/// Each implementation wraps a specific network library but exposes the same interface,
/// allowing PanelViewModel to display remote files identically to local files.
protocol RemoteFileSystemProtocol: AnyObject {

    /// Whether the connection is currently alive.
    var isConnected: Bool { get }

    /// Human-readable protocol name for UI display (e.g. "FTP", "SFTP", "WebDAV").
    var protocolDisplayName: String { get }

    // MARK: - Connection lifecycle

    /// Establish connection using credentials from the associated RemoteConnection.
    func connect() async throws

    /// Gracefully close the connection.
    func disconnect()

    // MARK: - Directory operations

    /// List contents of a remote directory, returning FileItem array suitable for PanelViewModel.
    /// - Parameter path: Absolute remote path (Unix-style, e.g. "/home/user/docs").
    func listDirectory(at path: String) async throws -> [FileItem]

    /// Create a new directory on the remote server.
    func createDirectory(at path: String, name: String) async throws

    // MARK: - File operations

    /// Delete a remote file or directory.
    func deleteItem(at path: String, isDirectory: Bool) async throws

    /// Rename or move a remote item.
    func rename(at path: String, to newName: String) async throws

    /// Move a remote item to a different directory (server-side, uses RNFR/RNTO for FTP).
    func moveItem(from sourcePath: String, to destinationPath: String) async throws

    // MARK: - Transfer

    /// Download a remote file to a local path.
    /// - Parameter progress: Callback `(bytesDone, bytesTotal) -> shouldCancel`.
    ///   Return `true` from the callback to cancel the transfer.
    func download(remotePath: String, to localPath: String,
                  progress: @escaping (_ bytesDone: Int64, _ bytesTotal: Int64) -> Bool) async throws

    /// Upload a local file to a remote path.
    /// - Parameter progress: Callback `(bytesDone, bytesTotal) -> shouldCancel`.
    func upload(localPath: String, to remotePath: String,
                progress: @escaping (_ bytesDone: Int64, _ bytesTotal: Int64) -> Bool) async throws

    /// Whether an interrupted transfer can be picked up where it stopped instead of started
    /// over. FTP and SFTP can; WebDAV and SMB cannot, and simply begin again from zero.
    var supportsResume: Bool { get }

    /// Умеет ли хранилище снести папку со всем содержимым одним действием.
    ///
    /// У облаков и S3 такое действие есть, и оно стоит одного обращения. Обход дерева
    /// своими руками — запрос на каждый файл: на папке в двести файлов это двести
    /// обращений и минуты ожидания вместо секунды. У FTP и SFTP выбора нет: там непустую
    /// папку не удалить, содержимое приходится выносить самим.
    var deletesTreesItself: Bool { get }

    /// Whether a broken upload picks itself up without a draft under a spare name.
    ///
    /// S3 keeps an unfinished upload on its own side, complete with the parts it has taken,
    /// so the usual `.part` twin buys nothing there — and the rename at the end would be a
    /// server-side copy of the whole object: paid for by the gigabyte and capped at five.
    var uploadResumesItself: Bool { get }

    /// The same two transfers, continued from `resumeFrom` bytes already at the destination.
    /// Zero means "from the beginning", and the destination is truncated.
    ///
    /// Progress is reported for the WHOLE file — offset included — so a reconnect does not
    /// throw the bar back to zero. A far end that refuses to continue throws
    /// `RemoteFileSystemError.resumeRefused`: the caller must drop what it has and ask again
    /// from zero, since retrying the same way would fail forever.
    func download(remotePath: String, to localPath: String, resumeFrom: Int64,
                  progress: @escaping (_ bytesDone: Int64, _ bytesTotal: Int64) -> Bool) async throws

    func upload(localPath: String, to remotePath: String, resumeFrom: Int64,
                progress: @escaping (_ bytesDone: Int64, _ bytesTotal: Int64) -> Bool) async throws

    // MARK: - Path utilities

    /// Compute the parent path for a given remote path.
    func parentPath(for path: String) -> String

    /// The root path for this connection (e.g. "/" or "/home/user").
    var rootPath: String { get }
}

// MARK: - Default implementations

extension RemoteFileSystemProtocol {

    /// Everyone else needs the draft-and-rename dance.
    var uploadResumesItself: Bool { false }

    /// По умолчанию — нет: обычный сервер требует, чтобы папку освободили перед удалением.
    var deletesTreesItself: Bool { false }

    /// The honest default: a backend says nothing about resuming, so it cannot do it.
    var supportsResume: Bool { false }

    /// …and then continuing is just starting over. The caller only ever passes a non-zero
    /// offset to a backend that claims `supportsResume`, so the offset is not silently
    /// ignored here — there is simply nothing to ignore.
    func download(remotePath: String, to localPath: String, resumeFrom: Int64,
                  progress: @escaping (Int64, Int64) -> Bool) async throws {
        try await download(remotePath: remotePath, to: localPath, progress: progress)
    }

    func upload(localPath: String, to remotePath: String, resumeFrom: Int64,
                progress: @escaping (Int64, Int64) -> Bool) async throws {
        try await upload(localPath: localPath, to: remotePath, progress: progress)
    }

    func parentPath(for path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1
            ? String(path.dropLast())
            : path
        guard let lastSlash = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[trimmed.startIndex..<lastSlash])
        return parent.isEmpty ? "/" : parent
    }

    var rootPath: String { "/" }
}

// MARK: - Remote errors

enum RemoteFileSystemError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed(String)
    /// Сервер не принял имя или пароль. В строке лежит уже готовое объяснение — вместе со
    /// словами самого сервера, если он их сказал (см. `RemoteLogin`).
    case loginRefused(String)
    case timeout
    case pathNotFound(String)
    case permissionDenied(String)
    case transferFailed(String)
    case transferCancelled
    /// The far end will not continue an interrupted transfer — start over from zero.
    case resumeRefused(String)
    case operationFailed(String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return L("network.error.notConnected")
        case .connectionFailed(let detail):
            return L("network.error.connectionFailed", detail)
        case .authenticationFailed(let detail):
            return L("network.error.authFailed", detail)
        case .loginRefused(let reason):
            // Уже сложенное предложение: приставка «Ошибка такая-то:» здесь только мешала бы.
            return reason
        case .timeout:
            return L("network.error.timeout")
        case .pathNotFound(let path):
            return L("network.error.pathNotFound", path)
        case .permissionDenied(let path):
            return L("network.error.permissionDenied", path)
        case .transferFailed(let detail):
            return L("network.error.transferFailed", detail)
        case .transferCancelled:
            return L("network.error.transferCancelled")
        case .resumeRefused(let detail):
            return L("network.error.resumeRefused", detail)
        case .operationFailed(let detail):
            return L("network.error.operationFailed", detail)
        case .protocolError(let detail):
            return L("network.error.protocolError", detail)
        }
    }

    /// Three endings look alike coming out of a bridge: the person pressed Cancel, the link
    /// broke, or the far end cannot continue an interrupted transfer. Only the last one must
    /// stop the caller from retrying the same way, so it gets a case of its own.
    static func fromTransfer(_ error: Error) -> RemoteFileSystemError {
        let message = error.localizedDescription
        if message.contains("Cancel") { return .transferCancelled }
        if CoreErrorCode.of(error) == .notSupported { return .resumeRefused(message) }
        return .transferFailed(message)
    }
}
