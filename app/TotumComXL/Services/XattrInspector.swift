import Foundation

/// Reading and removing a file's extended attributes — the invisible notes macOS and apps
/// pin next to a file: quarantine, Finder tags, "where from", resource forks, TextEdit's
/// cursor position. The inspector SHOWS them and can strip one; writing new ones is a
/// different craft nobody asked for.
///
/// Plain Darwin syscalls, the same road the quarantine switch already takes — the C++ core
/// has its own xattr API, but a second staircase to the same floor helps no one.
enum XattrInspector {

    struct Entry: Identifiable, Equatable {
        let name: String
        let size: Int
        /// The value, made lookable: text when it decodes as UTF-8, hex bytes otherwise,
        /// both cut to a sane length. Empty for a zero-length attribute.
        let preview: String
        /// The TRANSLATION, when the attribute is one of the well-known ones: what this
        /// note is and what it says — "Скачан с: example.com", not "62 70 6c…".
        let friendly: String?
        var id: String { name }
    }

    /// Every attribute on `path`, alphabetized. A file without any — or an unreadable one —
    /// answers an empty list; the inspector shows "none", not an error.
    static func list(path: String) -> [Entry] {
        let listSize = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard listSize > 0 else { return [] }
        var nameBuffer = [CChar](repeating: 0, count: listSize)
        let filled = listxattr(path, &nameBuffer, listSize, XATTR_NOFOLLOW)
        guard filled > 0 else { return [] }

        let names = nameBuffer.prefix(filled)
            .split(separator: 0, omittingEmptySubsequences: true)
            .compactMap { chunk in
                String(bytes: chunk.map { UInt8(bitPattern: $0) }, encoding: .utf8)
            }

        return names.sorted().map { name in
            let value = read(path: path, name: name) ?? Data()
            return Entry(name: name, size: value.count,
                         preview: preview(of: value),
                         friendly: friendly(name: name, data: value))
        }
    }

    static func read(path: String, name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        guard size > 0 else { return Data() }
        var buffer = Data(count: size)
        let filled = buffer.withUnsafeMutableBytes {
            getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        guard filled >= 0 else { return nil }
        return buffer.prefix(filled)
    }

    /// Strip one attribute. True when it is gone — including when it was not there.
    @discardableResult
    static func remove(path: String, name: String) -> Bool {
        removexattr(path, name, XATTR_NOFOLLOW) == 0 || errno == ENOATTR
    }

    /// Text if it reads as text, hex if it does not — cut short either way: a preview is a
    /// glance, not a dump. Binary plists (Finder's favourite shape) announce themselves.
    nonisolated static func preview(of data: Data, limit: Int = 200) -> String {
        guard !data.isEmpty else { return "" }
        if data.starts(with: Array("bplist".utf8)) {
            return "binary plist · \(data.count) B"
        }
        // Scalars, not Characters: Swift folds "\r\n" into ONE grapheme that equals
        // neither "\r" nor "\n" — checked per grapheme, every Windows text fell into hex.
        if let text = String(data: data, encoding: .utf8),
           !text.contains("\0"),
           text.unicodeScalars.allSatisfy({ !$0.isASCII || $0.value >= 0x20
                                            || $0 == "\n" || $0 == "\t" || $0 == "\r" }) {
            return text.count > limit ? String(text.prefix(limit)) + "…" : text
        }
        let shown = data.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
        return shown + (data.count > 24 ? " …" : "")
    }

    // MARK: - The translator

    /// The well-known notes, told in words. Everything decoded here is best-effort: a
    /// malformed value simply gets no translation and shows its raw preview instead.
    nonisolated static func friendly(name: String, data: Data) -> String? {
        switch name {
        case "com.apple.quarantine":
            return friendlyQuarantine(data)
        case "com.apple.metadata:kMDItemWhereFroms":
            guard let urls = plistStrings(data), !urls.isEmpty else { return nil }
            return L("xattr.whereFroms", urls.joined(separator: ", "))
        case "com.apple.metadata:kMDItemDownloadedDate":
            guard let date = plistDates(data)?.first else { return nil }
            return L("xattr.downloadedDate", Self.dateText(date))
        case "com.apple.metadata:_kMDItemUserTags":
            guard let tags = plistStrings(data), !tags.isEmpty else { return nil }
            // Finder stores "Red\n4" — the name, a newline, the colour number.
            let names = tags.map { $0.split(separator: "\n").first.map(String.init) ?? $0 }
            return L("xattr.userTags", names.joined(separator: ", "))
        case "com.apple.FinderInfo":
            return L("xattr.finderInfo")
        case "com.apple.ResourceFork":
            return L("xattr.resourceFork")
        case "com.apple.TextEncoding":
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return L("xattr.textEncoding", text)
        case "com.apple.macl":
            return L("xattr.macl")
        case "com.apple.provenance":
            return L("xattr.provenance")
        case "Zone.Identifier":
            // Windows' own quarantine, carried over on NTFS/exFAT: [ZoneTransfer] ZoneId=3.
            return L("xattr.zoneIdentifier")
        case "com.apple.lastuseddate#PS":
            guard data.count >= 8 else { return nil }
            let seconds = data.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
            let date = Date(timeIntervalSince1970: TimeInterval(seconds))
            guard date.timeIntervalSince1970 > 0 else { return nil }
            return L("xattr.lastUsed", Self.dateText(date))
        default:
            return nil
        }
    }

    /// The LONG story behind a known attribute — what it is for and what it entails —
    /// unfolded by the row's "?" button. One translated value line answers "what does it
    /// say"; this answers "so what".
    nonisolated static func explanation(name: String) -> String? {
        let keys: [String: String] = [
            "com.apple.quarantine": "xattr.help.quarantine",
            "com.apple.metadata:kMDItemWhereFroms": "xattr.help.whereFroms",
            "com.apple.metadata:kMDItemDownloadedDate": "xattr.help.downloadedDate",
            "com.apple.metadata:_kMDItemUserTags": "xattr.help.userTags",
            "com.apple.FinderInfo": "xattr.help.finderInfo",
            "com.apple.ResourceFork": "xattr.help.resourceFork",
            "com.apple.TextEncoding": "xattr.help.textEncoding",
            "com.apple.macl": "xattr.help.macl",
            "com.apple.provenance": "xattr.help.provenance",
            "Zone.Identifier": "xattr.help.zoneIdentifier",
            "com.apple.lastuseddate#PS": "xattr.help.lastUsed",
        ]
        return keys[name].map { L($0) }
    }

    /// "0083;5f9b2c00;Safari;UUID" — flags, hex unix time, the app that downloaded it.
    nonisolated private static func friendlyQuarantine(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return L("xattr.quarantine") }
        let fields = text.split(separator: ";", omittingEmptySubsequences: false)
        let agent = fields.count > 2 ? String(fields[2]) : ""
        var when = ""
        if fields.count > 1, let stamp = UInt64(fields[1], radix: 16), stamp > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(stamp))
            // Hex zero and absurd values mean "unknown", not 1970.
            if date.timeIntervalSince1970 > 631_152_000 { when = Self.dateText(date) }
        }
        switch (agent.isEmpty, when.isEmpty) {
        case (false, false): return L("xattr.quarantine.by.at", agent, when)
        case (false, true):  return L("xattr.quarantine.by", agent)
        default:             return L("xattr.quarantine")
        }
    }

    nonisolated private static func plistStrings(_ data: Data) -> [String]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String]
    }

    nonisolated private static func plistDates(_ data: Data) -> [Date]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [Date]
    }

    nonisolated private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
