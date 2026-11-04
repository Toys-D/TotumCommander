import SwiftUI

/// Making a new vault: a name, a ceiling, a password — and the choice to put that password
/// behind the fingerprint.
struct VaultCreateDialogView: View {
    let session: FCXLDialogSession<VaultCreateRequest>
    /// The folder the vault will live in — the panel the person stood in.
    let folder: String

    @State private var name = ""
    @State private var sizeText = "1024"
    @State private var password = ""
    @State private var confirmation = ""
    @State private var remember = true
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""

    private var size: Int { Int(sizeText.filter(\.isNumber)) ?? 0 }
    private var mismatch: Bool { !confirmation.isEmpty && password != confirmation }
    private var ready: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && size >= 10 && !password.isEmpty && password == confirmation
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("vault.create.title"), icon: "lock.shield")

            Text(L("vault.create.subtitle"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                FCXLFormCard {
                    FCXLFormRow(label: L("vault.create.name")) {
                        FCXLDialogTextField(text: $name, placeholder: L("vault.create.name.hint"),
                                            focusOnAppear: true)
                    }
                    FCXLFormRow(label: L("vault.create.size"), showDivider: false) {
                        FCXLDialogTextField(text: $sizeText, placeholder: "1024")
                            .frame(width: 90)
                        Text(L("vault.create.size.unit"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                Text(L("vault.create.size.note"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                FCXLFormCard {
                    FCXLFormRow(label: L("vault.create.password")) {
                        FCXLRevealablePasswordField(placeholder: "", text: $password)
                    }
                    FCXLFormRow(label: L("vault.create.confirm")) {
                        FCXLRevealablePasswordField(placeholder: "", text: $confirmation)
                    }
                    FCXLToggleRow(label: L("vault.create.remember"), isOn: $remember,
                                  showDivider: false)
                }
                if mismatch {
                    Text(L("vault.create.mismatch"))
                        .font(.system(size: 11)).foregroundColor(.orange)
                }
                Text(L(remember ? "vault.create.remember.note" : "vault.create.password.note"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 8)

            FCXLDialogButtonBar(
                primaryTitle: L("vault.create.confirmButton"),
                primaryEnabled: ready,
                primaryAction: {
                    let cleaned = name.trimmingCharacters(in: .whitespaces)
                    let path = (folder as NSString)
                        .appendingPathComponent("\(cleaned).\(VaultService.fileExtension)")
                    session.finish(VaultCreateRequest(path: path, sizeMB: size,
                                                      password: password,
                                                      rememberInKeychain: remember))
                },
                cancelAction: { session.cancel() })
        }
        .frame(minWidth: 520, minHeight: 460)
    }
}

struct VaultCreateRequest {
    let path: String
    let sizeMB: Int
    let password: String
    let rememberInKeychain: Bool
}
