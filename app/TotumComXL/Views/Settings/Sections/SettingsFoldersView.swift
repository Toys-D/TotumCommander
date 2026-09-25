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
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    var body: some View {
        Form {
            Section(L("design.section.folderIcons")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("design.folderIconStyle"))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(FolderIconStyle.allCases) { style in
                            VStack(spacing: 4) {
                                let tintColor: Color? = {
                                    guard let c = PanelAppearanceSettings.optionalNSColor(from: folderIconColorHex) else { return nil }
                                    return Color(nsColor: c)
                                }()
                                FolderCanvasView(
                                    style: style,
                                    baseColor: tintColor ?? Color(red: 0.42, green: 0.73, blue: 0.95)
                                )
                                .frame(width: 36, height: 36)
                                Text(style.title)
                                    .font(.system(size: 9))
                                    .lineLimit(1)
                            }
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(folderIconStyleRaw == style.rawValue
                                          ? accent.opacity(0.2)
                                          : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(folderIconStyleRaw == style.rawValue
                                            ? accent
                                            : Color.clear, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                folderIconStyleRaw = style.rawValue
                                FolderIconRenderer.clearCache()
                            }
                        }
                    }
                }
                Toggle(L("settings.folders.customIcons"), isOn: $showCustomFolderIcons)
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
                Toggle(L("settings.folders.iconZoom"), isOn: $iconZoomEnabled)
                HStack {
                    Text(L("settings.folders.iconZoomAmount"))
                    Slider(value: $iconZoomAmount, in: 1.0...2.0)
                    Text("\(Int(iconZoomAmount * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .disabled(!iconZoomEnabled)
                HStack {
                    Text(L("settings.folders.iconZoomSpread"))
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
