import AppKit

/// The network "connect to…" menu, in ONE place.
///
/// It is offered from two buttons — the drive bar's globe (PanelVolumeBar) and the centre
/// divider's "Сеть" button (CenterDividerView) — and those two used to build the item list
/// separately. They drifted apart immediately: a new entry and a changed icon landed in one
/// copy only, so the same menu showed different things depending on where it was opened.
/// Both call sites now build this menu, so adding or renaming an entry is a single edit here.
///
/// An NSMenu shown through `ContextPopupMenuController`, like every menu of the program — not
/// a popover of SwiftUI buttons, which it was: macOS 27 put keyboard focus on the first button
/// of a popover and drew a blue ring around it.
enum NetworkMenu {

    /// Подпись пункта облака: что случится по щелчку.
    static func cloudTitle(_ provider: CloudProvider, _ placement: CloudPlacement) -> String {
        switch placement {
        case .bar, .menuHidden:     return provider.title
        case .menuSignIn:           return "\(provider.title) — \(L("cloud.menu.signIn"))"
        case .menuInstall:          return "\(provider.title) — \(L("cloud.menu.install"))"
        case .menuSystemSettings:   return "\(provider.title) — \(L("cloud.menu.systemSettings"))"
        }
    }

    /// - onLocalNetwork: browse computers discovered on the LAN.
    /// - onConnectNetworkDrive: Finder-style "Connect to Server" — mount a share by its address.
    /// - onFTPDisk: the saved-connections manager (FTP/SFTP/WebDAV).
    /// - clouds: облака, которых сейчас нет в полосе: подключить, войти, взять программу, вернуть.
    static func build(onLocalNetwork: (() -> Void)?,
                      onConnectNetworkDrive: (() -> Void)?,
                      onFTPDisk: (() -> Void)?,
                      clouds: [(provider: CloudProvider, placement: CloudPlacement)] = [],
                      onCloud: ((CloudProvider, CloudPlacement) -> Void)? = nil) -> NSMenu {
        let menu = NSMenu()
        // "Computers on the network" — deliberately NOT a wifi glyph, which described the
        // transport (a wired machine appears here just the same).
        menu.addStyledItem(title: L("network.localNetwork"), symbolName: "desktopcomputer",
                           id: "network.localNetwork") { onLocalNetwork?() }
        menu.addStyledItem(title: L("network.connectDrive"), symbolName: "externaldrive.badge.plus",
                           id: "network.connectDrive") { onConnectNetworkDrive?() }
        menu.addStyledItem(title: L("network.ftpDisk"), symbolName: "externaldrive.connected.to.line.below",
                           id: "network.ftpDisk") { onFTPDisk?() }
        if !clouds.isEmpty {
            menu.addItem(.separator())
            for entry in clouds {
                menu.addStyledItem(title: cloudTitle(entry.provider, entry.placement),
                                   symbolName: entry.provider.icon,
                                   id: "cloud." + entry.provider.title) {
                    onCloud?(entry.provider, entry.placement)
                }
                // Фирменный логотип вместо системного значка — своими цветами, не шаблон.
                if let logo = entry.provider.logo { menu.items.last?.image = logo }
            }
        }
        return menu
    }
}
