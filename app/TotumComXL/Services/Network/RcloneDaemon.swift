import Foundation
import Security

/// Мост к rclone — чужой программе, которая умеет разговаривать с семью десятками хранилищ:
/// Google Drive, Dropbox, OneDrive, Яндекс.Диск, Box, pCloud и так далее.
///
/// Писать каждое из них своими руками — это годы: у всех своя выдача ключей через браузер,
/// свои причуды со списком и свои пределы. rclone это уже сделал и держит настройку в
/// собственном файле, куда человек складывает свои хранилища командой `rclone config`.
/// Наше дело — показать их панелью.
///
/// Разговор идёт не запуском команды на каждое действие, а через служебный сервер самого
/// rclone (`rclone rcd`): один процесс на всю работу, ответы в JSON, ход дела и отмена — по
/// номеру задания. Запуск отдельного процесса на каждый шаг стоил бы четверти секунды на
/// ровном месте и не дал бы ни полосы, ни отмены.
///
/// Сервер поднимается на петле (127.0.0.1) на свободном порту и закрыт паролем, который
/// придумывается заново при каждом запуске: без пароля любая программа на этой же машине
/// получила бы полный доступ ко всем хранилищам человека.
actor RcloneDaemon {

    static let shared = RcloneDaemon()

    /// Где искать программу, если своей вдруг не оказалось. Homebrew на Apple Silicon
    /// кладёт её первым путём, на Intel — вторым; MacPorts и ручная установка — остальными.
    static let knownPaths = [
        "/opt/homebrew/bin/rclone",
        "/usr/local/bin/rclone",
        "/opt/local/bin/rclone",
        "/usr/bin/rclone"
    ]

    /// Путь, указанный человеком в настройках, если программа лежит где-то ещё.
    static let customPathKey = "rclone.binaryPath"

    /// Своя, внутри бандла. Она и есть основной случай: человек ничего не ставит.
    nonisolated static var bundledPath: String? {
        let inside = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/rclone").path
        return FileManager.default.isExecutableFile(atPath: inside) ? inside : nil
    }

    private var process: Process?
    private var address: URL?
    private var password = ""

    /// Тот же процесс, но доступный без ожидания очереди актёра. Нужен ровно для одного:
    /// убить помощника при выходе из программы. Выход не ждёт асинхронных задач — они
    /// просто не успевают выполниться, — и чужой процесс остался бы висеть в системе
    /// с ключами от всех хранилищ человека в памяти.
    private static let runningLock = NSLock()
    private static var running: Process?
    /// Кто сейчас пользуется сервером. Не счётчик, а именные места.
    ///
    /// Счётчика мало: «отпускаю» приходит отложенно, и оно может относиться к помощнику,
    /// которого уже нет. Окно выбора хранилищ берёт сервер и отпускает его следом, а
    /// человек в это время нажимает «Подключиться» — и запоздалое «отпускаю» гасило ТОЛЬКО
    /// ЧТО поднятого помощника. Подключение падало с «rclone запустился, но не отвечает» —
    /// чистой правдой, потому что его уже убили. Именное место чужим не отдать, а при
    /// перезапуске все прежние места пропадают вместе со старым помощником.
    private var tickets: Set<Int> = []
    private var nextTicket = 1

    /// Куда помощник пишет свои жалобы. Читается, когда он не поднялся.
    private var logFile: URL?

    // MARK: - Наличие программы

    /// Путь к rclone или nil, если её нет. Проверяется существование и право на запуск —
    /// пустой файл с нужным именем не годится.
    nonisolated static func binaryPath() -> String? {
        let manager = FileManager.default
        // Указанная человеком — первой: он мог поставить свою, посвежее, и захотеть именно её.
        if let custom = UserDefaults.standard.string(forKey: customPathKey),
           !custom.isEmpty, manager.isExecutableFile(atPath: custom) {
            return custom
        }
        // Дальше своя, из бандла: она проверена вместе с программой.
        if let bundled = bundledPath { return bundled }
        // И только потом — чужая, поставленная в систему.
        return knownPaths.first { manager.isExecutableFile(atPath: $0) }
    }

    nonisolated static var isInstalled: Bool { binaryPath() != nil }

    /// Что сказать человеку, у которого rclone нет. Одной командой, чтобы можно было
    /// скопировать и вставить.
    nonisolated static var installHint: String { "brew install rclone" }

    // MARK: - Жизнь сервера

    /// Поднять сервер, если он ещё не поднят, и занять у него именное место.
    @discardableResult
    func acquire() async throws -> (url: URL, ticket: Int) {
        let ticket = nextTicket
        nextTicket += 1
        tickets.insert(ticket)
        do {
            if let address, process?.isRunning == true { return (address, ticket) }
            return (try await start(), ticket)
        } catch {
            tickets.remove(ticket)
            throw error
        }
    }

    /// Адрес поднятого сервера — только для проверок: в них надо уметь спросить у него
    /// самого, сколько запросов он обслужил.
    var addressForTests: URL? { address }

    /// Отпустить своё место. Последний уходящий гасит свет.
    ///
    /// Место из прошлой жизни помощника просто не найдётся — и ничего не погасит.
    func release(_ ticket: Int) {
        guard tickets.remove(ticket) != nil, tickets.isEmpty else { return }
        stop()
    }

    /// Погасить сервер немедленно, сколько бы ни было пользователей: так уходит программа.
    func stop() {
        Self.kill(process)
        Self.forget(process)
        process = nil
        address = nil
        password = ""
        tickets.removeAll()
    }

    /// Номер процесса-помощника, если он сейчас живёт. По нему проверяют, что помощник
    /// действительно ушёл, а не только вычеркнут из наших записей.
    nonisolated static var helperProcessID: pid_t? {
        runningLock.lock()
        defer { runningLock.unlock() }
        guard let task = running, task.isRunning else { return nil }
        return task.processIdentifier
    }

    /// Убить помощника прямо сейчас, из любого потока и без ожидания. Так уходит программа.
    nonisolated static func terminateHelper() {
        runningLock.lock()
        let task = running
        running = nil
        runningLock.unlock()
        Self.kill(task)
    }

    /// Помощника снимаем жёстко, а не вежливой просьбой.
    ///
    /// Вежливая — это SIGTERM, а его мы у себя ГЛУШИМ, чтобы успеть прибраться, когда
    /// программу снимают снаружи. Глушение наследуется потомком: попроси мы его так же —
    /// он бы просьбу не услышал и остался жить. Терять ему нечего: настройку rclone
    /// пишет заменой файла целиком, оборвать её на середине нельзя.
    private nonisolated static func kill(_ task: Process?) {
        guard let task, task.isRunning else { return }
        Darwin.kill(task.processIdentifier, SIGKILL)
    }

    static func complaintsFile(port: UInt16) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("totum-rclone-\(port).log")
    }

    /// Последнее, что сказал помощник. Пусто — значит он молчал и сам.
    private func lastComplaint() -> String {
        guard let logFile,
              let text = try? String(contentsOf: logFile, encoding: .utf8) else { return "" }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(3)
            .joined(separator: " ")
    }

    private nonisolated static func remember(_ task: Process) {
        runningLock.lock()
        running?.terminate()
        running = task
        runningLock.unlock()
    }

    private nonisolated static func forget(_ task: Process?) {
        guard let task else { return }
        runningLock.lock()
        if running === task { running = nil }
        runningLock.unlock()
    }

    private func start() async throws -> URL {
        guard let binary = Self.binaryPath() else {
            throw RemoteFileSystemError.connectionFailed(
                L("rclone.error.notInstalled", Self.installHint))
        }

        let port = try Self.freePort()
        let secret = Self.freshPassword()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = [
            "rcd",
            "--rc-addr", "127.0.0.1:\(port)",
            "--log-level", "ERROR"
        ]
        // Пароль передаётся окружением, а не аргументом: аргументы чужого процесса видны
        // в `ps` любому, кто сидит за этой же машиной, и пароль от всех хранилищ человека
        // светился бы там весь сеанс.
        var environment = ProcessInfo.processInfo.environment
        environment["RCLONE_RC_USER"] = "totum"
        environment["RCLONE_RC_PASS"] = secret
        task.environment = environment
        // Вывод — в файл, а не в трубу и не в никуда.
        //
        // Труба, которую никто не читает, однажды наполняется, и чужой процесс замирает на
        // записи в неё. А «в никуда» уже подводило: когда помощник однажды не поднялся,
        // сказать человеку было нечего — жалоба самого rclone уходила в пустоту. Файл
        // решает и то, и другое: труба не переполнится, а причина сохранится.
        let complaints = Self.complaintsFile(port: port)
        FileManager.default.createFile(atPath: complaints.path, contents: nil)
        if let sink = try? FileHandle(forWritingTo: complaints) {
            task.standardOutput = sink
            task.standardError = sink
        }
        logFile = complaints

        do {
            try task.run()
        } catch {
            throw RemoteFileSystemError.connectionFailed(
                L("rclone.error.cannotStart", error.localizedDescription))
        }

        let url = URL(string: "http://127.0.0.1:\(port)")!
        Self.remember(task)
        process = task
        address = url
        password = secret

        // Сервер поднимается не мгновенно. Стучимся, пока не ответит, но не дольше
        // десяти секунд: дальше это уже не «медленно запускается», а «не запустился».
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            guard task.isRunning else { break }
            switch await probe() {
            case .open:
                return url
            case .silent:
                try? await Task.sleep(nanoseconds: 100_000_000)
            case .unhappy(let complaint):
                // Дверь открыли и не пустили. Ждать дальше нечего: за портом сидит либо
                // не наш сервер, либо наш, но с другим паролем — и десять секунд молчания
                // сказали бы человеку куда меньше, чем эта жалоба.
                stop()
                throw RemoteFileSystemError.connectionFailed(complaint)
            }
        }

        // Что именно случилось, знает сам помощник — и теперь мы это прочли.
        let complaint = lastComplaint()
        stop()
        throw RemoteFileSystemError.connectionFailed(
            complaint.isEmpty ? L("rclone.error.noAnswer")
                              : L("rclone.error.noAnswerBecause", complaint))
    }

    private enum Probe {
        /// Ответил и пустил.
        case open
        /// Никто не открыл: сервер ещё поднимается.
        case silent
        /// Открыли, но не пустили.
        case unhappy(String)
    }

    /// Стук в дверь. Отличать «ещё не поднялся» от «поднялся и отказал» важно: первое
    /// лечится ожиданием, второе — никогда.
    private func probe() async -> Probe {
        do {
            _ = try await send("rc/noop", [:])
            return .open
        } catch let error as URLError {
            return Self.nobodyHome(error) ? .silent : .unhappy(error.localizedDescription)
        } catch let error as RemoteFileSystemError {
            return .unhappy(error.errorDescription ?? "\(error)")
        } catch {
            return .silent
        }
    }

    /// Отказ соединения — это «ещё не слушают», а не «отказали». Разбирается по коду
    /// ошибки, а не по её тексту: текст переведён на язык системы.
    static func nobodyHome(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost,
             .notConnectedToInternet, .timedOut:
            return true
        default:
            return false
        }
    }

    // MARK: - Разговор

    /// Один вызов служебного сервера. Все они POST и все отвечают объектом JSON.
    @discardableResult
    func call(_ path: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        do {
            return try await send(path, arguments)
        } catch let error as URLError where error.code == .timedOut {
            throw RemoteFileSystemError.timeout
        } catch let error as URLError {
            throw RemoteFileSystemError.connectionFailed(error.localizedDescription)
        }
    }

    /// То же самое, но сбой связи уходит наружу как есть — чтобы можно было отличить
    /// «никто не слушает» от «ответили отказом». Через текст ошибки это не отличить:
    /// он переведён на язык системы и меняется от версии к версии.
    private func send(_ path: String, _ arguments: [String: Any]) async throws
    -> [String: Any] {
        guard let address else { throw RemoteFileSystemError.notConnected }

        var request = URLRequest(url: address.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = Data("totum:\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: arguments)
        // Переносы идут отдельным заданием и здесь не ждутся, поэтому любой вызов —
        // короткий разговор, а не многочасовое ожидание.
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, http.statusCode / 100 == 2 else {
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                throw RemoteFileSystemError.authenticationFailed(L("rclone.error.refused"))
            }
            throw Self.error(from: object, path: path)
        }
        return object
    }

    /// Перевести жалобу rclone на язык программы.
    ///
    /// Разбор идёт по тексту, потому что кодов ошибок rclone не даёт — только строку. Она
    /// устойчивая (эти же слова разбирают и другие обёртки над rclone), но случай, который
    /// не узнали, обязан дойти до человека целиком, а не превратиться в «что-то не так».
    static func error(from object: [String: Any], path: String) -> RemoteFileSystemError {
        let text = (object["error"] as? String) ?? path
        let lower = text.lowercased()
        if lower.contains("didn't find section in config file")
            || lower.contains("didn't find backend called") {
            return .connectionFailed(L("rclone.error.noSuchRemote", text))
        }
        if lower.contains("directory not found") || lower.contains("object not found")
            || lower.contains("not found") && lower.contains("file") {
            return .pathNotFound(text)
        }
        if lower.contains("permission denied") || lower.contains("forbidden") {
            return .permissionDenied(text)
        }
        if lower.contains("token") || lower.contains("unauthorized")
            || lower.contains("authentication") {
            return .authenticationFailed(text)
        }
        return .operationFailed(text)
    }

    // MARK: - Мелочи

    /// Свободный порт: система сама выдаёт его, когда просят нулевой. Между закрытием
    /// сокета и запуском rclone порт теоретически может перехватить кто-то ещё — тогда
    /// rclone не поднимется и человек увидит внятный отказ, а не тихую поломку.
    static func freePort() throws -> UInt16 {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else {
            throw RemoteFileSystemError.connectionFailed(L("rclone.error.noPort"))
        }
        defer { close(handle) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
        address.sin_port = 0

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw RemoteFileSystemError.connectionFailed(L("rclone.error.noPort"))
        }

        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let asked = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &size)
            }
        }
        guard asked == 0 else {
            throw RemoteFileSystemError.connectionFailed(L("rclone.error.noPort"))
        }
        return UInt16(bigEndian: address.sin_port)
    }

    /// Пароль на один запуск. Двадцать четыре случайных байта — угадывать нечего, а живёт
    /// он только в памяти этого процесса и внутри аргументов запущенного сервера.
    static func freshPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}
