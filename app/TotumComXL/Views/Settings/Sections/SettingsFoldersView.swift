import AppKit
import SwiftUI

struct SettingsFoldersView: View {
    @AppStorage(FolderIconStyle.storageKey) private var folderIconStyleRaw: String = FolderIconStyle.macos.rawValue
    @AppStorage(PanelAppearanceSettings.folderIconColorHexKey) private var folderIconColorHex: String = ""
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    @AppStorage(PanelAppearanceSettings.cursorIconZoomEnabledKey) private var iconZoomEnabled: Bool = false
    @AppStorage(PanelAppearanceSettings.cursorIconZoomAmountKey) private var iconZoomAmount: Double = PanelAppearanceSettings.defaultCursorIconZoom
    @AppStorage(PanelAppearanceSettings.cursorIconZoomSpreadKey) private var iconZoomSpread: Int = 0
    @AppStorage(CustomFolderIconService.enabledKey) private var showCustomFolderIcons: Bool = false
    @AppStorage(FolderStyleLibrary.generationKey) private var libraryGeneration: Int = 0
    @State private var hoveredCustom: String?
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }
    private var folderTint: NSColor {
        PanelAppearanceSettings.optionalNSColor(from: folderIconColorHex) ?? FolderIconStyle.defaultTint
    }

    var body: some View {
        Form {
            Section(L("design.section.folderIcons")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("design.folderIconStyle")).settingAnchor("design.folderIconStyle")
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
        .onTapGesture {
            folderIconStyleRaw = style.rawValue
            FolderIconRenderer.clearCache()
        }
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
        .contextMenu {
            Button(L("folderStyles.delete")) { FolderStyleLibrary.remove(entry.id) }
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
        let panel = NSOpenPanel()
        panel.title = L("folderStyles.add.title")
        panel.allowedContentTypes = [.svg, .png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entry = try FolderStyleLibrary.add(contentsOf: url)
            folderIconStyleRaw = FolderIconStyle.custom(entry.id).rawValue
            FolderIconRenderer.clearCache()
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
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Totum-folder-sample.svg"
        panel.allowedContentTypes = [.svg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FolderStyleLibrary.sampleSVG.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            DialogService.shared.showError(title: L("folderStyles.sample.failed"),
                                           message: error.localizedDescription)
        }
    }
}

