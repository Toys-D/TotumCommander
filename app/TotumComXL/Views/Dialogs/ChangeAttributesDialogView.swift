import AppKit
import SwiftUI

/// TC's Files ▸ Change Attributes, in this app's own clothes: one dialog, the whole
/// selection — permissions, dates, and a switch to walk into folders.
///
/// Each section has its own "change this" switch, off by default. Only what is switched ON
/// leaves the dialog; a hundred files keep their differing dates untouched unless the person
/// explicitly said to level them. That is what makes the batch honest — the dialog cannot
/// SHOW a hundred different values, so it must not silently write back the one it shows.
struct ChangeAttributesDialogView: View {
    let session: FCXLDialogSession<FileOperationsService.AttributeChanges>
    let items: [FileItem]

    @State private var applyPermissions = false
    @State private var perms: PosixPermissions
    @State private var applyModified = false
    @State private var modifiedDate = Date()
    @State private var applyCreated = false
    @State private var createdDate = Date()
    /// One switch, seeded from the file itself: flip it and the new state is written to the
    /// whole selection; leave it alone and visibility is not touched at all. The untouched
    /// position IS the "leave alone" — no separate gate, no picker.
    @State private var hidden: Bool
    private let originalHidden: Bool
    /// Same manner as `hidden`: shows the file's CURRENT state, applies only when moved.
    @State private var quarantined: Bool
    private let originalQuarantined: Bool
    @State private var recursive = false

    private let hasFolders: Bool

    init(session: FCXLDialogSession<FileOperationsService.AttributeChanges>, items: [FileItem]) {
        self.session = session
        self.items = items
        hasFolders = items.contains(where: \.isDirectory)
        // The first item seeds the grid and the dates — a starting point to edit, not a
        // claim about the whole selection (nothing is written unless a switch says so).
        // Read FRESH from disk, not from the listing: the panel's permission string is the
        // core's symbolic "rwxr-xr-x", and parsing it as octal silently fell back to 644 —
        // this dialog and the properties window then showed the same file differently.
        let attrs = items.first.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)
        }
        let firstMode = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        _perms = State(initialValue: PosixPermissions(mode: firstMode))
        let isHiddenNow = items.first.flatMap {
            try? URL(fileURLWithPath: $0.path).resourceValues(forKeys: [.isHiddenKey]).isHidden
        } ?? false
        _hidden = State(initialValue: isHiddenNow)
        originalHidden = isHiddenNow
        let isQuarantinedNow = items.first.map {
            getxattr($0.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
        } ?? false
        _quarantined = State(initialValue: isQuarantinedNow)
        originalQuarantined = isQuarantinedNow
        _modifiedDate = State(initialValue: attrs?[.modificationDate] as? Date
                              ?? items.first?.dateModified ?? Date())
        _createdDate = State(initialValue: attrs?[.creationDate] as? Date
                             ?? items.first?.dateCreated ?? Date())
    }

    private var anythingToApply: Bool {
        applyPermissions || applyModified || applyCreated
            || hidden != originalHidden || quarantined != originalQuarantined
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("attributes.title"),
                             subtitle: L("attributes.subtitle", items.count))

            Form {
                Section {
                    FCXLToggleRow(label: L("attributes.applyPermissions"),
                                  isOn: $applyPermissions, showDivider: applyPermissions)
                    if applyPermissions {
                        // The four modes that cover almost every real wish — one tap
                        // instead of nine checkboxes. The grid stays for the rest.
                        HStack(spacing: 6) {
                            ForEach([0o644, 0o755, 0o600, 0o777], id: \.self) { preset in
                                Button(String(format: "%03o", preset)) {
                                    perms = PosixPermissions(mode: preset)
                                }
                                .buttonStyle(FCXLChipButtonStyle(compact: true))
                                .focusEffectDisabled()
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                        PermissionsGridView(perms: $perms)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                    }
                }

                Section {
                    dateRow(L("attributes.applyModified"), isOn: $applyModified, date: $modifiedDate)
                    dateRow(L("attributes.applyCreated"), isOn: $applyCreated, date: $createdDate)
                }

                Section {
                    FCXLToggleRow(label: L("properties.hidden"), isOn: $hidden)
                    FCXLToggleRow(label: L("attributes.quarantine"),
                                  isOn: $quarantined, showDivider: false)
                }

                if hasFolders {
                    Section {
                        FCXLToggleRow(label: L("properties.applyToEnclosed"),
                                      isOn: $recursive, showDivider: false)
                    }
                }
            }
            .formStyle(.grouped)

            FCXLDialogButtonBar(
                primaryTitle: L("button.apply"),
                primaryEnabled: anythingToApply,
                primaryAction: { confirm() },
                cancelAction: { session.cancel() }
            )
        }
    }

    /// A switch, a date field and a "now" chip in one row. The picker only appears once the
    /// switch is on — a visible date next to an OFF switch reads as "this will be written".
    @ViewBuilder
    private func dateRow(_ label: String, isOn: Binding<Bool>, date: Binding<Date>) -> some View {
        FCXLToggleRow(label: label, isOn: isOn, showDivider: isOn.wrappedValue)
        if isOn.wrappedValue {
            HStack(spacing: 8) {
                DatePicker("", selection: date, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
                    .labelsHidden()
                Button(L("attributes.now")) { date.wrappedValue = Date() }
                    .buttonStyle(FCXLChipButtonStyle(compact: true))
                    .focusEffectDisabled()
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    private func confirm() {
        session.finish(FileOperationsService.AttributeChanges(
            permissionsMode: applyPermissions ? perms.mode : nil,
            modificationDate: applyModified ? modifiedDate : nil,
            creationDate: applyCreated ? createdDate : nil,
            hidden: hidden != originalHidden ? hidden : nil,
            quarantine: quarantined != originalQuarantined ? quarantined : nil,
            recursive: recursive && hasFolders
        ))
    }
}
