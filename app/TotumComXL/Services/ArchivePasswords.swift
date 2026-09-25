import AppKit
import os

/// Passwords for the archives of THIS session — asked once, remembered until quit.
///
/// In memory only, never on disk: an archive password written anywhere would defeat the reason
/// the archive has one. The cache exists so that extracting an archive after browsing it — or
/// extracting it twice — asks once.
enum ArchivePasswords {

    /// Locked, not actor-bound: the panel browses and extracts on worker threads, and the
    /// remembered password has to be readable right where the bytes are pulled.
    private static let byPath = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    static func remembered(for path: String) -> String? {
        byPath.withLock { $0[path] }
    }

    static func remember(_ password: String, for path: String) {
        guard !password.isEmpty else { return }
        byPath.withLock { $0[path] = password }
    }

    /// A password that failed must not be offered again as if it were good.
    static func forget(for path: String) {
        _ = byPath.withLock { $0.removeValue(forKey: path) }
    }

    /// Does this error mean "the archive wants a password (or a different one)"?
    ///
    /// Two spellings reach us: minizip's password error is mapped to PermissionDenied by the
    /// core, and libarchive's passphrase failures arrive as ArchiveError with the word in the
    /// message. Matching the word is not elegant, but the alternative is a core-wide error-code
    /// migration for one question.
    nonisolated static func isPasswordFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == "com.fcxl.error" else { return false }
        if nsError.code == 2 { return true }   // ErrorCode::PermissionDenied
        let message = nsError.localizedDescription.lowercased()
        return message.contains("password") || message.contains("passphrase")
    }

    /// Ask for the archive's password: the app's own dialog, secure field, Enter/Esc.
    /// Nil when the person changes their mind.
    @MainActor
    static func ask(archiveName: String) -> String? {
        FCXLDialog.runModal(size: NSSize(width: 420, height: 210)) { session in
            ArchivePasswordPromptView(session: session, archiveName: archiveName)
        }
    }
}

import SwiftUI

private struct ArchivePasswordPromptView: View {
    let session: FCXLDialogSession<String>
    let archiveName: String

    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("archive.password.title"), subtitle: archiveName)

            VStack(alignment: .leading, spacing: 10) {
                FCXLFormCard {
                    FCXLFormRow(label: L("archive.password.field"), showDivider: false) {
                        FCXLRevealablePasswordField(placeholder: "", text: $password,
                                                    onSubmit: { submit() })
                            .focused($focused)
                    }
                }
                Text(L("archive.password.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            Spacer(minLength: 0)

            FCXLDialogButtonBar(
                primaryTitle: L("button.ok"),
                primaryEnabled: !password.isEmpty,
                primaryAction: { submit() },
                cancelAction: { session.cancel() })
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        session.finish(password)
    }
}

/// A password field with an eye: hidden by default, shown at a press — a typo in an archive
/// password locks the archive against its own author, and seeing what was typed is the cure.
/// One field for every password in the app, so they all behave the same.
struct FCXLRevealablePasswordField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil

    @State private var revealed = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { onSubmit?() }

            Button {
                revealed.toggle()
                // The swap replaces the field view; without handing focus back, the caret
                // vanishes and the next keystroke goes nowhere.
                DispatchQueue.main.async { focused = true }
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .contentShape(Rectangle())
            }
            .buttonStyle(FCXLChipButtonStyle(compact: true))
            .focusEffectDisabled()
            .help(L(revealed ? "password.hide" : "password.reveal"))
        }
    }
}
