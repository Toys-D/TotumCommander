import Foundation
import Security

/// Static utility for storing, loading, and deleting passwords in the macOS Keychain.
enum KeychainService {
    static let defaultService = "com.fcxl.credentials"

    /// Saves (or updates) a password for the given account in the Keychain.
    /// - Returns: `true` on success.
    @discardableResult
    static func save(password: String, account: String, service: String = defaultService) -> Bool {
        saveStatus(password: password, account: account, service: service) == errSecSuccess
    }

    /// То же самое, но с ответом связки ключей: по нему видно, ПОЧЕМУ пароль не записался.
    ///
    /// Прежде здесь стояло «не вышло обновить — и ладно»: любой ответ, кроме
    /// `errSecItemNotFound`, молча возвращал `false`, и человек видел только то, что пароль
    /// не сохранился. Так бывает, когда в связке лежит запись, доставшаяся от прежней
    /// подписи программы: обновить её нельзя, а завести новую мешает она же. Теперь
    /// мешающая запись убирается, и пароль ложится на её место.
    static func saveStatus(password: String, account: String,
                           service: String = defaultService) -> OSStatus {
        guard let data = password.data(using: .utf8) else { return errSecParam }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecSuccess { return errSecSuccess }
        if updateStatus != errSecItemNotFound {
            SecItemDelete(query as CFDictionary)
        }

        var addQuery = query
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Loads a password for the given account from the Keychain.
    /// - Returns: The password string, or `nil` if not found or decoding fails.
    static func load(account: String, service: String = defaultService) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }

        return password
    }

    /// Deletes the Keychain entry for the given account.
    /// - Returns: `true` on success or if the item was not found.
    @discardableResult
    static func delete(account: String, service: String = defaultService) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
