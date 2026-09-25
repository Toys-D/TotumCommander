import Foundation
import Combine

/// Active remote connection session. Wraps a RemoteFileSystemProtocol implementation
/// and tracks connection state. Owned by PanelViewModel when panel is in remote mode.
@MainActor
final class RemoteSession: ObservableObject, Identifiable {
    let id: UUID
    let connection: RemoteConnection
    let fileSystem: RemoteFileSystemProtocol

    /// Where this session is in its lifecycle. Before this existed the only signal was a
    /// bool nobody read, and there was no "connecting" state at all — so a panel entered
    /// remote mode before the connection existed and operations could start against nothing.
    enum Phase: Equatable {
        case idle                 // created, never connected
        case connecting           // connect() in flight
        case connected            // usable
        case failed(String)       // connect() threw
        case dead(String)         // was connected, then the server stopped responding
    }

    @Published private(set) var phase: Phase = .idle
    @Published var currentRemotePath: String
    @Published var connectionError: String?

    /// Kept for compatibility (tests and RemoteFileSystemProtocol callers read it).
    var isConnected: Bool { phase == .connected }

    /// The one question callers should ask before starting any remote work.
    var isReady: Bool { phase == .connected }

    /// Human-readable reason an operation is refused, or nil when the session is usable.
    var notReadyReason: String? {
        switch phase {
        case .connected:        return nil
        case .connecting:       return L("network.error.stillConnecting")
        case .idle:             return L("network.error.notConnected")
        case .failed(let why):  return why.isEmpty ? L("network.error.notConnected") : why
        case .dead(let why):    return why.isEmpty ? L("network.error.connectionLost") : why
        }
    }

    /// Called when the server has demonstrably stopped responding, so later operations are
    /// refused up front instead of each one hanging or failing on its own.
    func markDead(_ reason: String) {
        guard phase == .connected else { return }
        phase = .dead(reason)
        connectionError = reason
    }

    /// Связь восстановлена — сессия снова живая. Без этого однажды помеченная мёртвой
    /// сессия отвергала бы работу и после успешного переподключения.
    func revive() {
        phase = .connected
        connectionError = nil
    }

    init(connection: RemoteConnection, fileSystem: RemoteFileSystemProtocol) {
        self.id = connection.id
        self.connection = connection
        self.fileSystem = fileSystem
        self.currentRemotePath = connection.initialPath.isEmpty ? "/" : connection.initialPath
    }

    /// Establish the connection, publishing `.connecting` for the whole in-flight window so
    /// callers can refuse work instead of firing it at a socket that doesn't exist yet.
    func connect() async throws {
        connectionError = nil
        phase = .connecting
        do {
            try await fileSystem.connect()
            phase = .connected
        } catch {
            phase = .failed(error.localizedDescription)
            connectionError = error.localizedDescription
            throw error
        }
    }

    /// Disconnect gracefully.
    func disconnect() {
        fileSystem.disconnect()
        phase = .idle
    }

    /// Tab title for display: "Label" or "proto://host".
    var tabTitle: String {
        if !connection.label.isEmpty { return connection.label }
        return "\(connection.proto.displayName): \(connection.host)"
    }

    /// Short path for breadcrumb display: strips leading slash if only one level.
    var displayPath: String {
        let path = currentRemotePath
        if path == "/" { return "/" }
        return path
    }
}
