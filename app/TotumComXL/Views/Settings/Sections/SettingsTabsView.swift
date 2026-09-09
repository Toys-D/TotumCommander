import SwiftUI

struct SettingsTabsView: View {
    @AppStorage("tabFontSize") private var tabFontSize: Double = 13
    @AppStorage("tabCornerRadius") private var tabCornerRadius: Double = 8
    @AppStorage("tabChipHeight") private var tabChipHeight: Double = 28
    @AppStorage("tabMaxWidth") private var tabMaxWidth: Double = 200
    @AppStorage("tabMinWidth") private var tabMinWidth: Double = 80
    @AppStorage("tabBarHeight") private var tabBarHeight: Double = 32
    @AppStorage("tabBarSpacing") private var tabBarSpacing: Double = 10
    /// Follows the app appearance, NOT SwiftUI's colorScheme — the renderer uses the same source,
    /// and when the two disagree the settings page reads and writes the other theme's keys.
    private var isDark: Bool { PanelAppearanceSettings.isDarkAppearance }

    /// Fill opacity of the ACTIVE tab. Stored 0…1; the slider shows percent.
    @AppStorage(PanelAppearanceSettings.tabActiveOpacityKey) private var tabActiveOpacity: Double =
        PanelAppearanceSettings.defaultTabActiveOpacity

    var body: some View {
        Form {
            Section(L("design.section.tabs")) {
                Text(L("design.tabs.accentHint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                slider(L("design.tabFontSize"), value: $tabFontSize, in: 10...18, step: 1, unit: "pt")
                slider(L("design.tabCornerRadius"), value: $tabCornerRadius, in: 0...20, step: 1, unit: "px")
                slider(L("design.tabChipHeight"), value: $tabChipHeight, in: 18...40, step: 1, unit: "pt")
                slider(L("design.tabMaxWidth"), value: $tabMaxWidth, in: 80...400, step: 10, unit: "px")
                slider(L("design.tabMinWidth"), value: $tabMinWidth, in: 40...200, step: 10, unit: "px")
                slider(L("design.tabBarHeight"), value: $tabBarHeight, in: 24...48, step: 2, unit: "pt")
                slider(L("design.tabBarSpacing"), value: $tabBarSpacing, in: 0...16, step: 1, unit: "pt")
                // Percent on screen, 0…1 in storage — a slider from 0.2 to 1.0 reads as nothing.
                slider(L("design.tabActiveOpacity"),
                       value: Binding(get: { tabActiveOpacity * 100 },
                                      set: { tabActiveOpacity = $0 / 100 }),
                       in: 20...100, step: 5, unit: "%")
                Text(L("design.tabActiveOpacity.hint"))
                    .font(.caption).foregroundColor(.secondary)

                HStack {
                    Text(L("design.tabActiveTitleColor") + " — "
                         + L(isDark ? "settings.appearance.dark" : "settings.appearance.light"))
                    Spacer()
                    FCXLColorPicker(hex: activeTitleBinding, allowsReset: true,
                                    fallback: Color.primary)
                }
                .id("tabActiveTitle-\(isDark ? "dark" : "light")")
                Text(L("design.tabActiveTitleColor.hint"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Stored per theme, mirrored into the effective key the tab bar reads — the same shape as
    /// every other themed colour, so switching appearance swaps it automatically.
    private var activeTitleBinding: Binding<String> {
        let colorKey = isDark ? PanelAppearanceSettings.tabActiveTitleColorHexDarkKey
                              : PanelAppearanceSettings.tabActiveTitleColorHexLightKey
        return Binding(
            get: { UserDefaults.standard.string(forKey: colorKey) ?? "" },
            set: { newValue in
                let d = UserDefaults.standard
                if newValue.isEmpty {
                    d.removeObject(forKey: colorKey)
                    d.removeObject(forKey: PanelAppearanceSettings.tabActiveTitleColorHexKey)
                } else {
                    d.set(newValue, forKey: colorKey)
                    d.set(newValue, forKey: PanelAppearanceSettings.tabActiveTitleColorHexKey)
                }
            }
        )
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                        step: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
            Slider(value: value.snapped(to: step), in: range)
        }
    }
}
