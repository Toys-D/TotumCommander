import SwiftUI

/// One row of a custom accent-highlighted popover "menu". We use custom popovers
/// instead of native `Menu`/NSMenu because macOS draws native menu highlights with
/// the system colour, which an app cannot recolour. Highlights on hover with the
/// app accent (and contrasting text).
struct AccentMenuItem: View {
    let title: String
    var icon: String? = nil
    let accent: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).frame(width: 18)
                }
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(hovering ? PanelAppearanceSettings.contrastingTextColor(on: accent) : Color.primary)
            .background(hovering ? accent : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
