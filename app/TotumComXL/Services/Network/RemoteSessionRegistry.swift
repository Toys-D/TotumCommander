import Combine
import Foundation

/// Живые сессии обеих панелей одним списком — чтобы полоса дисков любой панели
/// показывала каждое подключение, как показывает каждый примонтированный том. Сессия
/// по-прежнему принадлежит панели, которая её открыла; здесь только справочник.
@MainActor
final class RemoteSessionRegistry: ObservableObject {
    static let shared = RemoteSessionRegistry()

    @Published private(set) var sessions: [RemoteSession] = []

    /// Панель сменила сессию: прежняя уходит из списка, новая встаёт в конец.
    func replace(_ previous: RemoteSession?, with next: RemoteSession?) {
        if let previous { sessions.removeAll { $0 === previous } }
        if let next, !sessions.contains(where: { $0 === next }) { sessions.append(next) }
    }

    struct Chip: Identifiable {
        let session: RemoteSession
        /// Сессия другой панели: щелчок открывает то же место здесь, своей вкладкой.
        let foreign: Bool
        var id: UUID { session.id }
    }

    /// Что показать полосе панели со своей сессией `own`: своя — первой, чужие — следом,
    /// но не те, что ведут на тот же сервер: второй чип того же места лишний.
    static func chips(own: RemoteSession?, all: [RemoteSession]) -> [Chip] {
        var result: [Chip] = []
        var seen = Set<UUID>()
        if let own {
            result.append(Chip(session: own, foreign: false))
            seen.insert(own.connection.id)
        }
        for session in all where seen.insert(session.connection.id).inserted {
            result.append(Chip(session: session, foreign: true))
        }
        return result
    }
}
