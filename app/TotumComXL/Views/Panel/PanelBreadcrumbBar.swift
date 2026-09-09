import SwiftUI

/// Breadcrumb path bar for PanelViewController, embedded via NSHostingView.
struct PanelBreadcrumbBar: View {
    @ObservedObject var state: PanelState
    let viewModel: PanelViewModel  // not observed — for actions only
    var onDismiss: (() -> Void)?
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isFieldFocused: Bool
    @AppStorage("fcxl.breadcrumbSelectAll") private var selectAllOnEdit: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if isEditing {
                BreadcrumbEditField(
                    text: $editText,
                    isFocused: $isFieldFocused,
                    selectAll: selectAllOnEdit,
                    onCommit: commitEdit,
                    onCancel: cancelEdit
                )
                .padding(.leading, 4)

                Button {
                    commitEdit()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                // Same 38pt trailing slot as the pencil / tab bar "+" so the
                // confirm icon lines up with them too.
                .frame(width: 38)
                .help(L("breadcrumb.finishEdit"))
            } else {
                pathSegments
            }
        }
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
        .interfaceBackground()
    }

    private func startEditing() {
        editText = state.currentPath
        isEditing = true
        DispatchQueue.main.async {
            isFieldFocused = true
        }
    }

    private var pathSegments: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(state.breadcrumbs.indices, id: \.self) { i in
                        let crumb = state.breadcrumbs[i]
                        let isLast = i == state.breadcrumbs.count - 1
                        let isRoot = crumb.name == "/"

                        if i > 0 {
                            Text("/")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }

                        BreadcrumbSegment(
                            name: isRoot ? "~" : crumb.name,
                            isLast: isLast
                        ) {
                            viewModel.pushHistory(from: viewModel.currentPath, to: crumb.path)
                            viewModel.loadDirectory(at: crumb.path, resetCursor: true)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .padding(.leading, 6)
                .padding(.vertical, 2)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { startEditing() }

            // Edit button — pinned to trailing edge, centered in the same 38pt
            // trailing slot as the tab bar "+" so the two icons line up vertically.
            Button {
                startEditing()
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 38)
        }
    }

    private func commitEdit() {
        let path = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
            viewModel.pushHistory(from: state.currentPath, to: path)
            viewModel.loadDirectory(at: path, resetCursor: true)
        }
        isEditing = false
        onDismiss?()
    }

    private func cancelEdit() {
        isEditing = false
        onDismiss?()
    }
}

/// NSTextField wrapper that controls selection behavior (select all vs cursor at end).
private struct BreadcrumbEditField: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let selectAll: Bool
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.font = .systemFont(ofSize: 12)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        // Focus and selection on first appearance
        if !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            context.coordinator.selectAll = selectAll
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                context.coordinator.startMonitoring(field)
                guard let editor = field.currentEditor() else { return }
                if selectAll {
                    editor.selectAll(nil)
                } else {
                    let end = field.stringValue.utf16.count
                    editor.selectedRange = NSRange(location: end, length: 0)
                }
            }
        }
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: BreadcrumbEditField
        var didFocus = false
        var selectAll = false
        weak var field: NSTextField?
        private var monitor: Any?
        private var didFinish = false

        init(parent: BreadcrumbEditField) {
            self.parent = parent
        }

        deinit {
            stopMonitoring()
        }

        func startMonitoring(_ field: NSTextField) {
            self.field = field
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.handleClick(event)
                return event
            }
        }

        func stopMonitoring() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handleClick(_ event: NSEvent) {
            guard !didFinish, let field = field, let window = field.window else { return }
            if event.window !== window { return }
            // Find the topmost NSHostingView in the ancestor chain — this is the
            // host view embedding the whole breadcrumb bar (containing both
            // the text field and the checkmark button).
            var topHost: NSView?
            var cursor: NSView? = field
            while let view = cursor {
                let className = String(describing: type(of: view))
                if className.contains("HostingView") {
                    topHost = view
                }
                cursor = view.superview
            }
            let host: NSView = topHost ?? field
            let pointInHost = host.convert(event.locationInWindow, from: nil)
            if !host.bounds.contains(pointInHost) {
                didFinish = true
                parent.onCancel()
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                didFinish = true
                parent.onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                didFinish = true
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

/// A single breadcrumb segment with underline on hover.
private struct BreadcrumbSegment: View {
    let name: String
    let isLast: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 11, weight: isLast ? .semibold : .regular))
                .foregroundStyle(isLast ? .primary : .secondary)
                .underline(isHovered && !isLast)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
