import SwiftUI

/// Settings sidebar with a CUSTOM selection pill so it follows the app accent
/// (the built-in `.sidebar` List selection always uses the macOS system accent).
///
/// Keyboard navigation is ours too: the rows are plain buttons, so macOS used to park its
/// focus ring on the FIRST row while the accent pill sat on the selected one — two things
/// that looked like a cursor, in different places — and arrow keys just beeped because
/// nothing handled them. The system focus effect is therefore switched off and ↑/↓ move the
/// accent pill itself, which is the only cursor the user ever sees.
struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    /// Поиск по настройкам: пока набрано, страница раздела уступает место результатам.
    @Binding var query: String
    @AppStorage(PanelAppearanceSettings.accentColorHexKey) private var accentColorHex: String = ""
    @FocusState private var listFocused: Bool

    var body: some View {
        // Resolve the colours ONCE per render (not per row).
        let accent = PanelAppearanceSettings.swiftUIColor(from: accentColorHex, fallback: .purple)
        let onAccent = PanelAppearanceSettings.contrastingTextColor(on: accent)

        let matched = query.isEmpty ? nil : Set(SettingsSearch.hits(for: query).map(\.section))
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L("settings.search.placeholder"), text: $query)
                            .textFieldStyle(.plain)
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 6)
                    ForEach(SettingsSection.allCases) { section in
                        let isSelected = section == selection && query.isEmpty
                        // При поиске разделы без совпадений блёкнут, чтобы видеть, где искать.
                        let dimmed = matched.map { !$0.contains(section) } ?? false
                        Button {
                            selection = section
                            query = ""              // выбор раздела закрывает поиск
                            listFocused = true      // clicking hands the arrows back to us
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: section.systemImage)
                                    .frame(width: 18)
                                    .foregroundStyle(isSelected ? onAccent : accent)
                                Text(section.title)
                                    .foregroundStyle(isSelected ? onAccent : .primary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(isSelected ? accent : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()      // the accent pill is the cursor
                        .opacity(dimmed ? 0.35 : 1)
                        .id(section.id)
                    }
                }
                .padding(8)
            }
            .focusable()                            // so ↑/↓ reach us at all
            .focusEffectDisabled()
            .focused($listFocused)
            .onMoveCommand { direction in
                move(direction, proxy: proxy)
            }
            .onAppear { listFocused = true }
            // ⌘F — в поле поиска, как в Системных настройках.
            .background(Button("") { listFocused = false }
                .keyboardShortcut("f", modifiers: .command).opacity(0))
        }
        .frame(width: 200)
    }

    /// Move the pill one step and keep it on screen. Clamped at both ends — wrapping around
    /// from the last section to the first is disorienting in a short settings list.
    private func move(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        let sections = SettingsSection.allCases
        guard let current = sections.firstIndex(of: selection) else { return }
        let target: Int
        switch direction {
        case .up:   target = current - 1
        case .down: target = current + 1
        default:    return
        }
        guard sections.indices.contains(target) else { return }
        selection = sections[target]
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(sections[target].id, anchor: .center)
        }
    }
}
