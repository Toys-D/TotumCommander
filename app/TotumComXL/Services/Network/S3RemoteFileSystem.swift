import CryptoKit
import Foundation

/// S3-совместимое хранилище как удалённый диск: Amazon S3, MinIO, Backblaze B2,
/// Cloudflare R2 — протокол один, различаются только адрес и способ адресации бакета.
///
/// Чистый Swift на URLSession, как WebDAV: официальный SDK и Soto притащили бы SwiftNIO
/// с собственным рантайком ради десятка запросов, которые здесь и нужны.
///
/// Главная особенность S3 — в нём НЕТ каталогов. Есть плоский список ключей вида
/// `папка/подпапка/файл.txt`, а «папки» получаются, когда просишь сервер свернуть всё
/// после ближайшего слэша (`delimiter=/`): такие свёртки приходят отдельным списком
/// CommonPrefixes и показываются здесь папками. Пустая папка существует только как
/// нулевой объект с ключом, оканчивающимся слэшем, — его и создаём.
final class S3RemoteFileSystem: RemoteFileSystemProtocol {

    private let connection: RemoteConnection
    private let secretKey: String
    private var session: URLSession?
    private(set) var isConnected = false

    var protocolDisplayName: String { "S3" }

    /// Корень — сам бакет. Путь внутри программы выглядит как «/папка/файл», а ключом
    /// объекта становится то же самое без ведущего слэша.
    var rootPath: String { "/" }

    var supportsResume: Bool { true }

    /// «Папка» в S3 — это общее начало ключей, и сносится она удалением по этому началу,
    /// пачками до тысячи имён за раз. Обходить её как дерево незачем.
    var deletesTreesItself: Bool { true }

    /// Незавершённая многочастная отправка лежит на сервере со всеми принятыми частями —
    /// черновик под именем «…part» здесь не нужен, а переименование в конце обошлось бы
    /// в копию всего объекта на стороне хранилища.
    var uploadResumesItself: Bool { true }

    init(connection: RemoteConnection, password: String) {
        self.connection = connection
        // Ключи вставляют из буфера, и вместе с ними приезжает невидимое: пробел, табуляция,
        // перевод строки. В подписи такой символ значим — сервер отвечает «не совпало» и
        // молчит о причине, а человек видит верный на вид ключ и ищет ошибку где угодно,
        // только не там. В ключах S3 пробельных символов не бывает, поэтому режем без потерь.
        self.secretKey = password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Адреса

    private var credentials: AWSSignatureV4.Credentials {
        AWSSignatureV4.Credentials(accessKeyID: connection.username
                                       .trimmingCharacters(in: .whitespacesAndNewlines),
                                   secretAccessKey: secretKey,
                                   region: connection.s3Region.isEmpty
                                       ? "us-east-1" : connection.s3Region,
                                   service: "s3")
    }

    /// Адрес запроса к ключу объекта.
    ///
    /// Два способа адресации: path-style (`https://сервер/бакет/ключ`) — так работает MinIO
    /// и всё, что живёт на своём домене; virtual-host (`https://бакет.сервер/ключ`) — так
    /// требует Amazon и R2. Выбор оставлен человеку, потому что определить его по адресу
    /// нельзя: один и тот же сервер бывает настроен и так, и так.
    private func url(forKey key: String, query: [URLQueryItem] = []) -> URL? {
        makeAddress(key: key, query: query)?.url
    }

    /// Адрес запроса и путь для подписи — из одних и тех же сырых сегментов.
    ///
    /// Считать путь по разобранному URL нельзя: Foundation раскодирует проценты, и ключ
    /// `a%2Fb` распадается на два сегмента. Подпись тогда не сходится, а сервер отвечает
    /// «не совпало» и молчит о причине.
    private func makeAddress(key: String, query: [URLQueryItem] = [])
    -> (url: URL, canonicalURI: String)? {
        let scheme = connection.s3UsesTLS ? "https" : "http"
        let standardPort: UInt16 = connection.s3UsesTLS ? 443 : 80
        let port = connection.effectivePort
        let keySegments = key.isEmpty ? [] : key.components(separatedBy: "/")

        let segments: [String]
        let host: String
        if connection.s3UsePathStyle {
            host = connection.host
            segments = [connection.s3Bucket] + keySegments
        } else {
            host = connection.s3Bucket + "." + connection.host
            segments = keySegments
        }

        let canonical = AWSSignatureV4.canonicalURI(segments: segments)
        var text = scheme + "://" + host
        if port != standardPort { text += ":\(port)" }
        text += canonical
        if !query.isEmpty {
            let pairs = query.map { item in
                AWSSignatureV4.encode(item.name, encodeSlash: true) + "="
                    + AWSSignatureV4.encode(item.value ?? "", encodeSlash: true)
            }
            text += "?" + pairs.joined(separator: "&")
        }
        guard let url = URL(string: text) else { return nil }
        return (url, canonical)
    }

    /// Ключ объекта из пути панели: «/папка/файл» → «папка/файл».
    private func key(for path: String) -> String {
        var key = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if key.hasSuffix("/") { key = String(key.dropLast()) }
        return key
    }

    // MARK: - Запросы

    private func makeRequest(method: String, key: String, query: [URLQueryItem] = [],
                             body: Data? = nil, extraHeaders: [String: String] = [:],
                             payloadHash: String? = nil) throws -> URLRequest {
        guard let address = makeAddress(key: key, query: query) else {
            throw RemoteFileSystemError.protocolError("Не удалось составить адрес запроса")
        }
        let url = address.url
        var headers = extraHeaders
        let hash = payloadHash ?? (body.map(AWSSignatureV4.payloadHash)
                                   ?? AWSSignatureV4.emptyPayloadHash)
        let signed = AWSSignatureV4.signedHeaders(
            for: .init(method: method, url: url, headers: headers,
                       payloadHash: hash, date: Date(),
                       canonicalURI: address.canonicalURI),
            with: credentials)
        headers = signed

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body { request.httpBody = body }
        return request
    }

    /// Выполнить запрос и разобрать ответ сервера. Ошибки S3 приходят телом в XML —
    /// там же лежит человеческая причина отказа, и молчать о ней нельзя.
    @discardableResult
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let session else { throw RemoteFileSystemError.notConnected }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFileSystemError.protocolError("Ответ не по HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data)
        }
        return (data, http)
    }

    /// Ошибка по коду ответа и телу: S3 кладёт в XML поля Code и Message.
    static func error(status: Int, body: Data) -> RemoteFileSystemError {
        let text = String(data: body, encoding: .utf8) ?? ""
        let code = value(ofTag: "Code", in: text)
        let message = value(ofTag: "Message", in: text)
        // Разъехавшиеся часы — самая обидная из ошибок: ключи верные, а сервер отказывает.
        // Своими словами, иначе человек ищет причину в паролях.
        if code == "RequestTimeTooSkewed" {
            return .operationFailed(
                "Часы на этом компьютере разошлись с сервером больше чем на 15 минут — "
                + "подпись запроса считается просроченной")
        }
        if code == "SignatureDoesNotMatch" {
            return .authenticationFailed(
                "Подпись не сошлась. Чаще всего дело в секретном ключе: проверьте, "
                + "не потерялся ли символ при вставке и совпадает ли область (регион)")
        }
        switch status {
        case 401, 403:
            return .authenticationFailed(message.isEmpty
                ? "Ключ доступа отвергнут (\(code.isEmpty ? "403" : code))" : message)
        case 404:
            return .pathNotFound(message.isEmpty ? "Объект не найден" : message)
        default:
            let detail = message.isEmpty ? "HTTP \(status)" : "\(message) (\(status))"
            return .operationFailed(detail)
        }
    }

    /// Простейшее извлечение значения тега — на ответах S3 этого достаточно, а полный
    /// разбор XML ради двух полей ошибки был бы лишним.
    static func value(ofTag tag: String, in xml: String) -> String {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex)
        else { return "" }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    // MARK: - Подключение

    func connect() async throws {
        guard !connection.s3Bucket.isEmpty else {
            throw RemoteFileSystemError.connectionFailed("Не указан бакет")
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)

        // Пробный список из одного объекта: он же проверяет и адрес, и ключи, и права —
        // в отличие от HeadBucket, который на некоторых серверах запрещён отдельно.
        let request = try makeRequest(method: "GET", key: "", query: [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "max-keys", value: "1"),
        ])
        do {
            _ = try await perform(request)
            isConnected = true
        } catch let error as RemoteFileSystemError {
            isConnected = false
            throw error
        } catch {
            isConnected = false
            throw RemoteFileSystemError.connectionFailed(error.localizedDescription)
        }
    }

    func disconnect() {
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
    }

    // MARK: - Список

    func listDirectory(at path: String) async throws -> [FileItem] {
        let prefix = key(for: path).isEmpty ? "" : key(for: path) + "/"
        var items: [FileItem] = []
        var token: String?

        // Список приходит страницами по тысяче — папку с десятью тысячами файлов надо
        // дочитать до конца, иначе половина просто не покажется.
        repeat {
            var query = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "delimiter", value: "/"),
                URLQueryItem(name: "max-keys", value: "1000"),
                // Ключи приходят закодированными: в имени объекта бывает что угодно,
                // вплоть до символов, которые в сыром виде рвут XML.
                URLQueryItem(name: "encoding-type", value: "url"),
            ]
            if !prefix.isEmpty { query.append(URLQueryItem(name: "prefix", value: prefix)) }
            if let token { query.append(URLQueryItem(name: "continuation-token", value: token)) }

            let request = try makeRequest(method: "GET", key: "", query: query)
            let (data, _) = try await perform(request)
            let page = S3ListingParser.parse(data, prefix: prefix)
            items.append(contentsOf: page.items)
            token = page.nextToken
        } while token != nil

        return items
    }

    func createDirectory(at path: String, name: String) async throws {
        let base = key(for: path)
        let folderKey = (base.isEmpty ? name : base + "/" + name) + "/"
        // Папка в S3 — это нулевой объект с ключом, оканчивающимся слэшем. Без него пустая
        // папка нигде не покажется: показывать нечего, ключей с таким префиксом нет.
        let request = try makeRequest(method: "PUT", key: folderKey, body: Data())
        try await perform(request)
    }

    // MARK: - Удаление, переименование

    func deleteItem(at path: String, isDirectory: Bool) async throws {
        if isDirectory {
            try await deleteTree(prefix: key(for: path) + "/")
        } else {
            let request = try makeRequest(method: "DELETE", key: key(for: path))
            try await perform(request)
        }
    }

    /// Папку удаляем по префиксу: настоящего каталога нет, есть ключи, начинающиеся с него.
    private func deleteTree(prefix: String) async throws {
        var token: String?
        repeat {
            var query = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: prefix),
                URLQueryItem(name: "max-keys", value: "1000"),
                URLQueryItem(name: "encoding-type", value: "url"),
            ]
            if let token { query.append(URLQueryItem(name: "continuation-token", value: token)) }
            let listing = try makeRequest(method: "GET", key: "", query: query)
            let (data, _) = try await perform(listing)
            let page = S3ListingParser.parseKeys(data)
            // Пачкой, а не по одному: на папке в тысячу файлов поштучное удаление — это
            // тысяча обращений к серверу и минуты ожидания вместо секунды.
            try await deleteBatch(page.keys)
            token = page.nextToken
        } while token != nil
    }

    /// Удалить до тысячи объектов одним запросом.
    private func deleteBatch(_ keys: [String]) async throws {
        guard !keys.isEmpty else { return }
        for chunk in stride(from: 0, to: keys.count, by: 1000).map({
            Array(keys[$0..<min($0 + 1000, keys.count)])
        }) {
            var xml = "<Delete><Quiet>true</Quiet>"
            for key in chunk {
                xml += "<Object><Key>" + Self.escapeXML(key) + "</Key></Object>"
            }
            xml += "</Delete>"
            let body = Data(xml.utf8)
            // Content-MD5 обязателен именно здесь — единственная операция S3, где его до
            // сих пор требуют. Без него сервер отвечает отказом.
            let request = try makeRequest(
                method: "POST", key: "",
                query: [URLQueryItem(name: "delete", value: "")],
                body: body,
                extraHeaders: ["content-md5": Self.contentMD5(body),
                               "content-type": "application/xml"])
            let (data, _) = try await perform(request)
            try Self.checkBodyForError(data)
        }
    }

    /// Имя объекта попадает в XML — угловые скобки и амперсанды в нём обязаны быть
    /// экранированы, иначе запрос разваливается на чужом имени файла.
    static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func contentMD5(_ data: Data) -> String {
        Data(Insecure.MD5.hash(data: data)).base64EncodedString()
    }

    func rename(at path: String, to newName: String) async throws {
        let parent = parentPath(for: path)
        let destination = parent == "/" ? "/" + newName : parent + "/" + newName
        try await moveItem(from: path, to: destination)
    }

    func moveItem(from sourcePath: String, to destinationPath: String) async throws {
        try await copyObject(from: key(for: sourcePath), to: key(for: destinationPath))
        let request = try makeRequest(method: "DELETE", key: key(for: sourcePath))
        try await perform(request)
    }

    /// Копирование на стороне сервера: файл не ходит через нас.
    private func copyObject(from source: String, to destination: String) async throws {
        let sourceHeader = "/" + connection.s3Bucket + "/" + source
        let request = try makeRequest(
            method: "PUT", key: destination,
            extraHeaders: ["x-amz-copy-source": AWSSignatureV4.encode(sourceHeader,
                                                                     encodeSlash: false)])
        let (data, _) = try await perform(request)
        // Копирование — та редкая операция, где S3 отвечает «200 ОК» и кладёт отказ в тело.
        // Поверив коду ответа, мы бы удалили исходный файл после несостоявшейся копии.
        try Self.checkBodyForError(data)
    }

    /// Ошибка внутри успешного ответа: у CopyObject и CompleteMultipartUpload так бывает.
    static func checkBodyForError(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8), text.contains("<Error") else {
            return
        }
        let message = value(ofTag: "Message", in: text)
        let code = value(ofTag: "Code", in: text)
        throw RemoteFileSystemError.operationFailed(
            message.isEmpty ? (code.isEmpty ? "Сервер отказал" : code) : message)
    }

    // MARK: - Скачивание

    func download(remotePath: String, to localPath: String,
                  progress: @escaping (Int64, Int64) -> Bool) async throws {
        try await download(remotePath: remotePath, to: localPath, resumeFrom: 0,
                           progress: progress)
    }

    func download(remotePath: String, to localPath: String, resumeFrom: Int64,
                  progress: @escaping (Int64, Int64) -> Bool) async throws {
        guard let session else { throw RemoteFileSystemError.notConnected }

        var extra: [String: String] = [:]
        if resumeFrom > 0 { extra["range"] = "bytes=\(resumeFrom)-" }
        let request = try makeRequest(method: "GET", key: key(for: remotePath),
                                      extraHeaders: extra)

        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFileSystemError.protocolError("Ответ не по HTTP")
        }
        if resumeFrom > 0, http.statusCode != 206 {
            // Сервер не понял просьбу продолжить — отдал файл целиком. Дописывать в этом
            // случае нельзя: получится склейка из двух начал.
            throw RemoteFileSystemError.resumeRefused("Сервер отдал файл целиком, а не остаток")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: Data())
        }

        let total = resumeFrom + max(0, http.expectedContentLength)
        let fileManager = FileManager.default
        if resumeFrom == 0 || !fileManager.fileExists(atPath: localPath) {
            fileManager.createFile(atPath: localPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: localPath) else {
            throw RemoteFileSystemError.transferFailed("Не удалось открыть \(localPath)")
        }
        defer { try? handle.close() }
        if resumeFrom > 0 { try handle.seek(toOffset: UInt64(resumeFrom)) }

        var buffer = Data()
        buffer.reserveCapacity(Self.chunkSize)
        var done = resumeFrom

        for try await byte in stream {
            buffer.append(byte)
            if buffer.count >= Self.chunkSize {
                try handle.write(contentsOf: buffer)
                done += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if progress(done, total) { throw RemoteFileSystemError.transferCancelled }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            done += Int64(buffer.count)
        }
        _ = progress(done, total)
    }

    /// Пишем на диск порциями по мегабайту: побайтовая запись в файл на гигабайт — это
    /// миллиард системных вызовов.
    private static let chunkSize = 1 << 20

    // MARK: - Загрузка

    func upload(localPath: String, to remotePath: String,
                progress: @escaping (Int64, Int64) -> Bool) async throws {
        try await upload(localPath: localPath, to: remotePath, resumeFrom: 0,
                         progress: progress)
    }

    func upload(localPath: String, to remotePath: String, resumeFrom: Int64,
                progress: @escaping (Int64, Int64) -> Bool) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: localPath)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        // Маленький файл уходит одним запросом: заводить ради него многочастную отправку
        // (создать, послать, завершить — три обращения к серверу) незачем.
        if size <= Self.singleShotLimit, resumeFrom == 0 {
            try await uploadWhole(localPath: localPath, key: key(for: remotePath),
                                  size: size, progress: progress)
            return
        }
        try await uploadInParts(localPath: localPath, key: key(for: remotePath),
                                size: size, progress: progress)
    }

    /// Отправка одним куском — для файлов до пяти мегабайт.
    private func uploadWhole(localPath: String, key: String, size: Int64,
                             progress: @escaping (Int64, Int64) -> Bool) async throws {
        guard let session else { throw RemoteFileSystemError.notConnected }
        let request = try makeRequest(method: "PUT", key: key,
                                      extraHeaders: ["content-length": String(size)],
                                      payloadHash: AWSSignatureV4.unsignedPayload)
        _ = progress(0, size)
        let (data, response) = try await session.upload(
            for: request, fromFile: URL(fileURLWithPath: localPath))
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFileSystemError.protocolError("Ответ не по HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data)
        }
        _ = progress(size, size)
    }

    /// Отправка частями.
    ///
    /// Так уходит всё крупное: одиночный PUT упирается в пять гигабайт и не показывает хода
    /// работы. Части идут по очереди, после каждой сообщается прогресс и спрашивается отмена.
    private func uploadInParts(localPath: String, key: String, size: Int64,
                               progress: @escaping (Int64, Int64) -> Bool) async throws {
        let partSize = Self.partSize(forFileOf: size)

        // Продолжение живёт НА СЕРВЕРЕ, а не у нас: незавершённая отправка со своим номером
        // и уже принятыми частями лежит там, поэтому оборванная заливка продолжается даже
        // после перезапуска программы. Спрашивать смещение у вышестоящего слоя бесполезно:
        // он смотрит на размер файла в хранилище, а недособранного файла там ещё нет.
        var parts: [(number: Int, etag: String)] = []
        var uploadID: String
        if let found = try await findUnfinishedUpload(key: key) {
            let accepted = try await listUploadedParts(key: key, uploadID: found)
            if try partsBelong(toFileAt: localPath, parts: accepted, partSize: partSize) {
                uploadID = found
                parts = accepted
            } else {
                // Тот же ключ, но части не от этого файла: человек правил файл между
                // попытками. Досылать к чужим частям — значит собрать мешанину.
                try? await abortMultipartUpload(key: key, uploadID: found)
                uploadID = try await createMultipartUpload(key: key)
            }
        } else {
            uploadID = try await createMultipartUpload(key: key)
        }

        guard let handle = FileHandle(forReadingAtPath: localPath) else {
            throw RemoteFileSystemError.transferFailed("Не удалось открыть \(localPath)")
        }
        defer { try? handle.close() }

        // Части нумеруются с единицы и идут подряд, поэтому по их числу сразу известно,
        // сколько байт сервер уже принял и откуда читать файл дальше.
        var sent = Int64(parts.count) * partSize
        var number = parts.count + 1
        if sent > 0 {
            if sent >= size {
                // Все части уже там — осталось только сложить их вместе.
                try await completeMultipartUpload(key: key, uploadID: uploadID, parts: parts)
                _ = progress(size, size)
                return
            }
            try handle.seek(toOffset: UInt64(sent))
        }

        do {
            // Первым же сообщением — сколько уже лежит на сервере: при продолжении полоса
            // обязана начаться с середины, а не прыгнуть с нуля.
            _ = progress(sent, size)
            while sent < size {
                let chunk = try handle.read(upToCount: Int(min(partSize, size - sent))) ?? Data()
                if chunk.isEmpty { break }
                let etag = try await uploadPart(key: key, uploadID: uploadID,
                                                number: number, body: chunk)
                parts.append((number, etag))
                sent += Int64(chunk.count)
                number += 1
                if progress(sent, size) {
                    throw RemoteFileSystemError.transferCancelled
                }
            }
            try await completeMultipartUpload(key: key, uploadID: uploadID, parts: parts)
            _ = progress(size, size)
        } catch let error as RemoteFileSystemError {
            // Отменил человек — убираем за собой: продолжать он не собирался.
            // А вот оборванная связь снимать отправку не должна, иначе принятые части
            // пропадут и следующая попытка пойдёт с нуля — ради этого всё и затевалось.
            if case .transferCancelled = error {
                try? await abortMultipartUpload(key: key, uploadID: uploadID)
            }
            throw error
        }
    }

    /// Похожи ли уже принятые части на начало этого самого файла.
    ///
    /// Ключ мог остаться от прошлой попытки с другим содержимым. Метка части — это MD5 её
    /// содержимого, поэтому достаточно пересчитать последнюю принятую часть по местному
    /// файлу и сверить: совпало — продолжаем, нет — начинаем заново.
    private func partsBelong(toFileAt path: String,
                             parts: [(number: Int, etag: String)],
                             partSize: Int64) throws -> Bool {
        guard let last = parts.last else { return false }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(Int64(last.number - 1) * partSize))
        guard let chunk = try handle.read(upToCount: Int(partSize)),
              chunk.count == Int(partSize) else { return false }
        let mine = Data(Insecure.MD5.hash(data: chunk)).map { String(format: "%02x", $0) }
            .joined()
        return last.etag.replacingOccurrences(of: "\"", with: "") == mine
    }

    /// Незавершённая отправка этого же ключа, если сервер её ещё держит.
    private func findUnfinishedUpload(key: String) async throws -> String? {
        let request = try makeRequest(method: "GET", key: "",
                                      query: [URLQueryItem(name: "uploads", value: ""),
                                              URLQueryItem(name: "encoding-type", value: "url")])
        let (data, _) = try await perform(request)
        return S3MultipartParser.uploadID(forKey: key, in: data)
    }

    /// Что сервер уже принял. Метки частей нужны целиком: без них отправку не завершить.
    private func listUploadedParts(key: String, uploadID: String) async throws
    -> [(number: Int, etag: String)] {
        let request = try makeRequest(
            method: "GET", key: key,
            query: [URLQueryItem(name: "uploadId", value: uploadID)])
        let (data, _) = try await perform(request)
        return S3MultipartParser.parts(in: data)
    }

    private func createMultipartUpload(key: String) async throws -> String {
        let request = try makeRequest(method: "POST", key: key,
                                      query: [URLQueryItem(name: "uploads", value: "")],
                                      body: Data())
        let (data, _) = try await perform(request)
        let text = String(data: data, encoding: .utf8) ?? ""
        let id = Self.value(ofTag: "UploadId", in: text)
        guard !id.isEmpty else {
            throw RemoteFileSystemError.operationFailed("Сервер не выдал номер отправки")
        }
        return id
    }

    private func uploadPart(key: String, uploadID: String, number: Int,
                            body: Data) async throws -> String {
        guard let session else { throw RemoteFileSystemError.notConnected }
        let request = try makeRequest(
            method: "PUT", key: key,
            query: [URLQueryItem(name: "partNumber", value: String(number)),
                    URLQueryItem(name: "uploadId", value: uploadID)],
            extraHeaders: ["content-length": String(body.count)],
            payloadHash: AWSSignatureV4.unsignedPayload)

        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFileSystemError.protocolError("Ответ не по HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data)
        }
        // Метка части нужна для завершения отправки: сервер сверяет по ней, что получил
        // именно то, что мы посылали.
        guard let etag = http.value(forHTTPHeaderField: "ETag") else {
            throw RemoteFileSystemError.operationFailed("Сервер не подтвердил часть \(number)")
        }
        return etag
    }

    private func completeMultipartUpload(key: String, uploadID: String,
                                         parts: [(number: Int, etag: String)]) async throws {
        var xml = "<CompleteMultipartUpload>"
        for part in parts {
            xml += "<Part><PartNumber>\(part.number)</PartNumber>"
                + "<ETag>\(part.etag)</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"

        let body = Data(xml.utf8)
        let request = try makeRequest(
            method: "POST", key: key,
            query: [URLQueryItem(name: "uploadId", value: uploadID)],
            body: body, extraHeaders: ["content-type": "application/xml"])
        let (data, _) = try await perform(request)
        // Здесь тоже бывает «200 ОК» с отказом в теле — сложить части сервер может и не суметь.
        try Self.checkBodyForError(data)
    }

    private func abortMultipartUpload(key: String, uploadID: String) async throws {
        let request = try makeRequest(
            method: "DELETE", key: key,
            query: [URLQueryItem(name: "uploadId", value: uploadID)])
        try await perform(request)
    }

    /// До этого размера файл уходит одним запросом.
    static let singleShotLimit: Int64 = 5 << 20

    /// Размер части считается от размера файла, а не берётся постоянным: частей не может
    /// быть больше десяти тысяч, и на файле в сто гигабайт кусок по пять мегабайт в этот
    /// потолок упирается.
    static func partSize(forFileOf size: Int64) -> Int64 {
        let minimum: Int64 = 5 << 20          // меньше S3 не принимает
        let maxParts: Int64 = 10_000
        let needed = (size + maxParts - 1) / maxParts
        return max(minimum, ((needed + minimum - 1) / minimum) * minimum)
    }

    // MARK: - Пути

    func parentPath(for path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[trimmed.startIndex..<slash])
        return parent.isEmpty ? "/" : parent
    }
}

// MARK: - Разбор списка

/// Ответ ListObjectsV2 — XML. Разбирается штатным XMLParser: свой разбор угловых скобок
/// на чужих данных — способ однажды получить не тот файл.
enum S3ListingParser {

    struct Page {
        var items: [FileItem] = []
        var nextToken: String?
    }

    struct KeyPage {
        var keys: [String] = []
        var nextToken: String?
    }

    static func parse(_ data: Data, prefix: String) -> Page {
        let delegate = Delegate(prefix: prefix)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return Page(items: delegate.items, nextToken: delegate.nextToken)
    }

    static func parseKeys(_ data: Data) -> KeyPage {
        let delegate = Delegate(prefix: "")
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return KeyPage(keys: delegate.rawKeys, nextToken: delegate.nextToken)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private let prefix: String
        private var element = ""
        private var text = ""
        private var currentKey = ""
        private var currentSize: UInt64 = 0
        private var currentDate = Date()
        private(set) var items: [FileItem] = []
        private(set) var rawKeys: [String] = []
        private(set) var nextToken: String?

        init(prefix: String) { self.prefix = prefix }

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            element = name
            text = ""
            if name == "Contents" {
                currentKey = ""; currentSize = 0; currentDate = Date()
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            // Ключи запрошены закодированными (encoding-type=url) — здесь их и
            // раскодируем: показывать человеку «%D0%A4» вместо «Ф» нельзя.
            let value = Self.decode(text.trimmingCharacters(in: .whitespacesAndNewlines))
            switch name {
            case "Key": currentKey = value
            case "Size": currentSize = UInt64(value) ?? 0
            case "LastModified": currentDate = Self.date(from: value) ?? Date()
            case "NextContinuationToken": nextToken = value.isEmpty ? nil : value
            case "Prefix" where element == "Prefix":
                // Это или свёрнутая «папка» внутри CommonPrefixes, или эхо нашего запроса —
                // второе отличается тем, что совпадает с запрошенным префиксом.
                if !value.isEmpty, value != prefix, value.hasSuffix("/") {
                    items.append(Self.folder(named: shortName(from: value), key: value,
                                             date: Date()))
                }
            case "Contents":
                rawKeys.append(currentKey)
                // Сам объект-папка в список не идёт: он уже показан как папка из CommonPrefixes,
                // а вторым пунктом выглядел бы как файл нулевого размера с пустым именем.
                guard !currentKey.hasSuffix("/") else { break }
                let short = shortName(from: currentKey)
                guard !short.isEmpty else { break }
                items.append(Self.file(named: short, key: currentKey,
                                       size: currentSize, date: currentDate))
            default: break
            }
            text = ""
        }

        /// Имя внутри папки: у ключа отрезается запрошенный префикс.
        private func shortName(from key: String) -> String {
            var name = key
            if !prefix.isEmpty, name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
            if name.hasSuffix("/") { name.removeLast() }
            return name
        }

        /// Раскодировать проценты. Токен продолжения приходит закодированным тоже, но он
        /// уходит обратно как параметр запроса — значит и его надо вернуть в исходный вид,
        /// иначе вторая страница списка запрашивается по испорченному токену.
        static func decode(_ text: String) -> String {
            text.removingPercentEncoding ?? text
        }

        private static func date(from text: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }

        private static func folder(named name: String, key: String, date: Date) -> FileItem {
            FileItem(path: "/" + key, name: name, fileExtension: "", size: 0,
                     isDirectory: true, isHidden: name.hasPrefix("."), isSymlink: false,
                     isAlias: false, symlinkTarget: nil, hardlinkCount: 1,
                     permissions: "drwxr-xr-x", dateModified: date, dateCreated: date,
                     dateAdded: date, owner: "", entryCount: 0)
        }

        private static func file(named name: String, key: String,
                                 size: UInt64, date: Date) -> FileItem {
            FileItem(path: "/" + key, name: name,
                     fileExtension: (name as NSString).pathExtension,
                     size: size, isDirectory: false, isHidden: name.hasPrefix("."),
                     isSymlink: false, isAlias: false, symlinkTarget: nil, hardlinkCount: 1,
                     permissions: "-rw-r--r--", dateModified: date, dateCreated: date,
                     dateAdded: date, owner: "", entryCount: 0)
        }
    }
}

// MARK: - Разбор незавершённых отправок

/// Ответы ListMultipartUploads и ListParts. Нужны, чтобы продолжить оборванную отправку:
/// какой у неё номер и какие части сервер уже принял.
enum S3MultipartParser {

    /// Номер незавершённой отправки этого ключа. Если их несколько (отправку обрывали
    /// не раз), берётся последняя: у неё частей больше всего.
    static func uploadID(forKey key: String, in data: Data) -> String? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.uploads.last { $0.key == key }?.id
    }

    /// Уже принятые части: номер и метка. Метки нужны целиком — без них отправку не
    /// завершить, сервер сверяет их при склейке.
    static func parts(in data: Data) -> [(number: Int, etag: String)] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        // Только сплошной ряд с начала: пропуск в середине означает, что часть не дошла,
        // и досылать надо с неё, а не с конца.
        var result: [(number: Int, etag: String)] = []
        for part in delegate.parts.sorted(by: { $0.number < $1.number }) {
            guard part.number == result.count + 1 else { break }
            result.append((part.number, part.etag))
        }
        return result
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private var text = ""
        private var key = ""
        private var id = ""
        private var number = 0
        private var etag = ""
        private(set) var uploads: [(key: String, id: String)] = []
        private(set) var parts: [(number: Int, etag: String)] = []

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            text = ""
            if name == "Upload" { key = ""; id = "" }
            if name == "Part" { number = 0; etag = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            // Ключ запрошен закодированным, как и в списке файлов.
            case "Key": key = value.removingPercentEncoding ?? value
            case "UploadId": id = value
            case "PartNumber": number = Int(value) ?? 0
            case "ETag": etag = value
            case "Upload":
                if !key.isEmpty, !id.isEmpty { uploads.append((key, id)) }
            case "Part":
                if number > 0 { parts.append((number, etag)) }
            default: break
            }
            text = ""
        }
    }
}
