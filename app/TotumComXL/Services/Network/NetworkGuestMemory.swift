import Foundation

/// Серверы, куда человек входит гостем.
///
/// Связка ключей помнит логины с паролями, а «гость» — это отсутствие логина, и помнить его
/// негде. Без этой памяти каждое подключение к домашнему Windows начиналось с попытки войти
/// по связке ключей (её сервер отвергает), потом шло окно входа, потом вход гостем: две
/// переговоров с сервером вместо одной и лишнее окно.
enum NetworkGuestMemory {
    static let key = "fcxl.network.guestServers"

    static func isGuest(_ server: String, defaults: UserDefaults = .standard) -> Bool {
        servers(defaults).contains(server.lowercased())
    }

    static func remember(_ server: String, defaults: UserDefaults = .standard) {
        var all = servers(defaults)
        all.insert(server.lowercased())
        defaults.set(Array(all).sorted(), forKey: key)
    }

    /// Сервер перестал пускать гостей — спрашивать снова.
    static func forget(_ server: String, defaults: UserDefaults = .standard) {
        var all = servers(defaults)
        all.remove(server.lowercased())
        defaults.set(Array(all).sorted(), forKey: key)
    }

    private static func servers(_ defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
}
