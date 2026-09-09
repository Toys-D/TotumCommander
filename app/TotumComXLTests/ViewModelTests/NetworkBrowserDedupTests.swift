import AppKit
import Network
import XCTest

@testable import TotumComXLApp

/// The network list showed four entries where Finder showed two: the user's own Mac, and one
/// machine listed twice — once as Bonjour named it ("MacBook Air — Ania") and once as the subnet
/// sweep did ("MACBOOK-ANIA"). Names never match; the address does. These pin the rules down.
@MainActor
final class NetworkBrowserDedupTests: XCTestCase {

    private func host(_ name: String, _ address: String,
                      viaScan: Bool, resolvedIP: String? = nil) -> DiscoveredHost {
        DiscoveredHost(name: name, host: address, proto: "SMB",
                       endpoint: .hostPort(host: NWEndpoint.Host(address), port: 445),
                       viaScan: viaScan, resolvedIP: resolvedIP)
    }

    // MARK: - Identity

    /// Equality is name+proto, which is precisely why the two names of one machine both got in.
    /// The address is the tiebreaker the service uses, so it must survive on the model.
    /// Один промах развёртки не вычёркивает компьютер: сначала повторная проба, а у кого
    /// папки смонтированы — тот жив и так. Найденные по Bonjour развёртка не трогает.
    func testASweepMissDoesNotDropAHostThatIsAliveOrMounted() {
        func scanHost(_ ip: String) -> DiscoveredHost {
            DiscoveredHost(name: ip, host: ip, proto: "SMB",
                           endpoint: .hostPort(host: NWEndpoint.Host(ip), port: 445),
                           viaScan: true, resolvedIP: ip)
        }
        let bonjour = DiscoveredHost(name: "Mac", host: "mac.local", proto: "SMB",
                                     endpoint: .hostPort(host: "mac.local", port: 445))
        let hosts = [scanHost("192.168.0.169"), scanHost("192.168.0.50"), scanHost("192.168.0.77"), bonjour]

        let drop = NetworkBrowserService.hostsToDrop(hosts, confirmed: [],
                                                     mounted: ["192.168.0.169"],
                                                     aliveOnRecheck: ["192.168.0.50"])
        XCTAssertEqual(drop, ["192.168.0.77"], "ушёл только тот, кто молчит и не смонтирован")

        let none = NetworkBrowserService.hostsToDrop(hosts, confirmed: ["192.168.0.77"],
                                                     mounted: [], aliveOnRecheck: ["192.168.0.50", "192.168.0.169"])
        XCTAssertTrue(none.isEmpty)
    }

    func testAHostRemembersItsResolvedAddress() {
        let bonjour = host("MacBook Air — Ania", "macbook-air-ania.local",
                           viaScan: false, resolvedIP: "192.168.0.114")
        XCTAssertEqual(bonjour.resolvedIP, "192.168.0.114")
        XCTAssertEqual(bonjour.displayName, "MacBook Air — Ania")
    }

    func testAScanHostStartsWithoutAResolvedAddressUnlessGivenOne() {
        XCTAssertNil(host("MACBOOK-ANIA", "192.168.0.114", viaScan: true).resolvedIP)
        XCTAssertEqual(host("SERVER_SO", "192.168.0.169", viaScan: true,
                            resolvedIP: "192.168.0.169").resolvedIP, "192.168.0.169")
    }

    /// The same machine under both names is NOT equal by the model's own rule — which is the
    /// whole reason the service has to compare addresses instead.
    func testTheTwoNamesOfOneMachineAreNotEqualByName() {
        XCTAssertNotEqual(host("MacBook Air — Ania", "macbook-air-ania.local", viaScan: false),
                          host("MACBOOK-ANIA", "192.168.0.114", viaScan: true))
    }

    func testTheSameNameOverDifferentProtocolsStaysDistinct() {
        let smb = DiscoveredHost(name: "server_so", host: "server_so.local", proto: "SMB",
                                 endpoint: .hostPort(host: "server_so.local", port: 445))
        let afp = DiscoveredHost(name: "server_so", host: "server_so.local", proto: "AFP",
                                 endpoint: .hostPort(host: "server_so.local", port: 548))
        XCTAssertNotEqual(smb, afp, "a machine offering both must not lose one of them")
    }

    // MARK: - This machine

    /// Finder never lists the Mac you are sitting at; the sweep, left alone, would — it answers
    /// its own port 445 like any other host.
    func testOurOwnAddressesAreKnown() {
        let mine = LANScanner.localAddresses()
        XCTAssertFalse(mine.isEmpty, "a machine on a network has at least one address")
        for address in mine {
            XCTAssertFalse(address.hasPrefix("169.254."), "link-local is not a real address")
            XCTAssertNotEqual(address, "0.0.0.0")
        }
    }

    // MARK: - Recognising ourselves

    /// The live case: Bonjour advertises this Mac's own SMB service under its network name, and
    /// the first fix only filtered the subnet sweep — so the entry stayed. The name arrives with
    /// the advertisement; the address only after resolving it. Either signal must be enough.
    func testOurOwnBonjourNameIsRecognisedBeforeAnyAddressIsKnown() {
        XCTAssertTrue(NetworkBrowserService.isSelf(
            name: "Dmitriis-MBP (2)", address: nil,
            ownName: "Dmitriis-MBP (2)", ownAddresses: ["192.168.0.104"]))
    }

    func testOurOwnAddressIsRecognisedEvenUnderAnotherName() {
        XCTAssertTrue(NetworkBrowserService.isSelf(
            name: "DMITRIIS-MBP", address: "192.168.0.104",
            ownName: "Dmitriis-MBP (2)", ownAddresses: ["192.168.0.104"]))
    }

    func testTheNameMatchIgnoresCase() {
        XCTAssertTrue(NetworkBrowserService.isSelf(
            name: "dmitriis-mbp (2)", address: nil,
            ownName: "Dmitriis-MBP (2)", ownAddresses: []))
    }

    /// Other people's machines must never be mistaken for us — that would hide a real host.
    func testOtherMachinesAreNotUs() {
        XCTAssertFalse(NetworkBrowserService.isSelf(
            name: "SERVER_SO", address: "192.168.0.169",
            ownName: "Dmitriis-MBP (2)", ownAddresses: ["192.168.0.104"]))
        XCTAssertFalse(NetworkBrowserService.isSelf(
            name: "MacBook Air — Ania", address: "192.168.0.114",
            ownName: "Dmitriis-MBP (2)", ownAddresses: ["192.168.0.104"]))
    }

    /// A machine with no name of its own must not swallow every unnamed host.
    func testAnEmptyOwnNameMatchesNothing() {
        XCTAssertFalse(NetworkBrowserService.isSelf(
            name: "", address: nil, ownName: "", ownAddresses: ["192.168.0.104"]))
        XCTAssertFalse(NetworkBrowserService.isSelf(
            name: "SERVER_SO", address: nil, ownName: "", ownAddresses: ["192.168.0.104"]))
    }

    // MARK: - Resolution is asked for, never guessed

    /// The bug that hid behind three rounds of dedup patching: the hostname was INVENTED from
    /// the advertised label. "MacBook Air — Ania" sanitised gives "MacBook-Air-Ania.local"; the
    /// machine actually answers to "MacBook-Ania.local". No such host existed — opening the row
    /// failed with "server not found", and the address could never be learned, so the duplicate
    /// could never be merged. A resolved host must therefore carry an ADDRESS, not a name.
    func testAResolvedHostIsAddressedByIPNotByAName() {
        let resolved = host("MacBook Air — Ania", "192.168.0.114",
                            viaScan: false, resolvedIP: "192.168.0.114")
        XCTAssertEqual(resolved.host, resolved.resolvedIP,
                       "the row must be reachable at the address it resolved to")
        XCTAssertFalse(resolved.host.hasSuffix(".local"),
                       "a .local name here means the invented-hostname path came back")
        XCTAssertEqual(resolved.serverURL, "smb://192.168.0.114")
        XCTAssertEqual(resolved.displayName, "MacBook Air — Ania",
                       "the pretty name is still what the user reads")
    }

    /// A no-break space sits inside the advertised name (U+00A0 before the dash) — one more
    /// reason no transformation of the label could ever produce the real hostname.
    func testTheAdvertisedNameContainsANoBreakSpace() {
        let advertised = "MacBook Air\u{00A0}— Ania"
        XCTAssertTrue(advertised.unicodeScalars.contains { $0.value == 0x00A0 })
        XCTAssertNotEqual(advertised, "MacBook Air — Ania",
                          "the plain-space version is a different string entirely")
    }

    // MARK: - The mount-name map the dedup feeds

    /// Whichever name wins, mounted shares must show it rather than a bare IP.
    func testRecordingANameMakesItRetrievableByAddress() {
        NetworkMountInfo.record(host: "192.168.0.199", name: "ТЕСТОВЫЙ_ПК")
        XCTAssertEqual(NetworkMountInfo.computerName(forHost: "192.168.0.199"), "ТЕСТОВЫЙ_ПК")
    }

    /// An address nobody named falls back to itself — never to an empty label.
    func testAnUnknownAddressKeepsItsOwnText() {
        XCTAssertEqual(NetworkMountInfo.computerName(forHost: "10.99.99.99"), "10.99.99.99")
    }
}

/// Компьютер в сети и общая папка — не файлы: у них нет даты, и возрастные правила цветов
/// не должны считать их только что появившимися.
final class NetworkVirtualItemTests: XCTestCase {

    private func networkFolder(_ name: String) -> FileItem {
        FileItem(path: "/NETWORK/\(name)", name: name, fileExtension: "", size: 0,
                 isDirectory: true, isHidden: false, isSymlink: false, symlinkTarget: nil,
                 hardlinkCount: 1, permissions: "",
                 dateModified: NetworkBrowserService.virtualDate,
                 dateCreated: nil, dateAdded: nil, owner: "SMB")
    }

    func test_сетевыеСтрокиНеСчитаютсяНовыми() {
        // Правило «всё новое за сутки — зелёным», в своей полке настроек.
        let suite = "fcxl.netcolor.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let rule = FileColorRule(mask: "*", colorHex: "#00FF00", freshMinutes: 60 * 24)
        defaults.set(try! JSONEncoder().encode([rule]), forKey: "rules")
        let store = FileColorRulesStore(defaults: defaults, key: "rules")

        let fresh = FileItem(path: "/п/новый.txt", name: "новый.txt", fileExtension: "txt",
                             size: 1, isDirectory: false, isHidden: false, isSymlink: false,
                             symlinkTarget: nil, hardlinkCount: 1, permissions: "",
                             dateModified: Date(), dateCreated: nil, dateAdded: nil, owner: "")
        XCTAssertNotNil(store.color(for: fresh, base: NSColor.black, dark: false), "настоящий свежий файл красится")
        XCTAssertNil(store.color(for: networkFolder("SERVER_SO"), base: NSColor.black, dark: false),
                     "компьютер в сети не «новый файл»")
        XCTAssertNil(store.color(for: networkFolder("Users"), base: NSColor.black, dark: false))
    }

    func test_датаСетевойСтрокиНеПоказывается() {
        XCTAssertEqual(NetworkBrowserService.virtualDate, Date.distantPast)
        XCTAssertEqual(networkFolder("D").typeDisplayName, L("type.folder"),
                       "в колонке «Тип» — «Папка», а не пусто")
    }
}
