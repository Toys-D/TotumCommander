import AppKit
import SwiftUI

struct SettingsNetworkNTFSView: View {
    @AppStorage("fcxl.remoteDirectToQueue") private var remoteDirectToQueue: Bool = true
    @AppStorage(TransferSpeedLimit.key) private var speedLimitKBps: Int = 0

    var body: some View {
        Form {
            Section(L("settings.section.network")) {
                Toggle(L("settings.remoteDirectToQueue"), isOn: $remoteDirectToQueue).settingAnchor("settings.remoteDirectToQueue")
                VStack(alignment: .leading, spacing: 2) {
                    Picker(L("settings.speedLimit"), selection: $speedLimitKBps) {
                        ForEach(TransferSpeedLimit.choices, id: \.self) { kbps in
                            Text(TransferSpeedLimit.label(forKilobytesPerSecond: kbps)).tag(kbps)
                        }
                    }
                    Text(L("settings.speedLimit.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section(L("settings.section.googleKey")) {
                GoogleClientKeySettingsView()
            }
            Section(L("settings.section.ntfs")) {
                NTFSPasswordSettingsView()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Свой ключ Google

/// Поля своего ключа Google. Устроено как пароль NTFS ниже: пока ключа нет — поля и
/// «Сохранить», когда есть — строка «задан» и «Убрать». Секрет обратно не показывается.
struct GoogleClientKeySettingsView: View {
    @State private var clientID = ""
    @State private var secret = ""
    @State private var saved: GoogleClientKey?

    /// `saved` — снаружи только для отрисовки в проверке: настройки читают связку сами.
    init(saved: GoogleClientKey? = GoogleClientKey.load()) {
        _saved = State(initialValue: saved)
    }

    private static let consoleURL = URL(string: "https://console.cloud.google.com/apis/credentials")!

    private var idLooksWrong: Bool {
        !clientID.isEmpty && !GoogleClientKey.looksLikeClientID(clientID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("settings.googleKey.explain")).settingAnchor("settings.googleKey.explain")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let saved {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text(L("settings.googleKey.saved")).settingAnchor("settings.googleKey.saved")
                    Text(saved.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(L("settings.googleKey.clear"), role: .destructive) {
                        GoogleClientKey.clear()
                        self.saved = nil
                    }
                }
                Text(L("settings.googleKey.reconnect")).settingAnchor("settings.googleKey.reconnect")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TextField(L("settings.googleKey.idPlaceholder"), text: $clientID)
                    .textFieldStyle(.roundedBorder)
                SecureField(L("settings.googleKey.secretPlaceholder"), text: $secret)
                    .textFieldStyle(.roundedBorder)
                if idLooksWrong {
                    Text(L("settings.googleKey.idLooksWrong"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Link(L("settings.googleKey.howTo"), destination: Self.consoleURL)
                        .settingAnchor("settings.googleKey.howTo")
                    Spacer()
                    Button(L("settings.googleKey.save")) {
                        let key = GoogleClientKey(id: clientID, secret: secret)
                        if key.save() {
                            saved = GoogleClientKey.load()
                            clientID = ""
                            secret = ""
                        }
                    }
                    .disabled(clientID.isEmpty || secret.isEmpty || idLooksWrong)
                }
            }
        }
    }
}

// MARK: - NTFS saved-password settings

private struct NTFSPasswordSettingsView: View {
    @State private var password: String = ""
    @State private var hasSaved: Bool = NTFSPasswordStore.hasPassword

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("settings.ntfs.explain")).settingAnchor("settings.ntfs.explain")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hasSaved {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text(L("settings.ntfs.saved")).settingAnchor("settings.ntfs.saved")
                    Spacer()
                    Button(L("settings.ntfs.clear"), role: .destructive) {
                        NTFSPasswordStore.clear()
                        hasSaved = false
                        password = ""
                    }
                }
            } else {
                SecureField(L("settings.ntfs.placeholder"), text: $password)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(L("settings.ntfs.save")) {
                        if NTFSPasswordStore.save(password) {
                            hasSaved = true
                            password = ""
                        }
                    }
                    .disabled(password.isEmpty)
                }
            }

            Text(L("settings.ntfs.warning")).settingAnchor("settings.ntfs.warning")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
