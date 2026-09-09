import AppKit
import SwiftUI

/// What the copy/move dialog hands back to DialogService (pref writing happens there).
struct CopyMoveDialogSelection {
    let destinationPath: String
    let renamedFileName: String?   // nil = keep the original name
    let dontShowAgain: Bool
    /// F2, Total Commander's oldest habit: do not run the operation now — put it in the
    /// queue and give the hands back. Same destination, same items, different tempo.
    let sendToQueue: Bool
}

/// Settings-style F5/F6 dialog: what is being copied/moved, where to, and the
/// occasional single-file rename — grouped form cards + accent action bar.
struct CopyMoveDialogView: View {
    let session: FCXLDialogSession<CopyMoveDialogSelection>
    let items: [FileItem]
    let isCopy: Bool

    @State private var fileName: String
    @State private var destination: String
    @State private var dontShowAgain = false
    /// The F2 listener. Owned by this dialog alone and taken down with it — the app-wide
    /// lesson about NSEvent monitors: one owner, one removal.
    @State private var f2Monitor: Any?

    init(session: FCXLDialogSession<CopyMoveDialogSelection>,
         items: [FileItem],
         defaultDestination: String,
         isCopy: Bool) {
        self.session = session
        self.items = items
        self.isCopy = isCopy
        _fileName = State(initialValue: items.count == 1 ? (items.first?.name ?? "") : "")
        _destination = State(initialValue: defaultDestination)
    }

    private var actionName: String { isCopy ? L("button.copy") : L("button.move") }
    private var title: String { isCopy ? L("copy.title", items.count) : L("move.title", items.count) }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: title)

            Form {
                Section(items.count == 1 ? L("copy.file") : L("copy.files")) {
                    if items.count == 1 {
                        // Single file: the name is editable (rename-on-copy), with the
                        // base name pre-selected like in the old dialog.
                        FCXLDialogTextField(
                            text: $fileName,
                            focusOnAppear: true,
                            initialSelection: .baseName,
                            onSubmit: { confirm() },
                            onCancel: { session.cancel() }
                        )
                    } else {
                        ForEach(items.prefix(5), id: \.path) { item in
                            Label {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                            } icon: {
                                Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if items.count > 5 {
                            Text(L("delete.andMore", items.count - 5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(L("copy.destinationFolder")) {
                    HStack(spacing: 8) {
                        FCXLDialogTextField(
                            text: $destination,
                            placeholder: L("copy.destination"),
                            onSubmit: { confirm() },
                            onCancel: { session.cancel() }
                        )
                        Button("\(L("button.select"))…") {
                            fcxlPresentModal {
                                if let picked = DialogService.shared.showFolderPicker(
                                    title: L("copy.selectFolder"),
                                    defaultPath: destination
                                ) {
                                    destination = picked
                                }
                            }
                        }
                        .buttonStyle(FCXLChipButtonStyle(compact: true))
                    }
                }

                Section {
                    Toggle(L("dialog.dontShowAgain"), isOn: $dontShowAgain)
                }
            }
            .formStyle(.grouped)

            FCXLDialogMultiButtonBar(buttons: [
                FCXLDialogBarButton(title: L("button.cancel")) { session.cancel() },
                FCXLDialogBarButton(title: L("dialog.toQueue"), enabled: destinationFilled) {
                    confirm(toQueue: true)
                },
                FCXLDialogBarButton(title: actionName, role: .primary, enabled: destinationFilled) {
                    confirm()
                },
            ])
        }
        .onAppear {
            // F2 = the middle button. A keyboard habit from Total Commander, so it must not
            // require reaching for the mouse — that is its whole point.
            f2Monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 120 {   // F2
                    confirm(toQueue: true)
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let f2Monitor {
                NSEvent.removeMonitor(f2Monitor)
                self.f2Monitor = nil
            }
        }
    }

    private var destinationFilled: Bool {
        !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func confirm(toQueue: Bool = false) {
        let path = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        // A rename only makes sense for a single item, and only if it changed.
        let newName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalName = items.count == 1 ? items[0].name : nil
        let renamed = (items.count == 1 && !newName.isEmpty && newName != originalName) ? newName : nil

        session.finish(CopyMoveDialogSelection(
            destinationPath: path,
            renamedFileName: renamed,
            dontShowAgain: dontShowAgain,
            sendToQueue: toQueue
        ))
    }
}
