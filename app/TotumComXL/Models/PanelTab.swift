import Foundation
import SwiftUI

enum TabAccentColor: String, CaseIterable, Identifiable {
    case violet
    case blue
    case green
    case orange
    case red
    case graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .violet: return L("tabs.color.purple")
        case .blue: return L("tabs.color.blue")
        case .green: return L("tabs.color.green")
        case .orange: return L("tabs.color.orange")
        case .red: return L("tabs.color.red")
        case .graphite: return L("tabs.color.graphite")
        }
    }

    var color: Color {
        switch self {
        case .violet: return .purple
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case .graphite: return .gray
        }
    }
}

enum TabKind: String, Codable {
    case directory
    case terminal
    case remote
    case networkMount
}

struct PanelTab: Identifiable, Codable {
    var id: UUID
    var path: String
    var title: String
    var pinned: Bool
    var colorHex: String?
    var kind: TabKind
    var savedViewMode: String?
    var viewModePinned: Bool = false
    static let terminalDefaultColorHex = "#00BCD4"
    static let remoteDefaultColorHex = "#FF9800"

    /// ID of the RemoteConnection this tab belongs to (only for .remote tabs).
    var remoteConnectionID: UUID?

    init(id: UUID = UUID(), path: String, title: String? = nil, pinned: Bool = false,
         colorHex: String? = nil, kind: TabKind = .directory, remoteConnectionID: UUID? = nil) {
        self.id = id
        self.path = path
        self.kind = kind
        self.remoteConnectionID = remoteConnectionID
        if kind == .terminal {
            self.title = title ?? "Terminal"
            self.colorHex = colorHex ?? Self.terminalDefaultColorHex
        } else if kind == .remote || kind == .networkMount {
            self.title = title ?? "Remote"
            self.colorHex = colorHex ?? Self.remoteDefaultColorHex
        } else {
            let lastComponent = URL(fileURLWithPath: path).lastPathComponent
            self.title = title ?? (lastComponent.isEmpty ? path : lastComponent)
            self.colorHex = colorHex
        }
        self.pinned = pinned
    }

    var isTerminal: Bool { kind == .terminal }
    var isRemote: Bool { kind == .remote }
    var isNetworkMount: Bool { kind == .networkMount }
}
