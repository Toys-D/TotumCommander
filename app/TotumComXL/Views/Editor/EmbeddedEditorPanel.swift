import SwiftUI
import WebKit

/// Embedded Monaco editor that replaces the opposite panel.
/// Full-featured — same capabilities as the standalone editor window.
struct EmbeddedEditorPanel: View {
    let filePath: String
    /// Where the file came from — `.fileSystem` for a normal file, `.archive(...)` when it was
    /// extracted from an archive (then `filePath` is the temp copy and close offers write-back).
    var source: EditorDocumentSource = .fileSystem
    /// Needed for the archive write-back on close; unused for plain files.
    var operations: FileOperationsService?
    let onClose: () -> Void
    /// Reports the unsaved (dirty) state outward so the disk-eject flow can warn about it.
    var onDirtyChange: ((Bool) -> Void)? = nil
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    @State private var isDirty = false
    @State private var statusText = L("editor.status.initial")
    @StateObject private var controller = EmbeddedMonacoState()

    @State private var wordWrap = true
    @State private var minimapOn = true
    @State private var whitespaceMode = 0
    @State private var lineHighlightMode = 0
    @State private var fontSize = 13
    @State private var selectedFont = "SF Mono"
    // Keyed by the Monaco theme ID, never by the display name: the names are localized now,
    // so a name-based selection would match nothing as soon as the UI language changes.
    @State private var selectedTheme = "vs-dark"
    @State private var selectedLang = "Text"

    // Use shared lists from MonacoEditorController
    private static var fonts: [String] { MonacoEditorController.editorFonts }
    private static var themes: [(name: String, id: String)] { MonacoEditorController.editorThemes }
    private static var languages: [(name: String, id: String)] { MonacoEditorController.editorLanguages }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar: filename + save + close
            HStack(spacing: 6) {
                Text(URL(fileURLWithPath: filePath).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isDirty {
                    Text("•").foregroundColor(.orange)
                }
                Spacer()
                Button {
                    controller.save(to: filePath) { saved in
                        if saved { isDirty = false }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless).controlSize(.small)
                .disabled(!isDirty).help(L("editor.save.tooltip"))

                Button {
                    handleClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless).controlSize(.small).help(L("common.close"))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)

            Divider()

            // Toolbar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // Font
                    FCXLDialogMenuPicker(items: Self.fonts, selection: $selectedFont,
                                         title: { $0 }, compact: true, chipWidth: 78)
                    .onChange(of: selectedFont) { name in
                        let escaped = MonacoEditorController.escapeForJSString(name)
                        controller.monaco?.webView.evaluateJavaScript("editor.updateOptions({ fontFamily: '\(escaped)' })")
                    }

                    // Font size
                    Text("\(fontSize)")
                        .font(.system(size: 11).monospacedDigit())
                        .frame(width: 22)
                    Button { fontSize = max(8, fontSize - 1); controller.monaco?.setFontSize(fontSize) } label: {
                        Image(systemName: "minus")
                    }.buttonStyle(.borderless).controlSize(.mini)
                    Button { fontSize = min(72, fontSize + 1); controller.monaco?.setFontSize(fontSize) } label: {
                        Image(systemName: "plus")
                    }.buttonStyle(.borderless).controlSize(.mini)

                    Divider().frame(height: 16)

                    // Theme
                    FCXLDialogMenuPicker(items: Self.themes.map(\.id), selection: $selectedTheme,
                                         title: { id in Self.themes.first { $0.id == id }?.name ?? id },
                                         compact: true, chipWidth: 68)
                    .onChange(of: selectedTheme) { id in
                        controller.monaco?.setTheme(id)
                    }

                    Divider().frame(height: 16)

                    // Action buttons
                    toolbarButton("magnifyingglass", tip: L("editor.toolbar.find")) { controller.monaco?.showFind() }
                    toolbarButton("arrow.2.squarepath", tip: L("editor.toolbar.replace")) { controller.monaco?.showReplace() }

                    Divider().frame(height: 16)

                    // Toggle buttons
                    toolbarToggle("text.word.spacing", tip: L("editor.toolbar.wordWrap"), isOn: wordWrap) {
                        wordWrap.toggle(); controller.monaco?.toggleWordWrap(wordWrap)
                    }
                    toolbarToggle("paragraphsign", tip: L("editor.toolbar.whitespace"), isOn: whitespaceMode > 0) {
                        whitespaceMode = (whitespaceMode + 1) % 3
                        controller.monaco?.toggleWhitespace(["none", "boundary", "all"][whitespaceMode])
                    }
                    toolbarToggle("sidebar.right", tip: L("editor.toolbar.minimap"), isOn: minimapOn) {
                        minimapOn.toggle(); controller.monaco?.toggleMinimap(minimapOn)
                    }
                    toolbarToggle("line.3.horizontal", tip: L("editor.toolbar.lineHighlight"), isOn: lineHighlightMode > 0) {
                        lineHighlightMode = (lineHighlightMode + 1) % 4
                        controller.monaco?.webView.evaluateJavaScript(
                            "toggleLineHighlight('\(["none","gutter","line","all"][lineHighlightMode])')")
                    }

                    Divider().frame(height: 16)

                    // Language
                    FCXLDialogMenuPicker(items: Self.languages.map(\.name), selection: $selectedLang,
                                         title: { $0 }, compact: true, chipWidth: 72)
                    .onChange(of: selectedLang) { name in
                        if let l = Self.languages.first(where: { $0.name == name }) {
                            controller.monaco?.setLanguage(l.id)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: 30)

            Divider()

            // Monaco WebView
            EmbeddedMonacoWebView(
                filePath: filePath,
                controller: controller,
                isDirty: $isDirty,
                statusText: $statusText
            )

            // Status bar
            HStack {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
        .onAppear {
            controller.source = source
            let lang = MonacoEditorController.detectLanguage(for: filePath)
            if let match = Self.languages.first(where: { $0.id == lang }) {
                selectedLang = match.name
            }
        }
        .onChange(of: isDirty) { newDirty in onDirtyChange?(newDirty) }
        .onReceive(NotificationCenter.default.publisher(for: .fcxlRequestEditorClose)) { _ in
            handleClose()
        }
    }

    // MARK: - Helpers

    private func handleClose() {
        Task { @MainActor in
            // 1. Offer to save the unsaved buffer (to the temp file when this is an archive).
            if isDirty {
                let decision = await fcxlPresentModalAsync {
                    DialogService.shared.showSaveChangesConfirmation(
                        title: L("editor.saveChanges.title"),
                        message: L("editor.saveChanges.message"))
                }
                switch decision {
                case .cancel: return                      // keep the editor open
                case .discard: break
                case .save:
                    if !(await controller.saveAsync(to: filePath)) { return }
                    isDirty = false
                }
            }
            // 2. TC-style archive write-back (no-op for plain files).
            if !(await updateArchiveOnClose()) { return }
            // 3. Drop the extracted temp dir.
            if case let .archive(_, _, temporaryRoot) = source {
                FileOperationsService.cleanupTemporaryDirectory(temporaryRoot)
            }
            onClose()
        }
    }

    /// Before an archive-sourced editor closes, offer to pack the edited temp file back into
    /// the archive. Returns false only if the user cancels (editor must stay open).
    private func updateArchiveOnClose() async -> Bool {
        guard case let .archive(archivePath, entryPath, _) = source,
              controller.archiveNeedsUpdate, let operations else { return true }
        let fileName = (entryPath as NSString).lastPathComponent
        let decision = await fcxlPresentModalAsync {
            DialogService.shared.showSaveChangesConfirmation(
                title: L("editor.archiveUpdate.title"),
                message: "«\(fileName)»: " + L("editor.archiveUpdate.message"))
        }
        switch decision {
        case .cancel: return false
        case .discard: return true
        case .save:
            do {
                try await operations.updateArchiveEntry(
                    editedFilePath: filePath, archivePath: archivePath, entryPath: entryPath)
                controller.archiveNeedsUpdate = false
                return true
            } catch {
                let ns = error as NSError
                if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return false }
                DialogService.shared.showError(
                    title: L("editor.error.saveTitle"), message: error.localizedDescription)
                return false
            }
        }
    }

    @ViewBuilder
    private func toolbarButton(_ symbol: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless).controlSize(.small).help(tip)
    }

    @ViewBuilder
    private func toolbarToggle(_ symbol: String, tip: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundColor(isOn ? .white : .secondary)
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? accent : Color.clear)
                )
        }
        .buttonStyle(.borderless).controlSize(.small).help(tip)
    }
}

// MARK: - State

@MainActor
final class EmbeddedMonacoState: ObservableObject {
    var monaco: MonacoEditorController?
    /// Encoding the file was decoded with — a save writes it back in the same encoding.
    var encoding: String.Encoding = .utf8
    /// True when the bytes couldn't be decoded; saving is blocked so the placeholder never
    /// overwrites the real file.
    var isReadOnly = false
    /// Where the file came from — used to flag archive write-back on save.
    var source: EditorDocumentSource = .fileSystem
    /// Set once the archive's temp copy has been saved, so it differs from the archive.
    var archiveNeedsUpdate = false

    func save(to path: String, completion: @escaping (Bool) -> Void) {
        guard let monaco else { completion(false); return }
        if isReadOnly {
            DialogService.shared.showWarning(
                title: L("editor.error.saveTitle"),
                message: L("editor.error.readOnly"))
            completion(false)
            return
        }
        let enc = encoding
        monaco.getContent { [weak self] text in
            guard let data = text.data(using: enc) else {
                DialogService.shared.showError(
                    title: L("editor.error.saveTitle"),
                    message: L("editor.error.encodeUtf8"))
                completion(false)
                return
            }
            do {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                DispatchQueue.main.async {
                    monaco.markSaved()
                    if case .archive = self?.source { self?.archiveNeedsUpdate = true }
                    completion(true)
                }
            } catch {
                DispatchQueue.main.async {
                    DialogService.shared.showError(title: L("editor.error.saveTitle"), message: error.localizedDescription)
                    completion(false)
                }
            }
        }
    }

    /// async wrapper over `save` for the close flow.
    func saveAsync(to path: String) async -> Bool {
        await withCheckedContinuation { continuation in
            save(to: path) { continuation.resume(returning: $0) }
        }
    }
}

// MARK: - WebView Wrapper

struct EmbeddedMonacoWebView: NSViewRepresentable {
    let filePath: String
    let controller: EmbeddedMonacoState
    @Binding var isDirty: Bool
    @Binding var statusText: String

    func makeNSView(context: Context) -> WKWebView {
        let monaco = MonacoEditorController()
        controller.monaco = monaco

        monaco.onDirtyChanged = { dirty in
            DispatchQueue.main.async { self.isDirty = dirty }
        }

        monaco.onCursorChanged = { line, col, total, selLen in
            DispatchQueue.main.async {
                var s = String(format: L("editor.status.position"), line, col, total)
                if selLen > 0 { s += "  |  " + String(format: L("editor.status.selection"), selLen) }
                s += "  |  UTF-8"
                self.statusText = s
            }
        }

        // Cmd+S inside the embedded editor (the panel has no key monitor of its own).
        monaco.onSaveRequested = {
            controller.save(to: filePath) { saved in
                if saved { DispatchQueue.main.async { self.isDirty = false } }
            }
        }

        monaco.onReady = { [weak controller] in
            let lang = MonacoEditorController.detectLanguage(for: filePath)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath), options: [.mappedIfSafe]) else {
                controller?.isReadOnly = true
                monaco.setContent("// Error loading file", language: "plaintext")
                return
            }
            let decoded = MonacoEditorController.decodeText(data)
            controller?.encoding = decoded.encoding
            controller?.isReadOnly = !decoded.decodable
            monaco.setContent(decoded.text, language: lang)
            // Word wrap ON by default
            monaco.toggleWordWrap(true)
            // Focus the editor so typing works right after F4 (no click needed).
            monaco.webView.window?.makeFirstResponder(monaco.webView)
            monaco.focusEditor()
        }

        return monaco.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
