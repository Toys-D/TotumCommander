import AppKit
import SwiftUI

struct SettingsNetworkNTFSView: View {
    @AppStorage("fcxl.remoteDirectToQueue") private var remoteDirectToQueue: Bool = true
    @AppStorage("fcxl.maxConcurrentTransfers") private var maxConcurrentTransfers: Int = 2
    @AppStorage(TransferSpeedLimit.key) private var speedLimitKBps: Int = 0

    var body: some View {
        Form {
            Section(L("settings.section.network")) {
                Toggle(L("settings.remoteDirectToQueue"), isOn: $remoteDirectToQueue)
                Stepper(value: $maxConcurrentTransfers, in: 1...8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("settings.maxConcurrentTransfers", maxConcurrentTransfers))
                        Text(L("settings.maxConcurrentTransfers.hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
            Section(L("settings.section.ntfs")) {
                NTFSPasswordSettingsView()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - NTFS saved-password settings

private struct NTFSPasswordSettingsView: View {
    @State private var password: String = ""
    @State private var hasSaved: Bool = NTFSPasswordStore.hasPassword

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("settings.ntfs.explain"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hasSaved {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text(L("settings.ntfs.saved"))
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

            Text(L("settings.ntfs.warning"))
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
