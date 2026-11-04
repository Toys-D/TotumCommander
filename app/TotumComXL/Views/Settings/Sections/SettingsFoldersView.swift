import AppKit
import SwiftUI

struct SettingsFoldersView: View {
    @AppStorage(FolderIconStyle.storageKey) private var folderIconStyleRaw: String = FolderIconStyle.macos.rawValue
    @AppStorage(FileIconStyle.storageKey) private var fileIconStyleRaw: String = FileIconStyle.fallback.rawValue
    @AppStorage(FileIconStyle.contourKey) private var fileIconContour: Bool = FileIconStyle.defaultContour
    @AppStorage(PanelAppearanceSettings.folderIconColorHexKey) private var folderIconColorHex: String = ""
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    @AppStorage(PanelAppearanceSettings.cursorIconZoomEnabledKey) private var iconZoomEnabled: Bool = false
    @AppStorage(PanelAppearanceSettings.cursorIconZoomAmountKey) private var iconZoomAmount: Double = PanelAppearanceSettings.defaultCursorIconZoom
    @AppStorage(PanelAppearanceSettings.cursorIconZoomSpreadKey) private var iconZoomSpread: Int = 0
    @AppStorage(CustomFolderIconService.enabledKey) private var showCustomFolderIcons: Bool = false
    @AppStorage(FolderStyleLibrary.generationKey) private var libraryGeneration: Int = 0
    @State private var hoveredCustom: String?
    /// Тема меняется — страница перерисовывается и показывает картинку этой темы.
    @Environment(\.colorScheme) private var colorScheme
    /// Чью картинку правит страница — как у цветов: по теме AppKit, а не по окружению SwiftUI.
    private var isDark: Bool { PanelAppearanceSettings.isDarkAppearance }
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }
    private var folderTint: NSColor {
        PanelAppearanceSettings.optionalNSColor(from: folderIconColorHex) ?? FolderIconStyle.defaultTint
    }

    var body: some View {
        Form {
            Section(L("design.section.folderIcons")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("design.folderIconStyle") + " — "
                         + L(isDark ? "settings.appearance.dark" : "settings.appearance.light"))
                        .settingAnchor("design.folderIconStyle")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(FolderIconStyle.allCases) { style in
                            styleTile(style) {
                                FolderCanvasView(style: style, baseColor: Color(nsColor: folderTint))
                            }
                        }
                        // Своё — следом за встроенными; правка библиотеки меняет поколение,
                        // и плитки перечитываются.
                        let _ = libraryGeneration
                        ForEach(FolderStyleLibrary.entries) { entry in
                            customTile(entry)
                        }
                        addTile
                    }
                }
                if case .custom(let id) = FolderIconStyle(rawValue: folderIconStyleRaw),
                   let entry = FolderStyleLibrary.entry(id), entry.format == .png {
                    Toggle(L("folderStyles.recolor"), isOn: Binding(
                        get: { entry.recolor },
                        set: { FolderStyleLibrary.setRecolor($0, for: id) }
                    ))
                    .settingAnchor("folderStyles.recolor")
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(L("folderStyles.hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(L("folderStyles.sample")) { saveSample() }
                        .buttonStyle(FCXLChipButtonStyle(compact: true))
                        .settingAnchor("folderStyles.sample")
                }
                Toggle(L("settings.folders.customIcons"), isOn: $showCustomFolderIcons).settingAnchor("settings.folders.customIcons")
                    .onChange(of: showCustomFolderIcons) { _, _ in
                        // Re-read the folders: entries cached while the setting was off would
                        // otherwise be replayed when it is switched back on.
                        CustomFolderIconService.clearCache()
                    }
                Text(L("settings.folders.customIcons.hint"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            fileIconsSection
            Section(L("settings.folders.iconZoomSection")) {
                Toggle(L("settings.folders.iconZoom"), isOn: $iconZoomEnabled).settingAnchor("settings.folders.iconZoom")
                HStack {
                    Text(L("settings.folders.iconZoomAmount")).settingAnchor("settings.folders.iconZoomAmount")
                    Slider(value: $iconZoomAmount, in: 1.0...2.0)
                    Text("\(Int(iconZoomAmount * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .disabled(!iconZoomEnabled)
                HStack {
                    Text(L("settings.folders.iconZoomSpread")).settingAnchor("settings.folders.iconZoomSpread")
                    // No step: — a stepped slider draws tick marks, which no other slider in
                    // the app has. The binding rounds instead, so the values stay whole rows.
                    Slider(value: Binding(get: { Double(iconZoomSpread) },
                                          set: { iconZoomSpread = Int($0.rounded()) }),
                           in: 0...5)
                    Text(iconZoomSpread == 0 ? "—" : "±\(iconZoomSpread)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!iconZoomEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Плитки стилей и свои стили

extension SettingsFoldersView {

    /// Плитка стиля: картинка, подпись, рамка у выбранного. Щелчок — выбрать.
    private func styleTile<Art: View>(_ style: FolderIconStyle, @ViewBuilder art: () -> Art) -> some View {
        let selected = folderIconStyleRaw == style.rawValue
        return VStack(spacing: 4) {
            art()
                .frame(width: 36, height: 36)
            Text(style.title)
                .font(.system(size: 9))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? accent.opacity(0.2) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? accent : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { FolderIconStyle.choose(style, dark: isDark) }
    }

    /// Свой стиль: как встроенный, плюс «удалить» — крестиком при наведении и в правом меню.
    private func customTile(_ entry: FolderStyleLibrary.Entry) -> some View {
        let style = FolderIconStyle.custom(entry.id)
        return styleTile(style) {
            Image(nsImage: FolderIconRenderer.image(style: style, size: 36, tintColor: folderTint))
        }
        .overlay(alignment: .topTrailing) {
            if hoveredCustom == entry.id {
                Button { FolderStyleLibrary.remove(entry.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("folderStyles.delete"))
                .offset(x: 4, y: -4)
            }
        }
        .onHover { inside in
            if inside { hoveredCustom = entry.id } else if hoveredCustom == entry.id { hoveredCustom = nil }
        }
        .overlay {
            RightClickMenu {
                let menu = NSMenu()
                menu.addStyledItem(title: L("folderStyles.delete"), symbolName: "trash", isDestructive: true) {
                    FolderStyleLibrary.remove(entry.id)
                }
                return menu
            }
        }
        .help(entry.name)
    }

    /// «Свой…»: выбрать SVG или PNG, проверить по правилам, добавить и сразу выбрать.
    private var addTile: some View {
        VStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary))
            Text(L("folderStyles.own"))
                .font(.system(size: 9))
                .lineLimit(1)
        }
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture { addCustomStyle() }
        .settingAnchor("folderStyles.own")
    }

    private func addCustomStyle() {
        guard let path = DialogService.shared.showFilePicker(title: L("folderStyles.add.title"),
                                                            defaultPath: nil, allowedTypes: [.svg, .png])
        else { return }
        do {
            let entry = try FolderStyleLibrary.add(contentsOf: URL(fileURLWithPath: path))
            FolderIconStyle.choose(.custom(entry.id), dark: isDark)
        } catch let rejection as FolderStyleRejection {
            DialogService.shared.showError(
                title: L("folderStyles.rejected.title"),
                message: rejection.problems.map { "• " + $0.message }.joined(separator: "\n"))
        } catch {
            DialogService.shared.showError(title: L("folderStyles.rejected.title"),
                                           message: error.localizedDescription)
        }
    }

    /// Образец SVG — туда, куда человек скажет.
    private func saveSample() {
        guard let path = DialogService.shared.showSavePanel(title: L("folderStyles.sample.title"),
                                                           defaultName: "Totum-folder-sample.svg",
                                                           allowedTypes: ["svg"])
        else { return }
        do {
            try FolderStyleLibrary.sampleSVG.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        } catch {
            DialogService.shared.showError(title: L("folderStyles.sample.failed"),
                                           message: error.localizedDescription)
        }
    }
}

// MARK: - Иконки файлов

extension SettingsFoldersView {

    /// Стоит в конце файла нарочно: поиск по настройкам относит подпись к ближайшему заголовку
    /// выше в тексте, и пункты папок, что идут следом, не должны попасть под «Иконки файлов».
    private var fileIconsSection: some View {
        Section(L("design.section.fileIcons")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("design.fileIconStyle") + " — "
                     + L(isDark ? "settings.appearance.dark" : "settings.appearance.light"))
                    .settingAnchor("design.fileIconStyle")
                HStack(spacing: 12) {
                    ForEach(FileIconStyle.allCases) { fileStyleTile($0) }
                }
            }
            // Контур — у значков macOS: у своих значков края и так цветные. При Totum
            // выключатель стоит, но не щёлкает, как ползунки увеличения при выключенном
            // увеличении. Помнится на каждую тему, как и стиль.
            Toggle(L("fileIconStyle.outline"), isOn: Binding(
                get: { fileIconContour },
                set: { FileIconStyle.chooseContour($0, dark: isDark) }))
                .settingAnchor("fileIconStyle.outline")
                .disabled(fileIconStyleRaw != FileIconStyle.macos.rawValue)
            Text(L("fileIconStyle.hint"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Образцы на плитке стиля файлов: обычный документ, картинка, архив — белые листы, что
    /// сливаются со светлой панелью, — и цветной PDF, которого обводка не трогает.
    private static let fileSamples = ["", "jpg", "zip", "pdf"]

    /// Плитка стиля значков файлов: образцы на фоне панели этой темы, подпись, рамка у
    /// выбранного — как у плиток папок. Щелчок — выбрать для темы на экране.
    private func fileStyleTile(_ style: FileIconStyle) -> some View {
        let selected = fileIconStyleRaw == style.rawValue
        let background = PanelAppearanceSettings.nsColor(
            from: UserDefaults.standard.string(forKey: PanelAppearanceSettings.panelBackgroundKey(dark: isDark)) ?? "",
            fallback: .controlBackgroundColor)
        let look = FileIconLook.panel(background: background, stripe: nil, style: style)
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(Self.fileSamples, id: \.self) { ext in
                    Image(nsImage: FileIcons.icon(forExtension: ext, size: 22, look: look))
                        .resizable()
                        .frame(width: 22, height: 22)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: background)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            Text(style.title)
                .font(.system(size: 9))
                .lineLimit(1)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? accent.opacity(0.2) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? accent : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { FileIconStyle.choose(style, dark: isDark) }
    }
}
