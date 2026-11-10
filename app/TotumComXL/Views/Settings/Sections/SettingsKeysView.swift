import SwiftUI

struct SettingsKeysView: View {
    @AppStorage("fcxl.spaceAction") private var spaceAction: String = "quickView"
    @AppStorage("fcxl.quickViewMode") private var quickViewMode: String = "native"
    @AppStorage("fcxl.backspaceAsBack") private var backspaceAsBack: Bool = true
    @AppStorage("fcxl.cmdQToQuit") private var cmdQToQuit: Bool = true
    @AppStorage("fcxl.viewerInPanel") private var viewerInPanel: Bool = false
    @AppStorage("fcxl.editorInPanel") private var editorInPanel: Bool = false
    @AppStorage(FKeyCapture.enabledKey) private var captureFKeys: Bool = true
    /// Выдано ли «Универсальный доступ». Его дают в Системных настройках, пока окно в фоне, —
    /// перечитывается, когда программа снова впереди.
    @State private var fkeysTrusted = FKeyCapture.isTrusted

    /// Набор сочетаний — тот же ключ, что пишет KeyBindings: окно правки меняет его само.
    @AppStorage(KeyBindings.profileKey) private var profileRaw: String = KeyProfile.totum.rawValue

    @AppStorage(PanelViewModel.includeCursorInOperationsKey)
    private var includeCursorInOperations: Bool = false

    /// Клавиши звука, которые сейчас держит macOS. Считается при открытии раздела и после
    /// нажатия кнопки — список меняется редко, следить за ним постоянно незачем.
    @State private var heldByMacOS: [String] = SystemShortcuts.heldKeys()
    /// Список поправлен, а система его не перечитала: скажем про перезаход.
    @State private var needsRelogin = false

    var body: some View {
        Form {
            Section(L("settings.keys.bindings")) {
                LabeledContent(L("settings.keys.profile")) {
                    FCXLDialogMenuPicker(
                        items: KeyProfile.choosable.map(\.rawValue)
                            + (profileRaw == KeyProfile.custom.rawValue ? [KeyProfile.custom.rawValue] : []),
                        selection: Binding(
                            get: { profileRaw },
                            set: { raw in
                                guard let chosen = KeyProfile(rawValue: raw), chosen != .custom else { return }
                                KeyBindings.choose(chosen)
                                profileRaw = chosen.rawValue
                            }),
                        title: { L(KeyProfile(rawValue: $0)?.titleKey ?? $0) })
                }
                Text(L("settings.keys.bindings.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    // Через runloop-вызов, не прямо из жеста кнопки: окно, открытое посреди
                    // него, выходило с мёртвыми кнопками — даже «Закрыть» не закрывала.
                    Button(L("settings.keys.edit")) {
                        fcxlPresentModal {
                            KeyBindingsEditor.show()
                            profileRaw = KeyBindings.profile.rawValue
                        }
                    }
                    Spacer()
                    Button(L("settings.keys.reset")) {
                        KeyBindings.resetAll()
                        profileRaw = KeyBindings.profile.rawValue
                    }
                    .disabled(profileRaw == KeyProfile.totum.rawValue)
                }
            }
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
                Toggle(L("settings.viewerInPanel"), isOn: $viewerInPanel).settingAnchor("settings.viewerInPanel")
                Toggle(L("settings.editorInPanel"), isOn: $editorInPanel).settingAnchor("settings.editorInPanel")
                if viewerInPanel && quickViewMode == "native" {
                    Text(L("settings.viewerInPanel.hint"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(L("settings.keys.backspace")) {
                Toggle(L("settings.backspaceAsBack"), isOn: $backspaceAsBack).settingAnchor("settings.backspaceAsBack")
                Text(L("settings.backspaceAsBack.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section(L("settings.keys.selection")) {
                Toggle(L("settings.includeCursorInOps"), isOn: $includeCursorInOperations).settingAnchor("settings.includeCursorInOps")
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
                        // Список правится всегда, а перечитывает его система отдельной
                        // командой по приватному пути. Не вышло — правка вступит в силу
                        // после перезахода в учётную запись, и об этом надо сказать, а не
                        // молча оставить человека с прежними клавишами.
                        needsRelogin = !SystemShortcuts.freeVolumeKeys()
                        heldByMacOS = SystemShortcuts.heldKeys()
                    }
                }
                if needsRelogin {
                    Text(L("settings.keys.sound.relogin")).settingAnchor("settings.keys.sound.relogin")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // F-клавиши, которые держит другая программа (заменитель Launchpad на F4).
            Section(L("settings.keys.fkeys")) {
                Toggle(L("settings.captureFKeys"), isOn: $captureFKeys).settingAnchor("settings.captureFKeys")
                    .onChange(of: captureFKeys) { _ in FKeyCapture.shared.refresh() }
                Text(L("settings.captureFKeys.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if captureFKeys {
                    HStack {
                        Text(L(fkeysTrusted ? "settings.captureFKeys.granted" : "settings.captureFKeys.notGranted"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if !fkeysTrusted {
                            Button(L("fkeys.grant")) { FKeyCapture.requestPermission() }
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                fkeysTrusted = FKeyCapture.isTrusted
            }
            Section(L("settings.keys.cmdQ")) {
                Toggle(L("settings.cmdQToQuit"), isOn: $cmdQToQuit).settingAnchor("settings.cmdQToQuit")
                Text(L("settings.cmdQToQuit.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
