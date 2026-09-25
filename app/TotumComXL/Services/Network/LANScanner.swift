import Foundation
import Network
import Darwin

/// Discovers SMB hosts on the local subnet by probing TCP port 445 and
/// resolving NetBIOS names via `smbutil status`.
///
/// Why this exists: Bonjour (NWBrowser `_smb._tcp`) only finds devices that
/// advertise over mDNS — Macs and some NAS. Windows PCs do NOT advertise SMB
/// over Bonjour (they use WS-Discovery / NetBIOS), so a Bonjour-only browser
/// never sees them. A direct subnet port-445 scan catches every host with
/// SMB file sharing enabled, regardless of discovery protocol — which is how
/// we match what Finder shows.
enum LANScanner {

    struct Host {
        let ip: String
        let name: String   // NetBIOS server name, or the IP if unresolved
    }

    /// Чем кончилась проба одного адреса.
    ///
    /// «Закрыт» и «не хватило дескрипторов» выглядят из Network.framework одинаково —
    /// соединение просто не состоялось. Разница решающая: в первом случае по этому адресу
    /// никого нет, во втором мы даже не спросили, и объявить его пустым значит потерять
    /// живой компьютер.
    enum ProbeOutcome: Equatable { case open, closed, outOfDescriptors }

    /// Программе, запущенной из Finder, launchd выдаёт мягкий предел в 256 дескрипторов, а
    /// развёртка подсети держит в воздухе больше двух сотен проб. Вместе с полутора сотнями
    /// уже открытых файлов дескрипторы кончались посреди развёртки — и часть подсети просто
    /// не опрашивалась. Какая именно, зависело от того, сколько всего было открыто в эту
    /// минуту: вчера компьютер в списке был, сегодня нет.
    /// - Returns: мягкий предел после попытки его поднять.
    @discardableResult
    static func raiseDescriptorLimit(to wanted: rlim_t = 8192) -> rlim_t {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
        // RLIM_INFINITY в Darwin — это (rlim_t)-1, до Swift этот макрос не доезжает.
        let unlimited = rlim_t.max
        let target = limit.rlim_max == unlimited ? wanted : min(wanted, limit.rlim_max)
        guard limit.rlim_cur < target else { return limit.rlim_cur }
        var raised = limit
        raised.rlim_cur = target
        guard setrlimit(RLIMIT_NOFILE, &raised) == 0 else { return limit.rlim_cur }
        return target
    }

    /// Сколько проб держать в воздухе разом, зная предел и то, что уже занято. Запас в 64
    /// дескриптора — на всё остальное, что программа делает во время развёртки: следит за
    /// папками, читает значки, качает файлы.
    nonisolated static func probeConcurrency(softLimit: Int, openDescriptors: Int,
                                             ceiling: Int = 224) -> Int {
        let spare = softLimit - openDescriptors - 64
        return max(8, min(ceiling, spare))
    }

    /// Сколько дескрипторов занято прямо сейчас.
    static func openDescriptorCount(softLimit: Int) -> Int {
        var count = 0
        for fd in 0..<Int32(min(max(softLimit, 0), 65_536)) where fcntl(fd, F_GETFD) != -1 {
            count += 1
        }
        return count
    }

    /// Scan the local /24 subnet(s) for SMB hosts. `onHost` is called on a
    /// background queue for each discovered host as soon as it's found;
    /// `completion` fires once when the whole scan finishes.
    static func scan(onHost: @escaping (Host) -> Void,
                     completion: @escaping () -> Void) {
        // 0.25s, not 0.6: on a LAN a live host answers in single-digit milliseconds, and a
        // dead address answers never — the extra third of a second bought nothing but waiting.
        sweep(port: 445,
              timeout: 0.25,
              identify: { netBIOSName(ip: $0) ?? $0 },
              onHost: onHost,
              completion: completion)
    }

    /// Probe every host on the local subnet for one open TCP port.
    ///
    /// `identify` runs on a background queue for each host that answers, and returns the name to
    /// show — or nil to reject the host. That is how a caller tells a real server apart from
    /// anything else that happens to listen on the same port number.
    ///
    /// Blocks the calling thread while the sweep is dispatched, so call it off the main thread.
    static func sweep(port: UInt16,
                      timeout: TimeInterval = 0.6,
                      identify: @escaping (String) -> String?,
                      onHost: @escaping (Host) -> Void,
                      completion: @escaping () -> Void) {
        let (ranges, selfIPs) = localScanTargets()
        guard !ranges.isEmpty else { completion(); return }

        // Поднять предел ПЕРЕД развёрткой и считать бюджет уже по новому: иначе первая же
        // развёртка идёт с launchd-овскими 256 на всю программу.
        let softLimit = Int(raiseDescriptorLimit())
        let budget = probeConcurrency(softLimit: softLimit,
                                      openDescriptors: openDescriptorCount(softLimit: softLimit))

        let probeQueue = DispatchQueue(label: "com.fcxl.lanscan.probe", attributes: .concurrent)
        let group = DispatchGroup()
        let gate = DispatchSemaphore(value: budget)
        // Адреса, до которых дело не дошло: дескрипторы кончились. Их спрашиваем ещё раз,
        // когда первая волна отпустит своё, — молча вычёркивать их нельзя.
        let unaskedLock = NSLock()
        var unasked: [String] = []

        for ip in ranges where !selfIPs.contains(ip) {
            group.enter()
            gate.wait()
            probePort(ip: ip, port: port, queue: probeQueue, timeout: timeout) { outcome in
                defer { gate.signal(); group.leave() }
                switch outcome {
                case .closed:
                    return
                case .outOfDescriptors:
                    unaskedLock.lock(); unasked.append(ip); unaskedLock.unlock()
                case .open:
                    guard let name = identify(ip) else { return }
                    onHost(Host(ip: ip, name: name))
                }
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            unaskedLock.lock(); let leftovers = unasked; unaskedLock.unlock()
            guard !leftovers.isEmpty else { completion(); return }
            secondWave(leftovers, port: port, timeout: timeout, identify: identify,
                       onHost: onHost, completion: completion)
        }
    }

    /// Второй заход по адресам, до которых не хватило дескрипторов. Волна поуже и подольше:
    /// торопиться уже некуда, зато никто не теряется.
    private static func secondWave(_ ips: [String], port: UInt16, timeout: TimeInterval,
                                   identify: @escaping (String) -> String?,
                                   onHost: @escaping (Host) -> Void,
                                   completion: @escaping () -> Void) {
        let queue = DispatchQueue(label: "com.fcxl.lanscan.probe.again", attributes: .concurrent)
        let group = DispatchGroup()
        let gate = DispatchSemaphore(value: 16)
        for ip in ips {
            group.enter()
            gate.wait()
            probePort(ip: ip, port: port, queue: queue, timeout: max(timeout, 0.5)) { outcome in
                defer { gate.signal(); group.leave() }
                guard outcome == .open, let name = identify(ip) else { return }
                onHost(Host(ip: ip, name: name))
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) { completion() }
    }

    // MARK: - This machine

    /// This machine's IPv4 addresses, best first — Wi-Fi and Ethernet ahead of anything
    /// tunnel-shaped, because a VPN address is never the one a phone across the room can reach.
    static func localAddresses() -> [String] {
        var found: [(interface: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
                  let addr = p.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                        &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostBuf)
            // 169.254.x.x means the interface never got a real address: nothing can reach it.
            guard !ip.isEmpty, ip != "0.0.0.0", !ip.hasPrefix("169.254.") else { continue }
            found.append((String(cString: p.pointee.ifa_name), ip))
        }
        return found.sorted { interfaceRank($0.interface) < interfaceRank($1.interface) }.map(\.ip)
    }

    nonisolated static func interfaceRank(_ interface: String) -> Int {
        if interface.hasPrefix("en") { return 0 }        // Wi-Fi / Ethernet
        if interface.hasPrefix("utun") || interface.hasPrefix("ipsec") { return 2 }   // VPN
        if interface.hasPrefix("bridge") { return 2 }    // virtual machines
        return 1
    }

    // MARK: - Subnet enumeration

    /// Returns the list of candidate IPs to probe (the /24 around each active
    /// IPv4 interface) plus the set of this machine's own IPs to skip.
    private static func localScanTargets() -> (ips: [String], selfIPs: Set<String>) {
        var selfIPs = Set<String>()
        var interfaces: [(name: String, ip: String)] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return ([], []) }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
                  let addr = p.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                        &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostBuf)
            guard !ip.isEmpty, ip != "0.0.0.0" else { continue }
            selfIPs.insert(ip)
            interfaces.append((String(cString: p.pointee.ifa_name), ip))
        }

        var ips: [String] = []
        for prefix in scanPrefixes(interfaces: interfaces) {
            for host in 1...254 { ips.append("\(prefix).\(host)") }
        }
        return (ips, selfIPs)
    }

    /// Подсети для обхода и собственные адреса — то же самое, что считает `localScanTargets`,
    /// но без разворачивания в 254 адреса на каждую: новому обходчику нужны сами подсети.
    static func scanScope() -> (prefixes: [String], selfIPs: Set<String>) {
        var selfIPs = Set<String>()
        var interfaces: [(name: String, ip: String)] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return ([], []) }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
                  let addr = p.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                        &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostBuf)
            guard !ip.isEmpty, ip != "0.0.0.0", !ip.hasPrefix("169.254.") else { continue }
            selfIPs.insert(ip)
            interfaces.append((String(cString: p.pointee.ifa_name), ip))
        }
        return (scanPrefixes(interfaces: interfaces), selfIPs)
    }

    /// Какие /24 обходить и в каком порядке.
    ///
    /// Проводная сеть и Wi-Fi — первыми, туннели VPN — последними. У человека с поднятым
    /// Tailscale адресов два: 192.168.0.x и 100.x.y.z, и это 508 проб вместо 254. Раньше
    /// порядок был случайным (множество), и когда первой шла подсеть VPN — где никого и
    /// нет, — на настоящую сеть уже не хватало ни дескрипторов, ни времени. Отсюда и
    /// «вчера компьютер был виден, сегодня нет».
    nonisolated static func scanPrefixes(interfaces: [(name: String, ip: String)]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in interfaces.enumerated()
            .sorted(by: { lhs, rhs in
                let l = interfaceRank(lhs.element.name), r = interfaceRank(rhs.element.name)
                // При равном ранге — порядок системы: она отдаёт интерфейсы не как попало.
                return l == r ? lhs.offset < rhs.offset : l < r
            })
            .map(\.element) {
            // /24 вокруг адреса: домашняя и рабочая сеть почти всегда такие, а /16 — это
            // шестьдесят пять тысяч адресов и минуты ожидания.
            let octets = entry.ip.split(separator: ".")
            guard octets.count == 4 else { continue }
            let prefix = octets[0...2].joined(separator: ".")
            if seen.insert(prefix).inserted { ordered.append(prefix) }
        }
        return ordered
    }

    /// Переспросить несколько адресов поодиночке и без спешки: развёртка бьёт по всей
    /// подсети залпом с пределом в четверть секунды, и живой хост за Wi-Fi иногда не
    /// успевает — а из-за одного такого промаха его вычёркивали из списка.
    /// - Returns: адреса, ответившие на этот раз.
    static func recheck(ips: [String], port: UInt16 = 445, timeout: TimeInterval = 1.5,
                        completion: @escaping (Set<String>) -> Void) {
        guard !ips.isEmpty else { completion([]); return }
        let queue = DispatchQueue(label: "com.fcxl.lanscan.recheck", attributes: .concurrent)
        let lock = NSLock()
        var alive = Set<String>()
        let group = DispatchGroup()
        for ip in ips {
            group.enter()
            probePort(ip: ip, port: port, queue: queue, timeout: timeout) { outcome in
                if outcome == .open { lock.lock(); alive.insert(ip); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) { completion(alive) }
    }

    // MARK: - Port probe

    static func probePort(ip: String, port: UInt16, queue: DispatchQueue,
                          timeout: TimeInterval,
                          completion: @escaping (ProbeOutcome) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { completion(.closed); return }
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: .tcp)
        var finished = false
        let finish: (ProbeOutcome) -> Void = { outcome in
            if finished { return }
            finished = true
            conn.cancel()
            completion(outcome)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(.open)
            case .failed(let error): finish(outcome(for: error))
            case .cancelled: finish(.closed)
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(.closed) }
    }

    /// Нехватка дескрипторов — это не «там никого нет». Системе нечем открыть сокет, и
    /// адрес остался неспрошенным.
    nonisolated static func outcome(for error: NWError) -> ProbeOutcome {
        guard case .posix(let code) = error else { return .closed }
        switch code {
        case .EMFILE, .ENFILE, .ENOBUFS, .ENOMEM: return .outOfDescriptors
        default: return .closed
        }
    }

    // MARK: - Name resolution

    /// `smbutil status <ip>` → NetBIOS server name (the macOS-native way, no
    /// Samba needed). Returns nil if the host doesn't answer NetBIOS.
    static func netBIOSName(ip: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
        proc.arguments = ["status", ip]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }

        let timer = DispatchSource.makeTimerSource(queue: .global())
        // Полторы секунды: сосед по сети отвечает за миллисекунды, а молчуна ждать дольше
        // значит держать весь обзор сети ради того, кто всё равно не назовётся.
        timer.schedule(deadline: .now() + 1.5)
        timer.setEventHandler { [weak proc] in if proc?.isRunning == true { proc?.terminate() } }
        timer.resume()
        proc.waitUntilExit()
        timer.cancel()

        guard proc.terminationStatus == 0 else { return nil }
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        // Expected lines:  "Server: HOSTNAME"  /  "Workgroup: WORKGROUP"
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("server:") {
                let name = trimmed.dropFirst("server:".count).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }
}
