import SwiftUI

/// The network "connect to…" menu, in ONE place.
///
/// It is offered from two buttons — the drive bar's globe (PanelVolumeBar) and the centre
/// divider's "Сеть" button (CenterDividerView) — and those two used to build the item list
/// separately. They drifted apart immediately: a new entry and a changed icon landed in one
/// copy only, so the same menu showed different things depending on where it was opened.
/// Both call sites now render this view, so adding or renaming an entry is a single edit here.
struct NetworkMenuContent: View {
    let accent: Color
    /// Browse computers discovered on the LAN.
    var onLocalNetwork: (() -> Void)?
    /// Finder-style "Connect to Server": mount a share by typing its address.
    var onConnectNetworkDrive: (() -> Void)?
    /// Open the saved-connections manager (FTP/SFTP/WebDAV).
    var onFTPDisk: (() -> Void)?
    /// Called before each action so the presenting popover can dismiss itself.
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // "Computers on the network" — deliberately NOT a wifi glyph, which described the
            // transport (a wired machine appears here just the same).
            AccentMenuItem(title: L("network.localNetwork"),
                           icon: "desktopcomputer", accent: accent) {
                onDismiss()
                onLocalNetwork?()
            }
            AccentMenuItem(title: L("network.connectDrive"),
                           icon: "externaldrive.badge.plus", accent: accent) {
                onDismiss()
                onConnectNetworkDrive?()
            }
            AccentMenuItem(title: L("network.ftpDisk"),
                           icon: "externaldrive.connected.to.line.below", accent: accent) {
                onDismiss()
                onFTPDisk?()
            }
        }
        .padding(6)
        .frame(width: 230)
    }
}
