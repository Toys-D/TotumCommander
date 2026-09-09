import SwiftUI

struct SettingsListView: View {
    @AppStorage("briefColumnWidth") private var briefColumnWidth: Double = 190
    @AppStorage("briefRowHeight") private var briefRowHeight: Double = 26
    @AppStorage(PanelAppearanceSettings.iconScaleKey) private var iconScale: Double = PanelAppearanceSettings.defaultIconScale
    @AppStorage(PanelAppearanceSettings.upIconScaleKey) private var upIconScale: Double = PanelAppearanceSettings.defaultUpIconScale
    @AppStorage(PanelAppearanceSettings.thumbnailSizeKey) private var thumbnailSize: Double = PanelAppearanceSettings.defaultThumbnailSize
    @AppStorage(PanelAppearanceSettings.upIconWeightKey) private var upIconWeight: Double = PanelAppearanceSettings.defaultUpIconWeight
    @AppStorage(PanelAppearanceSettings.upIconSymbolKey) private var upIconSymbol: String = PanelAppearanceSettings.defaultUpIconSymbol
    @AppStorage("iconNameGap") private var iconNameGap: Double = 6
    // Lives here, with the other row measurements: it is about how a ROW is laid out, not
    // about what a folder icon looks like.
    @AppStorage(PanelAppearanceSettings.iconEdgeInsetKey) private var iconEdgeInset: Double =
        PanelAppearanceSettings.defaultIconEdgeInset

    @AppStorage(PanelAppearanceSettings.gitStatusEnabledKey) private var showGitStatus = true

    var body: some View {
        Form {
            Section {
                Toggle(L("settings.git.show"), isOn: $showGitStatus)
                Text(L("settings.git.note"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L("settings.git.title"))
            }

            // Три группы вместо одной длинной ленты ползунков: заголовок говорит, к чему
            // относится каждый, и подписи под отдельными строками больше не нужны — они
            // висели посреди списка и читались как приписка к соседнему ползунку.
            Section {
                row(L("design.briefColumnWidth"), value: $briefColumnWidth, in: 120...400, step: 10,
                    display: "\(Int(briefColumnWidth)) \(L("unit.pixels"))")
                row(L("design.rowHeight"), value: $briefRowHeight, in: 18...60, step: 0.5,
                    display: String(format: "%.1f \(L("unit.pixels"))", briefRowHeight))
                row(L("design.iconScale"), value: $iconScale,
                    in: PanelAppearanceSettings.minimumIconScale...PanelAppearanceSettings.maximumIconScale,
                    step: 0.01,
                    display: String(format: "%.2fx", iconScale))
                row(L("design.iconNameGap"), value: $iconNameGap, in: 0...20, step: 0.5,
                    display: String(format: "%.1f \(L("unit.pixels"))", iconNameGap))
                row(L("settings.performance.iconEdgeInset"), value: $iconEdgeInset,
                    in: 0...40, step: 1,
                    display: "\(Int(iconEdgeInset)) \(L("unit.pixels"))")
            } header: {
                Text(L("design.section.rows"))
            } footer: {
                Text(L("settings.performance.iconEdgeInsetHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                row(L("design.thumbnailSize"), value: $thumbnailSize,
                    in: PanelAppearanceSettings.minimumThumbnailSize...PanelAppearanceSettings.maximumThumbnailSize,
                    step: 10,
                    display: "\(Int(thumbnailSize)) \(L("unit.pixels"))")
            } header: {
                Text(L("design.section.thumbnails"))
            }

            Section {
                LabeledContent(L("design.upIcon.kind")) {
                    FCXLDialogMenuPicker(
                        items: PanelAppearanceSettings.upIconSymbolOptions.map(\.symbol),
                        selection: $upIconSymbol,
                        title: { symbol in
                            let options = PanelAppearanceSettings.upIconSymbolOptions
                            return L(options.first { $0.symbol == symbol }?.nameKey ?? "")
                        },
                        icon: { $0 })
                }
                row(L("design.upIcon.scale"), value: $upIconScale, in: 0.3...2.0, step: 0.05,
                    display: String(format: "%.2fx", upIconScale))
                row(L("design.upIcon.weight"), value: $upIconWeight, in: 0...6, step: 1,
                    display: upIconWeightName(Int(upIconWeight.rounded())))
            } header: {
                Text(L("design.section.upIcon"))
            }
        }
        .formStyle(.grouped)
    }

    /// A CONTINUOUS slider (no `step:` — that maps to NSSlider tick marks, and a
    /// fine step like 0.01 draws ~125 ticks every frame → stutter). The value is
    /// snapped to `step` on change instead.
    private func row(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                     step: Double, display: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(display)
                    .foregroundColor(.secondary)
            }
            Slider(value: value.snapped(to: step), in: range)
        }
    }

    /// Human name for a ".." chevron weight index (matches PanelAppearanceSettings.upIconWeights).
    private func upIconWeightName(_ index: Int) -> String {
        let keys = ["weight.ultraLight", "weight.thin", "weight.light",
                    "weight.regular", "weight.medium", "weight.semibold", "weight.bold"]
        return L(keys[max(0, min(keys.count - 1, index))])
    }
}
