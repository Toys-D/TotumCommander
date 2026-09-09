import SwiftUI

struct SettingsKeysView: View {
    @AppStorage("fcxl.spaceAction") private var spaceAction: String = "quickView"
    @AppStorage("fcxl.quickViewMode") private var quickViewMode: String = "native"
    @AppStorage("fcxl.backspaceAsBack") private var backspaceAsBack: Bool = true
    @AppStorage("fcxl.cmdQToQuit") private var cmdQToQuit: Bool = true
    @AppStorage("fcxl.viewerInPanel") private var viewerInPanel: Bool = false
    @AppStorage("fcxl.editorInPanel") private var editorInPanel: Bool = false

    @AppStorage(PanelViewModel.includeCursorInOperationsKey)
    private var includeCursorInOperations: Bool = false

    /// Клавиши звука, которые сейчас держит macOS. Считается при открытии раздела и после
    /// нажатия кнопки — список меняется редко, следить за ним постоянно незачем.
    @State private var heldByMacOS: [String] = SystemShortcuts.heldKeys()

    var body: some View {
        Form {
            Section(L("settings.keys.space")) {
                LabeledContent(L("settings.spaceAction")) {
                    FCXLDialogMenuPicker(items: ["quickView", "select"],
                                         selection: $spaceAction,
                                         title: { L("settings.spaceAction.\($0)") })
                }
                LabeledContent(L("settings.quickViewMode")) {
                    FCXLDialogMenuPicker(items: ["native", "custom"],
                                         selection: $quickViewMode,
                                         title: { L("settings.quickViewMode.\($0)") })
                }
                .disabled(spaceAction == "select")
                .opacity(spaceAction == "select" ? 0.4 : 1)
            }
            Section(L("settings.keys.viewer")) {
                Toggle(L("settings.viewerInPanel"), isOn: $viewerInPanel)
                Toggle(L("settings.editorInPanel"), isOn: $editorInPanel)
                if viewerInPanel && quickViewMode == "native" {
                    Text(L("settings.viewerInPanel.hint"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(L("settings.keys.backspace")) {
                Toggle(L("settings.backspaceAsBack"), isOn: $backspaceAsBack)
                Text(L("settings.backspaceAsBack.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section(L("settings.keys.selection")) {
                Toggle(L("settings.includeCursorInOps"), isOn: $includeCursorInOperations)
                Text(L("settings.includeCursorInOps.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            // Клавиши звука. Раздел на месте всегда — он же и отвечает на вопрос «а мои ли
            // это клавиши»; кнопка появляется, только когда есть что освобождать. Сначала
            // прятался весь раздел, и тот, кто пришёл за кнопкой, её не находил.
            Section(L("settings.keys.sound")) {
                Text(heldByMacOS.isEmpty
                     ? L("settings.keys.sound.ours")
                     : String(format: L("settings.keys.sound.held"),
                              heldByMacOS.joined(separator: ", ")))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !heldByMacOS.isEmpty {
                    Button(L("settings.keys.sound.free")) {
                        SystemShortcuts.freeVolumeKeys()
                        heldByMacOS = SystemShortcuts.heldKeys()
                    }
                }
            }
            Section(L("settings.keys.cmdQ")) {
                Toggle(L("settings.cmdQToQuit"), isOn: $cmdQToQuit)
                Text(L("settings.cmdQToQuit.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
