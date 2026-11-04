import AppKit
import SwiftUI

/// "Select by mask" — the Total Commander Num+/Num− pair, as a dialog.
///
/// The mask itself is the same one the panel's quick filter understands (`*`, `?`), so a pattern
/// that narrowed the list can be reused to select what it showed. Recent masks are remembered:
/// the same handful — `*.jpg`, `*.tmp`, `IMG_*` — comes back every time.
@MainActor
enum MaskSelectionDialog {

    /// Masks the user typed before, newest first.
    private static let recentKey = "fcxl.selectionMaskRecent"
    private static let recentLimit = 8

    static var recent: [String] {
        UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }

    /// Remember a mask, newest first, without duplicates.
    static func remember(_ mask: String) {
        let trimmed = mask.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var list = recent.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(list.prefix(recentLimit)), forKey: recentKey)
    }

    /// Ask for a mask. Returns nil when the dialog is cancelled.
    static func run(deselecting: Bool) -> String? {
        let mask = FCXLDialog.runModal(size: NSSize(width: 460, height: 260)) { session in
            MaskSelectionDialogView(session: session, deselecting: deselecting)
        }
        if let mask { remember(mask) }
        return mask
    }
}

private struct MaskSelectionDialogView: View {
    let session: FCXLDialogSession<String>
    let deselecting: Bool

    /// Starts on the last mask used: the same one is wanted again more often than not.
    @State private var mask: String = MaskSelectionDialog.recent.first ?? "*.*"

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(
                title: L(deselecting ? "mask.deselect.title" : "mask.select.title"),
                subtitle: L("mask.subtitle"))

            VStack(alignment: .leading, spacing: 12) {
                FCXLFormCard {
                    FCXLFormRow(label: L("mask.field"), showDivider: false) {
                        FCXLDialogTextField(text: $mask, placeholder: "*.txt",
                                            focusOnAppear: true, initialSelection: .all,
                                            onSubmit: submit,
                                            onCancel: { session.cancel() })
                    }
                }

                if !MaskSelectionDialog.recent.isEmpty {
                    Text(L("mask.recent"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                    // Chips, so a repeat of last week's mask is one click rather than retyping.
                    HStack(spacing: 6) {
                        ForEach(MaskSelectionDialog.recent.prefix(6), id: \.self) { previous in
                            Button(previous) { mask = previous }
                                .buttonStyle(FCXLChipButtonStyle(compact: true))
                        }
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            Spacer(minLength: 0)

            FCXLDialogButtonBar(
                primaryTitle: L(deselecting ? "mask.deselect.button" : "mask.select.button"),
                primaryEnabled: !mask.trimmingCharacters(in: .whitespaces).isEmpty,
                primaryAction: submit,
                cancelAction: { session.cancel() })
        }
    }

    private func submit() {
        let trimmed = mask.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        session.finish(trimmed)
    }
}
