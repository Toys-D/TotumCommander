import Network
import XCTest

@testable import TotumComXLApp

/// Развёртка подсети не должна упираться в предел открытых файлов: именно из-за него
/// компьютер в «Локальной сети» то появлялся, то пропадал.
final class LANScannerBudgetTests: XCTestCase {

    func testTheLaunchdLimitLeavesRoomForOnlyAHandfulOfProbes() {
        // 256 — то, что launchd выдаёт программе, запущенной из Finder; 143 — сколько
        // дескрипторов программа держала открытыми в тот момент, когда сеть «пропала».
        XCTAssertEqual(LANScanner.probeConcurrency(softLimit: 256, openDescriptors: 143), 49)
    }

    func testWithARaisedLimitTheWholeSubnetGoesInOneWave() {
        XCTAssertEqual(LANScanner.probeConcurrency(softLimit: 8192, openDescriptors: 143), 224)
    }

    func testEvenAnExhaustedProcessStillProbesSomething() {
        XCTAssertEqual(LANScanner.probeConcurrency(softLimit: 256, openDescriptors: 250), 8)
    }

    func testTheCeilingIsRespected() {
        XCTAssertEqual(LANScanner.probeConcurrency(softLimit: 100_000, openDescriptors: 0,
                                                   ceiling: 32), 32)
    }

    // MARK: - Порядок подсетей

    func testTheRealNetworkIsScannedBeforeTheVpnTunnel() {
        let prefixes = LANScanner.scanPrefixes(interfaces: [
            ("utun4", "100.89.19.2"),
            ("en0", "192.168.0.104")
        ])
        XCTAssertEqual(prefixes, ["192.168.0", "100.89.19"])
    }

    func testTwoAddressesInOneSubnetGiveOnePass() {
        let prefixes = LANScanner.scanPrefixes(interfaces: [
            ("en0", "192.168.0.104"),
            ("en1", "192.168.0.7")
        ])
        XCTAssertEqual(prefixes, ["192.168.0"])
    }

    func testVirtualBridgesComeAfterTheWire() {
        let prefixes = LANScanner.scanPrefixes(interfaces: [
            ("bridge100", "10.211.55.2"),
            ("en0", "192.168.1.5"),
            ("utun0", "100.64.0.3")
        ])
        XCTAssertEqual(prefixes.first, "192.168.1")
        XCTAssertEqual(prefixes.count, 3)
    }

    func testGarbageAddressesAreIgnored() {
        XCTAssertEqual(LANScanner.scanPrefixes(interfaces: [("en0", "не адрес")]), [])
    }

    func testRunningOutOfDescriptorsIsNotAnEmptyAddress() {
        XCTAssertEqual(LANScanner.outcome(for: .posix(.EMFILE)), .outOfDescriptors)
        XCTAssertEqual(LANScanner.outcome(for: .posix(.ENFILE)), .outOfDescriptors)
        XCTAssertEqual(LANScanner.outcome(for: .posix(.ENOBUFS)), .outOfDescriptors)
    }

    func testARefusedConnectionMeansNobodyIsThere() {
        XCTAssertEqual(LANScanner.outcome(for: .posix(.ECONNREFUSED)), .closed)
        XCTAssertEqual(LANScanner.outcome(for: .posix(.EHOSTUNREACH)), .closed)
        XCTAssertEqual(LANScanner.outcome(for: .dns(-65554)), .closed)
    }

    func testRaisingTheLimitNeverLowersIt() {
        var before = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &before), 0)
        let after = LANScanner.raiseDescriptorLimit()
        XCTAssertGreaterThanOrEqual(after, before.rlim_cur)
        XCTAssertGreaterThanOrEqual(after, 8192)
    }

    func testCountingOpenDescriptorsSeesAFreshlyOpenedFile() {
        let limit = 1024
        let before = LANScanner.openDescriptorCount(softLimit: limit)
        let handle = FileHandle(forReadingAtPath: "/dev/null")
        XCTAssertNotNil(handle)
        XCTAssertGreaterThan(LANScanner.openDescriptorCount(softLimit: limit), before)
        try? handle?.close()
    }
}
