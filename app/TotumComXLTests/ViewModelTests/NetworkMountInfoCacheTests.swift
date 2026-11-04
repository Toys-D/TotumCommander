import XCTest

@testable import TotumComXLApp

/// Tests for the host → computer-name cache in `NetworkMountInfo` — the map that turns an SMB
/// share's IP into the friendly computer name shown in the breadcrumb / drive bar. Only the
/// cache-hit paths are exercised (record → computerName), which return before touching the LAN
/// browser singleton or spawning a NetBIOS lookup. Each test uses a unique host so the shared
/// static cache can't leak between cases.
@MainActor
final class NetworkMountInfoCacheTests: XCTestCase {

    private func uniqueHost() -> String { "nas-\(UUID().uuidString)" }

    func test_record_thenComputerName_returnsRecordedName() {
        let host = uniqueHost()
        NetworkMountInfo.record(host: host, name: "SERVER_SO")
        XCTAssertEqual(NetworkMountInfo.computerName(forHost: host), "SERVER_SO")
    }

    func test_lookup_isCaseInsensitive() {
        let host = uniqueHost()
        NetworkMountInfo.record(host: host.uppercased(), name: "NAS")
        XCTAssertEqual(NetworkMountInfo.computerName(forHost: host.lowercased()), "NAS")
    }

    func test_emptyName_doesNotOverwriteExisting() {
        let host = uniqueHost()
        NetworkMountInfo.record(host: host, name: "Good")
        NetworkMountInfo.record(host: host, name: "")   // ignored
        XCTAssertEqual(NetworkMountInfo.computerName(forHost: host), "Good")
    }

    func test_laterRecord_updatesTheName() {
        let host = uniqueHost()
        NetworkMountInfo.record(host: host, name: "Old")
        NetworkMountInfo.record(host: host, name: "New")
        XCTAssertEqual(NetworkMountInfo.computerName(forHost: host), "New")
    }
}
