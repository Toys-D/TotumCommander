import AppKit
import SwiftUI

/// "Connect network drive" — the app's equivalent of Finder's ⌘K "Connect to Server".
/// The user types a server/share address; the mount itself is performed by macOS NetFS,
/// which resolves credentials from the Keychain and shows the SYSTEM auth sheet when they
/// are missing. The app therefore never sees, asks for, or stores the password.
@MainActor
final class ConnectNetworkDriveController {
    private static let recentsKey = "fcxl.recentNetworkDrives"
    private static let recentsLimit = 8

    /// Show the dialog. Returns the address the user confirmed, or nil on cancel.
    static func show() -> String? {
        FCXLDialog.runModal(size: NSSize(width: 500, height: 440)) { session in
            ConnectNetworkDriveView(session: session)
        }
    }

    static var recents: [String] {
        UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
    }

    static func remember(_ address: String) {
        var list = recents.filter { $0.caseInsensitiveCompare(address) != .orderedSame }
        list.insert(address, at: 0)
        UserDefaults.standard.set(Array(list.prefix(recentsLimit)), forKey: recentsKey)
    }

    static func clearRecents() {
        UserDefaults.standard.removeObject(forKey: recentsKey)
    }

    /// Turn what the user typed into a mountable URL, accepting the forms people actually
    /// paste: "smb://host/share", "//host/share", "host/share" and Windows "\\host\share".
    /// Returns nil when it can't be read as a server address (drives the Connect button).
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "\\", with: "/")   // Windows \\host\share
        if s.hasPrefix("//") { s = "smb:" + s }           // //host/share
        if !s.contains("://") { s = "smb://" + s }        // host/share
        guard let url = URL(string: s),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

// MARK: - Dialog

private struct ConnectNetworkDriveView: View {
    let session: FCXLDialogSession<String>

    @State private var address: String = ""
    @State private var recents: [String] = ConnectNetworkDriveController.recents
    @FocusState private var fieldFocused: Bool

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    private var isValid: Bool { ConnectNetworkDriveController.normalize(address) != nil }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("network.connectDrive"),
                             subtitle: L("network.connectDrive.subtitle"))

            VStack(alignment: .leading, spacing: 12) {
                TextField(L("network.connectDrive.placeholder"), text: $address)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($fieldFocused)
                    .onSubmit { connect() }

                if !recents.isEmpty { recentsCard }

                examplesBlock
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 14)

            Spacer(minLength: 0)

            FCXLDialogButtonBar(
                primaryTitle: L("network.connect"),
                primaryEnabled: isValid,
                primaryAction: connect,
                cancelAction: { session.cancel() }
            )
        }
        .onAppear { fieldFocused = true }
    }

    // MARK: Recent addresses

    private var recentsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("network.connectDrive.recent"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("network.connectDrive.clearRecent")) {
                    ConnectNetworkDriveController.clearRecents()
                    recents = []
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(accent)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(recents, id: \.self) { item in
                        Text(item)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(address == item ? accent : Color.clear)
                            .foregroundStyle(address == item ? Color.white : Color.primary)
                            .contentShape(Rectangle())
                            // Одновременные жесты: по очереди одиночный ждал бы двойного,
                            // и выбор строки отставал бы на интервал двойного нажатия.
                            .simultaneousGesture(TapGesture(count: 2)
                                .onEnded { address = item; connect() })
                            .simultaneousGesture(TapGesture().onEnded { address = item })
                    }
                }
            }
            .frame(maxHeight: 92)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    // MARK: Examples / help

    private var examplesBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("network.connectDrive.examplesTitle"))
                .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
            exampleRow("smb://192.168.1.10/Documents")
            exampleRow("smb://server.local/Share")
            exampleRow("\\\\192.168.1.10\\Documents")
            exampleRow("afp://mac-mini.local/Backup")
            Text(L("network.connectDrive.hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    /// Examples are clickable — tapping one drops it into the field to edit.
    private func exampleRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onTapGesture { address = text }
    }

    private func connect() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ConnectNetworkDriveController.normalize(trimmed) != nil else { return }
        session.finish(trimmed)
    }
}
