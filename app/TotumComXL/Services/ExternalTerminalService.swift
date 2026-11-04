import AppKit

/// Opening a folder in an OUTSIDE terminal. The embedded one has its own ⌘` road and its
/// placement setting; this is for people whose shell life lives in iTerm, Warp or kitty —
/// and for everyone else, Apple's Terminal, which every Mac has.
enum ExternalTerminal: String, CaseIterable {
    case terminal = "com.apple.Terminal"
    case iterm = "com.googlecode.iterm2"
    case warp = "dev.warp.Warp-Stable"
    case kitty = "net.kovidgoyal.kitty"

    var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm2"
        case .warp: return "Warp"
        case .kitty: return "kitty"
        }
    }

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue)
    }
    var isInstalled: Bool { appURL != nil }

    /// The ones this Mac actually has — the settings picker offers only these; a choice
    /// between apps that are not there is a menu of broken buttons.
    static var installed: [ExternalTerminal] { allCases.filter(\.isInstalled) }

    static let defaultsKey = "fcxl.externalTerminal"

    /// The user's choice while it is still installed; a removed app falls back to the first
    /// installed one, and Apple's Terminal is the floor that is always there.
    static var chosen: ExternalTerminal {
        chosen(savedRawValue: UserDefaults.standard.string(forKey: defaultsKey),
               installed: installed)
    }

    /// The decision alone, testable without a Mac full of terminals.
    nonisolated static func chosen(savedRawValue: String?,
                                   installed: [ExternalTerminal]) -> ExternalTerminal {
        if let savedRawValue,
           let picked = ExternalTerminal(rawValue: savedRawValue),
           installed.contains(picked) {
            return picked
        }
        return installed.first ?? .terminal
    }

    /// Open `directory` in this terminal.
    func open(directory: String) {
        guard let appURL else { return }
        switch self {
        case .kitty:
            // kitty does not open folder URLs — the directory goes in as an argument.
            let process = Process()
            process.executableURL = appURL.appendingPathComponent("Contents/MacOS/kitty")
            process.arguments = ["--directory", directory]
            try? process.run()
        default:
            NSWorkspace.shared.open([URL(fileURLWithPath: directory)],
                                    withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
