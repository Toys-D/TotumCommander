import Foundation
import FCXLControlProtocol

/// The bridge between an MCP client and a running Totum Commander.
///
/// It speaks MCP (JSON-RPC 2.0 over stdin/stdout) on one side and the commander's control
/// socket on the other, and does nothing else — no file access of its own, no state. If the
/// commander is not running, or its control server is off, every tool answers so plainly
/// rather than doing the work itself: the point is to see what the PROGRAM sees.
enum MCPBridge {

    static let protocolVersion = "2024-11-05"

    // MARK: - The socket side

    /// Either the commander's answer or a sentence explaining why there is none. A plain
    /// enum rather than a thrown error: every failure here ends up as text for a reader.
    enum Answer {
        case answered(String)
        case unavailable(String)
    }

    static func ask(_ request: ControlRequest) -> Answer {
        let path = ControlProtocol.socketURL.path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unavailable("cannot open a socket") }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPath else { return .unavailable("socket path too long") }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: maxPath) { dst in
                _ = strlcpy(dst, path, maxPath)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let joined = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard joined == 0 else {
            return .unavailable("""
                Totum Commander is not answering. Start the program, and turn on \
                Settings ▸ General ▸ "Allow control by Claude" — it is off until you do.
                """)
        }

        guard var payload = try? JSONEncoder().encode(request) else {
            return .unavailable("cannot encode the request")
        }
        payload.append(0x0A)
        let written = payload.withUnsafeBytes { raw -> Int in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return sent }
                sent += n
            }
            return sent
        }
        guard written == payload.count else { return .unavailable("the connection closed while asking") }

        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while !pending.contains(0x0A) {
            let got = read(fd, &buffer, buffer.count)
            guard got > 0 else { break }
            pending.append(contentsOf: buffer[0..<got])
        }
        guard let newline = pending.firstIndex(of: 0x0A) else { return .unavailable("no answer") }
        let line = Data(pending[pending.startIndex..<newline])
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: line) else {
            return .unavailable("the answer was not understood")
        }
        return response.ok ? .answered(response.result ?? "") : .unavailable(response.error ?? "failed")
    }

    // MARK: - The MCP side

    static let tools: [[String: Any]] = ControlCommand.allCases.map { command in
        var properties: [String: Any] = [:]
        var required: [String] = []
        switch command {
        case .ping, .panels:
            break
        case .list:
            properties["path"] = ["type": "string",
                                  "description": "Folder to list. Absolute, ~/… , or relative to the folder the active panel shows."]
            properties["hidden"] = ["type": "string",
                                    "description": "\"true\" to include dot-files."]
            required = ["path"]
        case .find:
            properties["path"] = ["type": "string",
                                  "description": "Folder to search under. Absolute, ~/… , or relative to the active panel's folder."]
            properties["mask"] = ["type": "string",
                                  "description": "Name mask, e.g. *.pdf. A bare word matches anywhere in the name."]
            properties["limit"] = ["type": "string", "description": "Most results to return (default 200)."]
            properties["exclude"] = ["type": "string",
                                     "description": "Folders to skip, e.g. \"node_modules;.cache\". Omit to use the same list the program's own search uses."]
            required = ["path"]
        case .leftovers:
            properties["path"] = ["type": "string",
                                  "description": "The program to check: a .app, or the folder it was installed into. Absolute, ~/… , or relative to the active panel's folder."]
            required = ["path"]
        case .copy, .move:
            properties["from"] = ["type": "string",
                                  "description": "Files to act on: one path per line, or separated by \";\"."]
            properties["to"] = ["type": "string", "description": "Destination folder."]
            required = ["from", "to"]
        case .trash:
            properties["from"] = ["type": "string",
                                  "description": "Files to put in the Trash: one path per line, or separated by \";\"."]
            required = ["from"]
        case .mkdir:
            properties["to"] = ["type": "string", "description": "Folder to create."]
            required = ["to"]
        }
        return [
            "name": "totum_\(command.rawValue)",
            "description": command.summary,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
        ]
    }

    static func handle(_ message: [String: Any]) -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        let id = message["id"]

        switch method {
        case "initialize":
            return reply(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "totum-commander", "version": "1"],
            ])
        case "tools/list":
            return reply(id: id, result: ["tools": tools])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            let name = (params["name"] as? String ?? "").replacingOccurrences(of: "totum_", with: "")
            guard let command = ControlCommand(rawValue: name) else {
                return reply(id: id, result: text("unknown tool", isError: true))
            }
            var args: [String: String] = [:]
            for (key, value) in (params["arguments"] as? [String: Any] ?? [:]) {
                args[key] = String(describing: value)
            }
            switch ask(ControlRequest(id: Int.random(in: 1...1_000_000),
                                      command: command.rawValue, args: args)) {
            case .answered(let answer): return reply(id: id, result: text(answer, isError: false))
            case .unavailable(let why): return reply(id: id, result: text(why, isError: true))
            }
        case "notifications/initialized":
            return nil          // a notification has no id and wants no answer
        default:
            guard id != nil else { return nil }
            return ["jsonrpc": "2.0", "id": id!,
                    "error": ["code": -32601, "message": "method not found: \(method)"]]
        }
    }

    private static func text(_ body: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": body]], "isError": isError]
    }

    private static func reply(id: Any?, result: [String: Any]) -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { message["id"] = id }
        return message
    }

    static func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard let answer = handle(message),
                  let out = try? JSONSerialization.data(withJSONObject: answer),
                  let outText = String(data: out, encoding: .utf8)
            else { continue }
            print(outText)
            fflush(stdout)
        }
    }
}

MCPBridge.run()
