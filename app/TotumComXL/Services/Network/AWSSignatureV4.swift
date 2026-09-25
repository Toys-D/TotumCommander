import CryptoKit
import Foundation

/// Подпись запросов к S3 — AWS Signature Version 4.
///
/// Своя, а не из чужого пакета: официальный SDK и Soto тянут за собой SwiftNIO с
/// AsyncHTTPClient, а в этой программе внешних зависимостей ровно одна (терминал), и
/// сетевой WebDAV уже написан на голом URLSession. Подпись — сотня строк арифметики над
/// строками, зато без чужого рантайма в процессе файлового менеджера.
///
/// Проверяется официальными векторами AWS из документации — см. AWSSignatureV4Tests.
enum AWSSignatureV4 {

    /// Что подписываем: заголовки и тело запроса.
    struct Request {
        var method: String
        var url: URL
        var headers: [String: String]
        /// SHA-256 тела в шестнадцатеричном виде, или `UNSIGNED-PAYLOAD`.
        var payloadHash: String
        var date: Date
        /// Готовый путь для подписи, если он известен точнее, чем `url.path`.
        ///
        /// Ключ S3 — произвольная строка, и `/` внутри неё не разделитель. Разбирая
        /// путь обратно из URL, Foundation раскодирует проценты и ключ вида `a%2Fb`
        /// распадается на два сегмента — подпись выходит не та, а сервер отвечает
        /// «не совпало» без объяснений. Кто знает сырой ключ, тот и считает путь.
        var canonicalURI: String?
    }

    struct Credentials {
        var accessKeyID: String
        var secretAccessKey: String
        var region: String
        var service: String

        init(accessKeyID: String, secretAccessKey: String,
             region: String = "us-east-1", service: String = "s3") {
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
            self.region = region
            self.service = service
        }
    }

    /// Тело не читается ради хеша: файл на гигабайт пришлось бы прочесть дважды, а S3
    /// принимает подпись без хеша тела — соединение всё равно защищено TLS.
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    /// Хеш пустого тела — его требуют запросы без содержимого (GET, HEAD, DELETE).
    static let emptyPayloadHash =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    // MARK: - Главное

    /// Заголовки, которые нужно добавить к запросу: `Authorization`, дата и хеш тела.
    static func signedHeaders(for request: Request, with credentials: Credentials)
    -> [String: String] {
        var headers = request.headers
        headers["x-amz-date"] = amzDate(request.date)
        headers["x-amz-content-sha256"] = request.payloadHash
        if headers["host"] == nil, let host = request.url.host {
            headers["host"] = request.url.port.map { "\(host):\($0)" } ?? host
        }

        let canonical = canonicalRequest(method: request.method, url: request.url,
                                         headers: headers, payloadHash: request.payloadHash,
                                         canonicalURIOverride: request.canonicalURI)
        let scope = credentialScope(date: request.date, credentials: credentials)
        let toSign = stringToSign(date: request.date, scope: scope, canonicalRequest: canonical)
        let signature = sign(stringToSign: toSign, date: request.date, credentials: credentials)

        let signedList = signedHeaderNames(headers).joined(separator: ";")
        headers["Authorization"] = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedList), "
            + "Signature=\(signature)"
        return headers
    }

    // MARK: - Составные части (открыты для проверки векторами)

    /// Канонический запрос — то, из чего считается подпись. Порядок и написание здесь
    /// значат всё: лишний пробел или незакодированный символ дают чужую подпись и отказ
    /// сервера без объяснений.
    static func canonicalRequest(method: String, url: URL,
                                 headers: [String: String], payloadHash: String,
                                 canonicalURIOverride: String? = nil) -> String {
        let names = signedHeaderNames(headers)
        let canonicalHeaders = names.map { name -> String in
            let value = headers.first { $0.key.lowercased() == name }?.value ?? ""
            return name + ":" + value.trimmingCharacters(in: .whitespaces) + "\n"
        }.joined()

        return [
            method,
            canonicalURIOverride ?? canonicalURI(url),
            canonicalQuery(url),
            canonicalHeaders,
            names.joined(separator: ";"),
            payloadHash,
        ].joined(separator: "\n")
    }

    /// Путь запроса, закодированный по правилам AWS: каждый сегмент отдельно, слэши между
    /// ними остаются слэшами. Для S3 путь кодируется ОДИН раз (в остальных службах — два).
    static func canonicalURI(_ url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        let encoded = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0), encodeSlash: true) }
            .joined(separator: "/")
        return encoded.isEmpty ? "/" : encoded
    }

    /// Путь запроса из СЫРЫХ сегментов: каждый кодируется отдельно, слэши между ними
    /// остаются слэшами. Это то же, что делает `canonicalURI(_:)`, но исходником берётся
    /// не разобранный URL, а сам ключ — единственный способ не потерять символы,
    /// которые Foundation по дороге раскодирует.
    static func canonicalURI(segments: [String]) -> String {
        let encoded = segments.map { encode($0, encodeSlash: true) }.joined(separator: "/")
        return "/" + encoded
    }

    /// Параметры запроса: отсортированы по имени, значения закодированы.
    static func canonicalQuery(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              !items.isEmpty else { return "" }
        var pairs: [(String, String)] = []
        for item in items {
            let name = encode(item.name, encodeSlash: true)
            let value = encode(item.value ?? "", encodeSlash: true)
            pairs.append((name, value))
        }
        pairs.sort { left, right in
            left.0 == right.0 ? left.1 < right.1 : left.0 < right.0
        }
        return pairs.map { name, value in name + "=" + value }.joined(separator: "&")
    }

    static func stringToSign(date: Date, scope: String, canonicalRequest: String) -> String {
        [
            "AWS4-HMAC-SHA256",
            amzDate(date),
            scope,
            hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")
    }

    static func credentialScope(date: Date, credentials: Credentials) -> String {
        "\(dayStamp(date))/\(credentials.region)/\(credentials.service)/aws4_request"
    }

    /// Ключ подписи выводится по цепочке: дата → область → служба → «aws4_request».
    static func signingKey(date: Date, credentials: Credentials) -> SymmetricKey {
        let start = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        let dateKey = hmac(Data(dayStamp(date).utf8), key: start)
        let regionKey = hmac(Data(credentials.region.utf8), key: SymmetricKey(data: dateKey))
        let serviceKey = hmac(Data(credentials.service.utf8), key: SymmetricKey(data: regionKey))
        return SymmetricKey(data: hmac(Data("aws4_request".utf8),
                                       key: SymmetricKey(data: serviceKey)))
    }

    static func sign(stringToSign: String, date: Date, credentials: Credentials) -> String {
        let key = signingKey(date: date, credentials: credentials)
        return hex(hmac(Data(stringToSign.utf8), key: key))
    }

    // MARK: - Мелочи

    /// Имена подписываемых заголовков — в нижнем регистре и по алфавиту.
    private static func signedHeaderNames(_ headers: [String: String]) -> [String] {
        headers.keys.map { $0.lowercased() }.sorted()
    }

    /// Кодирование по RFC 3986: незарезервированными остаются только буквы, цифры и `-._~`.
    /// `URLComponents` кодирует иначе (оставляет, например, `+` и `=`), и подпись расходится.
    static func encode(_ value: String, encodeSlash: Bool) -> String {
        var out = ""
        for byte in Array(value.utf8) {
            let char = Character(UnicodeScalar(byte))
            if (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57) || char == "-" || char == "." || char == "_"
                || char == "~" {
                out.append(char)
            } else if char == "/" && !encodeSlash {
                out.append(char)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func amzDate(_ date: Date) -> String { formatter(.amz).string(from: date) }
    static func dayStamp(_ date: Date) -> String { formatter(.day).string(from: date) }

    private enum Stamp { case amz, day }

    private static func formatter(_ kind: Stamp) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        // Календарь задаётся явно: у человека с буддийским или японским календарём в
        // системе запросы уходили бы 2569 годом, и сервер отвечал бы отказом всегда.
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = kind == .amz ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd"
        return f
    }

    private static func hmac(_ data: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Хеш тела, когда оно небольшое и лежит в памяти.
    static func payloadHash(_ data: Data) -> String {
        data.isEmpty ? emptyPayloadHash : hex(SHA256.hash(data: data))
    }
}
