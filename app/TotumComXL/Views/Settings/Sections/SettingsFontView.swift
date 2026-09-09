import AppKit
import SwiftUI

/// File-list typography: font family, size, weight and line spacing, plus a switch that
/// enlarges the text on the cursor row. Applies to every view mode.
struct SettingsFontView: View {
    @AppStorage(PanelAppearanceSettings.listFontFamilyKey) private var fontFamily: String = ""
    @AppStorage(PanelAppearanceSettings.listFontSizeKey) private var fontSize: Double = PanelAppearanceSettings.defaultListFontSize
    @AppStorage(PanelAppearanceSettings.listFontBoldKey) private var fontBold: Bool = false
    @AppStorage(PanelAppearanceSettings.listLetterSpacingKey) private var letterSpacing: Double = 0
    @AppStorage(PanelAppearanceSettings.cursorFontZoomEnabledKey) private var fontZoomEnabled: Bool = false
    @AppStorage(PanelAppearanceSettings.cursorFontZoomAmountKey) private var fontZoomAmount: Double = PanelAppearanceSettings.defaultCursorFontZoom

    private let families: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Form {
            Section(L("settings.font.section")) {
                LabeledContent(L("settings.font.family")) {
                    FCXLDialogMenuPicker(items: [""] + families,
                                         selection: $fontFamily,
                                         title: { $0.isEmpty ? L("settings.font.system") : $0 })
                }
                Toggle(L("settings.font.bold"), isOn: $fontBold)
                sliderRow(L("settings.font.size"), value: $fontSize, range: 8...28, label: "\(Int(fontSize)) pt")
                sliderRow(L("settings.font.letterSpacing"), value: $letterSpacing, range: -3...10,
                          label: String(format: "%.1f pt", letterSpacing))
            }

            Section(L("settings.font.preview")) {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    Text("Documents").font(previewFont).tracking(CGFloat(letterSpacing))
                    Spacer()
                    Text("2026-07-10").font(previewFont).foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(L("settings.font.cursorZoom"), isOn: $fontZoomEnabled)
                HStack {
                    Text(L("settings.font.cursorZoomAmount"))
                    Slider(value: $fontZoomAmount, in: 1.0...2.0)
                    Text("\(Int(fontZoomAmount * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .disabled(!fontZoomEnabled)
            } header: {
                Text(L("settings.font.cursorZoomSection"))
            } footer: {
                Text(L("settings.font.cursorZoomHint"))
            }
        }
        .formStyle(.grouped)
    }

    private var previewFont: Font {
        let base = fontFamily.isEmpty ? Font.system(size: fontSize) : Font.custom(fontFamily, size: fontSize)
        return fontBold ? base.bold() : base
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(label)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
    }
}
