import SwiftUI

struct SettingsTerminalView: View {
    @AppStorage("terminalPlacement") private var terminalPlacement: String = "ask"
    @AppStorage(ExternalTerminal.defaultsKey) private var externalTerminal: String = ""

    var body: some View {
        Form {
            Section(L("settings.section.terminal")) {
                LabeledContent(L("settings.terminalPlacement")) {
                    FCXLDialogMenuPicker(
                        items: ["ask", "bottom", "activePanel", "leftPanel", "rightPanel"],
                        selection: $terminalPlacement,
                        title: { L("settings.terminalPlacement.\($0)") })
                }
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
                    Text(L("settings.terminal.shortcut"))
                    Spacer()
                    Text("⌘`")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text(L("settings.terminal.shortcut.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
