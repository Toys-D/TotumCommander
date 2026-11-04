import XCTest

@testable import TotumComXLApp

/// A no-op RemoteFileSystemProtocol used to drive RemoteSession without any real network.
/// It records connect/disconnect and inherits the protocol's default `parentPath`/`rootPath`.
private final class StubRemoteFileSystem: RemoteFileSystemProtocol {
    var isConnected = false
    let protocolDisplayName = "STUB"
    private(set) var didConnect = false
    private(set) var didDisconnect = false

    func connect() async throws { didConnect = true; isConnected = true }
    func disconnect() { didDisconnect = true; isConnected = false }
    func listDirectory(at path: String) async throws -> [FileItem] { [] }
    func createDirectory(at path: String, name: String) async throws {}
    func deleteItem(at path: String, isDirectory: Bool) async throws {}
    func rename(at path: String, to newName: String) async throws {}
    func moveItem(from sourcePath: String, to destinationPath: String) async throws {}
    func download(remotePath: String, to localPath: String,
                  progress: @escaping (Int64, Int64) -> Bool) async throws {}
    func upload(localPath: String, to remotePath: String,
                progress: @escaping (Int64, Int64) -> Bool) async throws {}
}

/// Tests for `RemoteSession` (session lifecycle + display strings), the protocol's default
/// `parentPath` (remote breadcrumb "up" logic) and the localized `RemoteFileSystemError` messages.
@MainActor
final class RemoteSessionTests: XCTestCase {

    private func session(label: String = "", proto: RemoteProtocol = .ftp,
                         host: String = "h", initialPath: String = "/") -> RemoteSession {
        let conn = RemoteConnection(label: label, proto: proto, host: host, initialPath: initialPath)
        return RemoteSession(connection: conn, fileSystem: StubRemoteFileSystem())
    }

    // MARK: - init

    func test_init_usesInitialPath() {
        XCTAssertEqual(session(initialPath: "/home/dima").currentRemotePath, "/home/dima")
    }

    func test_init_emptyInitialPathBecomesRoot() {
        XCTAssertEqual(session(initialPath: "").currentRemotePath, "/")
    }

    func test_init_idMatchesConnection() {
        let conn = RemoteConnection(proto: .sftp, host: "h")
        let s = RemoteSession(connection: conn, fileSystem: StubRemoteFileSystem())
        XCTAssertEqual(s.id, conn.id)
        XCTAssertFalse(s.isConnected)
    }

    // MARK: - tabTitle

    func test_tabTitle_prefersLabel() {
        XCTAssertEqual(session(label: "Мой сервер").tabTitle, "Мой сервер")
    }

    func test_tabTitle_fallsBackToProtoAndHost() {
        XCTAssertEqual(session(label: "", proto: .sftp, host: "10.0.0.1").tabTitle, "SFTP: 10.0.0.1")
    }

    // MARK: - displayPath

    func test_displayPath_root() {
        XCTAssertEqual(session(initialPath: "/").displayPath, "/")
    }

    func test_displayPath_deepPath() {
        let s = session(initialPath: "/var/www")
        XCTAssertEqual(s.displayPath, "/var/www")
    }

    // MARK: - connect / disconnect lifecycle

    func test_connect_setsConnected() async throws {
        let s = session()
        try await s.connect()
        XCTAssertTrue(s.isConnected)
        XCTAssertNil(s.connectionError)
    }

    func test_disconnect_clearsConnected() async throws {
        let s = session()
        try await s.connect()
        s.disconnect()
        XCTAssertFalse(s.isConnected)
    }

    // MARK: - parentPath default implementation (remote breadcrumb "up")

    func test_parentPath_stripsLastComponent() {
        let fs = StubRemoteFileSystem()
        XCTAssertEqual(fs.parentPath(for: "/a/b/c"), "/a/b")
        XCTAssertEqual(fs.parentPath(for: "/home/user"), "/home")
    }

    func test_parentPath_ignoresTrailingSlash() {
        let fs = StubRemoteFileSystem()
        XCTAssertEqual(fs.parentPath(for: "/a/b/c/"), "/a/b")
    }

    func test_parentPath_singleLevelAndRootGoToRoot() {
        let fs = StubRemoteFileSystem()
        XCTAssertEqual(fs.parentPath(for: "/a"), "/")
        XCTAssertEqual(fs.parentPath(for: "/"), "/")
    }

    func test_rootPath_defaultsToSlash() {
        XCTAssertEqual(StubRemoteFileSystem().rootPath, "/")
    }

    // MARK: - RemoteFileSystemError messages

    func test_errorDescriptions_areNonEmpty() {
        let errors: [RemoteFileSystemError] = [
            .notConnected, .connectionFailed("x"), .authenticationFailed("x"), .timeout,
            .pathNotFound("/p"), .permissionDenied("/p"), .transferFailed("x"),
            .transferCancelled, .operationFailed("x"), .protocolError("x")
        ]
        for e in errors {
            let desc = e.errorDescription
            XCTAssertNotNil(desc)
            XCTAssertFalse(desc?.isEmpty ?? true, "\(e) had an empty description")
        }
    }
}
