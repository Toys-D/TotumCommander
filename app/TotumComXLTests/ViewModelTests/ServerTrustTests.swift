import XCTest
import FCXLBridgeObjC
@testable import TotumComXLApp

/// Тот ли это сервер.
///
/// Программа не сверяла ни ключ узла SFTP, ни сертификат FTPS: тот, кто встал между
/// человеком и сервером, получал имя, пароль и все файлы. Теперь серверу, которого программа
/// не знает, не говорят ничего, пока человек не подтвердит его ключ, — а здесь проверено
/// всё, что решается без сети: память о подтверждённых ключах, разбор ответа ядра и то,
/// как на этот ответ смотрят повторы передачи и вопрос о пароле.
final class ServerTrustTests: XCTestCase {

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Свои настройки на каждый тест: настоящих подтверждённых ключей человека не касаемся.
        suite = "fcxl.tests.server-trust.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func store() -> ServerTrustStore { ServerTrustStore(defaults: defaults) }

    private func server(_ proto: RemoteProtocol = .sftp, host: String = "files.example.org",
                        port: UInt16 = 0) -> RemoteConnection {
        RemoteConnection(proto: proto, host: host, port: port)
    }

    private let key = "SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8"
    private let otherKey = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    // MARK: - Память о подтверждённых ключах

    func test_о_незнакомом_сервере_ничего_не_известно() {
        XCTAssertEqual(store().trustedKey(for: server()), "")
    }

    func test_подтверждённый_ключ_помнится() {
        let trust = store()
        trust.trust(key, for: server())
        XCTAssertEqual(trust.trustedKey(for: server()), key)
    }

    /// Подтверждение не на один запуск: иначе вопрос звучал бы при каждом подключении и
    /// человек привык бы соглашаться не глядя.
    func test_подтверждение_переживает_перезапуск() {
        store().trust(key, for: server())
        XCTAssertEqual(store().trustedKey(for: server()), key)
    }

    /// Подтверждают сервер, а не запись в списке подключений: два сохранённых подключения к
    /// одному адресу спрашивают один раз.
    func test_два_подключения_к_одному_адресу_один_сервер() {
        let trust = store()
        trust.trust(key, for: server())
        let another = RemoteConnection(label: "тот же сервер", proto: .sftp,
                                       host: "files.example.org", username: "другой")
        XCTAssertEqual(trust.trustedKey(for: another), key)
    }

    func test_порт_по_умолчанию_и_названный_явно_один_сервер() {
        let trust = store()
        trust.trust(key, for: server(port: 0))
        XCTAssertEqual(trust.trustedKey(for: server(port: 22)), key)
    }

    /// На другом порту того же узла отвечает другая служба со своим ключом.
    func test_другой_порт_другой_сервер() {
        let trust = store()
        trust.trust(key, for: server(port: 22))
        XCTAssertEqual(trust.trustedKey(for: server(port: 2222)), "")
    }

    func test_регистр_имени_узла_не_важен() {
        let trust = store()
        trust.trust(key, for: server(host: "Files.Example.ORG"))
        XCTAssertEqual(trust.trustedKey(for: server(host: "files.example.org")), key)
    }

    /// У SFTP и FTPS разные ключи и разная запись отпечатка — путать их нельзя.
    func test_sftp_и_ftps_помнятся_раздельно() {
        let trust = store()
        trust.trust(key, for: server(.sftp, port: 990))
        XCTAssertEqual(trust.trustedKey(for: server(.ftps, port: 990)), "")
    }

    func test_новый_ключ_заменяет_прежний() {
        let trust = store()
        trust.trust(key, for: server())
        trust.trust(otherKey, for: server())
        XCTAssertEqual(trust.trustedKey(for: server()), otherKey)
    }

    func test_ключ_одного_сервера_не_годится_другому() {
        let trust = store()
        trust.trust(key, for: server(host: "one.example.org"))
        XCTAssertEqual(trust.trustedKey(for: server(host: "two.example.org")), "")
    }

    /// Там, где сверять нечего (обычный FTP, SMB), память не заводится: записанный туда
    /// «ключ» создавал бы видимость проверки, которой нет.
    func test_где_сверять_нечего_ничего_не_помнится() {
        let trust = store()
        for proto in [RemoteProtocol.ftp, .smb, .webdav, .rclone] {
            trust.trust(key, for: server(proto))
            XCTAssertEqual(trust.trustedKey(for: server(proto)), "", "\(proto)")
        }
    }

    func test_пустой_отпечаток_не_становится_доверием() {
        let trust = store()
        trust.trust(key, for: server())
        trust.trust("", for: server())
        XCTAssertEqual(trust.trustedKey(for: server()), key, "пустая строка — не ключ")
    }

    // MARK: - Разбор ответа ядра

    private func coreError(_ userInfo: [String: Any], code: CoreErrorCode = .networkError) -> NSError {
        var info = userInfo
        info[NSLocalizedDescriptionKey] = "SSH host key is not trusted yet"
        return NSError(domain: "com.fcxl.network", code: code.rawValue, userInfo: info)
    }

    func test_незнакомый_ключ_становится_вопросом_а_не_ошибкой_сети() {
        let error = coreError([FCXLServerKeyStatusKey: "unknown",
                               FCXLServerKeyFingerprintKey: key,
                               FCXLServerKeyTypeKey: "ED25519"])

        guard case .serverKeyUntrusted(let challenge) = RemoteLogin.error(from: error) else {
            return XCTFail("ждали вопрос о ключе, получили \(RemoteLogin.error(from: error))")
        }
        XCTAssertEqual(challenge, ServerKeyChallenge(status: .unknown, fingerprint: key,
                                                     keyType: "ED25519"))
    }

    func test_сменившийся_ключ_отличается_от_незнакомого() {
        let error = coreError([FCXLServerKeyStatusKey: "changed",
                               FCXLServerKeyFingerprintKey: "sha256//abc=",
                               FCXLServerKeyReasonKey: ""])

        guard case .serverKeyUntrusted(let challenge) = RemoteLogin.error(from: error) else {
            return XCTFail("ждали предупреждение о ключе, получили \(RemoteLogin.error(from: error))")
        }
        XCTAssertEqual(challenge.status, .changed)
        XCTAssertEqual(challenge.fingerprint, "sha256//abc=")
    }

    func test_причина_отказа_сертификата_доходит_до_вопроса() {
        let error = coreError([FCXLServerKeyStatusKey: "unknown",
                               FCXLServerKeyFingerprintKey: "sha256//abc=",
                               FCXLServerKeyReasonKey: "SSL certificate problem: self signed certificate"])

        guard case .serverKeyUntrusted(let challenge) = RemoteLogin.error(from: error) else {
            return XCTFail("ждали вопрос о ключе")
        }
        XCTAssertEqual(challenge.reason, "SSL certificate problem: self signed certificate")
    }

    /// Вопрос без отпечатка задать нельзя: человеку нечего сверять. Такая ошибка остаётся
    /// обычным отказом сети.
    func test_без_отпечатка_вопроса_нет() {
        let error = coreError([FCXLServerKeyStatusKey: "unknown", FCXLServerKeyFingerprintKey: ""])
        guard case .connectionFailed = RemoteLogin.error(from: error) else {
            return XCTFail("ждали отказ сети, получили \(RemoteLogin.error(from: error))")
        }
    }

    func test_незнакомое_слово_о_ключе_не_становится_доверием_или_вопросом() {
        let error = coreError([FCXLServerKeyStatusKey: "trusted", FCXLServerKeyFingerprintKey: key])
        guard case .connectionFailed = RemoteLogin.error(from: error) else {
            return XCTFail("ждали отказ сети, получили \(RemoteLogin.error(from: error))")
        }
    }

    /// Закрепляющие: прежние дороги разбора не задеты.
    func test_обычный_отказ_сети_остаётся_отказом_сети() {
        guard case .connectionFailed = RemoteLogin.error(from: coreError([:])) else {
            return XCTFail("ждали отказ сети")
        }
    }

    func test_отказ_во_входе_остаётся_отказом_во_входе() {
        guard case .loginRefused = RemoteLogin.error(from: coreError([:], code: .permissionDenied)) else {
            return XCTFail("ждали отказ во входе")
        }
    }

    // MARK: - Что с таким отказом делают дальше

    private var challenge: ServerKeyChallenge {
        ServerKeyChallenge(status: .unknown, fingerprint: key, keyType: "ED25519")
    }

    /// Повтор ничего не изменит: сервер предъявит тот же ключ, а человек его так и не видел.
    func test_неподтверждённый_сервер_не_повод_повторять_передачу() {
        XCTAssertFalse(ResumableTransfer.worthRetrying(
            RemoteFileSystemError.serverKeyUntrusted(challenge)))
    }

    /// Закрепляющий: до имени и пароля дело не дошло — спрашивать их заново не о чем.
    func test_о_ключе_сервера_пароль_не_спрашивают() {
        XCTAssertFalse(RemoteLogin.asksAgain(
            after: RemoteFileSystemError.serverKeyUntrusted(challenge)))
    }

    /// Закрепляющий: молча переподключаться к неподтверждённому серверу панель не станет.
    @MainActor
    func test_неподтверждённый_сервер_не_повод_переподключаться_молча() {
        XCTAssertFalse(PanelViewModel.worthReconnecting(
            RemoteFileSystemError.serverKeyUntrusted(challenge)))
    }

    // MARK: - Слова для человека

    /// Там, где спросить некого (тихое подключение вкладки, передача в очереди), человек
    /// обязан прочитать, что случилось и какой ключ предъявлен, — и не спутать первое
    /// знакомство с подменой.
    func test_незнакомый_и_сменившийся_ключ_называются_по_разному_и_с_отпечатком() {
        let unknown = RemoteFileSystemError.serverKeyUntrusted(
            ServerKeyChallenge(status: .unknown, fingerprint: key)).localizedDescription
        let changed = RemoteFileSystemError.serverKeyUntrusted(
            ServerKeyChallenge(status: .changed, fingerprint: key)).localizedDescription

        XCTAssertNotEqual(unknown, changed)
        XCTAssertTrue(unknown.contains(key), unknown)
        XCTAssertTrue(changed.contains(key), changed)
    }

    func test_в_вопросе_названы_сервер_отпечаток_и_вид_ключа() {
        let text = challenge.question(server: "files.example.org:2222")
        XCTAssertTrue(text.contains("files.example.org:2222"), text)
        XCTAssertTrue(text.contains(key), text)
        XCTAssertTrue(text.contains("ED25519"), text)
    }

    func test_вопрос_о_сменившемся_ключе_не_тот_что_о_незнакомом() {
        let changed = ServerKeyChallenge(status: .changed, fingerprint: key, keyType: "ED25519")
        XCTAssertNotEqual(changed.question(server: "s"), challenge.question(server: "s"))
        XCTAssertNotEqual(changed.title, challenge.title)
        XCTAssertTrue(changed.question(server: "s").contains(key))
    }

    /// Причину отказа сертификата libcurl называет по-английски и для инженера. Человеку —
    /// своими словами; чего не узнали, показываем как есть, а не прячем.
    func test_причина_отказа_сертификата_названа_по_человечески() {
        func reason(_ raw: String) -> String {
            ServerKeyChallenge(status: .unknown, fingerprint: "sha256//abc=", reason: raw).readableReason
        }
        XCTAssertEqual(reason("SSL certificate problem: self signed certificate"),
                       L("network.serverKey.reason.selfSigned"))
        XCTAssertEqual(reason("SSL certificate problem: self-signed certificate in certificate chain"),
                       L("network.serverKey.reason.selfSigned"))
        XCTAssertEqual(reason("SSL certificate problem: certificate has expired"),
                       L("network.serverKey.reason.expired"))
        XCTAssertEqual(reason("SSL: no alternative certificate subject name matches target host name '127.0.0.1'"),
                       L("network.serverKey.reason.wrongName"))
        XCTAssertEqual(reason("SSL certificate problem: unable to get local issuer certificate"),
                       L("network.serverKey.reason.unknownIssuer"))
        XCTAssertEqual(reason("что-то совсем новое"), "что-то совсем новое")
        XCTAssertEqual(reason(""), L("network.serverKey.reason.generic"))
    }

    func test_причина_попадает_в_вопрос_о_сертификате() {
        let ftps = ServerKeyChallenge(status: .unknown, fingerprint: "sha256//abc=",
                                      reason: "SSL certificate problem: self signed certificate")
        let text = ftps.question(server: "ftp.example.org:990")
        XCTAssertTrue(text.contains(L("network.serverKey.reason.selfSigned")), text)
        XCTAssertTrue(text.contains("sha256//abc="), text)
    }

    // MARK: - Окно с вопросом

    /// О незнакомом сервере спрашивают как обо всём в программе: «Отмена» слева, согласие
    /// справа, и по Enter — согласие.
    func test_о_незнакомом_сервере_спрашивают_как_обычно() {
        let config = DialogService.serverTrustDialog(for: challenge,
                                                     server: "files.example.org:2222")

        XCTAssertEqual(config.title, challenge.title)
        XCTAssertEqual(config.message, challenge.question(server: "files.example.org:2222"))
        XCTAssertEqual(config.buttons.map(\.title),
                       [L("button.cancel"), L("network.serverKey.trust")])
        XCTAssertEqual(config.buttons.map(\.kind), [.normal, .primary])
    }

    /// Ключ сменился — так же выглядит и перехват подключения. Кнопки стоят на тех же
    /// местах, но по Enter срабатывает «Отмена»: согласиться можно только нарочно, а не
    /// привычным нажатием.
    func test_о_сменившемся_ключе_по_Enter_отказ() {
        let changed = ServerKeyChallenge(status: .changed, fingerprint: key, keyType: "ED25519")
        let config = DialogService.serverTrustDialog(for: changed,
                                                     server: "files.example.org:2222")

        XCTAssertEqual(config.title, changed.title)
        XCTAssertEqual(config.message, changed.question(server: "files.example.org:2222"))
        XCTAssertEqual(config.buttons.map(\.title),
                       [L("button.cancel"), L("network.serverKey.trustNew")])
        XCTAssertEqual(config.buttons.map(\.kind), [.primary, .normal])
    }
}
