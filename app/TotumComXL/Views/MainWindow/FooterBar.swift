import SwiftUI

/// Footer bar with F-key command buttons, embedded via NSHostingView in AppKit shell.
struct FooterBar: View {
    @ObservedObject var fKeyManager = FKeyModeManager.shared

    var onRename: () -> Void = {}
    var onView: () -> Void = {}
    var onEdit: () -> Void = {}
    var onCopy: () -> Void = {}
    var onMove: () -> Void = {}
    var onMkdir: () -> Void = {}
    var onDelete: () -> Void = {}
    var onSearch: () -> Void = {}
    var onTerminal: () -> Void = {}
    var onTerminalBottom: () -> Void = {}
    var onTerminalActive: () -> Void = {}
    var onTerminalLeft: () -> Void = {}
    var onTerminalRight: () -> Void = {}
    @AppStorage("terminalPlacement") private var terminalPlacement: String = "ask"
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }
    @State private var showTerminalMenu = false

    var body: some View {
        HStack(spacing: 0) {
            // Fn mode toggle
            Button {
                fKeyManager.toggle()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(fKeyManager.isEnabled
                              ? accent.opacity(0.18)
                              : Color.clear)
                    HStack(spacing: 2) {
                        Text("Fn")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(fKeyManager.isEnabled ? accent : Color.secondary)
                        if fKeyManager.isEnabled {
                            Circle()
                                .fill(accent)
                                .frame(width: 4, height: 4)
                        }
                    }
                }
                .frame(width: 34)
                .frame(minHeight: 22, maxHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(fKeyManager.isEnabled ? L("fn.tooltip.on") : L("fn.tooltip.off"))

            divider

            footerButton("button.f2.rename", fallback: "F2 Rename", accessibilityKey: "accessibility.rename_file", action: onRename)
            divider
            footerButton("button.f3.view", fallback: "F3 View", accessibilityKey: "accessibility.view_file", action: onView)
            divider
            footerButton("button.f4.edit", fallback: "F4 Edit", accessibilityKey: "accessibility.edit_file", action: onEdit)
            divider
            footerButton("button.f5.copy", fallback: "F5 Copy", accessibilityKey: "accessibility.copy_files", action: onCopy)
            divider
            footerButton("button.f6.move", fallback: "F6 Move", accessibilityKey: "accessibility.move_files", action: onMove)
            divider
            footerButton("button.f7.mkdir", fallback: "F7 Mkdir", accessibilityKey: "accessibility.create_folder", action: onMkdir)
            divider
            footerButton("button.f8.delete", fallback: "F8 Delete", accessibilityKey: "accessibility.delete_files", action: onDelete)
            divider
            footerButton("button.f9.search", fallback: "F9 Search", accessibilityKey: "accessibility.search", action: onSearch)
            divider

            // Terminal button — menu if "ask", direct action otherwise
            if terminalPlacement == "ask" {
                // Custom popover (not native Menu) so the highlight uses the accent.
                Button {
                    showTerminalMenu = true
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: 28)
                .help(L("terminal.title") + " (Cmd+`)")
                .popover(isPresented: $showTerminalMenu, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        AccentMenuItem(title: L("settings.terminalPlacement.bottom"), accent: accent) {
                            showTerminalMenu = false; onTerminalBottom()
                        }
                        AccentMenuItem(title: L("settings.terminalPlacement.activePanel"), accent: accent) {
                            showTerminalMenu = false; onTerminalActive()
                        }
                        AccentMenuItem(title: L("settings.terminalPlacement.leftPanel"), accent: accent) {
                            showTerminalMenu = false; onTerminalLeft()
                        }
                        AccentMenuItem(title: L("settings.terminalPlacement.rightPanel"), accent: accent) {
                            showTerminalMenu = false; onTerminalRight()
                        }
                    }
                    .padding(6)
                    .frame(width: 220)
                }
            } else {
                Button {
                    onTerminal()
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("terminal.title") + " (Cmd+`)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: 29, maxHeight: 29)
        .interfaceBackground()
    }

    private var divider: some View {
        Divider().frame(height: 14)
    }

    private func footerButton(_ key: String, fallback: String, accessibilityKey: String? = nil, action: @escaping () -> Void) -> some View {
        let localized = L(key)
        let text = (localized == key) ? fallback : localized
        let label = accessibilityKey.map { L($0) } ?? text
        return Button(action: action) {
            Text(text)
                .font(.system(size: 11, weight: .light))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
