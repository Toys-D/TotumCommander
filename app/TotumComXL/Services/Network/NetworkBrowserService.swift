import Foundation
import NetFS
import Network
import os

// MARK: - Discovered Host Model

struct DiscoveredHost: Hashable {
    let name: String
    let host: String
    let proto: String // "SMB" or "AFP"
    let endpoint: NWEndpoint
    /// true = found by the subnet port-445 scan (Windows/NAS); false = Bonjour.
    /// Lets a Bonjour refresh avoid wiping scan-discovered hosts.
    var viaScan: Bool = false
    /// The numeric address, once known. Bonjour gives a ".local" name and the sweep gives an IP:
    /// the SAME machine arrives twice under two different names ("MacBook Air — Ania" and
    /// "MACBOOK-ANIA"), and only the address can tell that it is one machine.
    var resolvedIP: String?

    var displayName: String { name.isEmpty ? host : name }

    /// URL for macOS native mount (same as Finder uses)
    var serverURL: String {
        let scheme = proto == "AFP" ? "afp" : "smb"
        return "\(scheme)://\(host)"
    }

    static func == (lhs: DiscoveredHost, rhs: DiscoveredHost) -> Bool {
        lhs.name == rhs.name && lhs.proto == rhs.proto
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(proto)
    }
}

/// Singleton service for browsing the local network.
/// Discovers SMB/AFP hosts via Bonjour, lists shares, mounts via NetFS.
///
/// Key optimizations (based on Apple developer forums research):
/// - NO IP resolution needed — NetFS resolves .local hostnames at kernel level
/// - NO manual Keychain reading — macOS handles credentials via session/Keychain automatically
/// - Share listing via smbutil; if no cached auth, triggers system auth dialog via NetFS
@MainActor
final class NetworkBrowserService {
    static let shared = NetworkBrowserService()
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.fcxl.filecommander",
        category: "NetworkBrowser")
    static let networkRoot = "/NETWORK"

    /// Дата для строк, у которых её нет: компьютер в сети и общая папка не «созданы» ни
    /// когда-либо. Далёкое прошлое, а не «сейчас», — иначе возрастные правила цветов считают
    /// их только что появившимися, а колонка даты показывает время открытия панели.
    static let virtualDate = Date.distantPast

    private var smbBrowser: NWBrowser?
    private var afpBrowser: NWBrowser?
    private(set) var discoveredHosts: [DiscoveredHost] = []
    private(set) var isScanning = false
    private var lanScanInProgress = false
    /// Resolutions in flight, keyed by service name. NetService is retained by nobody else, and
    /// an unretained one is deallocated before its delegate ever fires.
    private var resolvers: [String: NetService] = [:]
    private var resolverDelegate: BonjourResolver?

    /// Hosts the last sweep found, kept between visits so the list is not empty for the seconds
    /// a fresh sweep takes. Same trust-then-verify shape as the folder-size cache: shown at once,
    /// replaced by whatever the running sweep actually finds.
    private static let cacheKey = "fcxl.networkHostsCache"

    /// This machine's own addresses. Finder never lists the Mac you are sitting at, and neither
    /// should we — it answers its own port 445 like any other host.
    private lazy var ownAddresses: Set<String> = Set(LANScanner.localAddresses())

    /// This machine's own network name, e.g. "Dmitriis-MBP (2)". Bonjour advertises the Mac's
    /// SMB service under exactly this string, so the self-check has to work on names too — the
    /// address is not known until the .local name has been resolved, which happens later.
    private lazy var ownName: String = Host.current().localizedName ?? ""

    /// Is this discovery us? Two independent signals, because they arrive at different moments:
    /// the name comes with the Bonjour advertisement, the address only after resolving it.
    nonisolated static func isSelf(name: String, address: String?,
                                   ownName: String, ownAddresses: Set<String>) -> Bool {
        if !ownName.isEmpty, name.localizedCaseInsensitiveCompare(ownName) == .orderedSame {
            return true
        }
        if let address, ownAddresses.contains(address) { return true }
        return false
    }

    // MARK: - Scanning

    func startScanning() {
        guard !isScanning else { return }
        isScanning = true

        let smbParams = NWParameters()
        smbParams.includePeerToPeer = true
        smbBrowser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: smbParams)
        smbBrowser?.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async { self?.handleResults(results, proto: "SMB") }
        }
        smbBrowser?.start(queue: .main)

        let afpParams = NWParameters()
        afpParams.includePeerToPeer = true
        afpBrowser = NWBrowser(for: .bonjour(type: "_afpovertcp._tcp", domain: nil), using: afpParams)
        afpBrowser?.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async { self?.handleResults(results, proto: "AFP") }
        }
        afpBrowser?.start(queue: .main)

        // Bonjour misses Windows PCs (they don't advertise over mDNS) — also
        // run a direct subnet SMB port-445 scan to catch them, like Finder.
        startLANScan()
    }

    func stopScanning() {
        smbBrowser?.cancel(); afpBrowser?.cancel()
        smbBrowser = nil; afpBrowser = nil
        isScanning = false
    }

    /// True while the one-shot subnet sweep is running. Bonjour answers instantly, so it is
    /// this sweep that leaves "Local network" looking empty for the first few seconds.
    var isLANScanning: Bool { lanScanInProgress }

    /// Kick a (re)scan and wait until the subnet sweep is done. Both calls are self-guarded, so
    /// this is safe to call on every visit — a revisit refreshes the list. Returns immediately
    /// when nothing is scanning. Used to drive the per-tab spinner without blocking anything.
    func refreshAndWaitForLANScan() async {
        startScanning()   // idempotent — sets up the Bonjour browsers once
        startLANScan()    // self-guarded — re-sweeps unless a sweep is already running
        while lanScanInProgress {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// One-shot subnet SMB scan. Adds Windows/NAS hosts that Bonjour can't see.
    func startLANScan() {
        guard !lanScanInProgress else { return }
        lanScanInProgress = true
        // What THIS sweep answers for. Cached entries not confirmed by it are dropped at the
        // end, so a machine that has left the network stops being listed forever.
        var confirmed = Set<String>()
        // ВНЕ главного потока: обход блокирует вызывающего на всё время опроса, а служба
        // живёт на главном акторе — раньше это и было «программа думает пять секунд».
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scope = LANScanner.scanScope()
            let gateway = LANDiscovery.defaultGateway()
            let found = LANDiscovery.discover(prefixes: scope.prefixes, selfIPs: scope.selfIPs,
                                              gateway: gateway) { host in
                // Каждый найденный — сразу в список, не дожидаясь конца обхода.
                DispatchQueue.main.async { [weak self] in
                    self?.addScannedHost(ip: host.ip, name: host.name)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for host in found {
                    confirmed.insert(host.ip)
                    self.addScannedHost(ip: host.ip, name: host.name)
                }
                self.lanScanInProgress = false
                // Панель ждёт этого, чтобы отличить «ещё не спросили» от «спросили и никого»:
                // пустой список до конца обхода — не повод говорить, что сети нет.
                NotificationCenter.default.post(name: .networkBrowserScanDidFinish, object: nil)

                // Не подтверждённые обходом — ещё не мёртвые: живой хост за Wi-Fi иногда
                // не успевает ответить, и раньше один промах вычёркивал компьютер до
                // следующего захода. Сначала второе мнение — неспешная проба каждого
                // поодиночке; чьи папки смонтированы, те живы и без пробы.
                let mounted = NetworkMountInfo.mountedHosts()
                let suspects = self.discoveredHosts.filter {
                    $0.viaScan && !confirmed.contains($0.host)
                        && !mounted.contains($0.host.lowercased())
                }.map(\.host)
                LANScanner.recheck(ips: suspects) { alive in
                    DispatchQueue.main.async {
                        let drop = Self.hostsToDrop(self.discoveredHosts, confirmed: confirmed,
                                                    mounted: mounted, aliveOnRecheck: alive)
                        guard !drop.isEmpty else { return }
                        self.discoveredHosts.removeAll { drop.contains($0.host) }
                        self.saveCache()
                        NotificationCenter.default.post(name: .networkBrowserDidUpdate, object: nil)
                    }
                }
            }
        }
    }

    /// Кого вычеркнуть после развёртки: найденных развёрткой, кого она не подтвердила, кто не
    /// ответил и на повторную пробу и чьи папки не смонтированы. Найденные по Bonjour живут
    /// своей жизнью — их ведёт сам Bonjour.
    nonisolated static func hostsToDrop(_ hosts: [DiscoveredHost], confirmed: Set<String>,
                                        mounted: Set<String>, aliveOnRecheck: Set<String>) -> Set<String> {
        Set(hosts.filter {
            $0.viaScan && !confirmed.contains($0.host) && !aliveOnRecheck.contains($0.host)
                && !mounted.contains($0.host.lowercased())
        }.map(\.host))
    }

    /// Merge a scan-discovered SMB host into the list, deduped against the
    /// Bonjour results (by name, case-insensitive) and against itself (by IP).
    private func addScannedHost(ip: String, name: String) {
        // Never list the machine the user is sitting at — it answers its own port 445, and
        // Finder does not show it either.
        if ownAddresses.contains(ip) { return }
        // Already shown by Bonjour under the same name? Skip (avoid duplicates
        // of Macs/NAS that advertise AND answer the port scan).
        if discoveredHosts.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) { return }
        // Same physical host already added by a previous scan tick? Skip by IP.
        if discoveredHosts.contains(where: { $0.host == ip }) { return }
        // The same machine under its OTHER name: Bonjour called it "MacBook Air — Ania", the
        // sweep calls it "MACBOOK-ANIA". Names never match; the address does. The Bonjour entry
        // wins — its name is the human one — and simply learns the IP.
        if let index = discoveredHosts.firstIndex(where: { $0.resolvedIP == ip }) {
            NetworkMountInfo.record(host: ip, name: discoveredHosts[index].name)
            return
        }

        // Remember IP → computer name so mounted shares can show the name, not the IP.
        NetworkMountInfo.record(host: ip, name: name)

        let host = DiscoveredHost(
            name: name,
            host: ip,            // SMB mount / smbutil use the IP directly
            proto: "SMB",
            endpoint: .hostPort(host: NWEndpoint.Host(ip), port: 445),
            viaScan: true
        )
        discoveredHosts.append(host)
        discoveredHosts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        NotificationCenter.default.post(name: .networkBrowserDidUpdate, object: nil)
    }

    private func handleResults(_ results: Set<NWBrowser.Result>, proto: String) {
        // Names currently advertised. A host is listed ONLY once its address is known — see
        // adoptResolved — so this is what may exist, not what is shown.
        var advertised = Set<String>()
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
            // The Mac we are sitting at advertises its own SMB service; Finder does not list it
            // and neither do we. Reaching your own files never needs the network.
            if Self.isSelf(name: name, address: nil,
                           ownName: ownName, ownAddresses: ownAddresses) { continue }
            advertised.insert(name)
            let listed = discoveredHosts.contains { $0.name == name && $0.proto == proto && !$0.viaScan }
            guard !listed, resolvers[name] == nil else { continue }
            startResolving(name: name, type: type, domain: domain, proto: proto)
        }
        // A service that stopped advertising goes; one still resolving is left alone.
        let before = discoveredHosts.count
        discoveredHosts.removeAll {
            $0.proto == proto && !$0.viaScan && !advertised.contains($0.name)
        }
        if discoveredHosts.count != before {
            NotificationCenter.default.post(name: .networkBrowserDidUpdate, object: nil)
        }
    }

    /// Ask mDNS for the service's REAL address.
    ///
    /// What this replaces: the hostname used to be INVENTED from the advertised label — "MacBook
    /// Air — Ania" run through a sanitiser gave "MacBook-Air-Ania.local", while the machine
    /// actually answers to "MacBook-Ania.local". No such host existed, so opening that row failed
    /// with "server not found", and its address could never be learned — which is exactly why one
    /// machine sat in the list twice, under its Bonjour name and its SMB name.
    ///
    /// NetService needs a live run loop. An app has one; that is why this works here and why the
    /// same call in a blocking command-line helper returned nothing at all.
    private func startResolving(name: String, type: String, domain: String, proto: String) {
        if resolverDelegate == nil {
            resolverDelegate = BonjourResolver { [weak self] serviceName, ip, serviceProto in
                self?.adoptResolved(name: serviceName, ip: ip, proto: serviceProto)
            }
        }
        let service = NetService(domain: domain, type: type, name: name)
        service.delegate = resolverDelegate
        resolverDelegate?.protocolByName[name] = proto
        resolvers[name] = service
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 5)
        Self.log.info("resolve start: \(name, privacy: .public)")
    }

    /// A resolution came back. `ip` nil means it failed — the row is then NOT listed: a row that
    /// cannot be opened is worse than no row, and the subnet sweep lists the same machine by
    /// address anyway.
    private func adoptResolved(name: String, ip: String?, proto: String) {
        resolvers[name] = nil
        guard let ip else {
            Self.log.error("resolve failed: \(name, privacy: .public)")
            return
        }
        Self.log.info("resolve ok: \(name, privacy: .public) -> \(ip, privacy: .public)")
        guard !ownAddresses.contains(ip) else { return }

        NetworkMountInfo.record(host: ip, name: name)
        // The ADDRESS is the host: mounting by it works (mounting the invented name did not),
        // and it is what makes a sweep row recognisably the same machine.
        var host = DiscoveredHost(
            name: name,
            host: ip,
            proto: proto,
            endpoint: .hostPort(host: NWEndpoint.Host(ip), port: proto == "AFP" ? 548 : 445))
        host.resolvedIP = ip
        guard !discoveredHosts.contains(host) else { return }
        // The same machine found by the sweep, under its SMB name — one machine, one row.
        discoveredHosts.removeAll { $0.viaScan && $0.host == ip }
        discoveredHosts.append(host)
        discoveredHosts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        saveCache()
        NotificationCenter.default.post(name: .networkBrowserDidUpdate, object: nil)
    }

    // MARK: - List Computers

    /// Remembered hosts (name + address), so the next visit is not an empty list for the
    /// seconds a sweep takes. Only sweep-found hosts are cached: Bonjour answers instantly by
    /// itself, and a stale ".local" name would just be noise.
    private func saveCache() {
        let payload = discoveredHosts.filter { $0.viaScan }.map { ["name": $0.name, "ip": $0.host] }
        UserDefaults.standard.set(payload, forKey: Self.cacheKey)
    }

    private func loadCache() {
        guard discoveredHosts.isEmpty,
              let stored = UserDefaults.standard.array(forKey: Self.cacheKey) as? [[String: String]]
        else { return }
        for entry in stored {
            guard let name = entry["name"], let ip = entry["ip"], !ownAddresses.contains(ip)
            else { continue }
            NetworkMountInfo.record(host: ip, name: name)
            discoveredHosts.append(DiscoveredHost(
                name: name, host: ip, proto: "SMB",
                endpoint: .hostPort(host: NWEndpoint.Host(ip), port: 445),
                viaScan: true, resolvedIP: ip))
        }
        discoveredHosts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func listComputers() -> [FileItem] {
        loadCache()
        if !isScanning { startScanning() }
        return discoveredHosts.map { host in
            FileItem(
                path: "\(Self.networkRoot)/\(host.name)",
                name: host.name,
                fileExtension: "", size: 0, isDirectory: true,
                isHidden: false, isSymlink: false, symlinkTarget: nil,
                hardlinkCount: 1, permissions: "",
                // НЕ Date(): у компьютера и у общей папки нет своей даты, а «сейчас» делало
                // их вечно свежими — правило «новые файлы» красило всю сеть в свой цвет.
                dateModified: Self.virtualDate, dateCreated: nil, dateAdded: nil,
                owner: host.proto
            )
        }
    }

    // MARK: - List Shares

    /// List SMB shares on a host via `smbutil view`.
    /// Chain: what the Keychain holds → guest → a login typed in OUR window. The system's own
    /// "You are attempting to connect to server" sheet used to be the third step: it belongs to
    /// another process, cannot be restyled, and after Cancel the listing ran again and put it
    /// straight back up — a spinner and the same sheet, without end.
    func listShares(computerName: String) async -> SharesResult {
        guard let host = discoveredHosts.first(where: { $0.name == computerName }) else {
            return SharesResult(shares: [], cancelled: false)
        }
        let hostname = host.host

        var listing = await Task.detached(priority: .userInitiated) {
            Self.runSmbutil(host: hostname, asGuest: false)
        }.value
        if listing.shares.isEmpty {
            listing = await Task.detached(priority: .userInitiated) {
                Self.runSmbutil(host: hostname, asGuest: true)
            }.value
        }
        // Only a server that turned the login down is worth a login window; a server that is
        // silent, gone or simply has no shares is not.
        var cancelled = false
        if listing.shares.isEmpty, listing.failure == .authentication {
            let answered = await Self.listSharesWithOwnAuth(host: hostname)
            listing.shares = answered.shares
            cancelled = answered.cancelled
        }
        let shares = listing.shares

        let items = shares.map { name in
            FileItem(
                path: "\(Self.networkRoot)/\(computerName)/\(name)",
                name: name,
                fileExtension: "", size: 0, isDirectory: true,
                isHidden: false, isSymlink: false, symlinkTarget: nil,
                hardlinkCount: 1, permissions: "",
                // НЕ Date(): у компьютера и у общей папки нет своей даты, а «сейчас» делало
                // их вечно свежими — правило «новые файлы» красило всю сеть в свой цвет.
                dateModified: Self.virtualDate, dateCreated: nil, dateAdded: nil,
                owner: host.proto
            )
        }
        return SharesResult(shares: items, cancelled: cancelled)
    }

    /// Папки компьютера и то, отказался ли человек входить. «Отмена» — не «папок нет»:
    /// панель по ней возвращается к списку компьютеров, а не остаётся в пустой папке.
    struct SharesResult {
        var shares: [FileItem]
        var cancelled: Bool
    }

    /// Up to three logins typed in our window, each tried at once; the one that works is saved
    /// when asked. Cancel ends it — no second sheet, no spinner, no loop.
    static func listSharesWithOwnAuth(host: String) async -> (shares: [String], cancelled: Bool) {
        let saved = NetworkCredentialStore.lookup(server: host, scheme: "smb")
        var suggested = saved?.account ?? NetworkAuthDialog.defaultAccount
        var rejection = NetworkAuthDialog.Rejection.none
        for _ in 0..<3 {
            guard let answer = NetworkAuthDialog.ask(server: host, share: nil,
                                                     suggestedAccount: suggested,
                                                     rejection: rejection)
            else { return ([], true) }
            let listing = await Task.detached(priority: .userInitiated) {
                answer.asGuest
                    ? runSmbutil(host: host, asGuest: true)
                    : runSmbutil(host: host, account: answer.account, password: answer.password)
            }.value
            if !listing.shares.isEmpty {
                if answer.remember, !answer.asGuest {
                    NetworkCredentialStore.save(server: host, scheme: "smb",
                                                account: answer.account, password: answer.password)
                }
                return (listing.shares, false)
            }
            guard listing.failure == .authentication else { return ([], false) }
            suggested = answer.asGuest ? suggested : answer.account
            rejection = answer.asGuest ? .guest : .credentials
        }
        return ([], false)
    }

    // MARK: - Mount Share (NetFS)

    /// Mount a specific share via NetFS.
    /// - Passes nil for user/password → system uses Keychain automatically
    /// - Uses .local hostname → kernel mDNS resolver (fast, same as Finder)
    /// - If no Keychain entry → system shows native auth dialog
    func mountShare(computerName: String, shareName: String) async -> String? {
        guard let host = discoveredHosts.first(where: { $0.name == computerName }) else { return nil }
        let scheme = host.proto == "AFP" ? "afp" : "smb"
        let hostname = host.host

        // Build URL: smb://hostname.local/ShareName
        var components = URLComponents()
        components.scheme = scheme
        components.host = hostname
        components.path = "/\(shareName)"

        guard let shareURL = components.url else {
            NSLog("[NetworkBrowser] Invalid URL for %@/%@", hostname, shareName)
            return nil
        }

        NSLog("[NetworkBrowser] Mounting %@", shareURL.absoluteString)

        // Through the one mount that asks for a login in our own window.
        let result = await Self.mountWithOwnAuth(url: shareURL, shareName: shareName)
        if let mp = result.path {
            NSLog("[NetworkBrowser] Mounted at %@", mp)
            return mp
        }
        // NetFS can report success without naming the mount point; the share is where it always is.
        if result.status == 0 {
            let fb = "/Volumes/\(shareName)"
            if FileManager.default.fileExists(atPath: fb) { return fb }
        }
        NSLog("[NetworkBrowser] Mount failed: %d", result.status)
        return nil
    }

    // MARK: - Logging in through our own window

    /// Statuses that mean "the server wants a different login", as opposed to "there is no such
    /// server". Only these are worth putting a login dialog up for.
    nonisolated static func isAuthFailure(_ status: Int32) -> Bool {
        switch status {
        case Int32(EACCES), Int32(EPERM), Int32(EAUTH):     return true
        case ENETFSPWDNEEDSCHANGE, ENETFSPWDPOLICY,
             ENETFSACCOUNTRESTRICTED, ENETFSNOAUTHMECHSUPP: return true
        default:                                            return false
        }
    }

    /// One NetFS attempt with the system's own auth window suppressed.
    ///
    /// `kNAUIOptionNoUI` is what keeps macOS from putting up its own sheet — that sheet belongs to
    /// another process and cannot be restyled, so the only way to not see it is to never need it.
    /// A nil account means "use whatever the Keychain already holds", which silently reuses a
    /// share the user saved through Finder.
    nonisolated static func mountAttempt(url: URL,
                                         account: String?,
                                         password: String?,
                                         asGuest: Bool) -> (path: String?, status: Int32) {
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
        if asGuest { openOptions[kNetFSUseGuestKey] = true }

        var mountPoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(url as CFURL, nil,
                                       account as CFString?, password as CFString?,
                                       openOptions as CFMutableDictionary, nil, &mountPoints)
        guard status == 0 else { return (nil, status) }
        if let pts = mountPoints?.takeRetainedValue() as? [String], let mp = pts.first {
            waitUntilReadable(mp)
            return (mp, 0)
        }
        return (nil, 0)
    }

    /// Mount, asking for the login in OUR window when one is needed.
    ///
    /// First a silent try with whatever the Keychain holds — that covers everything already saved,
    /// here or in Finder. Only if the server turns that down does the dialog appear, and what the
    /// user types goes straight into the next attempt. A login that works is saved (if asked for);
    /// a saved login that the server rejects is deleted, so a stale password cannot go on failing
    /// silently every time the share is opened.
    static func mountWithOwnAuth(url: URL, shareName: String?) async -> (path: String?, status: Int32) {
        let server = url.host ?? ""
        let scheme = url.scheme ?? "smb"

        var result = await Task.detached(priority: .userInitiated) {
            mountAttempt(url: url, account: nil, password: nil, asGuest: false)
        }.value
        if result.status == 0 { return result }
        guard isAuthFailure(result.status), !server.isEmpty else { return result }

        let saved = NetworkCredentialStore.lookup(server: server, scheme: scheme)
        var suggested = saved?.account ?? NetworkAuthDialog.defaultAccount
        var rejection = NetworkAuthDialog.Rejection.none

        // Three goes at it: the usual typo, a second thought, then out of the way.
        for _ in 0..<3 {
            guard let answer = NetworkAuthDialog.ask(server: server, share: shareName,
                                                     suggestedAccount: suggested,
                                                     rejection: rejection)
            else { return (nil, Int32(ECANCELED)) }

            let account = answer.asGuest ? nil : answer.account
            let password = answer.asGuest ? nil : answer.password
            result = await Task.detached(priority: .userInitiated) {
                mountAttempt(url: url, account: account, password: password, asGuest: answer.asGuest)
            }.value

            if result.status == 0 {
                if answer.remember {
                    NetworkCredentialStore.save(server: server, scheme: scheme,
                                                account: answer.account, password: answer.password)
                }
                return result
            }
            guard isAuthFailure(result.status) else { return result }

            // What we had stored is wrong — drop it rather than let it fail forever.
            if let saved, saved.account == answer.account {
                NetworkCredentialStore.remove(server: server, scheme: scheme, account: saved.account)
            }
            suggested = answer.asGuest ? suggested : answer.account
            rejection = answer.asGuest ? .guest : .credentials
        }
        return result
    }

    /// Mount an arbitrary server address the user typed (smb://, afp://, nfs://…).
    /// Returns the mount point, or nil plus the NetFS status code on failure.
    nonisolated static func mountServerURL(_ url: URL) async -> (path: String?, status: Int32) {
        await mountWithOwnAuth(url: url, shareName: nil)
    }

    /// The raw NetFS mount, with macOS free to put up its own sheet. Kept for the paths that have
    /// no window of their own to ask from.
    nonisolated static func mountServerURLSystemAuth(_ url: URL) async -> (path: String?, status: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var mountPoints: Unmanaged<CFArray>?
                let status = NetFSMountURLSync(url as CFURL, nil, nil, nil, nil, nil, &mountPoints)
                if status == 0,
                   let pts = mountPoints?.takeRetainedValue() as? [String],
                   let mp = pts.first {
                    waitUntilReadable(mp)
                    continuation.resume(returning: (mp, 0))
                    return
                }
                NSLog("[NetworkBrowser] Mount of %@ failed: %d", url.absoluteString, status)
                continuation.resume(returning: (nil, status))
            }
        }
    }

    /// Poll until `path` is a readable directory (up to ~2s). Runs on a background
    /// queue during mount, so a short blocking sleep is fine.
    private nonisolated static func waitUntilReadable(_ path: String, tries: Int = 20) {
        var isDir: ObjCBool = false
        for _ in 0..<tries {
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: - Path Helpers

    static func isNetworkPath(_ path: String) -> Bool {
        path == networkRoot || path.hasPrefix(networkRoot + "/")
    }

    // Both parsers blindly chopped off networkRoot.count + 1 characters without checking the
    // path actually starts with /NETWORK. Handed a local path they returned confident garbage —
    // shareInfo("/Users/dimas/Documents") answered ("mas", "Documents") — which was enough to
    // send the panel off mounting a share that does not exist.

    static func computerName(from path: String) -> String? {
        guard isNetworkPath(path) else { return nil }
        let rest = path.dropFirst(networkRoot.count + 1)
        guard !rest.isEmpty else { return nil }
        return rest.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    static func shareInfo(from path: String) -> (computer: String, share: String)? {
        guard isNetworkPath(path) else { return nil }
        let rest = path.dropFirst(networkRoot.count + 1)
        let components = rest.split(separator: "/", maxSplits: 1)
        guard components.count == 2 else { return nil }
        return (String(components[0]), String(components[1]))
    }

    // MARK: - Private: smbutil

    /// What `smbutil view` came back with, and why it may have come back empty.
    struct SmbListing: Equatable {
        enum Failure: Equatable { case authentication, other }
        var shares: [String]
        var failure: Failure?
    }

    /// The server turned the login down — as opposed to being silent, gone or empty.
    nonisolated static func smbutilFailure(status: Int32, stderr: String) -> SmbListing.Failure? {
        guard status != 0 else { return nil }
        let text = stderr.lowercased()
        let refused = ["authentication", "permission denied", "logon failure", "access denied",
                       "password", "eauth"]
        return refused.contains { text.contains($0) } ? .authentication : .other
    }

    private nonisolated static func runSmbutil(host: String, asGuest: Bool) -> SmbListing {
        runSmbutil(target: asGuest ? "//guest@\(host)" : "//\(host)")
    }

    /// A login typed in our window goes into the URL smbutil takes — the tool has no other door
    /// for a password that is not in the Keychain yet.
    private nonisolated static func runSmbutil(host: String, account: String, password: String) -> SmbListing {
        let user = account.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? account
        let pass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
        return runSmbutil(target: "//\(user):\(pass)@\(host)")
    }

    private nonisolated static func runSmbutil(target: String) -> SmbListing {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
        proc.arguments = ["view", "-N", target]
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try proc.run() } catch { return SmbListing(shares: [], failure: .other) }

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 5)
        timer.setEventHandler { [weak proc] in if proc?.isRunning == true { proc?.terminate() } }
        timer.resume()
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errors = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        proc.waitUntilExit()
        timer.cancel()

        if let failure = smbutilFailure(status: proc.terminationStatus, stderr: errors) {
            return SmbListing(shares: [], failure: failure)
        }
        return SmbListing(shares: parseSmbutilShares(output), failure: nil)
    }

    /// The "Disk" shares out of `smbutil view` output, hidden ones (name$) left out.
    nonisolated static func parseSmbutilShares(_ output: String) -> [String] {
        var shares: [String] = []
        var inSection = false
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Share") && trimmed.contains("Type") { inSection = true; continue }
            if trimmed.hasPrefix("---") || trimmed.hasPrefix("===") { continue }
            if inSection && !trimmed.isEmpty {
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2, parts[1].lowercased() == "disk", !parts[0].hasSuffix("$") {
                    shares.append(parts[0])
                }
            }
        }
        return shares
    }

    // MARK: - Private: Helpers

}

extension Notification.Name {
    static let networkBrowserDidUpdate = Notification.Name("com.fcxl.networkBrowserDidUpdate")
    static let networkBrowserScanDidFinish = Notification.Name("com.fcxl.networkBrowserScanDidFinish")
}

// MARK: - Bonjour resolution

/// Turns NetService's delegate callbacks into one closure: (service name, IPv4 or nil, proto).
/// A single shared delegate for every resolution — NetService keeps only an unowned reference,
/// so one long-lived object is safer than one per service.
@MainActor
final class BonjourResolver: NSObject, NetServiceDelegate {
    /// Which protocol each in-flight name belongs to, so the answer lands in the right row.
    var protocolByName: [String: String] = [:]
    private let onResolved: (String, String?, String) -> Void

    init(onResolved: @escaping (String, String?, String) -> Void) {
        self.onResolved = onResolved
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let ip = Self.firstIPv4(in: sender.addresses ?? [])
        let name = sender.name
        Task { @MainActor in
            let proto = self.protocolByName.removeValue(forKey: name) ?? "SMB"
            self.onResolved(name, ip, proto)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let name = sender.name
        Task { @MainActor in
            let proto = self.protocolByName.removeValue(forKey: name) ?? "SMB"
            self.onResolved(name, nil, proto)
        }
    }

    /// IPv4 only: the subnet sweep speaks IPv4, and an address the two paths cannot compare is
    /// an address that cannot merge the duplicate.
    nonisolated private static func firstIPv4(in addresses: [Data]) -> String? {
        for data in addresses {
            let ip: String? = data.withUnsafeBytes { raw in
                guard let sa = raw.bindMemory(to: sockaddr.self).baseAddress,
                      sa.pointee.sa_family == UInt8(AF_INET) else { return nil }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                  &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
                else { return nil }
                return String(cString: buffer)
            }
            if let ip { return ip }
        }
        return nil
    }
}
