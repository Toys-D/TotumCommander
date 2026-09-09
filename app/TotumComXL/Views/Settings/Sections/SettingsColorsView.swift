import AppKit
import SwiftUI

struct SettingsColorsView: View {
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    @AppStorage(PanelAppearanceSettings.folderIconColorHexKey) private var folderIconColorHex: String = ""
    @AppStorage(PanelAppearanceSettings.folderNameColorHexKey) private var folderNameColorHex: String = ""
    @AppStorage(PanelAppearanceSettings.fileNameColorHexKey) private var fileNameColorHex: String = ""
    @AppStorage(PanelAppearanceSettings.appearanceModeKey) private var appearanceMode: Int = 0
    @AppStorage(PanelAppearanceSettings.beautyModeEnabledKey) private var beautyEnabled: Bool = false
    @AppStorage(PanelAppearanceSettings.alternateRowsEnabledKey) private var alternateRows: Bool = false
    @AppStorage(PanelAppearanceSettings.cursorBlurKey) private var cursorBlur: Double = PanelAppearanceSettings.defaultCursorBlur
    @AppStorage(PanelAppearanceSettings.cursorHeightKey) private var cursorHeight: Double = PanelAppearanceSettings.defaultCursorHeight
    @AppStorage(PanelAppearanceSettings.cursorWidthKey) private var cursorWidth: Double = PanelAppearanceSettings.defaultCursorWidth
    @AppStorage(PanelAppearanceSettings.cursorCornerKey) private var cursorCorner: Double = PanelAppearanceSettings.defaultCursorCorner
    @AppStorage(PanelAppearanceSettings.cursorOffsetXKey) private var cursorOffsetX: Double = 0
    @AppStorage(PanelAppearanceSettings.cursorOffsetYKey) private var cursorOffsetY: Double = 0
    @AppStorage(PanelAppearanceSettings.cursorAnchorXKey) private var cursorAnchorX: Double = PanelAppearanceSettings.defaultCursorAnchor
    @AppStorage(PanelAppearanceSettings.cursorAnchorYKey) private var cursorAnchorY: Double = PanelAppearanceSettings.defaultCursorAnchor
    @Environment(\.colorScheme) private var colorScheme
    /// Which theme's stored keys this page must read and write.
    ///
    /// Deliberately NOT `@Environment(\.colorScheme)`: the panel renderer and
    /// `syncThemedColorsToEffective()` both decide the theme from AppKit's effective appearance,
    /// and when SwiftUI's environment disagreed with it these pages edited the OTHER theme's keys —
    /// the cursor drew the dark colour while this page showed (and overwrote) the light one.
    /// `colorScheme` is still observed above so the view re-renders when the theme changes.
    private var isDark: Bool { PanelAppearanceSettings.isDarkAppearance }

    /// Quick-pick swatches for the accent (the former tab-accent presets).
    private var accentPresets: [String] {
        TabAccentColor.allCases.compactMap { PanelAppearanceSettings.hexString(from: $0.color) }
    }

    var body: some View {
        Form {
            Section(L("settings.appearance.title")) {
                Picker(L("settings.appearance.mode"), selection: Binding(
                    get: { appearanceMode },
                    set: { appearanceMode = $0; PanelAppearanceSettings.applyAppearanceMode() }
                )) {
                    Text(L("settings.appearance.system")).tag(0)
                    Text(L("settings.appearance.light")).tag(1)
                    Text(L("settings.appearance.dark")).tag(2)
                }
                .pickerStyle(.segmented)
                // NOTE: sibling rows MUST have UNIQUE explicit ids — two rows with the
                // same .id(colorScheme) collide and SwiftUI renders a clone of the
                // first row instead of the second. The id still includes the scheme so
                // the row rebuilds (re-reads its per-theme key) when the theme flips.
                colorRow(interfaceTitle, hex: interfaceBgBinding,
                         allowsReset: true, fallback: Color(nsColor: .windowBackgroundColor))
                    .id("interfaceColor-\(isDark ? "dark" : "light")")
                colorRow(titlebarTitle, hex: titlebarBinding,
                         allowsReset: true, fallback: Color(nsColor: .windowBackgroundColor))
                    .id("titlebarColor-\(isDark ? "dark" : "light")")
            }
            Section(L("design.section.accent")) {
                colorRow(L("design.color.accent"),
                         hex: themedColorBinding(PanelAppearanceSettings.accentColorHexKey,
                                                 PanelAppearanceSettings.accentColorHexLightKey,
                                                 PanelAppearanceSettings.accentColorHexDarkKey),
                         presets: accentPresets, fallback: .purple)
                    .id("accentColor-\(isDark ? "dark" : "light")")
                // Colour under the cursor, right here next to the accent — picking one turns on the
                // custom cursor colour; resetting turns it back off (cursor follows the accent).
                // The Cursor section keeps the full controls (this stays in sync with it).
                // Fallback shows what is ACTUALLY used when nothing is set — the automatic
                // black/white contrast against the cursor bar. The old system-selection blue made
                // the swatch look configured in a theme where no colour had been chosen at all.
                colorRow(L("design.color.cursorUnder"),
                         hex: cursorUnderBinding, allowsReset: true,
                         fallback: Color(nsColor: PanelAppearanceSettings.contrastingTextColor(
                             on: PanelAppearanceSettings.resolvedCursorBackground())))
                    .id("cursorUnderColor-\(isDark ? "dark" : "light")")
            }
            Section {
                colorRow(L("design.color.folderIcons"),
                         hex: themedColorBinding(PanelAppearanceSettings.folderIconColorHexKey,
                                                 PanelAppearanceSettings.folderIconColorHexLightKey,
                                                 PanelAppearanceSettings.folderIconColorHexDarkKey),
                         allowsReset: true, fallback: Color(nsColor: .systemBlue))
                    .id("folderIconColor-\(isDark ? "dark" : "light")")
                colorRow(L("design.color.folderNames"),
                         hex: themedColorBinding(PanelAppearanceSettings.folderNameColorHexKey,
                                                 PanelAppearanceSettings.folderNameColorHexLightKey,
                                                 PanelAppearanceSettings.folderNameColorHexDarkKey),
                         allowsReset: true, fallback: Color(nsColor: .systemYellow))
                    .id("folderNameColor-\(isDark ? "dark" : "light")")
                colorRow(L("design.color.fileNames"),
                         hex: themedColorBinding(PanelAppearanceSettings.fileNameColorHexKey,
                                                 PanelAppearanceSettings.fileNameColorHexLightKey,
                                                 PanelAppearanceSettings.fileNameColorHexDarkKey),
                         allowsReset: true, fallback: Color(nsColor: .labelColor))
                    .id("fileNameColor-\(isDark ? "dark" : "light")")
                colorRow(L("design.color.selectedNames"),
                         hex: themedColorBinding(PanelAppearanceSettings.selectedNameColorHexKey,
                                                 PanelAppearanceSettings.selectedNameColorHexLightKey,
                                                 PanelAppearanceSettings.selectedNameColorHexDarkKey),
                         allowsReset: true, fallback: PanelAppearanceSettings.accentColor)
                    .id("selectedNameColor-\(isDark ? "dark" : "light")")
                Text(L("design.color.selectedNames.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                colorRow(panelBackgroundTitle, hex: panelBgBinding,
                         allowsReset: true, fallback: Color(nsColor: .controlBackgroundColor))
                    .id("panelBgColor-\(isDark ? "dark" : "light")")

                // The switch first; the shade appears only while it is on, so there is never a
                // colour sitting there that changes nothing.
                Toggle(L("design.alternateRows"), isOn: $alternateRows)
                if alternateRows {
                    colorRow(alternateRowTitle, hex: alternateRowBinding,
                             allowsReset: true,
                             fallback: PanelAppearanceSettings.swiftUIColor(
                                from: PanelAppearanceSettings.defaultAlternateRowHex(dark: isDark),
                                fallback: .gray))
                        .id("alternateRowColor-\(isDark ? "dark" : "light")")
                }
            }

            // Performance / beauty effects live at the bottom of the design settings:
            // once colours are set, the user sees what fancier effects the Mac can run.
            Section(L("settings.performance.macInfo")) {
                infoRow(L("settings.performance.chip"), MacCapabilities.chipName)
                infoRow(L("settings.performance.memory"), "\(MacCapabilities.physicalMemoryGB) GB")
                infoRow(L("settings.performance.gpu"), gpuText)
            }
            Section {
                Toggle(L("settings.performance.beautyMode"), isOn: themedBoolBinding(
                    PanelAppearanceSettings.beautyModeEnabledKey,
                    PanelAppearanceSettings.beautyModeEnabledLightKey,
                    PanelAppearanceSettings.beautyModeEnabledDarkKey))
                    .id("beautyFlag-\(isDark ? "dark" : "light")")
                    .disabled(!beautySupported)
                Text(beautyVerdict)
                    .font(.caption)
                    .foregroundStyle(beautySupported ? Color.secondary : Color(nsColor: .systemOrange))
            } footer: {
                Text(L("settings.performance.beautyHint"))
            }
            Section(L("settings.performance.effects")) {
                HStack {
                    Text(L("settings.performance.cursorHeight"))
                    Slider(value: $cursorHeight, in: 0.3...1.0)
                    Text("\(Int(cursorHeight * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!beautyEnabled || !beautySupported)
                HStack {
                    Text(L("settings.performance.cursorWidth"))
                    Slider(value: $cursorWidth, in: 0.01...1.0)
                    Text("\(Int(cursorWidth * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!beautyEnabled || !beautySupported)
                HStack {
                    Text(L("settings.performance.cursorCorner"))
                    Slider(value: $cursorCorner, in: 0...20)
                    Text("\(Int(cursorCorner))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!beautyEnabled || !beautySupported)
                // The hand-drawn cursor: paint the shape yourself; colour and blur stay live.
                HStack {
                    Toggle(L("design.cursor.customMask"), isOn: customMaskBinding)
                    Spacer()
                    // Through a runloop callout, not straight from the button's gesture: a
                    // modal presented mid-callout starves its own SwiftUI buttons — the house
                    // pattern for every FCXLDialog opened from a control.
                    Button(L("design.cursor.customMask.draw")) {
                        fcxlPresentModal { CursorMaskEditor.show() }
                    }
                }
                .disabled(!beautyEnabled || !beautySupported)
                HStack {
                    Text(L("settings.performance.cursorBlur"))
                    Slider(value: $cursorBlur, in: 0...30)
                    Text("\(Int(cursorBlur))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!beautyEnabled || !beautySupported)
                HStack {
                    Text(L("settings.performance.cursorOffsetX"))
                    Slider(value: $cursorOffsetX, in: -100...100)
                    Text("\(Int(cursorOffsetX))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!beautyEnabled || !beautySupported)
                HStack {
                    Text(L("settings.performance.cursorOffsetY"))
                    Slider(value: $cursorOffsetY, in: -30...30)
                    Text("\(Int(cursorOffsetY))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!beautyEnabled || !beautySupported)
                HStack {
                    Text(L("settings.performance.cursorAnchorX"))
                    Slider(value: $cursorAnchorX, in: 0...1)
                    Text("\(Int(cursorAnchorX * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!beautyEnabled || !beautySupported)
                HStack {
                    Text(L("settings.performance.cursorAnchorY"))
                    Slider(value: $cursorAnchorY, in: 0...1)
                    Text("\(Int(cursorAnchorY * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!beautyEnabled || !beautySupported)
            }
        }
        .formStyle(.grouped)
        // Never leave beauty mode on where the hardware can't handle it.
        // Never leave beauty on where the hardware can't run it — clear the effective
        // AND both per-theme flags so a theme switch can't bring it back.
        .onAppear {
            guard !beautySupported else { return }
            let d = UserDefaults.standard
            for key in [PanelAppearanceSettings.beautyModeEnabledKey,
                        PanelAppearanceSettings.beautyModeEnabledLightKey,
                        PanelAppearanceSettings.beautyModeEnabledDarkKey] {
                if d.bool(forKey: key) { d.set(false, forKey: key) }
            }
        }
    }

    private var beautySupported: Bool { MacCapabilities.supportsBeautyMode }

    private var gpuText: String {
        let cores = MacCapabilities.gpuCoreCount
        guard cores > 0 else { return MacCapabilities.gpuName }
        return "\(MacCapabilities.gpuName) · \(cores) \(L("settings.performance.cores"))"
    }

    private var beautyVerdict: String {
        beautySupported
            ? L("settings.performance.verdictOk")
            : String(format: L("settings.performance.verdictNo"),
                     MacCapabilities.chipName, MacCapabilities.gpuCoreCount)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    /// Per-theme BOOL binding (writes the current theme's key + the shared effective key).
    private func themedBoolBinding(_ effective: String, _ light: String, _ dark: String) -> Binding<Bool> {
        let perThemeKey = isDark ? dark : light
        return Binding(
            get: { UserDefaults.standard.bool(forKey: perThemeKey) },
            set: {
                UserDefaults.standard.set($0, forKey: perThemeKey)
                UserDefaults.standard.set($0, forKey: effective)
            }
        )
    }

    /// Binding for a per-theme colour: reads/writes the value remembered for the theme
    /// currently on screen, and mirrors it into the shared "effective" key so every live
    /// consumer (accent tint, folder icons, …) updates at once.
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

    /// Panel background is stored per theme — edit the color for the theme currently on
    /// screen. Writing straight to UserDefaults fires the panel's KVO so it updates live.
    private var panelBgBinding: Binding<String> {
        let key = PanelAppearanceSettings.panelBackgroundKey(dark: isDark)
        return Binding(
            get: { UserDefaults.standard.string(forKey: key) ?? "" },
            set: {
                if $0.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
                else { UserDefaults.standard.set($0, forKey: key) }
            }
        )
    }

    /// The stripe shade for the theme on screen — per theme, like the panel background.
    private var alternateRowBinding: Binding<String> {
        let key = PanelAppearanceSettings.alternateRowColorKey(dark: isDark)
        return Binding(
            get: { UserDefaults.standard.string(forKey: key) ?? "" },
            set: {
                if $0.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
                else { UserDefaults.standard.set($0, forKey: key) }
            }
        )
    }

    private var alternateRowTitle: String {
        L("design.alternateRows.color") + " — "
            + L(isDark ? "settings.appearance.dark" : "settings.appearance.light")
    }

    /// Enabled only makes sense once something was drawn — flipping it on with no mask keeps
    /// the classic bar, so the toggle simply reflects the stored flag.
    private var customMaskBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: CursorMaskStore.enabledKey) },
            set: { CursorMaskStore.setEnabled($0) }   // tells the panels; a raw write cannot
        )
    }

    private var panelBackgroundTitle: String {
        L("design.color.panelBackground") + " — "
            + L(isDark ? "settings.appearance.dark" : "settings.appearance.light")
    }

    /// Interface (window chrome) tint for the theme on screen. Posts the appearance
    /// notification so the AppKit window background repaints too (SwiftUI bars react
    /// via @AppStorage on their own).
    private var interfaceBgBinding: Binding<String> {
        let key = PanelAppearanceSettings.interfaceColorKey(dark: isDark)
        return Binding(
            get: { UserDefaults.standard.string(forKey: key) ?? "" },
            set: {
                if $0.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
                else { UserDefaults.standard.set($0, forKey: key) }
                NotificationCenter.default.post(name: .fcxlAppearanceChanged, object: nil)
            }
        )
    }

    private var interfaceTitle: String {
        L("design.color.interface") + " — "
            + L(isDark ? "settings.appearance.dark" : "settings.appearance.light")
    }

    /// Titlebar-only colour for the theme on screen; posts the appearance
    /// notification so the AppKit window repaints live.
    private var titlebarBinding: Binding<String> {
        let key = PanelAppearanceSettings.titlebarColorKey(dark: isDark)
        return Binding(
            get: { UserDefaults.standard.string(forKey: key) ?? "" },
            set: {
                if $0.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
                else { UserDefaults.standard.set($0, forKey: key) }
                NotificationCenter.default.post(name: .fcxlAppearanceChanged, object: nil)
            }
        )
    }

    private var titlebarTitle: String {
        L("design.color.titlebar") + " — "
            + L(isDark ? "settings.appearance.dark" : "settings.appearance.light")
    }

    /// "Colour under cursor" for the Design page. Picking a colour enables the custom cursor colour
    /// (per theme + effective key) and stores it; resetting disables it so the cursor follows the
    /// accent again. Reads back the stored colour only while custom mode is on — otherwise empty
    /// (meaning "using the accent"). Stays consistent with the fuller Cursor settings section.
    /// "Colour under cursor" on the Design page: the colour a file or folder NAME takes while the
    /// cursor is on it (Total Commander's foreground-colour-of-cursor). Its own per-theme setting —
    /// picking a colour here must not switch the Cursor section's custom mode on, and it never
    /// tints the cursor bar. See resolvedCursorNameColor() for the precedence.
    private var cursorUnderBinding: Binding<String> {
        let colorKey = isDark ? PanelAppearanceSettings.cursorUnderNameColorHexDarkKey
                              : PanelAppearanceSettings.cursorUnderNameColorHexLightKey
        return Binding(
            get: { UserDefaults.standard.string(forKey: colorKey) ?? "" },
            set: { newValue in
                let d = UserDefaults.standard
                if newValue.isEmpty {
                    d.removeObject(forKey: colorKey)
                    d.removeObject(forKey: PanelAppearanceSettings.cursorUnderNameColorHexKey)
                } else {
                    d.set(newValue, forKey: colorKey)
                    d.set(newValue, forKey: PanelAppearanceSettings.cursorUnderNameColorHexKey)
                }
            }
        )
    }

    private func colorRow(_ title: String, hex: Binding<String>, presets: [String] = [],
                          allowsReset: Bool = false, fallback: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            FCXLColorPicker(hex: hex, presets: presets, allowsReset: allowsReset, fallback: fallback)
        }
    }
}
