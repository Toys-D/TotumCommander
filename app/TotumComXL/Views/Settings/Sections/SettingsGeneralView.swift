import AppKit
import FCXLControlProtocol
import SwiftUI

struct SettingsGeneralView: View {
    @AppStorage("showHiddenFiles") private var showHiddenFiles: Bool = false
    @AppStorage(DoubleClickSettings.intervalKey)
    private var doubleClickIntervalSeconds: Double = DoubleClickSettings.defaultIntervalSeconds
    @AppStorage(ForceTouchSupport.actionKey) private var forceClickActionRaw: String =
        ForceTouchSupport.Action.open.rawValue
    /// Asked of the system when the page is built — a trackpad can be plugged in at any time.
    @State private var forceTouchAvailable = ForceTouchSupport.isAvailable

    private var forceClickAction: Binding<ForceTouchSupport.Action> {
        Binding(get: { ForceTouchSupport.Action(rawValue: forceClickActionRaw) ?? .open },
                set: { forceClickActionRaw = $0.rawValue })
    }
    @AppStorage(DialogService.skipCopyMoveDialogKey) private var skipCopyMoveDialog: Bool = false
    @AppStorage(DialogService.skipDeleteDialogKey) private var skipDeleteDialog: Bool = false
    @AppStorage(DialogService.skipPackDialogKey) private var skipPackDialog: Bool = false
    @AppStorage(DialogService.skipExtractDialogKey) private var skipExtractDialog: Bool = false
    @AppStorage(FileOperationsService.externalEditorKey) private var externalEditorPath: String = ""
    @AppStorage("fcxl.breadcrumbSelectAll") private var breadcrumbSelectAll: Bool = false
    @AppStorage("fcxl.calculateFolderSizes") private var calculateFolderSizes: Bool = false
    @AppStorage("fcxl.folderSizeLoadPercent") private var folderSizeLoadPercent: Int = 25
    @AppStorage("fcxl.saveViewModePerTab") private var saveViewModePerTab: Bool = true
    @AppStorage("fcxl.persistColumnWidths") private var persistColumnWidths: Bool = true
    @AppStorage(DiskImageOpenMode.defaultsKey)
    private var diskImageOpen: String = DiskImageOpenMode.fallback.rawValue
    @AppStorage(ControlProtocol.enabledKey) private var controlServerEnabled: Bool = false

    @AppStorage(AppLanguage.defaultsKey) private var appLanguage: String = AppLanguage.system.rawValue

    @AppStorage(ToolbarLook.defaultsKey) private var toolbarLook: String = ToolbarLook.icons.rawValue
    @AppStorage(ToolbarLook.separatorsKey) private var toolbarSeparators: Bool = false
    @AppStorage(WindowLaunchMode.defaultsKey) private var windowLaunch: String = WindowLaunchMode.asLeft.rawValue
    @AppStorage(UpdateChecker.enabledKey) private var checkUpdates: Bool = true

    var body: some View {
        Form {
            Section {
                LabeledContent(L("settings.language")) {
                    FCXLDialogMenuPicker(
                        items: AppLanguage.allCases.map(\.rawValue),
                        selection: $appLanguage,
                        title: { AppLanguage(rawValue: $0)?.displayName ?? $0 })
                }
                // The main menu and every already-built window keep the strings they were
                // created with, so the switch only takes effect on the next launch — offer to
                // do it right away instead of leaving the user with a half-translated UI.
                Text(L("settings.language.restart"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .onChange(of: appLanguage) { _ in
                        fcxlPresentModal {
                            let restart = DialogService.shared.showConfirmationCustom(
                                title: L("settings.language.restartTitle"),
                                message: L("settings.language.restartMessage"),
                                confirmTitle: L("settings.language.restartNow"),
                                cancelTitle: L("settings.language.restartLater"))
                            // Only quit once the helper that brings the app back is running —
                            // otherwise "Restart now" would leave the user with nothing.
                            if restart, !AppLanguage.relaunchApp() {
                                DialogService.shared.showError(
                                    title: L("settings.language.restartTitle"),
                                    message: L("settings.language.restartFailed"))
                            }
                        }
                    }
            }
            Section {
                Toggle(L("settings.showHidden"), isOn: $showHiddenFiles)
                Toggle(L("settings.calculateFolderSizes"), isOn: $calculateFolderSizes)
                if calculateFolderSizes {
                    HStack {
                        Text(L("settings.folderSizeLoad"))
                        Slider(value: Binding(
                            get: { Double(folderSizeLoadPercent) },
                            set: { folderSizeLoadPercent = Int($0.rounded()) }
                        ), in: 10...100)
                        Text("\(folderSizeLoadPercent)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    Text(L("settings.folderSizeLoad.hint"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Toggle(L("settings.saveViewModePerTab"), isOn: $saveViewModePerTab)
                Toggle(L("settings.persistColumnWidths"), isOn: $persistColumnWidths)
                LabeledContent(L("settings.diskImageOpen")) {
                    FCXLDialogMenuPicker(
                        items: DiskImageOpenMode.allCases.map(\.rawValue),
                        selection: $diskImageOpen,
                        title: { L(DiskImageOpenMode(rawValue: $0)?.titleKey ?? $0) })
                }
                Text(L("settings.diskImageOpen.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section(L("settings.section.toolbar")) {
                LabeledContent(L("settings.toolbar.look")) {
                    FCXLDialogMenuPicker(
                        items: ToolbarLook.allCases.map(\.rawValue),
                        selection: $toolbarLook,
                        title: { L(ToolbarLook(rawValue: $0)?.titleKey ?? $0) })
                }
                Toggle(L("settings.toolbar.separators"), isOn: $toolbarSeparators)
                Text(L("settings.toolbar.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section(L("settings.section.window")) {
                LabeledContent(L("settings.windowLaunch")) {
                    FCXLDialogMenuPicker(
                        items: WindowLaunchMode.allCases.map(\.rawValue),
                        selection: $windowLaunch,
                        title: { L(WindowLaunchMode(rawValue: $0)?.titleKey ?? $0) })
                }
                Text(L("settings.windowLaunch.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            // Панель окна перестраивается на месте: и подписи, и черты видны сразу.
            .onChange(of: toolbarLook) { _ in
                NotificationCenter.default.post(name: .fcxlToolbarLookChanged, object: nil)
            }
            .onChange(of: toolbarSeparators) { _ in
                NotificationCenter.default.post(name: .fcxlToolbarLookChanged, object: nil)
            }
            Section(L("settings.section.editor")) {
                HStack {
                    FCXLDialogTextField(text: $externalEditorPath,
                                        placeholder: L("settings.externalEditor.placeholder"))
                    Button(L("settings.externalEditor.browse")) {
                        fcxlPresentModal {
                            if let path = DialogService.shared.showFilePicker(
                                title: L("settings.externalEditor.browse"),
                                defaultPath: "/Applications",
                                allowedTypes: [.application]
                            ) {
                                externalEditorPath = path
                            }
                        }
                    }
                    .buttonStyle(FCXLChipButtonStyle(compact: true))
                }
                if !externalEditorPath.isEmpty {
                    Text(L("settings.externalEditor.hint"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Section(L("settings.section.mouse")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(L("settings.doubleClickInterval"))
                        Spacer()
                        Text("\(doubleClickIntervalMilliseconds) \(L("unit.milliseconds"))")
                            .foregroundColor(.secondary)
                    }
                    Slider(
                        value: doubleClickIntervalBinding.snapped(to: 0.05),
                        in: DoubleClickSettings.minimumIntervalSeconds...DoubleClickSettings.maximumIntervalSeconds
                    )
                }

                // The trackpad's second detent. Shown even where there is no sensor — greyed
                // with the reason, because a setting that vanishes on some Macs looks lost
                // rather than inapplicable.
                LabeledContent(L("settings.forceClick")) {
                    FCXLDialogMenuPicker(
                        items: ForceTouchSupport.Action.allCases,
                        selection: forceClickAction,
                        title: { L($0.titleKey) })
                }
                .disabled(!forceTouchAvailable)
                if !forceTouchAvailable {
                    Text(L(ForceTouchSupport.isSuppressedBySystem
                           ? "settings.forceClick.suppressed"
                           : "settings.forceClick.unsupported"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Section(L("settings.section.dialogs")) {
                Toggle(L("settings.confirmCopyMove"), isOn: invertedBinding($skipCopyMoveDialog))
                Toggle(L("settings.confirmDelete"), isOn: invertedBinding($skipDeleteDialog))
                Toggle(L("settings.confirmPack"), isOn: invertedBinding($skipPackDialog))
                Toggle(L("settings.confirmExtract"), isOn: invertedBinding($skipExtractDialog))
            }
            Section(L("settings.section.breadcrumbs")) {
                Toggle(L("settings.breadcrumbSelectAll"), isOn: $breadcrumbSelectAll)
            }
            Section(L("settings.section.control")) {
                Toggle(L("settings.control.enabled"), isOn: Binding(
                    get: { controlServerEnabled },
                    set: {
                        controlServerEnabled = $0
                        ControlServer.shared.syncWithSetting()
                    }))
                Text(L("settings.control.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)

            }
            // The last word in the section: a check that runs by itself, out of the way.
            Section(L("settings.section.updates")) {
                Toggle(L("settings.updates.check"), isOn: $checkUpdates)
                Text(L("settings.updates.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func invertedBinding(_ source: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { !source.wrappedValue }, set: { source.wrappedValue = !$0 })
    }

    private var doubleClickIntervalBinding: Binding<Double> {
        Binding(
            get: { DoubleClickSettings.normalizedIntervalSeconds(doubleClickIntervalSeconds) },
            set: { value in doubleClickIntervalSeconds = DoubleClickSettings.normalizedIntervalSeconds(value) }
        )
    }

    private var doubleClickIntervalMilliseconds: Int {
        Int((DoubleClickSettings.normalizedIntervalSeconds(doubleClickIntervalSeconds) * 1000).rounded())
    }
}
