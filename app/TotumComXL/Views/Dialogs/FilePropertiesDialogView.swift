import AppKit
import SwiftUI

/// One read-only info line in the properties window (Type / Path / Size / …).
struct FilePropertiesInfoRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

/// The read-only lines, which for a folder keep changing after the window is already up.
///
/// Summing a folder means walking its whole subtree — seconds on a big one. The window used to wait
/// for that before it appeared at all; now it opens at once and these rows count up as the walk
/// proceeds, which is what Finder does.
@MainActor
final class FilePropertiesInfo: ObservableObject {
    @Published var rows: [FilePropertiesInfoRow]
    init(rows: [FilePropertiesInfoRow]) { self.rows = rows }
}

/// Everything the properties window needs to open: the read-only facts plus the one editable
/// thing — the permission mode. The hidden flag lives in «Сменить атрибуты» alone: that
/// dialog handles one file and a hundred alike, and one switch in two windows is one too many.
struct FilePropertiesInput {
    let name: String
    /// The file itself — the xattr card reads and strips attributes straight off it.
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let mode: Int
    let info: FilePropertiesInfo
}

/// What the window hands back — only the things the user actually changed. `nil` means "leave
/// it as it was", so we never chmod / chflags a file whose settings weren't touched.
struct FilePropertiesEdit {
    let newMode: Int?
    let applyRecursive: Bool
}

/// The properties window: read-only info on top, then a
/// permission grid (owner / group / everyone × read / write / execute) with a live octal
/// read-out. Folders also get "apply to enclosed items". Built on the shared FCXLDialog kit.
struct FilePropertiesDialogView: View {
    let session: FCXLDialogSession<FilePropertiesEdit>
    let input: FilePropertiesInput
    @ObservedObject private var info: FilePropertiesInfo

    @State private var perms: PosixPermissions
    /// The file's extended attributes, loaded once at open and after each strip.
    @State private var xattrs: [XattrInspector.Entry]
    /// Rows whose "?" is unfolded. Inline, not a popover — the same manner as the quick
    /// filter's help: reading must not steal the keyboard or float away.
    @State private var unfoldedHelp: Set<String> = []
    @State private var applyRecursive = false

    private let originalMode: Int

    init(session: FCXLDialogSession<FilePropertiesEdit>, input: FilePropertiesInput) {
        self.session = session
        self.input = input
        _info = ObservedObject(wrappedValue: input.info)
        _perms = State(initialValue: PosixPermissions(mode: input.mode))
        _xattrs = State(initialValue: XattrInspector.list(path: input.path))
        originalMode = input.mode
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: input.name)

            ScrollView {
                VStack(spacing: 16) {
                    infoCard
                    permissionsCard
                    xattrCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 14)
            }

            FCXLDialogButtonBar(
                primaryTitle: L("button.ok"),
                primaryAction: { confirm() },
                cancelAction: { session.cancel() }
            )
        }
    }

    // MARK: - Info (read-only)

    private var infoCard: some View {
        FCXLFormCard {
            ForEach(Array(info.rows.enumerated()), id: \.element.id) { index, row in
                FCXLFormRow(label: row.label, showDivider: index < info.rows.count - 1) {
                    Spacer(minLength: 8)
                    Text(row.value)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Permissions

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(L("properties.section.permissions"))
            FCXLFormCard {
                // The one shared rwx grid — see PermissionsGridView.
                PermissionsGridView(perms: $perms)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }

            if input.isDirectory {
                FCXLFormCard {
                    FCXLToggleRow(label: L("properties.applyToEnclosed"),
                                  isOn: $applyRecursive, showDivider: false)
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }

    // MARK: - Extended attributes (xattr)

    /// The invisible notes pinned to the file — each with a glanceable value preview and a
    /// strip button. Deleting is safe in the Finder sense: the FILE is untouched, only the
    /// note goes; quarantine removed here equals the attributes dialog's switch.
    private var xattrCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(L("properties.section.xattr"))
            FCXLFormCard {
                if xattrs.isEmpty {
                    HStack {
                        Text(L("properties.xattr.none"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(xattrs.enumerated()), id: \.element.id) { index, entry in
                            xattrRow(entry, showDivider: index < xattrs.count - 1)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func xattrRow(_ entry: XattrInspector.Entry, showDivider: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(entry.name)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Text("\(entry.size) B")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                if XattrInspector.explanation(name: entry.name) != nil {
                    Button {
                        if !unfoldedHelp.insert(entry.name).inserted {
                            unfoldedHelp.remove(entry.name)
                        }
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(unfoldedHelp.contains(entry.name)
                                             ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(L("properties.xattr.explain"))
                }
                Button {
                    XattrInspector.remove(path: input.path, name: entry.name)
                    xattrs = XattrInspector.list(path: input.path)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(L("properties.xattr.remove"))
            }
            if unfoldedHelp.contains(entry.name),
               let explanation = XattrInspector.explanation(name: entry.name) {
                Text(explanation)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            if let friendly = entry.friendly {
                // The translation: what this note IS and what it says — the raw bytes stay
                // behind the tooltip for the curious.
                Text(friendly)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(entry.preview)
            } else if !entry.preview.isEmpty {
                Text(entry.preview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if showDivider {
                Divider().padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    // MARK: - Confirm

    private func confirm() {
        let modeChanged = perms.mode != originalMode
        session.finish(FilePropertiesEdit(
            newMode: modeChanged ? perms.mode : nil,
            applyRecursive: applyRecursive
        ))
    }
}
