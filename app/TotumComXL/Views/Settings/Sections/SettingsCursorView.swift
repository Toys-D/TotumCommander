import AppKit
import SwiftUI

struct SettingsCursorView: View {
    @AppStorage(PanelAppearanceSettings.cursorUsesCustomColorKey) private var cursorUsesCustomColor: Bool = false
    @AppStorage(PanelAppearanceSettings.cursorOutlineEnabledKey) private var outlineEnabled: Bool = false
    @AppStorage(PanelAppearanceSettings.cursorOutlineWidthKey) private var outlineWidth: Double =
        PanelAppearanceSettings.defaultCursorOutlineWidth
    @Environment(\.colorScheme) private var colorScheme
    /// Which theme's stored keys this page must read and write.
    ///
    /// Deliberately NOT `@Environment(\.colorScheme)`: the panel renderer and
    /// `syncThemedColorsToEffective()` both decide the theme from AppKit's effective appearance,
    /// and when SwiftUI's environment disagreed with it these pages edited the OTHER theme's keys —
    /// the cursor drew the dark colour while this page showed (and overwrote) the light one.
    /// `colorScheme` is still observed above so the view re-renders when the theme changes.
    private var isDark: Bool { PanelAppearanceSettings.isDarkAppearance }

    /// Per-theme colour binding (writes the current theme's key + the shared effective
    /// key), so cursor colours are remembered separately for light and dark.
    private func themedColorBinding(_ effective: String, _ light: String, _ dark: String) -> Binding<String> {
        let perThemeKey = isDark ? dark : light
        return Binding(
            get: { UserDefaults.standard.string(forKey: perThemeKey) ?? "" },
            set: {
                let d = UserDefaults.standard
                if $0.isEmpty {
                    d.removeObject(forKey: perThemeKey); d.removeObject(forKey: effective)
                } else {
                    d.set($0, forKey: perThemeKey); d.set($0, forKey: effective)
                }
            }
        )
    }

    /// Per-theme BOOL binding (writes the current theme's key + the shared effective key).
    /// Reads the EFFECTIVE mirror (the same value the cursor is drawn from, and the same one
    /// @AppStorage observes) and writes through the shared setter so the theme keys stay in step.
    /// Reading the per-theme key here instead was what let this toggle show "off" while the cursor
    /// on screen was clearly using a custom colour.
    private func themedBoolBinding(_ effective: String, _ light: String, _ dark: String) -> Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: effective) },
            set: { PanelAppearanceSettings.setThemedBool($0, effective: effective, light: light, dark: dark) }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle(L("design.cursor.customColor"), isOn: themedBoolBinding(
                    PanelAppearanceSettings.cursorUsesCustomColorKey,
                    PanelAppearanceSettings.cursorUsesCustomColorLightKey,
                    PanelAppearanceSettings.cursorUsesCustomColorDarkKey))
                    .id("cursorCustomFlag-\(isDark ? "dark" : "light")")

                if cursorUsesCustomColor {
                    HStack {
                        Text(L("design.color.cursorBackground"))
                        Spacer()
                        FCXLColorPicker(hex: themedColorBinding(
                            PanelAppearanceSettings.cursorBackgroundColorHexKey,
                            PanelAppearanceSettings.cursorBackgroundColorHexLightKey,
                            PanelAppearanceSettings.cursorBackgroundColorHexDarkKey),
                                        allowsReset: true,
                                        fallback: Color(nsColor: .selectedContentBackgroundColor))
                    }
                    .id("cursorBg-\(isDark ? "dark" : "light")")
                    HStack {
                        Text(L("design.color.cursorName"))
                        Spacer()
                        FCXLColorPicker(hex: themedColorBinding(
                            PanelAppearanceSettings.cursorNameColorHexKey,
                            PanelAppearanceSettings.cursorNameColorHexLightKey,
                            PanelAppearanceSettings.cursorNameColorHexDarkKey),
                                        allowsReset: true,
                                        fallback: Color(nsColor: .systemOrange))
                    }
                    .id("cursorName-\(isDark ? "dark" : "light")")
                } else {
                    Text(L("design.cursor.accentHint"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // The rim: a crisp edge around the soft body — the look the mask bubble has. Drawn
            // after the feathering, so raising the blur softens the fill and leaves it sharp.
            Section {
                Toggle(L("design.cursor.outline"), isOn: themedBoolBinding(
                    PanelAppearanceSettings.cursorOutlineEnabledKey,
                    PanelAppearanceSettings.cursorOutlineEnabledLightKey,
                    PanelAppearanceSettings.cursorOutlineEnabledDarkKey))
                    .id("cursorOutlineFlag-\(isDark ? "dark" : "light")")

                if outlineEnabled {
                    HStack {
                        Text(L("design.cursor.outlineColor"))
                        Spacer()
                        FCXLColorPicker(hex: themedColorBinding(
                            PanelAppearanceSettings.cursorOutlineColorHexKey,
                            PanelAppearanceSettings.cursorOutlineColorHexLightKey,
                            PanelAppearanceSettings.cursorOutlineColorHexDarkKey),
                                        allowsReset: true,
                                        fallback: Color(nsColor: PanelAppearanceSettings
                                            .resolvedCursorOutlineColor()))
                    }
                    .id("cursorOutlineColor-\(isDark ? "dark" : "light")")
                    HStack {
                        Text(L("design.cursor.outlineWidth"))
                        Slider(value: $outlineWidth, in: 0.5...6)
                        Text(String(format: "%.1f", outlineWidth))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                } else {
                    Text(L("design.cursor.outlineHint"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text(L("design.cursor.outlineSection"))
            }
        }
        .formStyle(.grouped)
    }
}
