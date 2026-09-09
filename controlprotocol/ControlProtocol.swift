import Foundation

/// The wire between the running commander and anything that drives it — today the MCP bridge
/// that lets Claude look around the file manager.
///
/// One line of JSON per message, in both directions. A line is a whole message: no framing to
/// get wrong, no length prefixes, and a stalled reader can never mistake half a message for a
/// whole one. Everything here is shared by the app and the bridge, so the two can never drift.
public enum ControlProtocol {

    /// Where the socket lives. Inside the app's own support folder, which is already per-user
    /// and not world-readable — the socket controls a running program, so it must not be a
    /// public door.
    public static var socketURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("TotumCommander", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("control.sock")
    }

    /// Turning the server on is the user's decision, and it is off until they make it.
    public static let enabledKey = "fcxl.controlServerEnabled"
}

public struct ControlRequest: Codable, Sendable {
    public let id: Int
    public let command: String
    public let args: [String: String]

    public init(id: Int, command: String, args: [String: String] = [:]) {
        self.id = id
        self.command = command
        self.args = args
    }
}

/// The answer. `result` is deliberately loose — a JSON value the caller renders as text —
/// because the bridge only forwards it and the reader of it is a language model.
public struct ControlResponse: Codable, Sendable {
    public let id: Int
    public let ok: Bool
    public let result: String?
    public let error: String?

    public init(id: Int, result: String) {
        self.id = id
        self.ok = true
        self.result = result
        self.error = nil
    }

    public init(id: Int, error: String) {
        self.id = id
        self.ok = false
        self.result = nil
        self.error = error
    }
}

/// The commands the server answers. Everything here READS; nothing changes a file. A command
/// that could destroy something belongs behind a confirmation in the app itself, and is
/// deliberately absent until that exists.
public enum ControlCommand: String, CaseIterable, Sendable {
    case ping
    case panels
    case list
    case find
    case leftovers
    case copy
    case move
    case trash
    case mkdir

    /// True for a command that changes something on disk. Every one of these stops at a dialog
    /// in the program: the person sees exactly what was asked and answers for themselves. The
    /// distinction is not decoration — it is what the server uses to decide whether to ask.
    public var changesFiles: Bool {
        switch self {
        case .ping, .panels, .list, .find, .leftovers: return false
        case .copy, .move, .trash, .mkdir: return true
        }
    }

    public var summary: String {
        switch self {
        case .ping: return "Check that Totum Commander is running and reachable."
        case .panels: return "What both panels show: folder, cursor, selection, view mode."
        case .list: return "List a folder: names, sizes, dates, kind."
        case .find: return "Find files by name mask under a folder."
        case .leftovers:
            return "What the uninstaller found for a program: the paths it would remove, what each place is for, and its size. Use it to check the list — say which entries are shared with the maker's other programs and must be kept, and which leftovers were missed."
        case .copy:
            return "Ask to COPY files into a folder. The person sees what was asked and confirms it in the program; nothing happens until they do."
        case .move:
            return "Ask to MOVE files into a folder. The person confirms it in the program first."
        case .trash:
            return "Ask to put files in the Trash. The person confirms it in the program first; nothing is erased outright."
        case .mkdir:
            return "Ask to create a folder. The person confirms it in the program first."
        }
    }
}
