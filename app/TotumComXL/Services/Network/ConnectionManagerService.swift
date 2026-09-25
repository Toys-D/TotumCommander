import Foundation

/// Manages saved remote connection bookmarks and their credentials.
/// Passwords are stored securely in the macOS Keychain via KeychainService.
@MainActor
final class ConnectionManagerService: ObservableObject {
    static let shared = ConnectionManagerService()

    private static let storageKey = "fcxl.remoteConnections"

    @Published var connections: [RemoteConnection] = []

    private let passwordsFileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("FileCommanderXL", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        passwordsFileURL = appDir.appendingPathComponent("credentials.dat")
        migrateFromFileToKeychainIfNeeded()
        loadConnections()
    }

    // MARK: - CRUD

    func addConnection(_ connection: RemoteConnection) {
        connections.append(connection)
        saveConnections()
    }

    func updateConnection(_ connection: RemoteConnection) {
        guard let idx = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[idx] = connection
        saveConnections()
    }

    func removeConnection(_ id: UUID) {
        connections.removeAll { $0.id == id }
        KeychainService.delete(account: id.uuidString)
        saveConnections()
    }

    func connection(for id: UUID) -> RemoteConnection? {
        connections.first { $0.id == id }
    }

    func moveConnection(from source: IndexSet, to destination: Int) {
        connections.move(fromOffsets: source, toOffset: destination)
        saveConnections()
    }

    // MARK: - Passwords (Keychain)

    func setPassword(_ password: String, for connectionID: UUID) {
        // Записанный пароль отменяет введённый «на один раз»: иначе старое значение из
        // памяти пережило бы новое из связки ключей.
        unsavedPasswords.removeValue(forKey: connectionID)
        if password.isEmpty {
            KeychainService.delete(account: connectionID.uuidString)
        } else {
            KeychainService.save(password: password, account: connectionID.uuidString)
        }
    }

    /// Пароль, который человек ввёл, но не велел запоминать. Живёт до конца работы программы
    /// и никуда не записывается — без этого повторное подключение той же сессии (проба на
    /// параллельность, восстановление после обрыва) брало бы из связки старый, уже отвергнутый.
    private var unsavedPasswords: [UUID: String] = [:]

    func useOnce(_ password: String, for connectionID: UUID) {
        unsavedPasswords[connectionID] = password
    }

    func password(for connectionID: UUID) -> String? {
        unsavedPasswords[connectionID] ?? KeychainService.load(account: connectionID.uuidString)
    }

    // MARK: - One-time migration from XOR-obfuscated file

    /// Reads credentials.dat (if it exists), imports each password into the Keychain,
    /// then deletes the file. Called once from init(); no-op if the file is absent.
    private func migrateFromFileToKeychainIfNeeded() {
        guard FileManager.default.fileExists(atPath: passwordsFileURL.path),
              let data = try? Data(contentsOf: passwordsFileURL) else { return }

        // Deobfuscate: base64 decode → XOR → JSON
        if let decoded = Data(base64Encoded: data) {
            let xored = Self.xorData(decoded)
            if let dict = try? JSONDecoder().decode([String: String].self, from: xored) {
                for (uuidString, password) in dict {
                    KeychainService.save(password: password, account: uuidString)
                }
            }
        }

        try? FileManager.default.removeItem(at: passwordsFileURL)
    }

    /// Simple XOR obfuscation key — kept for migration only.
    /// Can be removed once all users have migrated (credentials.dat no longer exists).
    private static let xorKey: [UInt8] = [0x4F, 0x63, 0x58, 0x4C, 0x21, 0x72, 0x65, 0x6D]

    private static func xorData(_ data: Data) -> Data {
        var result = Data(count: data.count)
        for i in 0..<data.count {
            result[i] = data[i] ^ xorKey[i % xorKey.count]
        }
        return result
    }

    // MARK: - Persistence (UserDefaults JSON)

    private func loadConnections() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([RemoteConnection].self, from: data) {
            connections = decoded
            return
        }
        // Migrate from old connections.json format (pre-Build 742)
        migrateFromLegacyFile()
    }

    private func migrateFromLegacyFile() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let legacyFile = appSupport?.appendingPathComponent("FileCommanderXL/connections.json"),
              let data = try? Data(contentsOf: legacyFile),
              let legacy = try? JSONDecoder().decode([LegacyConnection].self, from: data) else {
            connections = []
            return
        }

        for old in legacy {
            let proto: RemoteProtocol
            switch old.connectionProtocol {
            case "FTP": proto = .ftp
            case "FTPS": proto = .ftps
            case "SFTP": proto = .sftp
            case "SMB": proto = .smb
            default: proto = .ftp
            }

            var conn = RemoteConnection(
                id: old.id,
                label: old.name,
                proto: proto,
                host: old.host,
                port: UInt16(clamping: old.port),
                username: old.username,
                initialPath: old.remotePath
            )
            if !old.privateKeyPath.isEmpty {
                conn.useKeyAuth = true
                conn.keyPath = old.privateKeyPath
            }

            connections.append(conn)
            if !old.password.isEmpty {
                setPassword(old.password, for: conn.id)
            }
        }

        if !connections.isEmpty {
            saveConnections()
        }
    }

    private struct LegacyConnection: Codable {
        let id: UUID
        var name: String
        var host: String
        var port: Int
        var username: String
        var password: String
        var privateKeyPath: String
        var connectionProtocol: String
        var remotePath: String
        var shareName: String
    }

    private func saveConnections() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    // MARK: - Session factory

    func createSession(for connection: RemoteConnection) -> RemoteSession {
        let pass = password(for: connection.id) ?? ""
        let fileSystem: RemoteFileSystemProtocol

        switch connection.proto {
        case .webdav, .webdavs:
            fileSystem = WebDAVRemoteFileSystem(connection: connection, password: pass)
        case .ftp, .ftps:
            fileSystem = FTPRemoteFileSystem(connection: connection, password: pass)
        case .sftp:
            fileSystem = SFTPRemoteFileSystem(connection: connection, password: pass)
        case .smb:
            fileSystem = SMBRemoteFileSystem(connection: connection, password: pass)
        case .s3:
            fileSystem = S3RemoteFileSystem(connection: connection, password: pass)
        case .rclone:
            // Пароль не передаётся: у rclone свои ключи к хранилищу, в его же настройке.
            fileSystem = RcloneRemoteFileSystem(connection: connection)
        }

        return RemoteSession(connection: connection, fileSystem: fileSystem)
    }

    // MARK: - Parallel-transfer capability (probed at connect time)

    /// Per-connection result of the "can this server open a 2nd connection?" probe.
    /// nil = not probed yet; true = parallel transfers OK; false = strictly one connection.
    /// @Published so the volume-bar remote badge repaints when the probe result lands.
    @Published private var parallelSupportByConnection: [UUID: Bool] = [:]

    func parallelSupport(for connectionID: UUID) -> Bool? {
        parallelSupportByConnection[connectionID]
    }

    func setParallelSupport(_ supported: Bool, for connectionID: UUID) {
        parallelSupportByConnection[connectionID] = supported
    }

    // MARK: - Live transfer connections (budgeted per server)

    /// Transfer connections the app currently holds to each saved connection. Retained when a
    /// transfer claims a connection and released when it disconnects. The queue budgets against
    /// THIS rather than against operation statuses, so it also accounts for direct (non-queued)
    /// transfers, which never appear in the operation list at all.
    private var activeTransferConnections: [UUID: Int] = [:]

    func retainTransferConnection(for connectionID: UUID) {
        activeTransferConnections[connectionID, default: 0] += 1
    }

    func releaseTransferConnection(for connectionID: UUID) {
        guard let n = activeTransferConnections[connectionID] else { return }
        if n <= 1 { activeTransferConnections.removeValue(forKey: connectionID) }
        else { activeTransferConnections[connectionID] = n - 1 }
    }

    func activeTransferCount(for connectionID: UUID) -> Int {
        activeTransferConnections[connectionID] ?? 0
    }

    /// How many transfers may run against THIS server at once. One for SMB (all its sessions
    /// share a single macOS mount, so a "second connection" isn't independent) and for servers
    /// the connect-time probe found to be single-connection; otherwise the user's setting.
    func concurrencyLimit(for connectionID: UUID, userMax: Int) -> Int {
        if let conn = connection(for: connectionID), conn.proto == .smb { return 1 }
        if parallelSupport(for: connectionID) == false { return 1 }
        return max(1, userMax)
    }
}
