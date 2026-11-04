import Foundation
import Security

/// Stores the optional admin password used to elevate NTFS write operations,
/// in the macOS Keychain (encrypted at rest, protected by the login keychain).
///
/// When a password is saved, `FCXLNTFSBridge` reads it (matching the same
/// service/account) and runs the privileged unmount/chmod via `sudo -S` without
/// showing the password dialog. When absent, the dialog is shown as before.
///
/// Security note: saving the admin password lets the app silently elevate to
/// root for NTFS operations. The user opts into this trade-off explicitly.
enum NTFSPasswordStore {
    // MUST match the constants in FCXLNTFSBridge.mm.
    private static let service = "com.filecommanderxl.ntfs-admin"
    private static let account = "admin"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Saves (or replaces) the admin password. Returns true on success.
    @discardableResult
    static func save(_ password: String) -> Bool {
        guard !password.isEmpty else { return false }
        SecItemDelete(baseQuery as CFDictionary)

        var attrs = baseQuery
        attrs[kSecValueData as String] = Data(password.utf8)
        // Available without a separate prompt while the device is unlocked.
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Removes any saved password.
    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    /// True if a password is currently saved.
    static var hasPassword: Bool {
        var query = baseQuery
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
