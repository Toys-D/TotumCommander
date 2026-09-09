import AppKit
import SwiftUI

/// Rich-text editor for RTF / RTFD files, embedded in a panel like the Monaco editor.
/// Monaco only edits plain text, so RTF (fonts, colours, bold/italic) needs AppKit's native
/// NSTextView, which reads and writes RTF directly. Formatting the user applies is preserved
/// on save because we write the attributed string back out as RTF.
struct RTFEditorPanel: View {
    let filePath: String
    let onClose: () -> Void
    /// Reports the unsaved (dirty) state outward so the disk-eject flow can warn about it.
    var onDirtyChange: ((Bool) -> Void)? = nil

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    @State private var isDirty = false
    @StateObject private var state = RTFEditorState()

    var body: some View {
        VStack(spacing: 0) {
            // Header: filename + formatting + save + close
            HStack(spacing: 6) {
                Text(URL(fileURLWithPath: filePath).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isDirty {
                    Text("•").foregroundColor(.orange)
                }

                Spacer()

                formatButton("bold", tip: L("editor.rtf.bold")) { state.toggleTrait(.boldFontMask) }
                formatButton("italic", tip: L("editor.rtf.italic")) { state.toggleTrait(.italicFontMask) }
                formatButton("underline", tip: L("editor.rtf.underline")) { state.toggleUnderline() }

                Divider().frame(height: 14)

                Button {
                    if state.save(to: filePath) { isDirty = false }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless).controlSize(.small)
                .disabled(!isDirty).help(L("editor.save.tooltip"))
                .contentShape(Rectangle())

                Button {
                    handleClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless).controlSize(.small).help(L("common.close"))
                .contentShape(Rectangle())
            }
            .padding(.horizontal, 8)
            .frame(height: 28)

            Divider()

            RTFTextView(filePath: filePath, state: state, isDirty: $isDirty)
        }
        .onChange(of: isDirty) { newDirty in onDirtyChange?(newDirty) }
        .onReceive(NotificationCenter.default.publisher(for: .fcxlRequestEditorClose)) { _ in
            handleClose()
        }
    }

    @ViewBuilder
    private func formatButton(_ symbol: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless).controlSize(.small).help(tip)
        .contentShape(Rectangle())
    }

    private func handleClose() {
        guard isDirty else { onClose(); return }
        // Runloop callout so the FCXLDialog's buttons work from a parked main queue.
        fcxlPresentModal {
            switch DialogService.shared.showSaveChangesConfirmation(
                title: L("editor.saveChanges.title"),
                message: L("editor.saveChanges.message")) {
            case .save: if state.save(to: filePath) { onClose() }
            case .discard: onClose()
            case .cancel: break
            }
        }
    }
}

// MARK: - State

@MainActor
final class RTFEditorState: ObservableObject {
    weak var textView: NSTextView?
    /// Set when the file couldn't be read as RTF — saving is blocked so we don't overwrite it.
    var isReadOnly = false

    /// Write the current attributed text back out as RTF (RTFD for a .rtfd path).
    func save(to path: String) -> Bool {
        guard let textView, !isReadOnly, let storage = textView.textStorage else {
            if isReadOnly {
                DialogService.shared.showWarning(
                    title: L("editor.error.saveTitle"), message: L("editor.error.readOnly"))
            }
            return false
        }
        let fullRange = NSRange(location: 0, length: storage.length)
        let isRTFD = path.lowercased().hasSuffix(".rtfd")
        let docType: NSAttributedString.DocumentType = isRTFD ? .rtfd : .rtf
        do {
            let data = try storage.data(
                from: fullRange,
                documentAttributes: [.documentType: docType])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            textView.breakUndoCoalescing()
            return true
        } catch {
            DialogService.shared.showError(
                title: L("editor.error.saveTitle"), message: error.localizedDescription)
            return false
        }
    }

    /// Toggle bold/italic across the selection by converting each run's font.
    func toggleTrait(_ trait: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        let fontManager = NSFontManager.shared

        // If the whole selection already has the trait, remove it; otherwise add it.
        var allHaveTrait = true
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 13)
            if !fontManager.traits(of: font).contains(trait) { allHaveTrait = false }
        }

        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 13)
            let newFont = allHaveTrait
                ? fontManager.convert(font, toNotHaveTrait: trait)
                : fontManager.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: newFont, range: subrange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    /// Toggle underline across the selection.
    func toggleUnderline() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }

        var allUnderlined = true
        storage.enumerateAttribute(.underlineStyle, in: range) { value, _, _ in
            let style = (value as? Int) ?? 0
            if style == 0 { allUnderlined = false }
        }
        let newStyle = allUnderlined ? 0 : NSUnderlineStyle.single.rawValue
        storage.beginEditing()
        storage.addAttribute(.underlineStyle, value: newStyle, range: range)
        storage.endEditing()
        textView.didChangeText()
    }
}

// MARK: - NSTextView wrapper

struct RTFTextView: NSViewRepresentable {
    let filePath: String
    let state: RTFEditorState
    @Binding var isDirty: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isRichText = true
        textView.isEditable = true
        textView.allowsUndo = true
        textView.importsGraphics = filePath.lowercased().hasSuffix(".rtfd")
        textView.usesFontPanel = true
        textView.usesFindPanel = true
        textView.delegate = context.coordinator
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 8)

        // Load the file as RTF/RTFD. On failure open read-only with a placeholder so a save
        // can't clobber a file we couldn't parse.
        let url = URL(fileURLWithPath: filePath)
        let isRTFD = filePath.lowercased().hasSuffix(".rtfd")
        let docType: NSAttributedString.DocumentType = isRTFD ? .rtfd : .rtf
        if let attributed = try? NSAttributedString(
            url: url,
            options: [.documentType: docType],
            documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attributed)
        } else {
            state.isReadOnly = true
            textView.isEditable = false
            textView.string = "(Cannot read RTF file)"
        }

        state.textView = textView
        context.coordinator.install(for: textView)

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(filePath: filePath, state: state, isDirty: $isDirty)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.removeKeyMonitor()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let filePath: String
        private let state: RTFEditorState
        private let isDirty: Binding<Bool>
        private weak var textView: NSTextView?
        private var keyMonitor: Any?

        init(filePath: String, state: RTFEditorState, isDirty: Binding<Bool>) {
            self.filePath = filePath
            self.state = state
            self.isDirty = isDirty
        }

        func install(for textView: NSTextView) {
            self.textView = textView
            // NSTextView doesn't handle Cmd+S itself (no File menu wired to it), so intercept
            // it here — but only while THIS editor's text view actually has keyboard focus.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self, let tv = self.textView, tv.window?.firstResponder === tv else {
                    return event
                }
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if mods == [.command], event.keyCode == 1 {   // Cmd+S
                    MainActor.assumeIsolated {
                        if self.state.save(to: self.filePath) { self.isDirty.wrappedValue = false }
                    }
                    return nil
                }
                return event
            }
        }

        func removeKeyMonitor() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        }

        deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

        func textDidChange(_ notification: Notification) {
            if !isDirty.wrappedValue { isDirty.wrappedValue = true }
        }
    }
}
