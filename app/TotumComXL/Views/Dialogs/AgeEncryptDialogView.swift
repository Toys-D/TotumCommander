import SwiftUI

/// The password for sealing files into age: typed twice, both fields with the eye. A typo
/// here locks the file against its own author — the second field and the reveal exist for
/// exactly that reason, same as the vault dialog.
struct AgeEncryptDialogView: View {
    let session: FCXLDialogSession<String>
    let subtitle: String

    @State private var password = ""
    @State private var repeated = ""
    @FocusState private var focused: Bool

    private var ready: Bool { !password.isEmpty && password == repeated }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("age.password.title"), subtitle: subtitle)

            VStack(alignment: .leading, spacing: 10) {
                FCXLFormCard {
                    FCXLFormRow(label: L("age.password.field")) {
                        FCXLRevealablePasswordField(placeholder: "", text: $password,
                                                    onSubmit: { submit() })
                            .focused($focused)
                    }
                    FCXLFormRow(label: L("age.password.repeat"), showDivider: false) {
                        FCXLRevealablePasswordField(placeholder: "", text: $repeated,
                                                    onSubmit: { submit() })
                    }
                }
                Text(mismatch ? L("age.password.mismatch") : L("age.password.hint"))
                    .font(.caption)
                    .foregroundStyle(mismatch ? Color.orange : Color.secondary)
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            Spacer(minLength: 0)

            FCXLDialogButtonBar(
                primaryTitle: L("age.password.seal"),
                primaryEnabled: ready,
                primaryAction: { submit() },
                cancelAction: { session.cancel() })
        }
        .onAppear { focused = true }
    }

    private var mismatch: Bool { !repeated.isEmpty && password != repeated }

    private func submit() {
        guard ready else { return }
        session.finish(password)
    }
}
