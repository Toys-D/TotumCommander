import Darwin
import Foundation

/// Обход локальной сети: кто там вообще есть.
///
/// Зачем ещё один обходчик. Прежний стучался в порт через `NWConnection` и ждал четверть
/// секунды. Замер на живой сети: сырой сокет доходит до соседнего компьютера за 4–87 мс, а
/// `NWConnection` до него же — за 1850 мс. То есть ответ не успевал прийти НИКОГДА, и
/// компьютер, который отвечает мгновенно, объявлялся отсутствующим. Здесь сокеты сырые,
/// неблокирующие, и вся подсеть опрашивается одним `poll` — 1778 проб за две секунды.
///
/// Windows не объявляет себя по Bonjour, старая Windows не открывает 445, у Linux бывает
/// только SSH, у Mac — общий экран и AFP. Поэтому спрашиваем несколько дверей сразу: кто
/// отозвался хоть в одну, тот и есть компьютер.
enum LANDiscovery {

    /// Двери, по которым узнаётся компьютер.
    ///
    /// 80 и 21 в этом списке тоже есть, но сами по себе компьютером не делают: за ними чаще
    /// принтер, камера или роутер (см. `isComputer`). Они уточняют картину, а не создают её.
    static let probedPorts: [UInt16] = [445, 139, 548, 22, 3389, 5900, 21, 80]

    /// Порты, которых достаточно, чтобы счесть адрес компьютером: общие папки Windows и
    /// Samba (445, 139), общие папки Mac (548), вход по SSH (22), удалённый рабочий стол
    /// Windows (3389), общий экран Mac и VNC (5900).
    static let computerPorts: Set<UInt16> = [445, 139, 548, 22, 3389, 5900]

    struct Found: Equatable {
        let ip: String
        /// Порты, ответившие на этом адресе.
        let ports: Set<UInt16>
        /// Имя — по NetBIOS, обратному DNS или, если никто не назвался, сам адрес.
        var name: String
        /// Есть ли у него общие папки, которые можно открыть.
        var hasShares: Bool { !ports.isDisjoint(with: [445, 139, 548]) }
    }

    // MARK: - Кого считать компьютером

    /// Отделяет компьютер от всего прочего, что отвечает по сети.
    ///
    /// Роутер отвечает на 22 и 80, и в списке компьютеров ему не место — Finder его тоже не
    /// показывает. Принтер отвечает на 80 и 9100, камера — на 80 и 554: сам по себе веб-порт
    /// компьютером не делает.
    nonisolated static func isComputer(ports: Set<UInt16>, isGateway: Bool) -> Bool {
        if isGateway { return false }
        return !ports.isDisjoint(with: computerPorts)
    }

    // MARK: - Опрос портов

    /// Опросить пачку пар «адрес: порт» разом: неблокирующие сокеты и один `poll` на всех.
    ///
    /// Дескрипторы кончаются молча, поэтому пачку сюда передают уже нарезанной по бюджету
    /// (см. `LANScanner.probeConcurrency`), а те, на кого сокета не хватило, возвращаются
    /// в `unreached` — их спрашивают ещё раз, а не вычёркивают.
    static func openPorts(_ pairs: [(ip: String, port: UInt16)], timeout: TimeInterval)
        -> (open: [(ip: String, port: UInt16)], unreached: [(ip: String, port: UInt16)]) {
        var descriptors: [Int32] = []
        var owner: [Int32: (ip: String, port: UInt16)] = [:]
        var unreached: [(ip: String, port: UInt16)] = []
        defer { descriptors.forEach { close($0) } }

        for pair in pairs {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                // Дескрипторы кончились: спросим этих во втором заходе.
                unreached.append(pair)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = pair.port.bigEndian
            guard inet_pton(AF_INET, pair.ip, &addr.sin_addr) == 1 else { close(fd); continue }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            // Мгновенный отказ (никого нет) виден сразу; всё остальное дозревает в poll.
            if rc != 0 && errno != EINPROGRESS { close(fd); continue }
            descriptors.append(fd)
            owner[fd] = pair
        }

        var open: [(ip: String, port: UInt16)] = []
        var pending = Set(descriptors)
        let deadline = Date().addingTimeInterval(timeout)
        while !pending.isEmpty, Date() < deadline {
            var polls = pending.map { pollfd(fd: $0, events: Int16(POLLOUT), revents: 0) }
            let milliseconds = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            let ready = polls.withUnsafeMutableBufferPointer {
                poll($0.baseAddress, nfds_t($0.count), milliseconds)
            }
            if ready <= 0 { break }
            for entry in polls where entry.revents != 0 {
                pending.remove(entry.fd)
                var failure: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, &failure, &size)
                if failure == 0, let who = owner[entry.fd] { open.append(who) }
            }
        }
        return (open, unreached)
    }

    // MARK: - Обход

    /// Все пары «адрес: порт» для перечисленных подсетей, кроме своих же адресов.
    nonisolated static func targets(prefixes: [String], selfIPs: Set<String>,
                                    ports: [UInt16] = probedPorts) -> [(ip: String, port: UInt16)] {
        var pairs: [(ip: String, port: UInt16)] = []
        for prefix in prefixes {
            for host in 1...254 {
                let ip = "\(prefix).\(host)"
                if selfIPs.contains(ip) { continue }
                for port in ports { pairs.append((ip, port)) }
            }
        }
        return pairs
    }

    /// Собрать ответы по адресам.
    nonisolated static func group(_ open: [(ip: String, port: UInt16)]) -> [String: Set<UInt16>] {
        var byHost: [String: Set<UInt16>] = [:]
        for entry in open { byHost[entry.ip, default: []].insert(entry.port) }
        return byHost
    }

    /// Толкнуть каждый адрес подсети одним UDP-байтом.
    ///
    /// Ответа не ждём и он не нужен: важно, что ради отправки система спрашивает «чей это
    /// адрес» по ARP, и живые соседи отзываются — сами, на канальном уровне, независимо от
    /// того, какая у них система и что у них закрыто брандмауэром. Через полсекунды все они
    /// лежат в таблице ARP.
    static func kick(prefixes: [String], selfIPs: Set<String>) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var byte: UInt8 = 0
        for prefix in prefixes {
            for host in 1...254 {
                let ip = "\(prefix).\(host)"
                if selfIPs.contains(ip) { continue }
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(9).bigEndian   // discard
                guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { continue }
                _ = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, &byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    /// Таблица ARP: кто отозвался на канальном уровне.
    static func arpTable() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-an"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Разбор `arp -an`: адреса с настоящим MAC, кроме широковещательных и групповых.
    nonisolated static func addresses(inArpOutput text: String, prefixes: [String],
                                      selfIPs: Set<String>) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            guard !line.contains("incomplete") else { continue }
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"),
                  open < close else { continue }
            let ip = String(line[line.index(after: open)..<close])
            let octets = ip.split(separator: ".")
            guard octets.count == 4, let last = Int(octets[3]) else { continue }
            // .255 — широковещательный адрес подсети, 224.х — группа: это не компьютеры.
            guard last != 255, last != 0, octets[0] != "224", octets[0] != "239" else { continue }
            let prefix = octets[0...2].joined(separator: ".")
            guard prefixes.contains(prefix), !selfIPs.contains(ip) else { continue }
            if seen.insert(ip).inserted { result.append(ip) }
        }
        return result.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Кто вообще есть в этих подсетях. Блокирует вызывающий поток на `settle`.
    static func liveAddresses(prefixes: [String], selfIPs: Set<String>,
                              settle: TimeInterval = 0.45) -> [String] {
        kick(prefixes: prefixes, selfIPs: selfIPs)
        Thread.sleep(forTimeInterval: settle)
        return addresses(inArpOutput: arpTable(), prefixes: prefixes, selfIPs: selfIPs)
    }

    /// Полный обход. Блокирует вызывающий поток — вызывать не с главного.
    ///
    /// Два шага вместо одного. Сначала ARP: кто отозвался на канальном уровне — быстро
    /// (доли секунды) и независимо от системы и брандмауэра. Потом стук в двери, но уже
    /// только к живым: десяток адресов вместо двух с половиной сотен. Прежний способ — стук
    /// во все двери подряд — заливал сеть полутора тысячами одновременных запросов, и живой
    /// сосед терялся в этом шуме.
    /// - Parameter onHost: зовётся, как только про очередной компьютер всё известно, — чтобы
    ///   список наполнялся на глазах, а не появлялся целиком в конце.
    static func discover(prefixes: [String], selfIPs: Set<String>, gateway: String?,
                         timeout: TimeInterval = 0.8,
                         onHost: ((Found) -> Void)? = nil) -> [Found] {
        LANScanner.raiseDescriptorLimit()
        let live = liveAddresses(prefixes: prefixes, selfIPs: selfIPs)
        guard !live.isEmpty else { return [] }

        var answers: [(ip: String, port: UInt16)] = []
        var leftovers: [(ip: String, port: UInt16)] = []
        let pairs = live.flatMap { ip in probedPorts.map { (ip: ip, port: $0) } }
        for batch in pairs.chunked(into: 512) {
            let result = openPorts(batch, timeout: timeout)
            answers.append(contentsOf: result.open)
            leftovers.append(contentsOf: result.unreached)
        }
        if !leftovers.isEmpty {
            for batch in leftovers.chunked(into: 128) {
                answers.append(contentsOf: openPorts(batch, timeout: timeout).open)
            }
        }

        var byHost = group(answers)
        // Первый обход после запуска программы медленнее остальных: пока macOS решает,
        // пускать ли нас в локальную сеть, часть дверей не успевает ответить. Живых соседей
        // мы уже знаем по ARP — переспросить их ещё раз стоит десятка сокетов.
        //
        // Но только когда не нашлось НИКОГО: в обычном обходе большинство живых адресов —
        // это телефоны и телевизоры, у которых и правда нечего спрашивать, и второй заход
        // по ним стоил бы двух секунд ожидания на ровном месте.
        let anyComputer = byHost.contains { isComputer(ports: $0.value, isGateway: $0.key == gateway) }
        let silent = anyComputer ? []
            : live.filter { !isComputer(ports: byHost[$0] ?? [], isGateway: $0 == gateway) }
        if !silent.isEmpty {
            let again = silent.flatMap { ip in probedPorts.map { (ip: ip, port: $0) } }
            for batch in again.chunked(into: 512) {
                for entry in openPorts(batch, timeout: max(timeout, 2.0)).open {
                    byHost[entry.ip, default: []].insert(entry.port)
                }
            }
        }

        let computers = byHost
            .filter { isComputer(ports: $0.value, isGateway: $0.key == gateway) }
            .sorted { $0.key.compare($1.key, options: .numeric) == .orderedAscending }

        // Имена спрашиваем разом: у каждого NetBIOS свой предел ожидания, и по очереди
        // десяток компьютеров занял бы полминуты. Каждый готовый уходит наверх сразу —
        // список наполняется на глазах.
        var found = [Found?](repeating: nil, count: computers.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: computers.count) { index in
            let entry = computers[index]
            let host = Found(ip: entry.key, ports: entry.value,
                             name: name(for: entry.key) ?? entry.key)
            lock.lock(); found[index] = host; lock.unlock()
            onHost?(host)
        }
        return found.compactMap { $0 }
    }

    // MARK: - Имена

    /// Как зовут этот компьютер: сначала NetBIOS (так себя называет Windows), потом обратный
    /// DNS (так его знает роутер). Пусто — значит никак, и в списке будет адрес.
    static func name(for ip: String) -> String? {
        if let netbios = LANScanner.netBIOSName(ip: ip) { return netbios }
        return reverseDNS(ip: ip)
    }

    /// Имя по обратному DNS. Домен `.local`/`.lan` от роутера отбрасывается: в списке нужен
    /// сам компьютер, а не его полное имя.
    static func reverseDNS(ip: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard ok == 0 else { return nil }
        return shortName(String(cString: buffer), ip: ip)
    }

    /// Отрезать домен и не выдавать за имя тот же адрес.
    nonisolated static func shortName(_ raw: String, ip: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !trimmed.isEmpty, trimmed != ip else { return nil }
        let head = trimmed.split(separator: ".").first.map(String.init) ?? trimmed
        return head.isEmpty ? nil : head
    }

    /// Адрес маршрутизатора — его в списке компьютеров быть не должно.
    static func defaultGateway() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return gatewayAddress(inRouteOutput: text)
    }

    /// Разбор ответа `route -n get default`.
    nonisolated static func gatewayAddress(inRouteOutput text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, parts[0] == "gateway", !parts[1].isEmpty { return parts[1] }
        }
        return nil
    }
}

extension Array {
    /// Нарезка на пачки — обход идёт волнами по бюджету дескрипторов.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
