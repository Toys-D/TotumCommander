import SwiftUI

/// Builds ONLY the selected section's content (lazy → fast). Each section view
/// is a Form that scrolls itself; the title is a fixed header above it.
struct SettingsDetailView: View {
    let section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.title2).fontWeight(.semibold)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 4)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general:     SettingsGeneralView()
        case .keys:        SettingsKeysView()
        case .terminal:    SettingsTerminalView()
        case .list:        SettingsListView()
        case .colors:      SettingsColorsView()
        case .fileColors:  SettingsFileColorsView()
        case .cursor:      SettingsCursorView()
        case .folders:     SettingsFoldersView()
        case .font:        SettingsFontView()
        case .tabs:        SettingsTabsView()
        case .divider:     SettingsDividerView()
        case .contextMenu: SettingsContextMenuView()
        case .networkNTFS: SettingsNetworkNTFSView()
        case .about:       SettingsAboutView()
        }
    }
}
