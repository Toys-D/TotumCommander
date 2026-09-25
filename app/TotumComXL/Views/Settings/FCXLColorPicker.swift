import AppKit
import SwiftUI

/// A self-contained colour picker that never opens the macOS system colour panel.
/// Renders a swatch button; clicking it shows a popover with an HSV square, H/S/B
/// gradient sliders, optional preset swatches, a shared "saved colours" palette,
/// a hex field, and an OK button. Binds to a hex string (`#RRGGBB`/`#RRGGBBAA`);
/// an empty string means "no value" and shows `fallback`.
struct FCXLColorPicker: View {
    @Binding var hex: String
    var presets: [String] = []
    var allowsReset: Bool = false
    var resetTitle: String = L("design.color.resetToSystem")
    var fallback: Color = .gray

    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(currentColor)
                .frame(width: 46, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.primary.opacity(0.18))
                )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            FCXLColorPickerPanel(
                hex: $hex,
                presets: presets,
                allowsReset: allowsReset,
                resetTitle: resetTitle,
                fallback: fallback,
                onDone: { showPopover = false }
            )
            .frame(width: 252)
            .padding(12)
        }
    }

    private var currentColor: Color {
        hex.isEmpty ? fallback : PanelAppearanceSettings.swiftUIColor(from: hex, fallback: fallback)
    }
}

// MARK: - Popover content

/// The picker panel itself (HSV square, sliders, eyedropper, palettes, hex). Public so non-Settings
/// callers (e.g. the tab-colour popover) can host it directly, not only via the swatch button.
struct FCXLColorPickerPanel: View {
    @Binding var hex: String
    let presets: [String]
    let allowsReset: Bool
    let resetTitle: String
    let fallback: Color
    let onDone: () -> Void

    // Shared, persisted palette of user-saved colours (comma-separated hex list).
    @AppStorage("fcxl.savedColors") private var savedColorsRaw: String = ""
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    @State private var hue: CGFloat = 0      // 0…1
    @State private var sat: CGFloat = 1      // 0…1
    @State private var bri: CGFloat = 1      // 0…1
    @State private var hexField: String = ""
    // Sliders follow `hex` through onChange, except when the sliders themselves wrote it — see
    // needsSliderReload. (A flag used to do this and got stuck whenever a drag landed on the
    // colour already there: onChange never fired to clear it, and the next preset tap changed
    // the colour but left the sliders where they were.)
    // A drag's own hex must not reload mid-gesture — the HSB state is already right and a reload
    // would fight the drag; every OTHER source (eyedropper, preset, hex field, reset) must.

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            saturationBrightnessSquare

            slider(title: L("colorPicker.hue"), value: $hue, display: "\(Int((hue * 360).rounded()))°", track: hueStops)
            slider(title: L("colorPicker.saturation"), value: $sat, display: "\(Int((sat * 100).rounded())) %", track: saturationTrack)
            slider(title: L("colorPicker.brightness"), value: $bri, display: "\(Int((bri * 100).rounded())) %", track: brightnessTrack)

            if !presets.isEmpty {
                swatchRow(presets) { applyHex($0) }
            }

            savedPalette

            HStack(spacing: 8) {
                eyedropperButton
                Text("#").foregroundColor(.secondary)
                TextField("RRGGBB", text: $hexField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 88)
                    .onSubmit(applyHexField)
                if allowsReset {
                    Button(resetTitle) { hex = "" }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Spacer(minLength: 0)
            }

            Button(action: onDone) { Text("OK") }
                .buttonStyle(FCXLDialogPrimaryButtonStyle(
                    accent: accent,
                    textColor: PanelAppearanceSettings.contrastingTextColor(on: accent),
                    fontSize: 14, height: 36, cornerRadius: 8))
                .keyboardShortcut(.defaultAction)
        }
        .onAppear(perform: load)
        .onChange(of: hex) { newValue in
            if Self.needsSliderReload(hex: newValue, sliders: PanelAppearanceSettings.hexString(
                hue: hue, saturation: sat, brightness: bri)) { load() }
        }
    }

    /// Eyedropper: sample any pixel on the screen (system magnifier). Sets `hex`; the onChange
    /// reload then moves the square/sliders to the sampled colour.
    private var eyedropperButton: some View {
        Button {
            NSColorSampler().show { picked in
                guard let picked else { return }
                hex = PanelAppearanceSettings.hexString(from: picked)
            }
        } label: {
            Image(systemName: "eyedropper")
                .font(.system(size: 13))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("colorPicker.eyedropper"))
    }

    // MARK: - HSV square

    private var saturationBrightnessSquare: some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1))
                LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .background(Circle().fill(previewColor))
                    .frame(width: 14, height: 14)
                    .shadow(radius: 1)
                    .position(x: sat * geo.size.width, y: (1 - bri) * geo.size.height)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard geo.size.width > 0, geo.size.height > 0 else { return }
                    sat = clamp(value.location.x / geo.size.width)
                    bri = 1 - clamp(value.location.y / geo.size.height)
                    commit()
                }
            )
        }
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }

    // MARK: - Sliders

    private func slider(title: String, value: Binding<CGFloat>, display: String, track: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(display).font(.caption).foregroundColor(.secondary).monospacedDigit()
            }
            GradientSlider(value: value, track: track, onChange: commit)
        }
    }

    // MARK: - Palettes

    private func swatchRow(_ colors: [String], onTap: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(colors, id: \.self) { c in
                Button { onTap(c) } label: {
                    Circle()
                        .fill(PanelAppearanceSettings.swiftUIColor(from: c, fallback: .gray))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var savedPalette: some View {
        HStack(spacing: 6) {
            ForEach(savedColors, id: \.self) { c in
                Button { applyHex(c) } label: {
                    Circle()
                        .fill(PanelAppearanceSettings.swiftUIColor(from: c, fallback: .gray))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .contextMenu { Button(L("common.delete"), role: .destructive) { removeSaved(c) } }
            }
            Button(action: saveCurrent) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L("colorPicker.saveCurrent"))
            Spacer(minLength: 0)
        }
    }

    // MARK: - Derived

    private var previewColor: Color {
        Color(nsColor: NSColor(hue: hue, saturation: sat, brightness: bri, alpha: 1))
    }

    private var hueStops: [Color] {
        stride(from: 0.0, through: 1.0, by: 1.0 / 6.0).map {
            Color(nsColor: NSColor(hue: CGFloat($0), saturation: 1, brightness: 1, alpha: 1))
        }
    }

    private var saturationTrack: [Color] {
        [Color(nsColor: NSColor(hue: hue, saturation: 0, brightness: bri, alpha: 1)),
         Color(nsColor: NSColor(hue: hue, saturation: 1, brightness: bri, alpha: 1))]
    }

    private var brightnessTrack: [Color] {
        [.black, Color(nsColor: NSColor(hue: hue, saturation: sat, brightness: 1, alpha: 1))]
    }

    private var savedColors: [String] {
        savedColorsRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    private var displayHex: String {
        let stripped = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if stripped.count >= 6 { return String(stripped.prefix(6)).uppercased() }
        let derived = PanelAppearanceSettings.hexString(hue: hue, saturation: sat, brightness: bri)
        return String(derived.dropFirst().prefix(6)).uppercased()
    }

    // MARK: - Actions

    private func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }

    private func load() {
        if let hsb = PanelAppearanceSettings.hsbComponents(fromHex: hex) {
            (hue, sat, bri) = (hsb.hue, hsb.saturation, hsb.brightness)
        } else {
            let hsb = PanelAppearanceSettings.hsbComponents(from: fallback)
            (hue, sat, bri) = (hsb.hue, hsb.saturation, hsb.brightness)
        }
        hexField = displayHex
    }

    private func commit() {
        hex = PanelAppearanceSettings.hexString(hue: hue, saturation: sat, brightness: bri)
        hexField = displayHex
    }

    /// Whether a new `hex` must move the sliders: yes for a preset, the eyedropper, the hex
    /// field or a reset — no when it is the colour the sliders already stand on, which is what a
    /// drag writes. Compared as colours, not strings: "#ff8800" and "#FF8800" are one colour.
    static func needsSliderReload(hex: String, sliders: String) -> Bool {
        hex.trimmingCharacters(in: .whitespaces).lowercased() != sliders.lowercased()
    }

    private func applyHex(_ value: String) {
        hex = value             // onChange reloads the square/sliders
    }

    private func applyHexField() {
        let cleaned = hexField.trimmingCharacters(in: .whitespaces)
        if PanelAppearanceSettings.optionalNSColor(from: cleaned) != nil {
            hex = cleaned.hasPrefix("#") ? cleaned : "#" + cleaned   // onChange reloads
        } else {
            hexField = displayHex
        }
    }

    private func saveCurrent() {
        let current = "#" + displayHex
        var list = savedColors
        guard !list.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) else { return }
        list.append(current)
        if list.count > 12 { list.removeFirst(list.count - 12) }
        savedColorsRaw = list.joined(separator: ",")
    }

    private func removeSaved(_ value: String) {
        savedColorsRaw = savedColors
            .filter { $0.caseInsensitiveCompare(value) != .orderedSame }
            .joined(separator: ",")
    }
}

// MARK: - Gradient slider

/// A horizontal slider whose track is an arbitrary gradient (hue rainbow,
/// saturation ramp, brightness ramp). Value is 0…1.
private struct GradientSlider: View {
    @Binding var value: CGFloat
    let track: [Color]
    let onChange: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.25)))
                    .frame(width: geo.size.height, height: geo.size.height)
                    .shadow(radius: 1)
                    .position(x: value * geo.size.width, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { v in
                    guard geo.size.width > 0 else { return }
                    value = min(max(v.location.x / geo.size.width, 0), 1)
                    onChange()
                }
            )
        }
        .frame(height: 18)
    }
}
