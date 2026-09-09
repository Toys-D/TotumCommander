import AppKit
import SwiftUI

// MARK: - Pack dialog (settings-style)

/// Settings-style archive pack dialog. All the archive-name logic (extension
/// normalization, base-name selection) still lives in PackDialogController's
/// static helpers — this is only the presentation layer.
struct PackDialogView: View {
    let session: FCXLDialogSession<ArchivePackDialogResult>
    let selectedItemsCount: Int

    @State private var archiveName: String
    @State private var folderPath: String
    @State private var format: ArchiveFormat
    @State private var compressionLevel: Double = 6
    @State private var preservePaths = true
    @State private var includeSubfolders = true
    @State private var deleteAfterPack = false
    @State private var separateArchives = false
    @State private var dontShowAgain = false
    @State private var password = ""
    @State private var passwordRepeat = ""

    init(session: FCXLDialogSession<ArchivePackDialogResult>,
         defaultArchivePath: String,
         defaultFormat: ArchiveFormat,
         selectedItemsCount: Int) {
        self.session = session
        self.selectedItemsCount = selectedItemsCount
        // Split the incoming path into folder + file name (same as the old dialog).
        let nsPath = defaultArchivePath as NSString
        let folder = defaultArchivePath.contains("/") ? nsPath.deletingLastPathComponent : ""
        let name = defaultArchivePath.contains("/") ? nsPath.lastPathComponent : defaultArchivePath
        _folderPath = State(initialValue: folder)
        _archiveName = State(initialValue: PackDialogController.normalizedArchiveName(name, format: defaultFormat))
        _format = State(initialValue: defaultFormat)
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("window.pack.title"),
                             subtitle: L("pack.header", selectedItemsCount))

            Form {
                Section {
                    LabeledContent(L("pack.archiveName")) {
                        FCXLDialogTextField(
                            text: $archiveName,
                            placeholder: "archive.zip",
                            focusOnAppear: true,
                            initialSelection: .baseName,
                            onSubmit: { confirm() },
                            onCancel: { session.cancel() }
                        )
                    }
                    LabeledContent(L("pack.folderPath")) {
                        HStack(spacing: 8) {
                            FCXLDialogTextField(
                                text: $folderPath,
                                placeholder: "/path/to/folder",
                                onSubmit: { confirm() },
                                onCancel: { session.cancel() }
                            )
                            Button("\(L("button.select"))…") {
                                fcxlPresentModal {
                                    if let picked = DialogService.shared.showFolderPicker(
                                        title: L("pack.browseFolder"),
                                        defaultPath: folderPath.isEmpty ? nil : folderPath
                                    ) {
                                        folderPath = picked
                                    }
                                }
                            }
                            .buttonStyle(FCXLChipButtonStyle(compact: true))
                        }
                    }
                }

                Section(L("pack.format")) {
                    // A menu, not segments: ten formats do not fit a 500pt segmented control,
                    // and Keka's list is the shape people already know. Our own picker, so the
                    // popup highlight follows the app accent, not the system one.
                    LabeledContent(L("pack.format")) {
                        FCXLDialogMenuPicker(items: ArchiveFormat.allCases,
                                             selection: $format,
                                             title: \.displayName)
                    }
                    .onChange(of: format) { newFormat in
                        // Keep the file extension in step with the chosen format.
                        archiveName = PackDialogController.normalizedArchiveName(archiveName, format: newFormat)
                        // Each codec has its own sensible default — bzip2 lives at 9 where
                        // lz4 lives at 1; keeping the old number would misrepresent both.
                        compressionLevel = Double(newFormat.defaultCompressionLevel)
                    }
                    HStack {
                        Text(L("pack.compression"))
                        // No `step:` — it makes macOS draw tick marks, which is the system
                        // look, not ours. Our sliders (Settings) are plain and continuous;
                        // the value is rounded to an integer where it's read instead.
                        Slider(value: $compressionLevel, in: 0...9)
                        Text("\(Int(compressionLevel.rounded()))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 24, alignment: .trailing)
                    }
                    // TAR and ISO are plain containers: nothing in them compresses, and a live
                    // slider would promise a knob that turns nothing.
                    .disabled(!format.supportsCompressionLevel)
                    .opacity(format.supportsCompressionLevel ? 1 : 0.4)
                }

                // A password never applies silently: the section is shown for the one format
                // that can honour it, and the archive is refused elsewhere anyway.
                if format == .zip || format == .dmg {
                    Section(L("pack.password.section")) {
                        FCXLRevealablePasswordField(placeholder: L("pack.password.field"),
                                                    text: $password)
                        FCXLRevealablePasswordField(placeholder: L("pack.password.repeat"),
                                                    text: $passwordRepeat)
                        if !password.isEmpty && password != passwordRepeat {
                            Text(L("pack.password.mismatch"))
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        if !password.isEmpty {
                            // The two formats keep different secrets: a zip hides contents but
                            // not names; a DMG hides the lot.
                            Text(L(format == .dmg ? "pack.password.note.dmg" : "pack.password.note"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(L("pack.settings")) {
                    Toggle(L("pack.preservePaths"), isOn: $preservePaths)
                    Toggle(L("pack.includeSubfolders"), isOn: $includeSubfolders)
                    Toggle(L("pack.deleteAfterPack"), isOn: $deleteAfterPack)
                    Toggle(L("pack.separateArchives"), isOn: $separateArchives)
                }

                Section {
                    Toggle(L("dialog.dontShowAgain"), isOn: $dontShowAgain)
                }
            }
            .formStyle(.grouped)

            FCXLDialogButtonBar(
                primaryTitle: L("button.ok"),
                // A typo in a password would lock the archive against its own author — OK waits
                // for the two fields to agree.
                primaryEnabled: password.isEmpty || password == passwordRepeat,
                primaryAction: { confirm() },
                cancelAction: { session.cancel() }
            )
        }
    }

    private func confirm() {
        let folder = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = PackDialogController.normalizedArchiveName(archiveName, format: format)
        let archivePath = folder.isEmpty ? name : (folder as NSString).appendingPathComponent(name)

        if dontShowAgain {
            UserDefaults.standard.set(true, forKey: DialogService.skipPackDialogKey)
        }
        session.finish(ArchivePackDialogResult(
            archivePath: archivePath,
            format: format,
            compressionLevel: Int(compressionLevel.rounded()),
            preservePaths: preservePaths,
            includeSubfolders: includeSubfolders,
            deleteAfterPack: deleteAfterPack,
            separateArchives: separateArchives,
            password: (format == .zip || format == .dmg) ? password : ""
        ))
    }
}

// MARK: - Extract dialog (settings-style)

/// What the extract dialog hands back (pref writing happens in DialogService).
struct ExtractDialogSelection {
    let destinationPath: String
    let createSubfolder: Bool
    let overwriteExisting: Bool
    let dontShowAgain: Bool
}

struct ExtractDialogView: View {
    let session: FCXLDialogSession<ExtractDialogSelection>

    @State private var destination: String
    @State private var createSubfolder: Bool
    @State private var overwriteExisting = false
    @State private var dontShowAgain = false

    init(session: FCXLDialogSession<ExtractDialogSelection>,
         defaultDestinationPath: String,
         createSubfolderDefault: Bool) {
        self.session = session
        _destination = State(initialValue: defaultDestinationPath)
        _createSubfolder = State(initialValue: createSubfolderDefault)
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("window.unpack.title"),
                             subtitle: L("unpack.description"))

            Form {
                Section(L("unpack.destination")) {
                    HStack(spacing: 8) {
                        FCXLDialogTextField(
                            text: $destination,
                            focusOnAppear: true,
                            initialSelection: .all,
                            onSubmit: { confirm() },
                            onCancel: { session.cancel() }
                        )
                        Button("\(L("button.select"))…") {
                            fcxlPresentModal {
                                if let picked = DialogService.shared.showFolderPicker(
                                    title: L("unpack.selectFolder"),
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
                    Toggle(L("unpack.createSubfolder"), isOn: $createSubfolder)
                    Toggle(L("unpack.overwrite"), isOn: $overwriteExisting)
                }

                Section {
                    Toggle(L("dialog.dontShowAgain"), isOn: $dontShowAgain)
                }
            }
            .formStyle(.grouped)

            FCXLDialogButtonBar(
                primaryTitle: L("button.unpack"),
                primaryEnabled: !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                primaryAction: { confirm() },
                cancelAction: { session.cancel() }
            )
        }
    }

    private func confirm() {
        let path = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        session.finish(ExtractDialogSelection(
            destinationPath: path,
            createSubfolder: createSubfolder,
            overwriteExisting: overwriteExisting,
            dontShowAgain: dontShowAgain
        ))
    }
}
