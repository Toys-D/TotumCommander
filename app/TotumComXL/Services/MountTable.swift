import Darwin
import Foundation

/// Таблица подключённых томов — как её знает ядро. Читается без обращения к самим томам:
/// сервер, который не отвечает, её не задержит.
enum MountTable {
    struct Entry: Equatable {
        /// Откуда: «//GUEST:@192.168.1.20/D» у сетевой папки, «/dev/disk3s1» у диска.
        let source: String
        /// Точка подключения.
        let path: String
        /// Вид файловой системы: smbfs, apfs…
        let type: String
    }

    static func entries() -> [Entry] {
        var list: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&list, MNT_NOWAIT)
        guard count > 0, let list else { return [] }
        defer { free(list) }
        return (0..<Int(count)).map { index in
            var item = list[index]
            let source = withUnsafeBytes(of: &item.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let path = withUnsafeBytes(of: &item.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let type = withUnsafeBytes(of: &item.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return Entry(source: source, path: path, type: type)
        }
    }

    /// Стоит ли по этому пути том. Папка, оставшаяся от отключённого тома, — уже не том.
    static func isMountPoint(_ path: String, among entries: [Entry] = MountTable.entries()) -> Bool {
        let wanted = normalized(path)
        return entries.contains { normalized($0.path) == wanted }
    }

    /// «//логин:пароль@сервер/папка» → сервер и папка. Имя папки в таблице записано процентами.
    static func networkSource(_ source: String) -> (host: String, share: String)? {
        guard source.hasPrefix("//") else { return nil }
        let rest = source.dropFirst(2)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        var host = String(rest[..<slash])
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        let rawShare = rest[rest.index(after: slash)...].split(separator: "/").first.map(String.init) ?? ""
        let share = rawShare.removingPercentEncoding ?? rawShare
        guard !host.isEmpty, !share.isEmpty else { return nil }
        return (host, share)
    }

    /// Где уже подключена эта папка сервера.
    ///
    /// На повторное подключение система отвечает «уже есть» (EEXIST) и точки не называет, а
    /// имя тома по папке не угадать: «D» с сервера встаёт как /Volumes/192.168.1.20. Сервер
    /// мог быть назван иначе (по адресу, а спрашивают по имени) — тогда папка с таким именем
    /// должна быть одна; две с разных серверов — гадать нельзя.
    static func existingMount(host: String, share: String, among entries: [Entry] = MountTable.entries()) -> String? {
        let sameShare = entries.compactMap { entry -> (host: String, path: String)? in
            guard let source = networkSource(entry.source),
                  source.share.compare(share, options: [.caseInsensitive]) == .orderedSame else { return nil }
            return (source.host, entry.path)
        }
        if let exact = sameShare.first(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }) {
            return exact.path
        }
        return sameShare.count == 1 ? sameShare[0].path : nil
    }

    private static func normalized(_ path: String) -> String {
        let standard = (path as NSString).standardizingPath
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }
}

/// Отключать ли том вместе с закрываемой вкладкой.
enum NetworkTabClose {
    /// Только если на томе не стоит больше ни одна вкладка ни в одной панели: иначе соседняя
    /// вкладка осталась бы на отключённой папке.
    static func unmountsVolume(_ volumeRoot: String, remainingPaths: [String]) -> Bool {
        let root = volumeRoot.count > 1 && volumeRoot.hasSuffix("/") ? String(volumeRoot.dropLast()) : volumeRoot
        return !remainingPaths.contains { $0 == root || $0.hasPrefix(root + "/") }
    }
}
