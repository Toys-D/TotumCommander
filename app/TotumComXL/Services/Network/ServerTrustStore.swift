import Foundation
import FCXLBridgeObjC

/// Сервер предъявил ключ, которому программа не доверяет, и подключение остановлено — до
/// того, как серверу назвали имя и пароль.
///
/// Это не ошибка сети, а вопрос к человеку: тот ли это сервер. Ответить на него может только
/// он — сверив отпечаток с тем, что дал администратор.
struct ServerKeyChallenge: Equatable {

    enum Status: Equatable {
        /// О сервере ещё ничего не известно: первое подключение либо сертификат, который не
        /// прошёл обычную проверку.
        case unknown
        /// Ключ не тот, что человек подтвердил раньше: сервер переустановили — или отвечает
        /// не он.
        case changed
    }

    let status: Status
    /// SFTP: «SHA256:…», как печатает `ssh-keygen -l`. FTPS: «sha256//…» — хеш открытого
    /// ключа сертификата. В этом виде отпечаток и запоминается.
    let fingerprint: String
    /// SFTP: «ED25519», «RSA», «ECDSA». У FTPS пусто.
    let keyType: String
    /// FTPS: чем сертификат не устроил, словами libcurl. У SFTP пусто.
    let reason: String

    init(status: Status, fingerprint: String, keyType: String = "", reason: String = "") {
        self.status = status
        self.fingerprint = fingerprint
        self.keyType = keyType
        self.reason = reason
    }

    /// Разобрать ошибку моста. Вопросом она становится, только если ядро прямо сказало, что
    /// дело в ключе, и приложило отпечаток: без него человеку нечего сверять, а незнакомое
    /// слово о ключе — не повод ни доверять, ни спрашивать.
    init?(error: Error) {
        let nsError = error as NSError
        guard CoreErrorCode.domains.contains(nsError.domain),
              let word = nsError.userInfo[FCXLServerKeyStatusKey] as? String,
              let fingerprint = nsError.userInfo[FCXLServerKeyFingerprintKey] as? String,
              !fingerprint.isEmpty else { return nil }
        switch word {
        case "unknown": status = .unknown
        case "changed": status = .changed
        default: return nil
        }
        self.fingerprint = fingerprint
        keyType = nsError.userInfo[FCXLServerKeyTypeKey] as? String ?? ""
        reason = nsError.userInfo[FCXLServerKeyReasonKey] as? String ?? ""
    }

    /// Речь о сертификате TLS, а не о ключе узла SSH. Видно по самой записи отпечатка.
    var isCertificate: Bool { fingerprint.hasPrefix("sha256//") }

    // MARK: - Слова для человека

    var title: String {
        switch status {
        case .unknown: return L("network.serverKey.unknown.title")
        case .changed: return L("network.serverKey.changed.title")
        }
    }

    /// Почему сертификат не прошёл проверку — своими словами. libcurl говорит по-английски и
    /// для инженера; чего не узнали, показываем как есть, а не прячем.
    var readableReason: String {
        let raw = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return L("network.serverKey.reason.generic") }
        let text = raw.lowercased()
        // «Самоподписанный» раньше «неизвестного центра»: у самоподписанного сертификата в
        // цепочке libcurl упоминает и то и другое.
        if text.contains("self signed") || text.contains("self-signed") {
            return L("network.serverKey.reason.selfSigned")
        }
        if text.contains("not yet valid") { return L("network.serverKey.reason.notYetValid") }
        if text.contains("expired") { return L("network.serverKey.reason.expired") }
        if text.contains("subject name") || text.contains("host name")
            || text.contains("does not match") {
            return L("network.serverKey.reason.wrongName")
        }
        if text.contains("issuer") || text.contains("unable to verify") {
            return L("network.serverKey.reason.unknownIssuer")
        }
        return raw
    }

    /// Отпечаток с подписью, двумя строками: его сверяют глазами, знак за знаком.
    private var fingerprintLines: String {
        if isCertificate { return L("network.serverKey.fingerprint.certificate", fingerprint) }
        if keyType.isEmpty { return L("network.serverKey.fingerprint.plain", fingerprint) }
        return L("network.serverKey.fingerprint.typed", keyType, fingerprint)
    }

    /// Вопрос для окна подтверждения. `server` — адрес с портом: подтверждают именно его.
    func question(server: String) -> String {
        switch status {
        case .changed:
            return L("network.serverKey.changed.question", server, fingerprintLines)
        case .unknown where isCertificate:
            return L("network.serverKey.unknown.certificateQuestion", server, readableReason,
                     fingerprintLines)
        case .unknown:
            return L("network.serverKey.unknown.question", server, fingerprintLines)
        }
    }

    /// Что сказать там, где спросить некого: вкладка подключается сама, передача идёт в
    /// очереди. Отпечаток виден и здесь — и первое знакомство не спутать с подменой.
    var refusal: String {
        switch status {
        case .unknown: return L("network.serverKey.unknown.error", fingerprint)
        case .changed: return L("network.serverKey.changed.error", fingerprint)
        }
    }
}

/// Память о серверах, чей ключ человек подтвердил.
///
/// Подтверждают сервер — узел и порт, — а не запись в списке подключений: два сохранённых
/// подключения к одному адресу спрашивают один раз. `~/.ssh/known_hosts` не читается и не
/// пишется: это чужой файл со своим форматом, и доверие, выданное в терминале, выдано не этой
/// программе.
final class ServerTrustStore: @unchecked Sendable {

    static let shared = ServerTrustStore()

    private static let storageKey = "fcxl.trustedServerKeys"

    private let defaults: UserDefaults
    /// Читают с очередей подключений, пишут с главного потока.
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Под каким именем сервер помнится. nil — сверять у этого протокола нечего (обычный
    /// FTP, SMB, WebDAV, rclone), и память для него не заводится: записанный туда «ключ»
    /// создавал бы видимость проверки, которой нет.
    static func identity(of connection: RemoteConnection) -> String? {
        guard connection.proto == .sftp || connection.proto == .ftps else { return nil }
        let host = connection.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return nil }
        return "\(connection.proto.rawValue)://\(host):\(connection.effectivePort)"
    }

    /// Адрес сервера для вопроса о ключе: узел и порт, всегда оба.
    static func address(of connection: RemoteConnection) -> String {
        "\(connection.host):\(connection.effectivePort)"
    }

    /// Отпечаток, подтверждённый для этого сервера. Пусто — сервер ещё не знаком.
    func trustedKey(for connection: RemoteConnection) -> String {
        guard let identity = Self.identity(of: connection) else { return "" }
        lock.lock(); defer { lock.unlock() }
        return stored()[identity] ?? ""
    }

    /// Запомнить, что человек подтвердил этот ключ. Прежний ключ сервера заменяется.
    func trust(_ fingerprint: String, for connection: RemoteConnection) {
        guard !fingerprint.isEmpty, let identity = Self.identity(of: connection) else { return }
        lock.lock(); defer { lock.unlock() }
        var keys = stored()
        keys[identity] = fingerprint
        defaults.set(keys, forKey: Self.storageKey)
    }

    private func stored() -> [String: String] {
        defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }
}
