import AppKit
import FCXLBridgeObjC
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ArchivePackDialogResult {
    let archivePath: String
    let format: ArchiveFormat
    let compressionLevel: Int
    let preservePaths: Bool
    let includeSubfolders: Bool
    let deleteAfterPack: Bool
    let separateArchives: Bool
    /// AES-256, ZIP only; empty means an ordinary archive.
    var password: String = ""
}

struct ArchiveExtractDialogResult {
    let destinationPath: String
    let createSubfolder: Bool
    let overwriteExisting: Bool
}

enum SaveChangesDecision {
    case save
    case discard
    case cancel
}

/// Cross-thread result carrier for DialogService.blockingDialogOnMain.
private final class DialogResultBox<R>: @unchecked Sendable {
    var value: R?
}

@MainActor
final class DialogService {
    static let shared = DialogService()
    private let skipCancelConfirmationKey = "skipCancelConfirmation"

    // UserDefaults keys for "don't show dialog" settings
    static let skipCopyMoveDialogKey  = "skipCopyMoveDialog"
    static let skipDeleteDialogKey    = "skipDeleteDialog"
    static let skipPackDialogKey      = "skipPackDialog"
    static let skipExtractDialogKey   = "skipExtractDialog"

    private init() {}

    /// Run `body` on the main thread as a RUNLOOP callout and block the calling
    /// (background) thread until it returns. Unlike DispatchQueue.main.sync, the
    /// body is NOT a main-queue block — so a modal dialog shown inside it leaves
    /// the main queue free and its open animation can actually run (the AppKit
    /// animator delivers its frames through the main queue; see FCXLDialogKit).
    nonisolated static func blockingDialogOnMain<R>(_ body: @escaping @MainActor () -> R) -> R {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        let box = DialogResultBox<R>()
        let sema = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            box.value = MainActor.assumeIsolated { body() }
            sema.signal()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        sema.wait()
        return box.value!
    }

    func showInfo(title: String, message: String) {
        showAlert(style: .informational, title: title, message: message)
    }

    /// The editable properties window (info + hidden flag + permission grid). Returns only the
    /// things the user changed, or nil if they cancelled. Blocks like the other FCXL dialogs.
    func showFilePropertiesEditor(input: FilePropertiesInput) -> FilePropertiesEdit? {
        // Folders show one extra card ("apply to enclosed"); give them a touch more height.
        let height: CGFloat = input.isDirectory ? 620 : 580
        return FCXLDialog.runModal(size: NSSize(width: 480, height: height)) { session in
            FilePropertiesDialogView(session: session, input: input)
        }
    }

    func showWarning(title: String, message: String) {
        showAlert(style: .warning, title: title, message: message)
    }

    /// True when an error means "nothing went wrong — this was called off".
    ///
    /// Two different things arrive this way: the user answered no to a question, and the service
    /// found a problem it has ALREADY explained with its own dialog. Neither deserves a second
    /// window, and telling them apart from a real failure is what this exists for.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    /// Report a failed operation — unless it was merely cancelled.
    ///
    /// The check used to be copy-pasted at each call site, and the copy that mattered most was
    /// missing: copying to a folder that does not exist showed the real explanation and then a
    /// second window saying "cancelled by user", which the user had not done.
    func showOperationError(title: String, error: Error) {
        guard !Self.isCancellation(error) else { return }
        showError(title: title, message: error.localizedDescription)
    }

    func showError(title: String, message: String) {
        showAlert(style: .critical, title: title, message: message)
    }

    func showConfirmation(title: String, message: String) -> Bool {
        let result = FCXLMessageDialog.run(FCXLMessageConfig(
            title: title,
            message: message,
            // macOS order: the negative answer sits on the LEFT, the confirmation on the
            // RIGHT as the accent default. FCXLMessageDialog renders buttons left-to-right.
            buttons: [
                FCXLMessageButton(title: L("button.no"), kind: .normal),
                FCXLMessageButton(title: L("button.yes"), kind: .primary)
            ]
        ))
        return result.buttonIndex == 1
    }

    /// Confirmation with a custom (destructive-styled) primary button.
    /// Returns true if the user chose the primary action.
    /// Confirmation with both button titles supplied, for questions where "Yes/No" reads
    /// wrong — e.g. "Restart now" / "Later". Returns true when the primary was chosen.
    func showConfirmationCustom(title: String, message: String,
                                confirmTitle: String, cancelTitle: String) -> Bool {
        let result = FCXLMessageDialog.run(FCXLMessageConfig(
            title: title,
            message: message,
            // macOS order: the dismissive answer on the LEFT, the confirmation on the RIGHT.
            buttons: [
                FCXLMessageButton(title: cancelTitle, kind: .normal),
                FCXLMessageButton(title: confirmTitle, kind: .primary)
            ]
        ))
        return result.buttonIndex == 1
    }

    /// Confirmation with a custom (destructive-styled) primary button.
    func showDestructiveConfirmation(title: String, message: String,
                                     confirmTitle: String,
                                     icon: String? = nil, iconColor: Color? = nil) -> Bool {
        let result = FCXLMessageDialog.run(FCXLMessageConfig(
            title: title,
            message: message,
            icon: icon,
            iconColor: iconColor,
            // macOS order: the negative answer sits on the LEFT, the confirmation on the
            // RIGHT as the accent default. FCXLMessageDialog renders buttons left-to-right.
            buttons: [
                FCXLMessageButton(title: L("button.cancel"), kind: .normal),
                FCXLMessageButton(title: confirmTitle, kind: .destructive)
            ]
        ))
        // Index 1 is the destructive/confirm button (index 0 is Cancel). This was inverted,
        // so "Cancel" performed the destructive action (e.g. force-eject a busy disk).
        return result.buttonIndex == 1
    }

    func showSaveChangesConfirmation(title: String, message: String) -> SaveChangesDecision {
        let result = FCXLMessageDialog.run(FCXLMessageConfig(
            title: title,
            message: message,
            icon: "exclamationmark.triangle.fill",
            iconColor: .orange,
            // macOS order: the negative answer sits on the LEFT, the confirmation on the
            // RIGHT as the accent default. FCXLMessageDialog renders buttons left-to-right.
            buttons: [
                FCXLMessageButton(title: L("button.cancel"), kind: .normal),
                FCXLMessageButton(title: L("button.discard"), kind: .normal),
                FCXLMessageButton(title: L("button.save"), kind: .primary)
            ]
        ))
        switch result.buttonIndex {
        case 2:  return .save
        case 1:  return .discard
        default: return .cancel    // index 0 or ESC (nil)
        }
    }

    func showDeleteConfirmation(items: [FileItem], totalBytes: Int64 = 0) -> Bool {
        if UserDefaults.standard.bool(forKey: Self.skipDeleteDialogKey) {
            return true
        }

        let title = items.count == 1 ? L("delete.title.single") : L("delete.title.multiple")
        let result = FCXLMessageDialog.run(FCXLMessageConfig(
            title: title,
            message: deleteConfirmationText(items: items, totalBytes: totalBytes),
            icon: "trash.fill",
            iconColor: .red,
            // macOS order: the negative answer sits on the LEFT, the confirmation on the
            // RIGHT as the accent default. FCXLMessageDialog renders buttons left-to-right.
            buttons: [
                FCXLMessageButton(title: L("delete.cancel"), kind: .normal),
                FCXLMessageButton(title: L("delete.confirm"), kind: .destructive)
            ],
            checkboxTitle: L("dialog.dontShowAgain")
        ))
        let confirmed = result.buttonIndex == 1
        if confirmed && result.checkboxOn {
            UserDefaults.standard.set(true, forKey: Self.skipDeleteDialogKey)
        }
        return confirmed
    }

    /// Shift+Del confirmation. Unlike the ordinary delete dialog there is NO "don't ask again":
    /// this is the one action the app cannot undo, so the question is never skippable.
    func showPermanentDeleteConfirmation(items: [FileItem], totalBytes: Int64 = 0) -> Bool {
        let body = deleteConfirmationText(items: items, totalBytes: totalBytes)
        let result = FCXLMessageDialog.run(FCXLMessageConfig(
            title: L("delete.permanent.title"),
            message: L("delete.permanent.warning") + "\n\n" + body,
            icon: "flame.fill",
            iconColor: .red,
            // macOS order: negative on the LEFT, the destructive default on the RIGHT.
            buttons: [
                FCXLMessageButton(title: L("delete.cancel"), kind: .normal),
                FCXLMessageButton(title: L("delete.permanent.confirm"), kind: .destructive)
            ]
        ))
        return result.buttonIndex == 1
    }

    func showFileConflict(
        sourcePath: String,
        destinationPath: String
    ) -> (resolution: ConflictResolution, applyToAll: Bool) {
        let fileName = URL(fileURLWithPath: destinationPath).lastPathComponent

        // Source vs destination comparison, with "newer"/"larger" hints.
        let (srcBase, srcSize, srcDate) = ConflictSideInfo.make(
            label: L("conflict.sourceNew"), path: sourcePath)
        let (dstBase, dstSize, dstDate) = ConflictSideInfo.make(
            label: L("conflict.destinationExisting"), path: destinationPath)
        var srcHints: [String] = []
        var dstHints: [String] = []
        if let s = srcDate, let d = dstDate, s != d {
            if s > d { srcHints.append(L("conflict.hint.newer")) } else { dstHints.append(L("conflict.hint.newer")) }
        }
        if srcSize != dstSize {
            if srcSize > dstSize { srcHints.append(L("conflict.hint.larger")) } else { dstHints.append(L("conflict.hint.larger")) }
        }

        let choice: ConflictDialogChoice? = FCXLDialog.runModal(
            size: NSSize(width: 700, height: 300)
        ) { session in
            ConflictDialogView(
                session: session,
                fileName: fileName,
                source: srcBase.withHints(srcHints),
                destination: dstBase.withHints(dstHints)
            )
        }
        switch choice {
        case .replace:    return (.replace, false)
        case .replaceAll: return (.replace, true)
        case .createCopy: return (.copy, true)   // Create Copy applies to all
        case .skip:       return (.skip, false)
        case .skipAll:    return (.skip, true)
        case nil:         return (.cancel, false)
        }
    }

    func showTextInput(
        title: String,
        message: String,
        defaultValue: String,
        confirmButtonTitle: String = L("button.ok"),
        cancelButtonTitle: String = L("button.cancel"),
        selectNameOnly: Bool = false
    ) -> String? {
        let result = FCXLMessageDialog.run(FCXLMessageConfig(
            title: title,
            message: message,
            // macOS order: the negative answer sits on the LEFT, the confirmation on the
            // RIGHT as the accent default. FCXLMessageDialog renders buttons left-to-right.
            buttons: [
                FCXLMessageButton(title: cancelButtonTitle, kind: .normal),
                FCXLMessageButton(title: confirmButtonTitle, kind: .primary)
            ],
            textFieldInitial: defaultValue,
            selectNameOnly: selectNameOnly
        ))
        guard result.buttonIndex == 1 else { return nil }
        return result.text
    }

    func showFilePicker(title: String, defaultPath: String?, allowedTypes: [UTType] = []) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = L("button.select")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if !allowedTypes.isEmpty {
            panel.allowedContentTypes = allowedTypes
        }

        if let defaultPath,
           !defaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.directoryURL = URL(fileURLWithPath: defaultPath, isDirectory: true)
        }

        presentDialogWindow(panel)
        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }
        return selectedURL.path
    }

    func showFolderPicker(title: String, defaultPath: String?) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = L("button.select")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if let defaultPath,
           !defaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.directoryURL = URL(fileURLWithPath: defaultPath, isDirectory: true)
        }

        presentDialogWindow(panel)
        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }
        return selectedURL.path
    }

    func showSavePanel(title: String, defaultName: String, allowedTypes: [String]?) -> String? {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = L("button.save")
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = true

        if let allowedTypes {
            let contentTypes = allowedTypes.compactMap { rawType -> UTType? in
                let cleaned = rawType.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return UTType(filenameExtension: cleaned)
            }
            if !contentTypes.isEmpty {
                panel.allowedContentTypes = contentTypes
                panel.allowsOtherFileTypes = false
            }
        }

        presentDialogWindow(panel)
        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }
        return selectedURL.path
    }

    struct CopyMoveDialogResult {
        let destinationPath: String
        let renamedFileName: String?  // nil = keep original name
        /// F2 in the dialog: enqueue instead of running now.
        let sendToQueue: Bool
    }

    func showCopyMoveDialog(
        items: [FileItem],
        defaultDestination: String,
        isCopy: Bool
    ) -> CopyMoveDialogResult? {
        // If user chose "don't show", return default destination immediately
        if UserDefaults.standard.bool(forKey: Self.skipCopyMoveDialogKey) {
            return CopyMoveDialogResult(destinationPath: defaultDestination, renamedFileName: nil,
                                        sendToQueue: false)
        }

        // Settings-style dialog (FCXLDialog kit); blocks like the old NSAlert did.
        let height: CGFloat = items.count > 1 ? 480 : 400
        let selection: CopyMoveDialogSelection? = FCXLDialog.runModal(
            size: NSSize(width: 520, height: height)
        ) { session in
            CopyMoveDialogView(
                session: session,
                items: items,
                defaultDestination: defaultDestination,
                isCopy: isCopy
            )
        }
        guard let selection else { return nil }

        if selection.dontShowAgain {
            UserDefaults.standard.set(true, forKey: Self.skipCopyMoveDialogKey)
        }
        return CopyMoveDialogResult(
            destinationPath: selection.destinationPath,
            renamedFileName: selection.renamedFileName,
            sendToQueue: selection.sendToQueue
        )
    }

    /// The batch attributes dialog. Nil on cancel; an empty change set never comes back —
    /// the Apply button stays grey until at least one switch is on.
    func showChangeAttributesDialog(items: [FileItem]) -> FileOperationsService.AttributeChanges? {
        FCXLDialog.runModal(size: NSSize(width: 520, height: 560)) { session in
            ChangeAttributesDialogView(session: session, items: items)
        }
    }

    /// A new vault's name, ceiling and password. Nil on cancel.
    func showVaultCreate(folder: String) -> VaultCreateRequest? {
        FCXLDialog.runModal(size: NSSize(width: 540, height: 480)) { session in
            VaultCreateDialogView(session: session, folder: folder)
        }
    }

    /// The password for sealing files into age — typed twice. Nil on cancel.
    func showAgeEncrypt(subtitle: String) -> String? {
        FCXLDialog.runModal(size: NSSize(width: 460, height: 280)) { session in
            AgeEncryptDialogView(session: session, subtitle: subtitle)
        }
    }

    /// How to make a PDF out of the chosen files. Nil on cancel.
    func showPDFMake(paths: [String]) -> PDFMakeRequest? {
        FCXLDialog.runModal(size: NSSize(width: 560, height: 480)) { session in
            PDFMakeDialogView(session: session, paths: paths)
        }
    }

    /// How to take a PDF apart. Nil on cancel.
    func showPDFSplit(path: String, pageCount: Int) -> PDFSplitRequest? {
        FCXLDialog.runModal(size: NSSize(width: 540, height: 440)) { session in
            PDFSplitDialogView(session: session, path: path, pageCount: pageCount)
        }
    }

    /// How to turn the pages. Nil on cancel.
    func showPDFRotate(paths: [String], pageCount: Int) -> PDFRotateRequest? {
        FCXLDialog.runModal(size: NSSize(width: 520, height: 360)) { session in
            PDFRotateDialogView(session: session, paths: paths, pageCount: pageCount)
        }
    }

    /// The order to merge in, and what the result is called. Nil on cancel.
    func showPDFMerge(paths: [String]) -> PDFMergeRequest? {
        FCXLDialog.runModal(size: NSSize(width: 560, height: 460)) { session in
            PDFMergeDialogView(session: session, paths: paths)
        }
    }

    /// How to convert the chosen pictures. Nil on cancel.
    func showImageConvert(paths: [String]) -> ImageConversionService.Options? {
        FCXLDialog.runModal(size: NSSize(width: 640, height: 600)) { session in
            ImageConvertDialogView(session: session, paths: paths)
        }
    }

    /// What to take out of the chosen photographs. Nil on cancel.
    func showCleanMetadata(paths: [String]) -> CleanMetadataRequest? {
        FCXLDialog.runModal(size: NSSize(width: 540, height: 420)) { session in
            CleanMetadataDialogView(session: session, paths: paths)
        }
    }

    /// The text found inside the chosen files. The window does its own copying and saving, so
    /// the answer only says it was closed.
    @discardableResult
    func showTextRecognition(paths: [String]) -> Bool? {
        FCXLDialog.runModal(size: NSSize(width: 700, height: 540)) { session in
            TextRecognitionDialogView(session: session, paths: paths)
        }
    }

    /// The rules themselves. Nil on cancel; otherwise the whole list as it was left.
    func showFolderRulesEditor(rules: [FolderRule]) -> [FolderRule]? {
        FCXLDialog.runModal(size: NSSize(width: 800, height: 600)) { session in
            FolderRulesEditorView(session: session, rules: rules)
        }
    }

    /// What the rules would do here. Nil on cancel; otherwise the steps left ticked.
    func showFolderRulesApply(folder: String, steps: [RuleStep]) -> [RuleStep]? {
        FCXLDialog.runModal(size: NSSize(width: 680, height: 480)) { session in
            FolderRulesApplyView(session: session, folder: folder, steps: steps)
        }
    }

    /// The uninstall list. Nil on cancel; otherwise the paths the person left ticked.
    func showUninstallDialog(appPath: String, appName: String,
                             bundleID: String?) -> [String]? {
        FCXLDialog.runModal(size: NSSize(width: 640, height: 500)) { session in
            UninstallDialogView(session: session, appPath: appPath, appName: appName,
                                bundleID: bundleID)
        }
    }

    enum FileConflictChoice {
        case replace
        case makeCopy
        case cancel
    }

    struct FileConflictResult {
        let choice: FileConflictChoice
        let applyToAll: Bool
    }

    /// Shows a conflict dialog when a file already exists at the destination.
    /// - `allowReplace`: false when copying to same folder (replace makes no sense)
    /// - `showApplyToAll`: show "Replace All" / "Skip All" buttons (Total Commander style)
    func showFileConflictDialog(fileName: String, allowReplace: Bool, showApplyToAll: Bool = false) -> FileConflictResult {
        let choice: ConflictDialogChoice? = FCXLDialog.runModal(
            size: NSSize(width: showApplyToAll ? 700 : 520, height: 190)
        ) { session in
            ConflictDialogView(
                session: session,
                fileName: fileName,
                message: L("conflict.message"),
                allowReplace: allowReplace,
                showApplyToAll: showApplyToAll
            )
        }
        switch choice {
        case .replace:    return FileConflictResult(choice: .replace, applyToAll: false)
        case .replaceAll: return FileConflictResult(choice: .replace, applyToAll: true)
        case .createCopy: return FileConflictResult(choice: .makeCopy, applyToAll: showApplyToAll)
        case .skip:       return FileConflictResult(choice: .cancel, applyToAll: false)
        case .skipAll:    return FileConflictResult(choice: .cancel, applyToAll: true)
        case nil:         return FileConflictResult(choice: .cancel, applyToAll: false)
        }
    }

    /// Conflict dialog for archive operations. Returns the RAW choice: showFileConflictDialog
    /// collapses skip/skipAll into `.cancel`, which is fine for copy but not here — skipping
    /// one entry and aborting the whole extraction are different outcomes. "Create copy" is
    /// disabled because extraction cannot write an entry under another name.
    func showArchiveConflictDialog(fileName: String) -> ConflictDialogChoice? {
        FCXLDialog.runModal(size: NSSize(width: 700, height: 190)) { session in
            ConflictDialogView(
                session: session,
                fileName: fileName,
                message: L("conflict.message"),
                allowReplace: true,
                showApplyToAll: true,
                allowCreateCopy: false
            )
        }
    }

    /// Generate a unique copy name: "file.txt" → "file (копия).txt", "file (копия 2).txt", etc.
    static func generateCopyName(for originalName: String, in directory: String) -> String {
        let nsName = originalName as NSString
        let ext = nsName.pathExtension
        let baseName = ext.isEmpty ? originalName : nsName.deletingPathExtension

        var candidate = ext.isEmpty ? "\(baseName) \(L("file.copySuffix"))" : "\(baseName) \(L("file.copySuffix")).\(ext)"
        var counter = 2
        while FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(candidate)) {
            candidate = ext.isEmpty ? "\(baseName) \(L("file.copySuffixNumbered", counter))" : "\(baseName) \(L("file.copySuffixNumbered", counter)).\(ext)"
            counter += 1
        }
        return candidate
    }

    func showArchivePackDialog(
        defaultArchivePath: String,
        defaultFormat: ArchiveFormat,
        selectedItemsCount: Int
    ) -> ArchivePackDialogResult? {
        if UserDefaults.standard.bool(forKey: Self.skipPackDialogKey) {
            return ArchivePackDialogResult(
                archivePath: defaultArchivePath,
                format: defaultFormat,
                compressionLevel: defaultFormat.defaultCompressionLevel,
                preservePaths: true,
                includeSubfolders: true,
                deleteAfterPack: false,
                separateArchives: false
            )
        }
        return PackDialogController.run(
            defaultArchivePath: defaultArchivePath,
            defaultFormat: defaultFormat,
            selectedItemsCount: selectedItemsCount
        )
    }

    func showArchiveExtractDialog(
        defaultDestinationPath: String,
        createSubfolderDefault: Bool
    ) -> ArchiveExtractDialogResult? {
        if UserDefaults.standard.bool(forKey: Self.skipExtractDialogKey) {
            return ArchiveExtractDialogResult(
                destinationPath: defaultDestinationPath,
                createSubfolder: createSubfolderDefault,
                overwriteExisting: false
            )
        }

        // Settings-style dialog (FCXLDialog kit); blocks like the old NSAlert did.
        let selection: ExtractDialogSelection? = FCXLDialog.runModal(
            size: NSSize(width: 520, height: 400)
        ) { session in
            ExtractDialogView(
                session: session,
                defaultDestinationPath: defaultDestinationPath,
                createSubfolderDefault: createSubfolderDefault
            )
        }
        guard let selection else { return nil }

        if selection.dontShowAgain {
            UserDefaults.standard.set(true, forKey: Self.skipExtractDialogKey)
        }
        return ArchiveExtractDialogResult(
            destinationPath: selection.destinationPath,
            createSubfolder: selection.createSubfolder,
            overwriteExisting: selection.overwriteExisting
        )
    }

    func showProgress(
        title: String,
        message: String,
        cancelHandler: (() -> Void)?
    ) -> ProgressController {
        ProgressController(title: title, message: message, cancelHandler: cancelHandler)
    }

    func shouldConfirmProgressCancellation(
        operationTitle: String,
        filesDone: Int,
        filesTotal: Int
    ) -> Bool {
        if UserDefaults.standard.bool(forKey: skipCancelConfirmationKey) {
            return true
        }

        let result = FCXLMessageDialog.run(FCXLMessageConfig(
            title: L("cancel.title"),
            message: "\(L("cancel.message", operationTitle))\n\(L("cancel.processed", max(0, filesDone), max(0, filesTotal)))",
            icon: "exclamationmark.triangle.fill",
            iconColor: .orange,
            // Negative on the LEFT, confirmation on the RIGHT (macOS order).
            buttons: [
                FCXLMessageButton(title: L("cancel.no"), kind: .normal),
                FCXLMessageButton(title: L("cancel.yes"), kind: .destructive)
            ],
            checkboxTitle: L("cancel.dontAsk")
        ))
        let confirmed = result.buttonIndex == 1
        if confirmed && result.checkboxOn {
            UserDefaults.standard.set(true, forKey: skipCancelConfirmationKey)
        }
        return confirmed
    }

    private func showAlert(style: NSAlert.Style, title: String, message: String) {
        let icon: String
        let color: Color
        switch style {
        case .warning:  icon = "exclamationmark.triangle.fill"; color = .orange
        case .critical: icon = "exclamationmark.octagon.fill";  color = .red
        default:        icon = "info.circle.fill";              color = .accentColor
        }
        let config = FCXLMessageConfig(
            title: title,
            message: message,
            icon: icon,
            iconColor: color,
            buttons: [FCXLMessageButton(title: L("button.ok"), kind: .primary)]
        )
        // Info/warning/error alerts are fire-and-forget and are frequently raised from
        // inside a Task/GCD main-queue block (e.g. a failed async connect). Opening the
        // modal there parks the main queue and the dialog's SwiftUI rendering (the accent
        // OK button's fill) stalls for a beat. Enter via a runloop callout so the queue
        // stays free and the button paints immediately.
        fcxlPresentModal { _ = FCXLMessageDialog.run(config) }
    }

    private func activateAppForDialog() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentDialogWindow(_ window: NSWindow) {
        configureDialogWindow(window)
        activateAppForDialog()
        window.center()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    private func configureDialogWindow(_ window: NSWindow) {
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    private func deleteConfirmationText(items: [FileItem], totalBytes: Int64 = 0) -> String {
        guard !items.isEmpty else { return L("delete.none") }
        var header = L("delete.message", items.count)
        if totalBytes > 0 {
            let sizeText = ByteText.file(totalBytes)
            header += " (\(sizeText))"
        }

        let listedItems = items.prefix(5).map { "• \($0.name)" }.joined(separator: "\n")
        let additionalCount = items.count - min(items.count, 5)
        if additionalCount > 0 {
            return "\(header)\n\n\(listedItems)\n\(L("delete.andMore", additionalCount))"
        }
        return "\(header)\n\n\(listedItems)"
    }

    /// Shows NTFS write-permission dialog. Returns true if user approved.
    func showNTFSPermissionDialog(volumeName: String) -> Bool {
        let result = FCXLMessageDialog.run(FCXLMessageConfig(
            title: L("ntfs.title"),
            message: L("ntfs.message", volumeName),
            icon: "externaldrive.fill.badge.checkmark",
            iconColor: .accentColor,
            // Negative on the LEFT, confirmation on the RIGHT (macOS order).
            buttons: [
                FCXLMessageButton(title: L("button.cancel"), kind: .normal),
                FCXLMessageButton(title: L("ntfs.allow"), kind: .primary)
            ]
        ))
        return result.buttonIndex == 1
    }

    enum NTFSWriteApproval {
        case savedPassword   // verified + stored in Keychain → future writes are silent
        case enterEachTime   // proceed; the system password dialog will appear
        case cancelled
    }

    /// First-time NTFS write dialog: confirms the write AND offers to save the
    /// admin password so it isn't asked again — right here, without the user
    /// having to open Settings.
    func showNTFSSavePasswordDialog(volumeName: String) -> NTFSWriteApproval {
        let result = FCXLMessageDialog.run(FCXLMessageConfig(
            title: L("ntfs.save.title"),
            message: L("ntfs.save.message", volumeName),
            icon: "externaldrive.fill.badge.checkmark",
            iconColor: .accentColor,
            // Negative on the LEFT, confirmation on the RIGHT (macOS order).
            buttons: [
                FCXLMessageButton(title: L("button.cancel"), kind: .normal),
                FCXLMessageButton(title: L("ntfs.save.eachTime"), kind: .normal),
                FCXLMessageButton(title: L("ntfs.save.saveButton"), kind: .primary)
            ],
            textFieldInitial: "",
            textFieldPlaceholder: L("settings.ntfs.placeholder"),
            secureText: true
        ))

        switch result.buttonIndex {
        case 2:                       // Save (rightmost / default)
            let pw = result.text
            guard !pw.isEmpty else { return .enterEachTime }
            guard FCXLNTFSBridge.verifyAdminPassword(pw) else {
                showError(title: L("ntfs.save.wrongTitle"),
                          message: L("ntfs.save.wrongMessage"))
                return .enterEachTime
            }
            NTFSPasswordStore.save(pw)
            return .savedPassword
        case 1:
            return .enterEachTime
        default:
            return .cancelled
        }
    }

}

@MainActor
final class ProgressController {

    // MARK: - Static tracking (for F2 shortcut)

    private static var activeControllers: [ProgressController] = []

    /// True if any progress dialog can accept "Send to Queue".
    static var canSendToQueue: Bool {
        activeControllers.contains { $0.isQueueButtonVisible && !$0.isSentToQueue && !$0.isCancelled }
    }

    /// Trigger "Send to Queue" on the first eligible progress dialog.
    static func sendFirstToQueue() {
        guard let controller = activeControllers.first(where: {
            $0.isQueueButtonVisible && !$0.isSentToQueue && !$0.isCancelled
        }) else { return }
        controller.requestSendToQueue()
    }

    // MARK: - Properties

    private let operationTitle: String
    private let panel: NSPanel
    private let progressIndicator: FCXLProgressBar
    private let currentFileLabel: NSTextField
    private let percentLabel: NSTextField
    private let bytesLabel: NSTextField
    private let filesLabel: NSTextField
    /// Operation-specific line under the counters (pack: format, level, live estimate).
    private let detailLabel: NSTextField
    private let timeLabel: NSTextField
    /// While this is set, it takes the time line's place: an estimate of "time left" during a
    /// dead link counts down to a moment that will never come, and the person watching cannot
    /// tell a stalled transfer from a slow one.
    private var troubleText: String?
    private let cancelHandler: (() -> Void)?
    private let startedAt: Date
    private var timer: Timer?
    private var f2KeyMonitor: Any?
    private(set) var isCancelled: Bool = false

    // Real pause support. The worker blocks inside waitWhilePaused() (called from the archive
    // progress callback), which is what lets us freeze an operation while a question is on
    // screen. NSLock + semaphore because the worker is a background thread.
    // nonisolated(unsafe) + NSLock: the worker thread must read these, and the lock is what
    // actually makes that safe (the class itself is main-actor bound).
    nonisolated(unsafe) private var pausedFlag = false
    private let pauseLock = NSLock()
    private let pauseSemaphore = DispatchSemaphore(value: 0)

    /// Freeze/resume the running operation.
    func setPaused(_ paused: Bool) {
        pauseLock.lock()
        pausedFlag = paused
        pauseLock.unlock()
        if !paused { pauseSemaphore.signal() }
    }

    nonisolated var isPausedFlagValue: Bool {
        pauseLock.lock()
        defer { pauseLock.unlock() }
        return pausedFlag
    }

    /// Blocks the calling (worker) thread while paused. Cancellation is not consulted here —
    /// cancelling always unpauses first, and the archive layer checks its own cancel flag.
    nonisolated func waitWhilePausedImpl() -> Bool {
        while isPausedFlagValue {
            _ = pauseSemaphore.wait(timeout: .now() + 0.1)
        }
        return false
    }
    private(set) var isSentToQueue: Bool = false
    /// Called when user clicks "Send to queue". The closure receives the current reporter
    /// and must return true if the operation was successfully enqueued.
    var onSendToQueue: (() -> Bool)?
    /// Settings-style bottom button bar ([Queue | Cancel]), shared FCXLDialog look.
    private var buttonBarHost: NSHostingView<ProgressButtonBar>?
    private(set) var isQueueButtonVisible = false
    private(set) var lastProgress: Double = 0
    private(set) var lastBytesDone: Int64 = 0
    private(set) var lastBytesTotal: Int64 = 0
    private(set) var lastFilesDone: Int = 0
    private(set) var lastFilesTotal: Int = 0

    /// Public accessors for current progress state (used by send-to-queue).
    var lastProgressValue: Double { lastProgress }
    var lastBytesDoneValue: Int64 { lastBytesDone }
    var lastBytesTotalValue: Int64 { lastBytesTotal }
    var lastFilesDoneValue: Int { lastFilesDone }
    var lastFilesTotalValue: Int { lastFilesTotal }
    var window: NSWindow { panel }

    init(title: String, message: String, cancelHandler: (() -> Void)?) {
        operationTitle = title
        self.cancelHandler = cancelHandler
        startedAt = Date()
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 272),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior.insert(.moveToActiveSpace)

        let contentView = NSView(frame: panel.contentView?.bounds ?? .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = contentView

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        currentFileLabel = NSTextField(labelWithString: L("progress.currentFile", message))
        currentFileLabel.lineBreakMode = .byTruncatingMiddle
        currentFileLabel.translatesAutoresizingMaskIntoConstraints = false

        percentLabel = NSTextField(labelWithString: "0%")
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false

        bytesLabel = NSTextField(labelWithString: L("progress.bytesProgress", "—", "—"))
        bytesLabel.translatesAutoresizingMaskIntoConstraints = false

        filesLabel = NSTextField(labelWithString: L("progress.filesProgress", 0, 0))
        filesLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel = NSTextField(labelWithString: "")
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        timeLabel = NSTextField(labelWithString: "\(L("progress.elapsed", "00:00"))    \(L("progress.estimating"))")
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator = FCXLProgressBar()
        progressIndicator.isIndeterminate = false
        progressIndicator.value = 0
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        // Bottom bar in the shared FCXLDialog style: full-width, 48pt, equal-width
        // segments ([Queue | Cancel]); the queue segment appears only when enabled.
        let barHost = NSHostingView(rootView: ProgressButtonBar(
            showQueue: false,
            onQueue: { },
            onCancel: { }
        ))
        barHost.translatesAutoresizingMaskIntoConstraints = false
        buttonBarHost = barHost

        contentView.addSubview(titleLabel)
        contentView.addSubview(progressIndicator)
        contentView.addSubview(currentFileLabel)
        contentView.addSubview(percentLabel)
        contentView.addSubview(bytesLabel)
        contentView.addSubview(filesLabel)
        contentView.addSubview(detailLabel)
        contentView.addSubview(timeLabel)
        contentView.addSubview(barHost)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),

            progressIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            progressIndicator.trailingAnchor.constraint(equalTo: percentLabel.leadingAnchor, constant: -10),
            progressIndicator.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            progressIndicator.heightAnchor.constraint(equalToConstant: 14),

            percentLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            percentLabel.centerYAnchor.constraint(equalTo: progressIndicator.centerYAnchor),
            percentLabel.widthAnchor.constraint(equalToConstant: 52),

            currentFileLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            currentFileLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            currentFileLabel.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 12),

            bytesLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            bytesLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            bytesLabel.topAnchor.constraint(equalTo: currentFileLabel.bottomAnchor, constant: 10),

            filesLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            filesLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            filesLabel.topAnchor.constraint(equalTo: bytesLabel.bottomAnchor, constant: 8),

            detailLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            detailLabel.topAnchor.constraint(equalTo: filesLabel.bottomAnchor, constant: 8),

            timeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            timeLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 8),

            barHost.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            barHost.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            barHost.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            barHost.heightAnchor.constraint(equalToConstant: 49)
        ])

        // Now that self is fully initialized, wire the bar buttons to the controller.
        rebuildButtonBar()

        panel.center()
        panel.initialFirstResponder = nil
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Self.activeControllers.append(self)

        // F2 shortcut → send to queue (only when this panel has focus)
        f2KeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 120, // F2
                  self.panel.isKeyWindow,
                  self.isQueueButtonVisible,
                  !self.isSentToQueue, !self.isCancelled else { return event }
            self.requestSendToQueue()
            return nil
        }

        let newTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateTimeLabel()
            }
        }
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
        updateTimeLabel()
    }

    func setIndeterminate(_ value: Bool) {
        progressIndicator.isIndeterminate = value
        percentLabel.isHidden = value
        bytesLabel.isHidden = value
        filesLabel.isHidden = value
        timeLabel.isHidden = value
        if value {
            // Своя полоска сама заводит бегунок при isIndeterminate — гонять нечего.
        } else {
            progressIndicator.value = 0
        }
    }

    func update(
        currentFile: String,
        progress: Double,
        bytesDone: Int64,
        bytesTotal: Int64,
        filesDone: Int,
        filesTotal: Int
    ) {
        let clamped = min(max(progress, 0.0), 1.0)
        progressIndicator.value = clamped
        currentFileLabel.stringValue = L("progress.currentFile", currentFile)
        percentLabel.stringValue = "\(Int((clamped * 100).rounded()))%"

        let doneText = ByteText.file(max(0, bytesDone))
        let totalText = bytesTotal > 0
            ? ByteText.file(bytesTotal)
            : "—"
        bytesLabel.stringValue = L("progress.bytesProgress", doneText, totalText)
        filesLabel.stringValue = L("progress.filesProgress", max(0, filesDone), max(0, filesTotal))

        lastProgress = clamped
        lastBytesDone = bytesDone
        lastBytesTotal = bytesTotal
        lastFilesDone = filesDone
        lastFilesTotal = filesTotal
        // NOT cleared here: during a dead link the progress callback keeps firing once a
        // second with the very same byte count, and clearing on that would blink the warning
        // out of existence the moment it appeared. The transfer says when it is over.
        updateTimeLabel()
    }

    /// The pack path calls this on every progress tick; anything else never does, and the label
    /// stays an empty line. NOT hidden by setIndeterminate — the format and level are known
    /// before the totals are, and that is exactly when the user reads them.
    func setDetail(_ text: String) {
        detailLabel.stringValue = text
    }

    /// Raise the trouble line (or lower it with nil). Painted in warning colour so a glance is
    /// enough to tell "waiting on a dead link" from "working".
    func setTrouble(_ text: String?) {
        troubleText = text
        timeLabel.textColor = text == nil ? .labelColor : .systemOrange
        updateTimeLabel()
    }

    func update(progress: Double, message: String) {
        update(
            currentFile: message,
            progress: progress,
            bytesDone: lastBytesDone,
            bytesTotal: lastBytesTotal,
            filesDone: lastFilesDone,
            filesTotal: lastFilesTotal
        )
    }

    func close() {
        timer?.invalidate()
        timer = nil
        if let monitor = f2KeyMonitor {
            NSEvent.removeMonitor(monitor)
            f2KeyMonitor = nil
        }
        Self.activeControllers.removeAll { $0 === self }
        panel.orderOut(nil)
        panel.close()
    }

    private func updateTimeLabel() {
        if let troubleText {
            timeLabel.stringValue = troubleText
            return
        }
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let elapsedText = Self.formatDuration(seconds: elapsed)
        if lastProgress < 0.05 {
            timeLabel.stringValue = "\(L("progress.elapsed", elapsedText))    \(L("progress.estimating"))"
            return
        }

        let remainingSeconds = Int((Double(elapsed) * (1.0 - lastProgress) / max(lastProgress, 0.0001)).rounded())
        let remainingText = Self.formatDuration(seconds: max(0, remainingSeconds))
        timeLabel.stringValue = "\(L("progress.elapsed", elapsedText))    \(L("progress.remaining", remainingText))"
    }

    private static func formatDuration(seconds: Int) -> String {
        let safe = max(0, seconds)
        let minutes = safe / 60
        let secondsPart = safe % 60
        return String(format: "%02d:%02d", minutes, secondsPart)
    }

    /// Show the "Send to queue" button. Call after setting `onSendToQueue`.
    func showSendToQueueButton() {
        isQueueButtonVisible = true
        rebuildButtonBar()
    }

    /// Re-render the bottom bar with the current queue-button visibility.
    private func rebuildButtonBar() {
        buttonBarHost?.rootView = ProgressButtonBar(
            showQueue: isQueueButtonVisible,
            onQueue: { [weak self] in self?.requestSendToQueue() },
            onCancel: { [weak self] in self?.requestCancel() }
        )
    }

    func requestSendToQueue() {
        guard !isSentToQueue, !isCancelled else { return }
        if let handler = onSendToQueue, handler() {
            isSentToQueue = true
            // Close the progress dialog — the queue panel takes over
            close()
        }
    }

    private func requestCancel() {
        if isCancelled {
            return
        }
        // This runs from the progress window's OWN SwiftUI button — i.e. a modal opened from
        // inside a modal whose run loop is already parked. Presented directly, the nested
        // confirmation appears but its buttons never receive input: the user cannot cancel,
        // cannot dismiss, and is left force-quitting a running archive write. Enter through
        // the runloop callout, like every other modal-from-modal in the app.
        // Freeze the work while we ask. Otherwise the operation runs on — and, since adding a
        // file takes a fraction of a second, usually FINISHES — while the question is still on
        // screen, so "yes, cancel" answers something already moot and the file is in the
        // archive anyway. Resumed on either answer.
        setPaused(true)
        fcxlPresentModal { [weak self] in
            guard let self else { return }
            defer { self.setPaused(false) }
            guard !self.isCancelled else { return }
            let confirmed = DialogService.shared.shouldConfirmProgressCancellation(
                operationTitle: self.operationTitle,
                filesDone: self.lastFilesDone,
                filesTotal: self.lastFilesTotal
            )
            guard confirmed else { return }          // "no, continue" → unpaused by the defer
            self.isCancelled = true
            self.cancelHandler?()
        }
    }
}

/// Bottom bar of the progress window, in the shared FCXLDialog style: full-width
/// 48pt equal segments ([В очередь | Отмена]). Deliberately NO accent/default
/// button — Return must never cancel a running operation; ESC still cancels.
struct ProgressButtonBar: View {
    let showQueue: Bool
    let onQueue: () -> Void
    let onCancel: () -> Void

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                if showQueue {
                    // Accent on purpose: of the two, this is the productive one — the work
                    // continues, just out of the way. It still does NOT answer Return: no key
                    // may fire a button by accident while gigabytes are mid-flight.
                    Button(action: onQueue) { barLabel(L("button.sendToQueue")) }
                        .buttonStyle(FCXLDialogPrimaryButtonStyle(
                            accent: accent,
                            textColor: PanelAppearanceSettings.contrastingTextColor(on: accent),
                            fontSize: 13))
                        .focusEffectDisabled()
                    Divider().frame(height: 48)
                }
                Button(action: onCancel) { barLabel(L("button.cancel")) }
                    .buttonStyle(FCXLDialogSecondaryButtonStyle(fontSize: 13))
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func barLabel(_ title: String) -> some View {
        Text(title)
            .lineLimit(1)
            .padding(.horizontal, 4)
    }
}

