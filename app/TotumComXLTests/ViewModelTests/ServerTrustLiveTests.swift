import XCTest
import CryptoKit
@testable import TotumComXLApp

// Тот ли это сервер — на настоящих соединениях.
//
// Подключается тот же код, что и в окне программы: к sshd, поднятому на этой машине на
// свободном порту, и к маленькому FTPS-серверу с самоподписанным сертификатом. Проверяется
// главное: пока человек не подтвердил ключ сервера, серверу не называют ни имени, ни пароля.
// Смотрим это в журнале самого сервера, а не в словах программы.
//
// Оба сервера живут во временной папке теста, слушают только 127.0.0.1 и убираются за собой.
// Настоящих ключей, подключений и настроек человека тесты не касаются.

// MARK: - Общее

private enum LiveServerKit {

    /// Свободный порт на 127.0.0.1: система выдаёт его сама, мы только спрашиваем номер.
    static func freePort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else { return nil }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }

    /// Ждать, пока условие не выполнится. false — не дождались.
    static func wait(upTo seconds: TimeInterval, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    static func text(_ path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Запустить сервер так, чтобы всё им сказанное легло в файл: из канала длинный журнал
    /// пришлось бы вычитывать, иначе сервер встанет на записи.
    static func launch(_ tool: String, _ arguments: [String], logTo logPath: String) -> Process? {
        FileManager.default.createFile(atPath: logPath, contents: nil)
        guard let log = FileHandle(forWritingAtPath: logPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        do { try process.run() } catch { return nil }
        return process
    }

    /// Остановить сервер и дождаться, пока он уйдёт, — но не дольше нескольких секунд.
    ///
    /// Не через `waitUntilExit`: однажды он не вернулся. sshd к тому времени вышел — это видно
    /// по его журналу («Received signal 15; terminating») и по списку процессов, где его уже
    /// не было, — а `Process` этого так и не заметил, и прогон встал насовсем. Повторить
    /// случай не удалось: сорок остановок sshd сразу после входа прошли чисто. Поэтому ждём
    /// сами — смотрим не только на `isRunning`, но и на то, есть ли процесс на самом деле, — а
    /// что увидели в необычном случае, печатаем: по этим показаниям его можно будет разобрать.
    static func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, kill(pid, 0) == 0, Date() < deadline { usleep(20_000) }
        guard process.isRunning else { return }

        // Необычный случай: процесса уже нет, а `Process` считает его живым, — либо он не ушёл
        // за отведённое время. waitpid отвечает, что именно: pid — процесс вышел, но его никто
        // не подобрал; 0 — он ещё работает; -1 — его подобрал кто-то другой.
        let exists = kill(pid, 0) == 0
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        let reapError = reaped < 0 ? errno : 0
        // Добиваем только заведомо свой и живой процесс: номер исчезнувшего мог достаться
        // другому.
        if reaped == 0 { kill(pid, SIGKILL) }
        print("[LiveServerKit] сервер pid \(pid) остановлен не как обычно: isRunning=true, "
              + "процесс \(exists ? "есть" : "исчез"), waitpid=\(reaped) errno=\(reapError) "
              + "status=\(status)\(reaped == 0 ? ", добит SIGKILL" : "")")
    }
}

// MARK: - SFTP

/// Настоящий sshd на 127.0.0.1: свой ключ узла, вход только по ключу, только SFTP. Работает от
/// имени того, кто запустил тесты; о настоящих ключах человека не знает ничего.
private final class LocalSSHD {
    let port: UInt16
    /// Отпечаток ключа узла, как его печатает `ssh-keygen -l`: «SHA256:…».
    let hostKeyFingerprint: String
    let clientKeyPath: String
    /// Папка, которую видно через SFTP; в ней лежит probe.txt.
    let rootPath: String

    private let folder: String
    private let logPath: String
    private var process: Process?

    init() async throws {
        let sshd = "/usr/sbin/sshd", keygen = "/usr/bin/ssh-keygen"
        guard FileManager.default.isExecutableFile(atPath: sshd),
              FileManager.default.isExecutableFile(atPath: keygen) else {
            throw XCTSkip("на этой машине нет sshd или ssh-keygen")
        }
        guard let port = LiveServerKit.freePort() else { throw XCTSkip("не нашлось свободного порта") }
        self.port = port
        folder = NSTemporaryDirectory() + "fcxl-sshd-\(UUID().uuidString)"
        rootPath = folder + "/root"
        clientKeyPath = folder + "/client_key"
        logPath = folder + "/sshd.log"
        try FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
        try Data("проба".utf8).write(to: URL(fileURLWithPath: rootPath + "/probe.txt"))

        let hostKey = folder + "/host_key"
        for key in [hostKey, clientKeyPath] {
            guard TestDiskImage.run(keygen, ["-q", "-t", "ed25519", "-N", "", "-f", key]).status == 0 else {
                try? FileManager.default.removeItem(atPath: folder)
                throw XCTSkip("ssh-keygen не создал ключ")
            }
        }
        try FileManager.default.copyItem(atPath: clientKeyPath + ".pub",
                                         toPath: folder + "/authorized_keys")

        // «SHA256:…» — второе слово в строке «256 SHA256:… примечание (ED25519)».
        let printed = TestDiskImage.run(keygen, ["-l", "-E", "sha256", "-f", hostKey + ".pub"])
        let words = printed.output.split(separator: " ")
        guard printed.status == 0, words.count >= 2, words[1].hasPrefix("SHA256:") else {
            try? FileManager.default.removeItem(atPath: folder)
            throw XCTSkip("ssh-keygen не назвал отпечаток: \(printed.output)")
        }
        hostKeyFingerprint = String(words[1])

        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey)
        PidFile \(folder)/sshd.pid
        AuthorizedKeysFile \(folder)/authorized_keys
        StrictModes no
        UsePAM no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        AllowUsers \(NSUserName())
        Subsystem sftp internal-sftp
        ForceCommand internal-sftp -d \(rootPath)
        LogLevel DEBUG1

        """
        let configPath = folder + "/sshd_config"
        try Data(config.utf8).write(to: URL(fileURLWithPath: configPath))

        // -D — не уходить в фон, -e — журнал в stderr (он у нас в файле).
        process = LiveServerKit.launch(sshd, ["-D", "-e", "-f", configPath], logTo: logPath)
        let logPath = self.logPath
        let listening = await LiveServerKit.wait(upTo: 5) {
            LiveServerKit.text(logPath).contains("Server listening")
        }
        guard listening else {
            let said = LiveServerKit.text(logPath)
            stop()
            throw XCTSkip("sshd не поднялся: \(said.suffix(400))")
        }
    }

    var log: String { LiveServerKit.text(logPath) }

    /// Спрашивал ли кто-нибудь у сервера вход. До этой строки в журнале сервер не слышал
    /// ни имени, ни пароля, ни подписи ключом.
    var sawLoginAttempt: Bool { log.contains("userauth-request") }

    /// Дождаться, пока сервер запишет, что соединение закрыто: иначе «в журнале нет попытки
    /// входа» могло бы значить всего лишь «сервер ещё не дописал журнал».
    func waitUntilConnectionClosed() async -> Bool {
        let logPath = self.logPath
        return await LiveServerKit.wait(upTo: 5) {
            let said = LiveServerKit.text(logPath)
            return said.contains("Disconnected from") || said.contains("Received disconnect")
                || said.contains("Connection closed by")
        }
    }

    func stop() {
        LiveServerKit.stop(process)
        process = nil
        try? FileManager.default.removeItem(atPath: folder)
    }
}

final class ServerTrustLiveSFTPTests: XCTestCase {

    private var server: LocalSSHD!
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suite = "fcxl.tests.server-trust-live.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        server = try await LocalSSHD()
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        defaults?.removePersistentDomain(forName: suite)
        defaults = nil
        try await super.tearDown()
    }

    private var connection: RemoteConnection {
        RemoteConnection(proto: .sftp, host: "127.0.0.1", port: server.port,
                         username: NSUserName(), useKeyAuth: true, keyPath: server.clientKeyPath)
    }

    private func fileSystem(_ trust: ServerTrustStore) -> SFTPRemoteFileSystem {
        SFTPRemoteFileSystem(connection: connection, password: "", trust: trust)
    }

    /// Сервер, которого программа видит впервые: вместо входа — вопрос с его отпечатком.
    /// Отпечаток тот самый, что напечатал бы администратор сервера у себя, и входа у сервера
    /// никто не просил.
    func test_незнакомому_серверу_не_называют_ни_имени_ни_ключа() async throws {
        let fs = fileSystem(ServerTrustStore(defaults: defaults))
        defer { fs.disconnect() }

        do {
            try await fs.connect()
            return XCTFail("подключились к серверу, ключ которого никто не подтверждал")
        } catch RemoteFileSystemError.serverKeyUntrusted(let challenge) {
            XCTAssertEqual(challenge.status, .unknown)
            XCTAssertEqual(challenge.fingerprint, server.hostKeyFingerprint)
            XCTAssertEqual(challenge.keyType, "ED25519")
        } catch {
            return XCTFail("ждали вопрос о ключе сервера, получили: \(error)")
        }

        XCTAssertFalse(fs.isConnected)
        let closed = await server.waitUntilConnectionClosed()
        XCTAssertTrue(closed, "сервер так и не записал, что соединение закрыто:\n\(server.log)")
        XCTAssertFalse(server.sawLoginAttempt,
                       "сервер услышал попытку входа до того, как человек подтвердил его ключ:\n\(server.log)")
    }

    /// Подтверждённый ключ: вход идёт как обычно, и файлы видны.
    func test_подтверждённому_серверу_вход_открыт() async throws {
        let trust = ServerTrustStore(defaults: defaults)
        trust.trust(server.hostKeyFingerprint, for: connection)
        let fs = fileSystem(trust)
        defer { fs.disconnect() }

        try await fs.connect()

        XCTAssertTrue(fs.isConnected)
        let names = try await fs.listDirectory(at: server.rootPath).map(\.name)
        XCTAssertEqual(names, ["probe.txt"])
        // Заодно убеждаемся, что журнал сервера вообще показывает попытку входа: без этого
        // её отсутствие в соседних тестах ничего бы не значило.
        XCTAssertTrue(server.sawLoginAttempt, server.log)
    }

    /// Сервер отвечает не тем ключом, что был подтверждён: это либо переустановка, либо
    /// перехват. Входа нет, и человеку показан новый отпечаток — как изменившийся, а не как
    /// незнакомый.
    func test_сменившему_ключ_серверу_вход_закрыт() async throws {
        let trust = ServerTrustStore(defaults: defaults)
        let stale = "SHA256:" + String(repeating: "A", count: 43)
        trust.trust(stale, for: connection)
        let fs = fileSystem(trust)
        defer { fs.disconnect() }

        do {
            try await fs.connect()
            return XCTFail("подключились к серверу с другим ключом")
        } catch RemoteFileSystemError.serverKeyUntrusted(let challenge) {
            XCTAssertEqual(challenge.status, .changed)
            XCTAssertEqual(challenge.fingerprint, server.hostKeyFingerprint)
        } catch {
            return XCTFail("ждали предупреждение о ключе сервера, получили: \(error)")
        }

        XCTAssertFalse(fs.isConnected)
        let closed = await server.waitUntilConnectionClosed()
        XCTAssertTrue(closed, "сервер так и не записал, что соединение закрыто:\n\(server.log)")
        XCTAssertFalse(server.sawLoginAttempt,
                       "сервер услышал попытку входа, хотя ключ у него не тот:\n\(server.log)")
        XCTAssertEqual(trust.trustedKey(for: connection), stale,
                       "новый ключ не запоминается сам — только по слову человека")
    }
}

// MARK: - FTPS

/// Маленький FTPS-сервер с самоподписанным сертификатом. Шифрование начинается сразу, с
/// первого байта, — так, как программа и подключается по адресу `ftps://`. Каждую полученную
/// команду сервер записывает в журнал: по нему видно, дошли ли до него имя и пароль.
private final class FakeFTPS {
    let port: UInt16
    /// Отпечаток открытого ключа сертификата в записи libcurl: «sha256//…».
    let pin: String

    private let folder: String
    private let logPath: String
    private var process: Process?

    private static let script = #"""
    import os, socket, ssl, sys, threading

    cert, key, logpath, portpath = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    lock = threading.Lock()


    def log(line):
        with lock:
            with open(logpath, "a") as f:
                f.write(line + "\n")


    def serve(raw):
        raw.settimeout(15)
        try:
            conn = ctx.wrap_socket(raw, server_side=True)
        except Exception as e:
            log("TLS-FAILED " + type(e).__name__)
            try:
                raw.close()
            except Exception:
                pass
            log("CLOSED")
            return
        log("TLS-OK")
        data_listener = None
        protected = False

        def send(text):
            conn.sendall((text + "\r\n").encode())

        try:
            send("220 fake ftps")
            buf = b""
            while True:
                while b"\r\n" not in buf:
                    chunk = conn.recv(4096)
                    if not chunk:
                        return
                    buf += chunk
                line, buf = buf.split(b"\r\n", 1)
                cmd = line.decode("utf-8", "replace")
                log(cmd)
                verb = cmd.split(" ")[0].upper()
                if verb == "USER":
                    send("331 need password")
                elif verb == "PASS":
                    send("230 ok")
                elif verb == "PBSZ":
                    send("200 ok")
                elif verb == "PROT":
                    protected = True
                    send("200 ok")
                elif verb == "PWD":
                    send('257 "/" is current')
                elif verb == "CWD":
                    send("250 ok")
                elif verb == "TYPE":
                    send("200 ok")
                elif verb == "OPTS":
                    send("200 ok")
                elif verb == "SYST":
                    send("215 UNIX Type: L8")
                elif verb == "EPSV":
                    data_listener = socket.socket()
                    data_listener.bind(("127.0.0.1", 0))
                    data_listener.listen(1)
                    data_listener.settimeout(15)
                    send("229 Entering Extended Passive Mode (|||%d|)" % data_listener.getsockname()[1])
                elif verb in ("LIST", "NLST"):
                    send("150 here it comes")
                    data, _ = data_listener.accept()
                    data.settimeout(15)
                    if protected:
                        data = ctx.wrap_socket(data, server_side=True)
                    if verb == "NLST":
                        data.sendall(b"probe.txt\r\n")
                    else:
                        data.sendall(b"-rw-r--r--   1 user group        5 Jan 01 00:00 probe.txt\r\n")
                    try:
                        data = data.unwrap()
                    except Exception:
                        pass
                    data.close()
                    data_listener.close()
                    data_listener = None
                    send("226 done")
                elif verb == "QUIT":
                    send("221 bye")
                    return
                else:
                    send("502 not implemented")
        except Exception as e:
            log("SERVER-EXC " + type(e).__name__ + " " + str(e))
        finally:
            try:
                conn.close()
            except Exception:
                pass
            log("CLOSED")


    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(8)
    with open(portpath + ".tmp", "w") as f:
        f.write(str(listener.getsockname()[1]))
    os.rename(portpath + ".tmp", portpath)
    while True:
        c, _ = listener.accept()
        log("CONNECTION")
        threading.Thread(target=serve, args=(c,), daemon=True).start()
    """#

    init() async throws {
        let python = "/usr/bin/python3", openssl = "/usr/bin/openssl"
        guard FileManager.default.isExecutableFile(atPath: python),
              FileManager.default.isExecutableFile(atPath: openssl) else {
            throw XCTSkip("на этой машине нет python3 или openssl")
        }
        folder = NSTemporaryDirectory() + "fcxl-ftps-\(UUID().uuidString)"
        logPath = folder + "/commands.log"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        let cert = folder + "/cert.pem", key = folder + "/key.pem"
        let made = TestDiskImage.run(openssl, ["req", "-x509", "-newkey", "rsa:2048", "-nodes",
                                               "-keyout", key, "-out", cert, "-days", "2",
                                               "-subj", "/CN=localhost"])
        guard made.status == 0 else {
            try? FileManager.default.removeItem(atPath: folder)
            throw XCTSkip("openssl не создал сертификат: \(made.output.suffix(300))")
        }

        // Отпечаток считаем сами и другим путём, чем программа: openssl отдаёт открытый ключ
        // сертификата, SHA-256 от его записи DER и есть то, что сверяет libcurl.
        let publicKey = TestDiskImage.run(openssl, ["x509", "-in", cert, "-pubkey", "-noout"])
        let body = publicKey.output.split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }.joined()
        guard publicKey.status == 0, let der = Data(base64Encoded: body), !der.isEmpty else {
            try? FileManager.default.removeItem(atPath: folder)
            throw XCTSkip("openssl не отдал открытый ключ сертификата")
        }
        pin = "sha256//" + Data(SHA256.hash(data: der)).base64EncodedString()

        let scriptPath = folder + "/server.py", portPath = folder + "/port"
        try Data(Self.script.utf8).write(to: URL(fileURLWithPath: scriptPath))
        // -I — чистый запуск: ни настроек, ни чужих модулей из окружения человека.
        process = LiveServerKit.launch(python, ["-I", scriptPath, cert, key, logPath, portPath],
                                       logTo: folder + "/server.err")
        let started = await LiveServerKit.wait(upTo: 10) {
            FileManager.default.fileExists(atPath: portPath)
        }
        guard started, let port = UInt16(LiveServerKit.text(portPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)) else {
            let said = LiveServerKit.text(folder + "/server.err")
            LiveServerKit.stop(process)
            try? FileManager.default.removeItem(atPath: folder)
            throw XCTSkip("FTPS-сервер не поднялся: \(said.suffix(400))")
        }
        self.port = port
    }

    /// Всё, что сервер услышал: по строке на команду.
    var log: String { LiveServerKit.text(logPath) }

    /// Дошли ли до сервера имя или пароль.
    var heardCredentials: Bool {
        log.split(separator: "\n").contains { $0.hasPrefix("USER") || $0.hasPrefix("PASS") }
    }

    /// Дождаться, пока сервер закончит со всеми начатыми соединениями: иначе «имени в журнале
    /// нет» могло бы значить «сервер ещё не дописал журнал».
    func waitUntilIdle() async -> Bool {
        let logPath = self.logPath
        return await LiveServerKit.wait(upTo: 5) {
            let lines = LiveServerKit.text(logPath).split(separator: "\n")
            let opened = lines.filter { $0 == "CONNECTION" }.count
            return opened > 0 && opened == lines.filter { $0 == "CLOSED" }.count
        }
    }

    func stop() {
        LiveServerKit.stop(process)
        process = nil
        try? FileManager.default.removeItem(atPath: folder)
    }
}

final class ServerTrustLiveFTPSTests: XCTestCase {

    private var server: FakeFTPS!
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suite = "fcxl.tests.server-trust-live.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        server = try await FakeFTPS()
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        defaults?.removePersistentDomain(forName: suite)
        defaults = nil
        try await super.tearDown()
    }

    private var connection: RemoteConnection {
        RemoteConnection(proto: .ftps, host: "127.0.0.1", port: server.port, username: "tester")
    }

    private func fileSystem(_ trust: ServerTrustStore) -> FTPRemoteFileSystem {
        FTPRemoteFileSystem(connection: connection, password: "пароль-пустышка", trust: trust)
    }

    /// Сертификат, за который никто не поручился: вместо входа — вопрос с отпечатком его
    /// ключа и причиной отказа. Имя и пароль серверу не отправлены.
    func test_серверу_с_непроверенным_сертификатом_не_называют_ни_имени_ни_пароля() async throws {
        let fs = fileSystem(ServerTrustStore(defaults: defaults))
        defer { fs.disconnect() }

        do {
            try await fs.connect()
            return XCTFail("подключились к серверу, сертификат которого никто не проверил")
        } catch RemoteFileSystemError.serverKeyUntrusted(let challenge) {
            XCTAssertEqual(challenge.status, .unknown)
            XCTAssertEqual(challenge.fingerprint, server.pin)
            XCTAssertEqual(challenge.readableReason, L("network.serverKey.reason.selfSigned"),
                           "причина как её назвал libcurl: \(challenge.reason)")
        } catch {
            return XCTFail("ждали вопрос о ключе сервера, получили: \(error)")
        }

        XCTAssertFalse(fs.isConnected)
        let idle = await server.waitUntilIdle()
        XCTAssertTrue(idle, "сервер не закончил с соединениями:\n\(server.log)")
        XCTAssertFalse(server.heardCredentials,
                       "сервер услышал имя или пароль до того, как человек подтвердил его ключ:\n\(server.log)")
    }

    /// Подтверждённый ключ: вход идёт, список приходит — и сам список тоже по защищённому
    /// каналу с тем же ключом.
    func test_подтверждённому_серверу_вход_открыт() async throws {
        let trust = ServerTrustStore(defaults: defaults)
        trust.trust(server.pin, for: connection)
        let fs = fileSystem(trust)
        defer { fs.disconnect() }

        try await fs.connect()

        XCTAssertTrue(fs.isConnected)
        let names = try await fs.listDirectory(at: "/").map(\.name)
        XCTAssertEqual(names, ["probe.txt"])
        // Заодно убеждаемся, что журнал сервера вообще показывает имя и пароль: без этого их
        // отсутствие в соседних тестах ничего бы не значило.
        XCTAssertTrue(server.heardCredentials, server.log)
    }

    /// Сервер предъявил другой ключ, чем был подтверждён: входа нет, человеку показан новый
    /// отпечаток — как изменившийся.
    func test_сменившему_ключ_серверу_не_называют_ни_имени_ни_пароля() async throws {
        let trust = ServerTrustStore(defaults: defaults)
        let stale = "sha256//" + String(repeating: "/", count: 42) + "8="
        trust.trust(stale, for: connection)
        let fs = fileSystem(trust)
        defer { fs.disconnect() }

        do {
            try await fs.connect()
            return XCTFail("подключились к серверу с другим ключом")
        } catch RemoteFileSystemError.serverKeyUntrusted(let challenge) {
            XCTAssertEqual(challenge.status, .changed)
            XCTAssertEqual(challenge.fingerprint, server.pin)
        } catch {
            return XCTFail("ждали предупреждение о ключе сервера, получили: \(error)")
        }

        XCTAssertFalse(fs.isConnected)
        let idle = await server.waitUntilIdle()
        XCTAssertTrue(idle, "сервер не закончил с соединениями:\n\(server.log)")
        XCTAssertFalse(server.heardCredentials,
                       "сервер услышал имя или пароль, хотя ключ у него не тот:\n\(server.log)")
        XCTAssertEqual(trust.trustedKey(for: connection), stale,
                       "новый ключ не запоминается сам — только по слову человека")
    }
}
