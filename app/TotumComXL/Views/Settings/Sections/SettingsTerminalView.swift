import SwiftUI

struct SettingsTerminalView: View {
    @AppStorage("terminalPlacement") private var terminalPlacement: String = "ask"
    @AppStorage(ExternalTerminal.defaultsKey) private var externalTerminal: String = ""
    @AppStorage(TerminalToggleMode.defaultsKey) private var toggleAction: String = TerminalToggleMode.hide.rawValue

    var body: some View {
        Form {
            Section(L("settings.section.terminal")) {
                LabeledContent(L("settings.terminalPlacement")) {
                    FCXLDialogMenuPicker(
                        items: ["ask", "bottom", "activePanel", "leftPanel", "rightPanel"],
                        selection: $terminalPlacement,
                        title: { L("settings.terminalPlacement.\($0)") })
                }
                LabeledContent(L("settings.terminalToggleAction")) {
                    FCXLDialogMenuPicker(
                        items: TerminalToggleMode.allCases.map(\.rawValue),
                        selection: $toggleAction,
                        title: { L("settings.terminalToggleAction.\($0)") })
                }
                .settingAnchor("settings.terminalToggleAction")
                Text(L("settings.terminalToggleAction.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                // Only what this Mac actually has: a picker of absent apps is broken buttons.
                LabeledContent(L("settings.externalTerminal")) {
                    FCXLDialogMenuPicker(
                        items: ExternalTerminal.installed.map(\.rawValue),
                        selection: $externalTerminal,
                        title: { raw in
                            ExternalTerminal(rawValue: raw)?.displayName ?? raw
                        })
                }
                Text(L("settings.externalTerminal.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section(L("settings.keys.terminal")) {
                HStack {
                    Text(L("settings.terminal.shortcut")).settingAnchor("settings.terminal.shortcut")
                    Spacer()
                    TerminalKeyCaps(keys: ["⌘", "`"])
                }
                Text(L("settings.terminal.shortcut.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                shortcutRow(Text(L("settings.terminal.splitSideBySide")),
                            anchor: "settings.terminal.splitSideBySide", keys: ["⌘", "D"])
                shortcutRow(Text(L("settings.terminal.splitStacked")),
                            anchor: "settings.terminal.splitStacked", keys: ["⇧", "⌘", "D"])
                shortcutRow(Text(L("settings.terminal.movePane")),
                            anchor: "settings.terminal.movePane", keys: ["⌥", "⌘", "← ↑ ↓ →"])
                shortcutRow(Text(L("settings.terminal.closePane")),
                            anchor: "settings.terminal.closePane", keys: ["⌘", "W"])
                shortcutRow(Text(L("settings.terminal.newTab")),
                            anchor: "settings.terminal.newTab", keys: ["⌘", "T"])
                Text(L("settings.terminal.splitHint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Строка клавиши: что делает — слева, клавиши плашками — справа.
    private func shortcutRow(_ title: Text, anchor: String, keys: [String]) -> some View {
        HStack {
            title.settingAnchor(anchor)
            Spacer()
            TerminalKeyCaps(keys: keys)
        }
    }
}

/// Сочетание клавиш плашками, по одной на клавишу, — как на самой клавиатуре. Слитное «⌘⌥←↑↓→»
/// читалось с трудом. Цвета от `primary`, поэтому плашки одинаково видны в светлой и тёмной теме.
struct TerminalKeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .frame(minWidth: 14)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
