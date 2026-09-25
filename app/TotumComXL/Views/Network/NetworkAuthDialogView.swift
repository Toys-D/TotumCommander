import AppKit
import SwiftUI

/// Asking for a server login in the app's own window instead of the system one.
///
/// macOS puts up its own authentication sheet whenever NetFS is handed no credentials. That sheet
/// belongs to a separate process, so it cannot be restyled — the only way to stop seeing it is to
/// never need it: ask here, and pass what the user typed straight to the mount.
@MainActor
enum NetworkAuthDialog {

    struct Answer: Equatable {
        /// Empty account plus empty password means the user chose to connect as a guest.
        let account: String
        let password: String
        let remember: Bool
        let asGuest: Bool
    }

    /// What the server said no to last time. A guest turned away needs different words from a
    /// wrong password: "try again" sent people back to the guest button and round again.
    enum Rejection: Equatable { case none, credentials, guest }

    nonisolated static func bannerKey(for rejection: Rejection) -> String? {
        switch rejection {
        case .none:        return nil
        case .credentials: return "network.auth.rejected"
        case .guest:       return "network.auth.guestRefused"
        }
    }

    /// Ask for a login. `suggestedAccount` pre-fills the name — the one already in the Keychain,
    /// or failing that the local user's short name, which is what Finder offers.
    /// `rejection` turns the dialog into a retry: the server said no to the last attempt.
    /// `explanation` заменяет общие слова баннера словами самого сервера («530 User cannot log
    /// in.») — человеку виднее, что делать, когда он читает ответ, а не наш пересказ.
    static func ask(server: String,
                    share: String?,
                    suggestedAccount: String,
                    rejection: Rejection = .none,
                    explanation: String? = nil) -> Answer? {
        let size = NSSize(width: 480, height: dialogHeight(rejection: rejection,
                                                           explanation: explanation))
        return FCXLDialog.runModal(size: size) { session in
            NetworkAuthDialogView(session: session,
                                  server: server,
                                  share: share,
                                  initialAccount: suggestedAccount,
                                  rejection: rejection,
                                  explanation: explanation)
        }
    }

    /// Высота окна: баннер с ответом сервера бывает в несколько строк, и обрезать его нельзя —
    /// ради него всё и затевалось. Ширина окна 480, кегль 12 — около шестидесяти знаков в строке.
    nonisolated static func dialogHeight(rejection: Rejection, explanation: String?) -> CGFloat {
        guard rejection != .none else { return 372 }
        guard let explanation, !explanation.isEmpty else { return 400 }
        let wrapped = Int(ceil(Double(explanation.count) / 60.0))
        let breaks = explanation.filter { $0.isNewline }.count
        let lines = max(1, wrapped + breaks)
        return 400 + CGFloat(lines - 1) * 16
    }

    /// The name to offer when nothing is saved yet.
    static var defaultAccount: String { NSUserName() }
}

// MARK: - Dialog

private struct NetworkAuthDialogView: View {
    let session: FCXLDialogSession<NetworkAuthDialog.Answer>
    let server: String
    let share: String?
    let initialAccount: String
    let rejection: NetworkAuthDialog.Rejection
    /// Слова сервера вместо общего «попробуйте ещё раз», если они были.
    let explanation: String?

    @State private var asGuest = false
    @State private var account: String
    @State private var password: String = ""
    @State private var remember = true
    /// Read once, when the field is built — so it has to be true from the start. Setting it later
    /// in onAppear left every field unfocused, and AppKit handed the keyboard to the first control
    /// it could find instead: the guest radio button, drawing its focus ring there.
    @State private var focusName: Bool
    @State private var focusPassword = false

    init(session: FCXLDialogSession<NetworkAuthDialog.Answer>,
         server: String,
         share: String?,
         initialAccount: String,
         rejection: NetworkAuthDialog.Rejection,
         explanation: String? = nil) {
        self.session = session
        self.server = server
        self.share = share
        self.initialAccount = initialAccount
        self.rejection = rejection
        self.explanation = explanation
        _account = State(initialValue: initialAccount)
        _focusName = State(initialValue: true)
    }

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    private var canConnect: Bool {
        asGuest || !account.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("network.auth.title"),
                             subtitle: share.map { L("network.auth.subtitleShare", $0, server) }
                                 ?? L("network.auth.subtitle", server))

            VStack(alignment: .leading, spacing: 14) {
                if rejection != .none { rejectedBanner }

                connectAsPicker

                if !asGuest { credentialFields }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 14)

            Spacer(minLength: 0)

            FCXLDialogButtonBar(
                primaryTitle: L("network.connect"),
                primaryEnabled: canConnect,
                primaryAction: connect,
                cancelAction: { session.cancel() }
            )
        }

    }

    private var rejectedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(explanation ?? L(NetworkAuthDialog.bannerKey(for: rejection) ?? "network.auth.rejected"))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var connectAsPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("network.auth.connectAs"))
                .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                radio(L("network.auth.guest"), selected: asGuest) { asGuest = true }
                radio(L("network.auth.registered"), selected: !asGuest) {
                    asGuest = false
                    focusName = true
                }
            }
        }
    }

    private func radio(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? accent : Color.secondary)
                Text(title).font(.system(size: 13)).foregroundStyle(Color.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Nothing here should take the keyboard from the fields — a focused button is exactly
        // where the stray ring came from.
        .focusable(false)
    }

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            field(L("network.auth.name")) {
                // The app's own field: no AppKit focus ring, which is a blue rounded rectangle
                // that belongs to no other control in this dialog.
                boxed {
                    FCXLDialogTextField(text: $account,
                                        focusOnAppear: focusName,
                                        initialSelection: .all,
                                        onSubmit: { focusPassword = true })
                }
            }
            field(L("network.auth.password")) {
                boxed {
                    FCXLDialogTextField(text: $password,
                                        focusOnAppear: focusPassword,
                                        onSubmit: connect,
                                        isSecure: true)
                }
            }
            HStack(spacing: 8) {
                FCXLSwitch(isOn: $remember)
                Text(L("network.auth.remember")).font(.system(size: 12))
                Spacer(minLength: 0)
            }
                .font(.system(size: 12))
        }
    }

    /// The quiet box the app uses for an editable value — a filled rounded rectangle, no ring.
    private func boxed<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.10)))
    }

    private func field<Content: View>(_ label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
            content()
        }
    }

    private func connect() {
        guard canConnect else { return }
        if asGuest {
            session.finish(NetworkAuthDialog.Answer(account: "", password: "",
                                                    remember: false, asGuest: true))
            return
        }
        session.finish(NetworkAuthDialog.Answer(
            account: account.trimmingCharacters(in: .whitespaces),
            password: password,
            // Nothing to remember when the password is blank; saving an empty one would only
            // make the next connection fail silently instead of asking.
            remember: remember && !password.isEmpty,
            asGuest: false))
    }
}
