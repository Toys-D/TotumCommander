import SwiftUI

/// The rwx grid — three actors by three bits, with the octal/symbolic readout under it.
///
/// One grid for every window that edits permissions: the properties window and the batch
/// attributes dialog. Extracted rather than copied so the two can never drift apart — the
/// rule that put FCXLSwitch everywhere applies to layouts too.
struct PermissionsGridView: View {
    @Binding var perms: PosixPermissions
    /// The octal code as typed — its own state, because while someone is in the middle of
    /// "774" the text is briefly not what the checkboxes say, and rewriting it under the
    /// keyboard would fight every keystroke.
    @State private var octalText: String

    init(perms: Binding<PosixPermissions>) {
        _perms = perms
        _octalText = State(initialValue: perms.wrappedValue.octalString)
    }

    var body: some View {
        VStack(spacing: 10) {
            // Column headers: Read / Write / Execute.
            HStack(spacing: 0) {
                Text("").frame(width: Self.actorColumnWidth, alignment: .leading)
                header(L("properties.perm.read"))
                header(L("properties.perm.write"))
                header(L("properties.perm.execute"))
            }
            row(L("properties.actor.owner"),
                $perms.ownerRead, $perms.ownerWrite, $perms.ownerExecute)
            row(L("properties.actor.group"),
                $perms.groupRead, $perms.groupWrite, $perms.groupExecute)
            row(L("properties.actor.everyone"),
                $perms.otherRead, $perms.otherWrite, $perms.otherExecute)

            Divider()

            HStack {
                Text(L("properties.perm.code"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                // The code WRITES as well as reads: type "774" and the checkboxes follow.
                // The app's own field (NSTextField under the hood), not SwiftUI's: inside a
                // grouped Form the raw TextField reports a stretched height and the digits
                // sink out of their own box. The AppKit one measures like text everywhere.
                FCXLDialogTextField(text: $octalText, fontSize: 12,
                                    monospaced: true, alignment: .center)
                    .frame(width: 44, height: 16)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                Text(perms.symbolic)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .onChange(of: octalText) { _, newText in
            // Anything but octal digits is quietly dropped; three digits is the whole word.
            let filtered = String(newText.filter { "01234567".contains($0) }.prefix(3))
            if filtered != newText { octalText = filtered; return }
            if let parsed = PosixPermissions(octalString: filtered), parsed != perms {
                perms = parsed
            }
        }
        .onChange(of: perms) { _, newPerms in
            // A checkbox spoke — the code repeats it. But not while the TYPED text already
            // means the same thing: "74" parses to 074, and rewriting it to "074" mid-word
            // would wrestle the cursor out of the person's hands.
            if PosixPermissions(octalString: octalText) != newPerms {
                octalText = newPerms.octalString
            }
        }
    }

    static let actorColumnWidth: CGFloat = 110

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }

    private func row(_ actor: String,
                     _ read: Binding<Bool>, _ write: Binding<Bool>,
                     _ exec: Binding<Bool>) -> some View {
        HStack(spacing: 0) {
            Text(actor)
                .font(.system(size: 13))
                .frame(width: Self.actorColumnWidth, alignment: .leading)
            box(read)
            box(write)
            box(exec)
        }
    }

    private func box(_ isOn: Binding<Bool>) -> some View {
        // Мелкий: их здесь девять в сетке, и крупные превращают таблицу прав в частокол.
        FCXLSwitch(isOn: isOn, size: .mini)
            .frame(maxWidth: .infinity)
    }
}
