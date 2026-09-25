import Foundation
import Security

/// Server logins in the macOS Keychain, in the same drawer Finder uses.
///
/// These are stored as *internet* passwords keyed by server + protocol, which is exactly what
/// Finder writes when you tick "Remember this password in my keychain". Reading the same shape
/// means a share the user already saved through Finder logs in here without asking again, and a
/// password saved here shows up in Keychain Access as a normal server entry rather than as some
/// private blob of ours.
///
/// The password itself never leaves this file except to be handed straight to NetFS.
enum NetworkCredentialStore {

    struct Credentials: Equatable {
        let account: String
        let password: String
    }

    /// Keychain's own name for the protocol. Anything we do not recognise is stored without one,
    /// which still works — it just will not be shared with Finder's entry for that server.
    nonisolated static func protocolAttribute(for scheme: String) -> CFString? {
        switch scheme.lowercased() {
        case "smb", "cifs": return kSecAttrProtocolSMB
        case "afp":         return kSecAttrProtocolAFP
        case "ftp":         return kSecAttrProtocolFTP
        case "ftps":        return kSecAttrProtocolFTPS
        case "http":        return kSecAttrProtocolHTTP
        case "https":       return kSecAttrProtocolHTTPS
        default:            return nil
        }
    }

    private static func baseQuery(server: String, scheme: String, account: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server.lowercased()
        ]
        if let proto = protocolAttribute(for: scheme) {
            q[kSecAttrProtocol as String] = proto
        }
        if let account, !account.isEmpty {
            q[kSecAttrAccount as String] = account
        }
        return q
    }

    /// What we already know for this server, if anything. Returns the first match — a server the
    /// user logs into under two names is rare, and the dialog lets them type the other one.
    static func lookup(server: String, scheme: String) -> Credentials? {
        var query = baseQuery(server: server, scheme: scheme, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let found = item as? [String: Any],
              let account = found[kSecAttrAccount as String] as? String,
              let data = found[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8)
        else { return nil }

        return Credentials(account: account, password: password)
    }

    /// Save, or replace what is there. Returns false if the Keychain refused.
    @discardableResult
    static func save(server: String, scheme: String, account: String, password: String) -> Bool {
        guard !server.isEmpty, !account.isEmpty, !password.isEmpty else { return false }
        let query = baseQuery(server: server, scheme: scheme, account: account)

        // Update in place when an entry for this exact account already exists, so a changed
        // password does not leave the old one behind under a second entry.
        let update: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess {
            return true
        }

        var attrs = query
        attrs[kSecValueData as String] = Data(password.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Forget a login — used when the server rejects it, so a stale password cannot keep
    /// silently failing every time the user opens the share.
    static func remove(server: String, scheme: String, account: String?) {
        SecItemDelete(baseQuery(server: server, scheme: scheme, account: account) as CFDictionary)
    }
}
