import SwiftUI
import AppKit

struct TabChipView: View {
    let tab: PanelTab
    let index: Int
    let isActive: Bool
    let isDragTarget: Bool
    let onSelect: () -> Void
    let onClose: (() -> Void)?
    let onTogglePin: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAllUnpinned: () -> Void
    let onDragStart: () -> Void
    let onSetColor: (String?) -> Void
    let onNewTab: (() -> Void)?
    let onRename: ((String) -> Void)?
    let onPinViewMode: (() -> Void)?
    let onUnpinViewMode: (() -> Void)?
    var isLoading: Bool = false

    @AppStorage("tabFontSize") private var tabFontSize: Double = 13
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    @AppStorage("tabCornerRadius") private var tabCornerRadius: Double = 8
    @AppStorage(PanelAppearanceSettings.tabActiveOpacityKey) private var tabActiveOpacityRaw: Double =
        PanelAppearanceSettings.defaultTabActiveOpacity
    /// The tab bar's own "active tab" colour, per theme. Deliberately NOT the panel cursor's
    /// colour: one setting governing two unrelated parts of the UI left neither looking right.
    @AppStorage(PanelAppearanceSettings.tabActiveTitleColorHexKey)
    private var activeTitleHex: String = ""
    @AppStorage("tabChipHeight") private var tabChipHeight: Double = 28
    @AppStorage("fcxl.saveViewModePerTab") private var saveViewModePerTab: Bool = true

    @State private var isRenaming = false
    @State private var editingTitle = ""
    @State private var showColorPicker = false
    @State private var pickerHex = ""

    private var globalAccentColor: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    private var effectiveColor: Color {
        if let hex = tab.colorHex, let color = Color(hex: hex) {
            return color
        }
        return globalAccentColor
    }

    private var backgroundColor: Color {
        if isDragTarget { return Color.gray.opacity(0.42) }
        return isActive ? effectiveColor.opacity(activeOpacity) : effectiveColor.opacity(0.22)
    }

    /// Clamped on read: a stored value outside the slider's range (an old default, a hand-edited
    /// preference) must not make the active tab invisible or paint it opaque over the bar.
    private var activeOpacity: Double {
        min(1.0, max(0.2, tabActiveOpacityRaw))
    }

    /// Colour of the ACTIVE tab's label, from the tab bar's own setting. Inactive tabs keep the
    /// ordinary label colour, and with nothing chosen the system colour stands.
    private var titleColor: Color {
        guard isActive,
              let c = PanelAppearanceSettings.optionalNSColor(from: activeTitleHex)
        else { return .primary }
        return Color(nsColor: c)
    }

    /// Colour for a glyph inside the tab. On the ACTIVE tab everything follows the label colour, so
    /// the pin, the terminal mark and the close button read as one piece with the title instead of
    /// staying dark on a coloured chip. Inactive tabs keep each icon's own meaning-carrying colour.
    private func iconColor(_ fallback: Color) -> Color {
        guard isActive, !activeTitleHex.isEmpty else { return fallback }
        return titleColor
    }

    private var borderColor: Color {
        if isDragTarget { return Color.white.opacity(0.55) }
        return isActive ? effectiveColor.opacity(0.95) : effectiveColor.opacity(0.62)
    }

    /// Tab outline — rounded top corners, square bottom (merges into the bar).
    /// Single source of truth for the fill, border and hit-test area.
    private var tabShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: tabCornerRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: tabCornerRadius
        )
    }

    var body: some View {
        ZStack {
            if isRenaming {
                InlineRenameField(
                    text: $editingTitle,
                    font: NSFont.systemFont(ofSize: tabFontSize, weight: .semibold),
                    onCommit: { commitRename() },
                    onCancel: { isRenaming = false }
                )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .frame(height: tabChipHeight)
            } else {
                Text(tab.title)
                    .font(.system(size: tabFontSize, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 28)
                    .frame(height: tabChipHeight)
            }
        }
        .overlay(alignment: .leading) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
                    .padding(.leading, 7)
            } else if tab.isTerminal {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(iconColor(.primary))
                    .padding(.leading, 8)
            } else if tab.isNetworkMount {
                Image(systemName: "network")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(iconColor(.orange))
                    .padding(.leading, 8)
            } else if tab.pinned && tab.viewModePinned {
                Image(systemName: "pin.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(iconColor(.primary))
                    .padding(.leading, 8)
            } else if tab.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(iconColor(.primary))
                    .padding(.leading, 8)
            } else if tab.viewModePinned {
                Image(systemName: "eye.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(iconColor(.secondary))
                    .padding(.leading, 8)
            }
        }
        .overlay(alignment: .trailing) {
            if !tab.pinned, let onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(iconColor(.primary))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
            }
        }
        .background(backgroundColor, in: tabShape)
        .overlay {
            // strokeBorder draws INSIDE the edge (not centered on it), so the
            // border sits flush with the fill — no overhang or colour build-up
            // at the rounded corners.
            tabShape.strokeBorder(borderColor, lineWidth: isDragTarget ? 2 : 1)
        }
        .contentShape(tabShape)
        .onTapGesture(perform: onSelect)
        .onDrag {
            onDragStart()
            return NSItemProvider(object: "\(index)" as NSString)
        } preview: {
            Color.clear.frame(width: 1, height: 1)
        }
        .overlay {
            TabContextMenuHelper(makeMenu: buildContextMenu)
        }
        .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
            FCXLColorPickerPanel(
                hex: Binding(get: { pickerHex },
                             set: { pickerHex = $0; onSetColor($0.isEmpty ? nil : $0) }),
                presets: [],
                allowsReset: false,
                resetTitle: "",
                fallback: globalAccentColor,
                onDone: { showColorPicker = false }
            )
            .frame(width: 252)
            .padding(12)
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        // — Group 1: New tab + Rename + Pin —
        if let onNewTab {
            menu.addActionItem(title: L("tabs.newTab"), symbolName: "plus") {
                onNewTab()
            }
        }
        if onRename != nil {
            menu.addActionItem(title: L("tabs.rename"), symbolName: "pencil") {
                startRenaming()
            }
        }
        if !tab.isTerminal {
            menu.addActionItem(
                title: tab.pinned ? L("tabs.unpin") : L("tabs.pin"),
                symbolName: tab.pinned ? "pin.slash" : "pin"
            ) { onTogglePin() }
        }

        // — Group 2: Close —
        menu.addItem(.separator())

        if !tab.pinned, let onClose {
            menu.addActionItem(title: L("tabs.close"), symbolName: "xmark") {
                onClose()
            }
        }

        menu.addActionItem(title: L("tabs.closeOthers"), symbolName: "xmark.circle") {
            onCloseOthers()
        }
        menu.addActionItem(title: L("tabs.closeAllUnpinned"), symbolName: "xmark.circle.fill") {
            onCloseAllUnpinned()
        }

        // — Group 3: View mode —
        let hasViewModeItems = (!saveViewModePerTab && !tab.viewModePinned) || tab.viewModePinned
        if hasViewModeItems {
            menu.addItem(.separator())

            if !saveViewModePerTab && !tab.viewModePinned, let onPinViewMode {
                menu.addActionItem(title: L("tabs.pinViewMode"), symbolName: "eye") {
                    onPinViewMode()
                }
            }
            if tab.viewModePinned, let onUnpinViewMode {
                menu.addActionItem(title: L("tabs.unpinViewMode"), symbolName: "eye.slash") {
                    onUnpinViewMode()
                }
            }
        }

        // — Group 4: Color —
        menu.addItem(.separator())

        let colorItem = NSMenuItem(title: L("tabs.color"), action: nil, keyEquivalent: "")
        if let img = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil) {
            img.isTemplate = true
            colorItem.image = img
        }
        let colorMenu = NSMenu()
        for preset in TabColor.presets {
            let item = NSMenuItem(title: preset.name, action: nil, keyEquivalent: "")
            let swatch = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                (NSColor(hex: preset.hex) ?? .gray).setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
            item.image = swatch
            let target = TabMenuActionTarget { onSetColor(preset.hex) }
            item.target = target
            item.action = #selector(TabMenuActionTarget.invoke(_:))
            item.representedObject = target
            colorMenu.addItem(item)
        }
        colorMenu.addItem(.separator())

        // Custom colour — opens the full picker (HSV, hex, eyedropper) for any colour, not just
        // the presets. Seeded with the tab's current colour so editing starts from where it is.
        let customItem = NSMenuItem(title: L("tabs.color.custom"), action: nil, keyEquivalent: "")
        if let img = NSImage(systemSymbolName: "eyedropper.halffull", accessibilityDescription: nil) {
            img.isTemplate = true
            customItem.image = img
        }
        let customTarget = TabMenuActionTarget { [self] in
            pickerHex = tab.colorHex ?? ""
            showColorPicker = true
        }
        customItem.target = customTarget
        customItem.action = #selector(TabMenuActionTarget.invoke(_:))
        customItem.representedObject = customTarget
        colorMenu.addItem(customItem)

        colorMenu.addItem(.separator())
        let resetItem = NSMenuItem(title: L("tabs.color.reset"), action: nil, keyEquivalent: "")
        if let img = NSImage(systemSymbolName: "circle.slash", accessibilityDescription: nil) {
            img.isTemplate = true
            resetItem.image = img
        }
        let resetTarget = TabMenuActionTarget { onSetColor(nil) }
        resetItem.target = resetTarget
        resetItem.action = #selector(TabMenuActionTarget.invoke(_:))
        resetItem.representedObject = resetTarget
        colorMenu.addItem(resetItem)

        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        menu.applyAccentStyle()
        return menu
    }

    private func startRenaming() {
        guard onRename != nil else { return }
        editingTitle = tab.title
        isRenaming = true
    }

    private func commitRename() {
        isRenaming = false
        let newName = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty {
            onRename?(newName)
        }
    }
}

// MARK: - Inline Rename Field

private struct InlineRenameField: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.font = font
        field.alignment = .center
        field.focusRingType = .none
        field.textColor = .white
        field.stringValue = text
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.selectText(nil) }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.font = font
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineRenameField
        private var handled = false

        init(_ parent: InlineRenameField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                parent.text = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)) {
                handled = true
                parent.onCancel()
                return true
            }
            if sel == #selector(NSResponder.insertNewline(_:)) {
                handled = true
                parent.onCommit()
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if !handled { parent.onCommit() }
            handled = false
        }
    }
}

private final class TabMenuActionTarget: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
    }
    @objc func invoke(_ sender: NSMenuItem) { action() }
}

private extension NSMenu {
    func addActionItem(title: String, symbolName: String, action: @escaping () -> Void) {
        let target = TabMenuActionTarget(action: action)
        let item = NSMenuItem(title: title, action: #selector(TabMenuActionTarget.invoke(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            img.isTemplate = true
            item.image = img
        }
        addItem(item)
    }
}

/// Right-click on a tab, shown through the app's OWN popup menu — the same one the file panels
/// use. A native NSMenu opens its submenus on hover and closes the whole menu when the parent
/// row is clicked; ours opens them on click, and the two menus in the app must not disagree
/// about that. The menu is built at click time rather than on every SwiftUI render.
private struct TabContextMenuHelper: NSViewRepresentable {
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> NSView {
        let view = TabContextMenuView()
        view.makeMenu = makeMenu
        // A menu has to be present for AppKit to route the right-click here at all; the real
        // one is built in menu(for:) and shown by our own controller.
        view.menu = NSMenu()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TabContextMenuView)?.makeMenu = makeMenu
    }
}

private final class TabContextMenuView: NSView {
    var makeMenu: (() -> NSMenu)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if NSApp.currentEvent?.type == .rightMouseDown {
            return super.hitTest(point)
        }
        return nil
    }

    /// The same road the file panels take: build the items, hand them to our popup, and return
    /// nil so AppKit does not also open a native menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = makeMenu?() else { return super.menu(for: event) }
        let screenPoint = window?.convertPoint(toScreen: event.locationInWindow)
            ?? event.locationInWindow
        ContextPopupMenuController.shared.show(menu, at: screenPoint)
        return nil
    }
}

struct TabColor {
    let name: String
    let hex: String

    static let presets: [TabColor] = [
        TabColor(name: L("tabs.color.red"), hex: "#FF3B30"),
        TabColor(name: L("tabs.color.orange"), hex: "#FF9500"),
        TabColor(name: L("tabs.color.yellow"), hex: "#FFCC00"),
        TabColor(name: L("tabs.color.green"), hex: "#34C759"),
        TabColor(name: L("tabs.color.blue"), hex: "#007AFF"),
        TabColor(name: L("tabs.color.purple"), hex: "#AF52DE"),
    ]
}

private extension Color {
    init?(hex: String) {
        var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6, let rgb = UInt64(str, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6, let rgb = UInt64(str, radix: 16) else { return nil }
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
