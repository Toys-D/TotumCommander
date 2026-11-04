import Foundation

/// Свой ключ службы у Google: «идентификатор клиента» и «секрет клиента», которые человек
/// заводит в Google Cloud Console для себя.
///
/// Зачем он. Google Drive подключается через rclone, и по умолчанию rclone ходит к Google
/// общим ключом — одним на всех своих пользователей. Google начал брать за такой ключ
/// деньги, и rclone объявил, что в 2026 году его выключит. После этого Google Drive
/// подключится только своим ключом. Пока общий жив, своё поле просто пустует.
///
/// Идентификатор не тайна — он лежит в настройках. Секрет — в связке ключей, как пароли
/// серверов.
struct GoogleClientKey: Equatable {
    var id: String
    var secret: String

    static let idDefaultsKey = "fcxl.google.clientID"
    private static let secretAccount = "google-drive-client-secret"

    /// Бэкенды rclone, которые говорят с Google и принимают этот ключ.
    static let backends: Set<String> = ["drive", "google photos"]

    /// Ключ, который пойдёт к этой службе: свой, если он заведён и служба — Google;
    /// иначе пусто, и rclone берёт общий.
    static func pair(for service: RcloneCloudService,
                     stored: GoogleClientKey?) -> (id: String, secret: String) {
        guard backends.contains(service.type), let stored, stored.isComplete else { return ("", "") }
        return (stored.id, stored.secret)
    }

    /// Обе половины на месте. Половина ключа rclone не примет: идентификатор без секрета
    /// он передаёт Google, а тот отвечает «invalid_client» уже в браузере.
    var isComplete: Bool { !id.isEmpty && !secret.isEmpty }

    /// Похоже ли на идентификатор клиента Google. Все они кончаются одинаково, и перепутать
    /// его с секретом — самая частая ошибка: поля стоят рядом, строки похожи.
    static func looksLikeClientID(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".apps.googleusercontent.com")
            && trimmed.count > ".apps.googleusercontent.com".count
            && !trimmed.contains(" ")
    }

    // MARK: - Хранение

    static func load(defaults: UserDefaults = .standard) -> GoogleClientKey? {
        let id = defaults.string(forKey: idDefaultsKey) ?? ""
        guard !id.isEmpty, let secret = KeychainService.load(account: secretAccount),
              !secret.isEmpty else { return nil }
        return GoogleClientKey(id: id, secret: secret)
    }

    /// Записать. Секрет — первым: не записался он — не трогаем и идентификатор, иначе
    /// в настройках остался бы ключ без второй половины.
    @discardableResult
    func save(defaults: UserDefaults = .standard) -> Bool {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty,
              KeychainService.save(password: secret, account: Self.secretAccount) else { return false }
        defaults.set(id, forKey: Self.idDefaultsKey)
        return true
    }

    static func clear(defaults: UserDefaults = .standard) {
        KeychainService.delete(account: secretAccount)
        defaults.removeObject(forKey: idDefaultsKey)
    }
}
