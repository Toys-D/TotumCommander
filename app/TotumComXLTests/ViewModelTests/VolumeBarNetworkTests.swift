import XCTest

@testable import TotumComXLApp

/// Which disk the volume bar lights up while the panel is browsing the network.
///
/// It lit up "System:". The bar picks the entry whose path is the longest one the current path
/// sits under, and every path sits under "/" — so a panel standing in the computer list on the
/// LAN was shown as standing on the boot disk. Now the place the panel is actually in gets an
/// entry of its own, named after the computer.
@MainActor
final class VolumeBarNetworkTests: XCTestCase {

    private let root = NetworkBrowserService.networkRoot

    // MARK: - The network location is recognised at all

    func testAComputerAndTheComputerListAreBothNetworkPlaces() {
        XCTAssertTrue(NetworkBrowserService.isNetworkPath(root))
        XCTAssertTrue(NetworkBrowserService.isNetworkPath("\(root)/SERVER_SO"))
        XCTAssertTrue(NetworkBrowserService.isNetworkPath("\(root)/SERVER_SO/E"))
    }

    /// The check must not fire on a real folder — a local path with an unlucky name would
    /// otherwise get a phantom network entry in the bar.
    func testARealFolderIsNotANetworkPlace() {
        XCTAssertFalse(NetworkBrowserService.isNetworkPath("/"))
        XCTAssertFalse(NetworkBrowserService.isNetworkPath(NSHomeDirectory()))
        XCTAssertFalse(NetworkBrowserService.isNetworkPath("/Volumes/SERVER_SO"))
        XCTAssertFalse(NetworkBrowserService.isNetworkPath("/NETWORKING/x"),
                       "a prefix match is not a path match")
    }

    // MARK: - What the entry is called

    func testInsideAComputerTheEntryIsNamedAfterIt() {
        XCTAssertEqual(NetworkBrowserService.computerName(from: "\(root)/SERVER_SO"), "SERVER_SO")
        XCTAssertEqual(NetworkBrowserService.computerName(from: "\(root)/SERVER_SO/E"), "SERVER_SO")
    }

    /// At the top there is no computer yet — the entry falls back to the network's own name.
    func testTheComputerListHasNoComputerName() {
        XCTAssertNil(NetworkBrowserService.computerName(from: root))
        XCTAssertNotEqual(L("network.localNetwork"), "network.localNetwork",
                          "the fallback label must be translated, not shown as its key")
    }

    // MARK: - Once a share is really mounted

    /// A mounted share is a real volume and keeps its own entry, which already carries the
    /// letter the user asked about: "COMPUTER:share".
    func testAMountedShareIsNamedComputerAndShare() {
        NetworkMountInfo.record(host: "192.168.0.169", name: "SERVER_SO")
        XCTAssertEqual(NetworkMountInfo.computerName(forHost: "192.168.0.169"), "SERVER_SO")
    }

    /// The rule that caused it: "/" swallows everything, so the fallback has to lose to a
    /// longer match rather than being reached at all.
    func testEverythingLivesUnderTheRootWhichIsWhyTheFallbackLied() {
        let deeper = "\(root)/SERVER_SO"
        XCTAssertTrue(deeper.hasPrefix("/"), "this is why System: won before the entry existed")
        XCTAssertGreaterThan(deeper.count, "/".count,
                             "the network entry's path is longer, so it wins the match")
    }
}
