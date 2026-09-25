import SwiftUI

/// Библиотека значков: окно, из которого человек выбирает значок папке или операции
/// туннеля. Щелчок по значку и есть выбор — отдельная кнопка «ОК» была бы лишним шагом.
@MainActor
enum TunnelIconPickerController {

    /// Возвращает выбранный значок или nil, если человек передумал.
    static func show(current: String) -> String? {
        FCXLDialog.runModal(size: NSSize(width: 380, height: 560)) { session in
            TunnelIconPickerView(current: current, session: session)
        }
    }
}

private struct TunnelIconPickerView: View {

    let current: String
    let session: FCXLDialogSession<String>

    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    private var accent: Color {
        PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    /// Разделы библиотеки и, в конце, значки команд меню, которых в ней нет.
    private var sections: [(title: String, icons: [String])] {
        var all = TunnelIconLibrary.sections.map { (L($0.title), $0.icons) }
        let extra = TunnelIconLibrary.menuIcons()
        if !extra.isEmpty { all.append((L("tunnel.icons.menu"), extra)) }
        return all
    }

    var body: some View {
        VStack(spacing: 0) {
            FCXLDialogHeader(title: L("tunnel.iconPicker.title"))

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(section.icons, id: \.self) { icon in
                                IconCell(icon: icon, chosen: icon == current, accent: accent) {
                                    session.finish(icon)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 16)
            }

            FCXLDialogMultiButtonBar(buttons: [
                FCXLDialogBarButton(title: L("button.cancel"), action: { session.cancel() })
            ])
        }
    }

    private struct IconCell: View {
        let icon: String
        let chosen: Bool
        let accent: Color
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 36, height: 32)
                    .foregroundStyle(chosen ? Color.white : Color.primary)
                    .contentShape(Rectangle())
                    .background(chosen ? accent
                                : hovering ? accent.opacity(0.18) : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(icon)
        }
    }
}
