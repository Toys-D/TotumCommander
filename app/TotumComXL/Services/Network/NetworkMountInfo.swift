import Foundation

/// Prettifies mounted SMB volumes: maps the server IP back to its computer name
/// (learned from LAN discovery) so the UI can show "SERVER_SO: D ▸ Доки" instead of
/// the raw IP. The mount itself stays IP-based (reliable) — only the DISPLAY changes.
///
/// A share `//192.168.0.169/D` may be mounted at `/Volumes/D` OR `/Volumes/192.168.0.169`
/// (macOS picks the name), so the mount-point name is unreliable. The reliable source
/// is the volume's `volumeURLForRemounting` (`smb://192.168.0.169/D`) — host + share.
@MainActor
enum NetworkMountInfo {

    /// host / IP (lower-cased)  →  computer name (NetBIOS / Bonjour).
    private static var nameByHost: [String: String] = [:]
    /// Hosts with an in-flight background NetBIOS resolve (dedupe).
    private static var resolving: Set<String> = []

    /// Remember a computer name for a host/IP, as hosts are discovered on the LAN.
    static func record(host: String, name: String) {
        let key = host.lowercased()
        guard !key.isEmpty, !name.isEmpty else { return }
        nameByHost[key] = name
    }

    /// Хосты, чьи общие папки смонтированы сейчас. Такой компьютер жив по определению —
    /// вычёркивать его из обзора сети из-за промаха развёртки нельзя.
    static func mountedHosts() -> Set<String> {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeURLForRemountingKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                            options: [.skipHiddenVolumes]) ?? []
        var hosts = Set<String>()
        for volume in volumes {
            guard let v = try? volume.resourceValues(forKeys: Set(keys)),
                  v.volumeIsLocal == false,
                  let host = v.volumeURLForRemounting?.host, !host.isEmpty else { continue }
            hosts.insert(host.lowercased())
        }
        return hosts
    }

    /// For a filesystem path inside a mounted SMB volume, returns
    /// `(computer, share, mountRoot)`; `nil` for local paths.
    static func info(forPath path: String) -> (computer: String, share: String, mountRoot: String)? {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsLocalKey, .volumeURLForRemountingKey]),
              v.volumeIsLocal == false,
              let mountRoot = v.volume?.path,
              let remount = v.volumeURLForRemounting,
              let host = remount.host, !host.isEmpty
        else { return nil }
        let share = remount.pathComponents.last { $0 != "/" && !$0.isEmpty } ?? host
        return (computerName(forHost: host), share, mountRoot)
    }

    /// Best-known display name for a host/IP: the discovery cache, then the live
    /// discovered-hosts list, else the bare host (the IP, or a Bonjour name minus
    /// the ".local" suffix).
    static func computerName(forHost host: String) -> String {
        let key = host.lowercased()
        if let n = nameByHost[key] { return n }
        if let h = NetworkBrowserService.shared.discoveredHosts.first(where: { $0.host.lowercased() == key }),
           !h.name.isEmpty {
            nameByHost[key] = h.name
            return h.name
        }
        // Unknown IP (e.g. a share mounted before the LAN browser ran, or across a
        // restart): resolve the NetBIOS name in the background and refresh once known.
        resolveInBackground(host: key)
        return key.hasSuffix(".local") ? String(host.dropLast(6)) : host
    }

    private static func resolveInBackground(host: String) {
        guard !host.hasSuffix(".local"), !resolving.contains(host) else { return }
        resolving.insert(host)
        Task.detached(priority: .utility) {
            let name = netbiosServerName(ip: host)
            await MainActor.run {
                resolving.remove(host)
                guard let name, !name.isEmpty else { return }
                nameByHost[host] = name
                // Refresh the drive buttons (which observe this); the breadcrumb / tab
                // pick up the name on the next navigation.
                NotificationCenter.default.post(name: Notification.Name("com.fcxl.volumeBarNeedsRefresh"), object: nil)
            }
        }
    }

    /// `smbutil status <ip>` → NetBIOS server name (macOS-native, no Samba). nil if none.
    private nonisolated static func netbiosServerName(ip: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
        proc.arguments = ["status", ip]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 2.5)
        timer.setEventHandler { [weak proc] in if proc?.isRunning == true { proc?.terminate() } }
        timer.resume()
        proc.waitUntilExit()
        timer.cancel()

        guard proc.terminationStatus == 0 else { return nil }
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("server:") {
                let name = trimmed.dropFirst("server:".count).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return String(name) }
            }
        }
        return nil
    }
}
