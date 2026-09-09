import AppKit
import SwiftUI

struct SettingsRootView: View {
    @AppStorage(SettingsSection.lastKey) private var lastSectionRaw: String = SettingsSection.general.rawValue
    @State private var selection: SettingsSection = .general
    @State private var window: NSWindow?
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color { PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SettingsSidebar(selection: $selection)
                Divider()
                SettingsDetailView(section: selection)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            // Full-width OK button at the bottom — the only way to dismiss
            // (the window has no close/minimize buttons).
            Button(action: closeSettings) { Text("OK") }
                .buttonStyle(SettingsOKButtonStyle(
                    accent: accent,
                    textColor: PanelAppearanceSettings.contrastingTextColor(on: accent)))
                .keyboardShortcut(.defaultAction)
        }
        // Flexible: the content fills the window, so it grows TOGETHER with the
        // window frame during the open "grow" (no clipping, no fixed size).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(accent)
        .background(WindowAccessor { win in
            configure(win)
            window = win
        })
        .onChange(of: selection) { new in
            lastSectionRaw = new.rawValue
        }
        .onAppear {
            selection = SettingsSection(rawValue: lastSectionRaw) ?? .general
        }
        // ESC dismisses via the same animated path (and ends the modal session),
        // instead of the window's default close which would leave the modal loop.
        .onExitCommand { closeSettings() }
    }

    private func closeSettings() {
        guard let window else { return }
        SettingsWindowAnimator.closeWithShrink(window)
    }

    private func configure(_ window: NSWindow) {
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Full-width accent OK button with a soft press animation.
private struct SettingsOKButtonStyle: ButtonStyle {
    let accent: Color
    let textColor: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(textColor)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(accent.opacity(configuration.isPressed ? 0.82 : 1))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.995 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Grabs the hosting NSWindow once it's available.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onResolve(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
