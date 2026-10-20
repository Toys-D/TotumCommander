import XCTest

@testable import TotumComXLApp

/// Обход локальной сети: кого считать компьютером, кого спрашивать и как назвать.
final class LANDiscoveryTests: XCTestCase {

    // MARK: - Кто здесь компьютер

    func testSharedFoldersMakeAComputer() {
        XCTAssertTrue(LANDiscovery.isComputer(ports: [445], isGateway: false))
        XCTAssertTrue(LANDiscovery.isComputer(ports: [139], isGateway: false))
        XCTAssertTrue(LANDiscovery.isComputer(ports: [548], isGateway: false))
    }

    func testAWindowsWithoutSharesIsStillAComputer() {
        // Удалённый рабочий стол открыт, общие папки закрыты — компьютер там есть.
        XCTAssertTrue(LANDiscovery.isComputer(ports: [3389], isGateway: false))
    }

    func testALinuxWithOnlySshCounts() {
        XCTAssertTrue(LANDiscovery.isComputer(ports: [22], isGateway: false))
    }

    func testAWebPortAloneIsNotAComputer() {
        // Так отвечают принтер, камера и умная лампочка.
        XCTAssertFalse(LANDiscovery.isComputer(ports: [80], isGateway: false))
        XCTAssertFalse(LANDiscovery.isComputer(ports: [80, 21], isGateway: false))
    }

    func testTheRouterIsNotListedEvenWithSshOpen() {
        XCTAssertFalse(LANDiscovery.isComputer(ports: [22, 80], isGateway: true))
    }

    func testNothingAnsweredMeansNoComputer() {
        XCTAssertFalse(LANDiscovery.isComputer(ports: [], isGateway: false))
    }

    // MARK: - Кого спрашивать

    func testEveryAddressOfTheSubnetIsAskedExceptOurOwn() {
        let pairs = LANDiscovery.targets(prefixes: ["192.168.0"],
                                         selfIPs: ["192.168.0.104"], ports: [445])
        XCTAssertEqual(pairs.count, 253)
        XCTAssertFalse(pairs.contains { $0.ip == "192.168.0.104" })
        XCTAssertTrue(pairs.contains { $0.ip == "192.168.0.169" && $0.port == 445 })
    }

    func testEveryDoorIsTriedOnEveryAddress() {
        let pairs = LANDiscovery.targets(prefixes: ["10.0.0"], selfIPs: [], ports: [445, 22])
        XCTAssertEqual(pairs.count, 254 * 2)
    }

    func testTwoSubnetsAreBothAsked() {
        let pairs = LANDiscovery.targets(prefixes: ["192.168.0", "100.89.19"],
                                         selfIPs: [], ports: [445])
        XCTAssertEqual(pairs.count, 508)
        // Порядок сохраняется: настоящая сеть раньше туннеля.
        XCTAssertEqual(pairs.first?.ip, "192.168.0.1")
    }

    func testAnswersAreGroupedByAddress() {
        let grouped = LANDiscovery.group([("192.168.0.169", 445), ("192.168.0.169", 139),
                                          ("192.168.0.5", 22)])
        XCTAssertEqual(grouped["192.168.0.169"], [445, 139])
        XCTAssertEqual(grouped["192.168.0.5"], [22])
    }

    // MARK: - Имена

    func testTheDomainIsTrimmedOffTheName() {
        XCTAssertEqual(LANDiscovery.shortName("SERVER-SO.local.", ip: "192.168.0.169"), "SERVER-SO")
        XCTAssertEqual(LANDiscovery.shortName("nas.lan", ip: "192.168.0.7"), "nas")
    }

    func testAnAddressIsNotAName() {
        XCTAssertNil(LANDiscovery.shortName("192.168.0.169", ip: "192.168.0.169"))
        XCTAssertNil(LANDiscovery.shortName("   ", ip: "192.168.0.169"))
    }

    // MARK: - Маршрутизатор

    func testTheGatewayIsReadFromTheRoutingTable() {
        let output = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.0.1
          interface: en0
        """
        XCTAssertEqual(LANDiscovery.gatewayAddress(inRouteOutput: output), "192.168.0.1")
    }

    func testNoDefaultRouteMeansNoGateway() {
        XCTAssertNil(LANDiscovery.gatewayAddress(inRouteOutput: "route: writing to routing socket"))
    }

    // MARK: - Волны

    func testProbesAreCutIntoWavesByBudget() {
        let pairs = LANDiscovery.targets(prefixes: ["192.168.0"], selfIPs: [], ports: [445])
        let waves = pairs.chunked(into: 100)
        XCTAssertEqual(waves.count, 3)
        XCTAssertEqual(waves.map(\.count), [100, 100, 54])
    }

    func testAZeroBudgetDoesNotLoseAnybody() {
        XCTAssertEqual([1, 2, 3].chunked(into: 0), [[1, 2, 3]])
    }
    /// macOS 27 прячет таблицу ARP от сторонней программы: живых по ней нет. Тогда обход
    /// идёт по всем адресам подсетей без туннелей — но только в двери общих папок, — и
    /// компьютер с Windows, который не объявляет себя по Bonjour, снова находится.
    func testSilentArpMeansSweepingTheWholeSubnetForShares() {
        let blind = LANDiscovery.sweepPlan(live: [], directPrefixes: ["192.168.0"],
                                           selfIPs: ["192.168.0.105"])
        XCTAssertTrue(blind.blind)
        XCTAssertEqual(blind.addresses.count, 253, "вся /24, кроме себя")
        XCTAssertTrue(blind.addresses.contains("192.168.0.169"))
        XCTAssertFalse(blind.addresses.contains("192.168.0.105"))
        XCTAssertEqual(Set(blind.ports), [445, 139, 548], "только общие папки")

        // Таблица ответила — как раньше: только живые и во все двери.
        let seen = LANDiscovery.sweepPlan(live: ["192.168.0.169"], directPrefixes: ["192.168.0"],
                                          selfIPs: [])
        XCTAssertFalse(seen.blind)
        XCTAssertEqual(seen.addresses, ["192.168.0.169"])
        XCTAssertEqual(seen.ports, LANDiscovery.probedPorts)
    }

    /// Вслепую не обходят туннели VPN: двести с лишним проб в утун, где никого, — время,
    /// отнятое у настоящей сети.
    func testTunnelsAreLeftOutOfTheBlindSweep() {
        let interfaces = [(name: "en0", ip: "192.168.0.105"), (name: "utun4", ip: "100.89.19.2")]
        XCTAssertEqual(LANScanner.scanPrefixes(interfaces: interfaces), ["192.168.0", "100.89.19"])
        XCTAssertEqual(LANScanner.scanPrefixes(interfaces: interfaces.filter {
            LANScanner.interfaceRank($0.name) < 2 }), ["192.168.0"])
    }

}
