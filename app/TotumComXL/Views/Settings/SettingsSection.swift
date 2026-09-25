import SwiftUI

/// Snap a Double binding to a step WITHOUT using `Slider(step:)` — the latter maps
/// to NSSlider tick marks, and a fine step draws dozens/hundreds of ticks every
/// frame → stutter. Use `Slider(value: $x.snapped(to: step), in: range)` instead.
extension Binding where Value == Double {
    func snapped(to step: Double) -> Binding<Double> {
        Binding(get: { wrappedValue },
                set: { wrappedValue = step > 0 ? ($0 / step).rounded() * step : $0 })
    }
}

/// One entry in the settings sidebar. Order of `allCases` = order in the sidebar.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, keys, terminal, list, colors, fileColors, cursor, folders, font, tabs,
         divider, contextMenu, networkNTFS, about

    var id: String { rawValue }

    /// Где помнится открытая страница настроек — окно достаётся из кармана, и по этому
    /// имени оно узнаёт, на чём человек остановился.
    static let lastKey = "fcxl.settingsLastSection"

    /// Нужен ли живой предпросмотр контекстного меню на этой странице.
    static func wantsContextMenuPreview(lastSection: String?) -> Bool {
        SettingsSection(rawValue: lastSection ?? "") == .contextMenu
    }

    var titleKey: String {
        switch self {
        case .general:     return "settings.section.general"
        case .keys:        return "settings.section.keys"
        case .terminal:    return "settings.section.terminalNav"
        case .list:        return "settings.section.list"
        case .colors:      return "settings.section.colors"
        case .fileColors:  return "settings.section.fileColors"
        case .cursor:      return "settings.section.cursor"
        case .folders:     return "settings.section.folders"
        case .font:        return "settings.section.font"
        case .tabs:        return "settings.section.tabsNav"
        case .divider:     return "settings.section.divider"
        case .contextMenu: return "settings.section.contextMenu"
        case .networkNTFS: return "settings.section.networkNtfs"
        case .about:       return "settings.section.about"
        }
    }

    var title: String {
        // TODO(localize): aliased until the section keys are added to strings.
        if self == .contextMenu { return L("context.menu.title") }
        // The "settings.section.divider" key is missing; reuse the in-section header.
        if self == .divider { return L("design.section.divider") }
        return L(titleKey)
    }

    var systemImage: String {
        switch self {
        case .general:     return "gearshape"
        case .keys:        return "keyboard"
        case .terminal:    return "terminal"
        case .list:        return "list.bullet"
        case .colors:      return "paintpalette"
        case .fileColors:  return "square.stack.3d.up"
        case .cursor:      return "cursorarrow.rays"
        case .folders:     return "folder"
        case .font:        return "textformat"
        case .tabs:        return "square.on.square"
        case .divider:     return "rectangle.split.2x1"
        case .contextMenu: return "filemenu.and.cursorarrow"
        case .networkNTFS: return "network"
        case .about:       return "info.circle"
        }
    }
}
