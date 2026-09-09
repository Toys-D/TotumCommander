import AppKit
import Foundation

/// Supported remote connection protocols.
enum RemoteProtocol: String, Codable, CaseIterable, Identifiable {
    case ftp
    case ftps
    case sftp
    case webdav
    case webdavs
    case smb
    /// S3-совместимое хранилище: Amazon S3, MinIO, Backblaze B2, Cloudflare R2.
    /// Протокол один на всех, различаются только адрес и способ адресации бакета.
    case s3
    /// Мост к rclone: одно имя протокола на семь десятков хранилищ — Google Drive,
    /// Dropbox, OneDrive, Яндекс.Диск и прочие. Что именно за ним стоит, знает сам rclone.
    case rclone

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ftp:     return "FTP"
        case .ftps:    return "FTPS"
        case .sftp:    return "SFTP"
        case .webdav:  return "WebDAV"
        case .webdavs: return "WebDAV (HTTPS)"
        case .smb:     return "SMB"
        case .s3:      return "S3"
        case .rclone:  return "rclone"
        }
    }

    var defaultPort: UInt16 {
        switch self {
        case .ftp:     return 21
        case .ftps:    return 990
        case .sftp:    return 22
        case .webdav:  return 80
        case .webdavs: return 443
        case .smb:     return 445
        case .s3:      return 443
        // Порта у него нет: адрес хранилища знает сам rclone.
        case .rclone:  return 0
        }
    }

    var iconName: String {
        switch self {
        case .ftp, .ftps: return "arrow.up.arrow.down.circle"
        case .sftp:       return "lock.shield"
        case .webdav, .webdavs: return "globe"
        case .smb:        return "network"
        case .s3:         return "cloud"
        case .rclone:     return "cloud.fill"
        }
    }
}

/// Saved remote connection bookmark. Credentials (password) stored separately in Keychain.
struct RemoteConnection: Identifiable, Codable, Hashable {
    var id: UUID
    var label: String
    var proto: RemoteProtocol
    var host: String
    var port: UInt16
    var username: String
    var initialPath: String

    // SFTP-specific
    var useKeyAuth: Bool
    var keyPath: String

    // FTP-specific
    var passiveMode: Bool

    // S3-specific
    /// Имя бакета — корень такого подключения.
    var s3Bucket: String
    /// Область хранения: участвует в подписи запроса, а не только в адресе.
    var s3Region: String
    /// Адресация бакета: путём (`сервер/бакет/ключ`) или именем узла (`бакет.сервер/ключ`).
    /// MinIO обычно первое, Amazon и R2 — второе; по адресу это не определить.
    var s3UsePathStyle: Bool
    /// HTTPS. Выключается ради MinIO, поднятого «на попробовать» без сертификата.
    var s3UsesTLS: Bool

    // rclone-specific
    /// Имя хранилища в настройке rclone — то самое, что человек дал ему при `rclone config`.
    /// Ключи и пароли к нему лежат там же, у rclone, и нас не касаются.
    var rcloneRemote: String
    /// Какая это служба: «drive», «dropbox», «onedrive»… Нужно, чтобы показывать человеку
    /// «Google Drive» с его значком, а не слово «rclone», которое ему ничего не говорит.
    /// Пусто у подключений, заведённых через сам rclone.
    var cloudService: String

    init(
        id: UUID = UUID(),
        label: String = "",
        proto: RemoteProtocol = .ftp,
        host: String = "",
        port: UInt16 = 0,
        username: String = "",
        initialPath: String = "/",
        useKeyAuth: Bool = false,
        keyPath: String = "",
        passiveMode: Bool = true,
        s3Bucket: String = "",
        s3Region: String = "us-east-1",
        s3UsePathStyle: Bool = false,
        s3UsesTLS: Bool = true,
        rcloneRemote: String = "",
        cloudService: String = ""
    ) {
        self.id = id
        self.label = label
        self.proto = proto
        self.host = host
        self.port = port
        self.username = username
        self.initialPath = initialPath
        self.useKeyAuth = useKeyAuth
        self.keyPath = keyPath
        self.passiveMode = passiveMode
        self.s3Bucket = s3Bucket
        self.s3Region = s3Region
        self.s3UsePathStyle = s3UsePathStyle
        self.s3UsesTLS = s3UsesTLS
        self.rcloneRemote = rcloneRemote
        self.cloudService = cloudService
    }

    /// Закладки, записанные до появления S3, читаются как были: новых полей в них нет.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UUID.self, forKey: .id)
        label = try box.decode(String.self, forKey: .label)
        proto = try box.decode(RemoteProtocol.self, forKey: .proto)
        host = try box.decode(String.self, forKey: .host)
        port = try box.decode(UInt16.self, forKey: .port)
        username = try box.decode(String.self, forKey: .username)
        initialPath = try box.decode(String.self, forKey: .initialPath)
        useKeyAuth = try box.decodeIfPresent(Bool.self, forKey: .useKeyAuth) ?? false
        keyPath = try box.decodeIfPresent(String.self, forKey: .keyPath) ?? ""
        passiveMode = try box.decodeIfPresent(Bool.self, forKey: .passiveMode) ?? true
        s3Bucket = try box.decodeIfPresent(String.self, forKey: .s3Bucket) ?? ""
        s3Region = try box.decodeIfPresent(String.self, forKey: .s3Region) ?? "us-east-1"
        s3UsePathStyle = try box.decodeIfPresent(Bool.self, forKey: .s3UsePathStyle) ?? false
        s3UsesTLS = try box.decodeIfPresent(Bool.self, forKey: .s3UsesTLS) ?? true
        rcloneRemote = try box.decodeIfPresent(String.self, forKey: .rcloneRemote) ?? ""
        cloudService = try box.decodeIfPresent(String.self, forKey: .cloudService) ?? ""
    }

    /// Годится ли строка в имя хоста для адреса.
    ///
    /// Пробел внутри хоста не даёт собрать URL — `URL(string:)` отвечает nil, и раньше
    /// программа падала на первом же обращении к WebDAV. Проверка та же, что и сама сборка
    /// адреса, поэтому разойтись с ней не может (кириллицу Foundation кодирует сама).
    static func isUsableHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              !trimmed.contains("/") else { return false }
        return URL(string: "https://\(trimmed):1")?.host != nil
    }

    /// Effective port (uses protocol default if 0).
    var effectivePort: UInt16 {
        port > 0 ? port : proto.defaultPort
    }

    /// Display string for UI: "user@host:port" or "host:port".
    var displayAddress: String {
        // У rclone адреса нет — вместо него имя хранилища из его настройки. Пустая строка
        // здесь означала бы подключение без опознавательных знаков в общем списке.
        if proto == .rclone { return rcloneRemote.isEmpty ? "—" : rcloneRemote + ":" }
        let portStr = port > 0 && port != proto.defaultPort ? ":\(port)" : ""
        if username.isEmpty {
            return "\(host)\(portStr)"
        }
        return "\(username)@\(host)\(portStr)"
    }

    /// Чем это подключение называть в списке: «Google Drive», а не «rclone». Человек
    /// выбирал службу, а не способ, которым мы с ней разговариваем.
    var kindTitle: String {
        if !cloudService.isEmpty,
           let service = RcloneCloudService.popular.first(where: { $0.type == cloudService }) {
            return service.title
        }
        return proto.displayName
    }

    /// Логотип службы, если это облако.
    var kindLogo: NSImage? {
        guard !cloudService.isEmpty,
              let service = RcloneCloudService.popular.first(where: { $0.type == cloudService })
        else { return nil }
        return service.logoImage
    }

    /// Значок службы — тот же, что человек видел, когда выбирал её.
    var kindIcon: String {
        if !cloudService.isEmpty,
           let service = RcloneCloudService.popular.first(where: { $0.type == cloudService }) {
            return service.icon
        }
        return proto.iconName
    }

    /// Full display: "Label (FTP: user@host)" or "FTP: user@host".
    var displayTitle: String {
        let addr = "\(kindTitle): \(displayAddress)"
        if label.isEmpty { return addr }
        return "\(label) (\(addr))"
    }
}
