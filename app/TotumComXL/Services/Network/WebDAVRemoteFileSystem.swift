import Foundation

/// WebDAV/WebDAVS remote filesystem implementation using URLSession.
/// Pure Swift, no C++ bridge needed.
final class WebDAVRemoteFileSystem: RemoteFileSystemProtocol {
    private let connection: RemoteConnection
    private let password: String
    private var session: URLSession?
    private(set) var isConnected: Bool = false

    var protocolDisplayName: String { connection.proto == .webdavs ? "WebDAVS" : "WebDAV" }
    var rootPath: String { connection.initialPath.isEmpty ? "/" : connection.initialPath }

    init(connection: RemoteConnection, password: String) {
        self.connection = connection
        self.password = password
    }

    // MARK: - Base URL construction

    /// Адрес хранилища; nil — хост не собирается в URL (пробел, кириллица). Раньше здесь
    /// стояла принудительная развёртка, и такой хост ронял программу при первом обращении.
    private var baseURL: URL? {
        let scheme = connection.proto == .webdavs ? "https" : "http"
        let port = connection.effectivePort
        return URL(string: "\(scheme)://\(connection.host):\(port)")
    }

    private func url(for path: String) throws -> URL {
        guard let baseURL else {
            throw RemoteFileSystemError.connectionFailed(L("connection.host.invalid", connection.host))
        }
        let clean = path.hasPrefix("/") ? path : "/\(path)"
        return baseURL.appendingPathComponent(clean)
    }

    private func authorizedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if !connection.username.isEmpty {
            let credentials = "\(connection.username):\(password)"
            if let data = credentials.data(using: .utf8) {
                request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    // MARK: - Connection

    func connect() async throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config)

        // Verify connection with PROPFIND on root
        let testURL = try url(for: rootPath)
        var request = authorizedRequest(url: testURL, method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)

        let (_, response) = try await session!.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteFileSystemError.connectionFailed("Invalid response")
        }
        if httpResponse.statusCode == 401 {
            throw RemoteFileSystemError.authenticationFailed(connection.host)
        }
        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 207 else {
            throw RemoteFileSystemError.connectionFailed("HTTP \(httpResponse.statusCode)")
        }
        isConnected = true
    }

    func disconnect() {
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
    }

    // MARK: - Directory listing

    func listDirectory(at path: String) async throws -> [FileItem] {
        guard let session else { throw RemoteFileSystemError.notConnected }

        let dirURL = try url(for: path.hasSuffix("/") ? path : path + "/")
        var request = authorizedRequest(url: dirURL, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 207 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { throw RemoteFileSystemError.pathNotFound(path) }
            if code == 401 { throw RemoteFileSystemError.authenticationFailed(connection.host) }
            throw RemoteFileSystemError.operationFailed("PROPFIND failed: HTTP \(code)")
        }

        let parser = WebDAVResponseParser(data: data, basePath: path)
        return parser.parse()
    }

    // MARK: - File operations

    func createDirectory(at path: String, name: String) async throws {
        guard let session else { throw RemoteFileSystemError.notConnected }
        let dirPath = path.hasSuffix("/") ? path + name : path + "/" + name
        let request = authorizedRequest(url: try url(for: dirPath), method: "MKCOL")
        let (_, response) = try await session.data(for: request)
        try validateResponse(response, context: "MKCOL")
    }

    func deleteItem(at path: String, isDirectory: Bool) async throws {
        guard let session else { throw RemoteFileSystemError.notConnected }
        let request = authorizedRequest(url: try url(for: path), method: "DELETE")
        let (_, response) = try await session.data(for: request)
        try validateResponse(response, context: "DELETE")
    }

    func rename(at path: String, to newName: String) async throws {
        guard let session else { throw RemoteFileSystemError.notConnected }
        let parentDir = parentPath(for: path)
        let destPath = parentDir.hasSuffix("/") ? parentDir + newName : parentDir + "/" + newName
        var request = authorizedRequest(url: try url(for: path), method: "MOVE")
        request.setValue(try url(for: destPath).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("T", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await session.data(for: request)
        try validateResponse(response, context: "MOVE")
    }

    func moveItem(from sourcePath: String, to destinationPath: String) async throws {
        guard let session else { throw RemoteFileSystemError.notConnected }
        var request = authorizedRequest(url: try url(for: sourcePath), method: "MOVE")
        request.setValue(try url(for: destinationPath).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("T", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await session.data(for: request)
        try validateResponse(response, context: "MOVE")
    }

    // MARK: - Transfer

    func download(remotePath: String, to localPath: String,
                  progress: @escaping (Int64, Int64) -> Bool) async throws {
        guard let session else { throw RemoteFileSystemError.notConnected }
        let request = authorizedRequest(url: try url(for: remotePath), method: "GET")

        let (tempURL, response) = try await session.download(for: request)
        try validateResponse(response, context: "GET")

        let localURL = URL(fileURLWithPath: localPath)
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: tempURL, to: localURL)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localPath)[.size] as? Int64) ?? 0
        _ = progress(fileSize, fileSize)
    }

    func upload(localPath: String, to remotePath: String,
                progress: @escaping (Int64, Int64) -> Bool) async throws {
        guard let session else { throw RemoteFileSystemError.notConnected }
        let localURL = URL(fileURLWithPath: localPath)
        var request = authorizedRequest(url: try url(for: remotePath), method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await session.upload(for: request, fromFile: localURL)
        try validateResponse(response, context: "PUT")

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localPath)[.size] as? Int64) ?? 0
        _ = progress(fileSize, fileSize)
    }

    // MARK: - Helpers

    private func validateResponse(_ response: URLResponse, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFileSystemError.operationFailed("\(context): invalid response")
        }
        switch http.statusCode {
        case 200...299, 201, 204, 207: break
        case 401: throw RemoteFileSystemError.authenticationFailed(connection.host)
        case 403: throw RemoteFileSystemError.permissionDenied(context)
        case 404: throw RemoteFileSystemError.pathNotFound(context)
        default: throw RemoteFileSystemError.operationFailed("\(context): HTTP \(http.statusCode)")
        }
    }

    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:displayname/>
        <d:resourcetype/>
        <d:getcontentlength/>
        <d:getlastmodified/>
        <d:creationdate/>
      </d:prop>
    </d:propfind>
    """
}

// MARK: - WebDAV XML Response Parser

private final class WebDAVResponseParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let basePath: String
    private var items: [FileItem] = []
    private var currentHref: String = ""
    private var currentDisplayName: String = ""
    private var currentIsDirectory: Bool = false
    private var currentSize: UInt64 = 0
    private var currentModified: Date?
    private var currentCreated: Date?
    private var currentElement: String = ""
    private var elementText: String = ""
    private var isFirstEntry = true

    init(data: Data, basePath: String) {
        self.data = data
        self.basePath = basePath
    }

    func parse() -> [FileItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let local = element.components(separatedBy: ":").last ?? element
        currentElement = local
        elementText = ""
        if local == "response" {
            currentHref = ""
            currentDisplayName = ""
            currentIsDirectory = false
            currentSize = 0
            currentModified = nil
            currentCreated = nil
        }
        if local == "collection" {
            currentIsDirectory = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        elementText += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let local = element.components(separatedBy: ":").last ?? element
        let text = elementText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch local {
        case "href":
            currentHref = text.removingPercentEncoding ?? text
        case "displayname":
            currentDisplayName = text
        case "getcontentlength":
            currentSize = UInt64(text) ?? 0
        case "getlastmodified":
            currentModified = Self.rfc1123Formatter.date(from: text)
                ?? Self.iso8601Formatter.date(from: text)
        case "creationdate":
            currentCreated = Self.iso8601Formatter.date(from: text)
        case "response":
            // Skip the directory itself (first response = parent)
            if isFirstEntry {
                isFirstEntry = false
                return
            }
            let name = currentDisplayName.isEmpty
                ? (URL(string: currentHref)?.lastPathComponent ?? currentHref)
                : currentDisplayName
            guard !name.isEmpty, name != "." else { return }

            let remotePath = basePath.hasSuffix("/")
                ? basePath + name
                : basePath + "/" + name
            let ext = currentIsDirectory ? "" : (URL(fileURLWithPath: name).pathExtension)
            let item = FileItem(
                path: remotePath,
                name: name,
                fileExtension: ext,
                size: currentSize,
                isDirectory: currentIsDirectory,
                isHidden: name.hasPrefix("."),
                isSymlink: false,
                permissions: "",
                dateModified: currentModified ?? Date.distantPast,
                dateCreated: currentCreated,
                owner: ""
            )
            items.append(item)
        default:
            break
        }
    }

    private static let rfc1123Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
