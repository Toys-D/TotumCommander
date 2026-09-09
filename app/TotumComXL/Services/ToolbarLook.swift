import AppKit

/// Как выглядит панель инструментов окна: одни значки, значки с подписями или одни подписи.
///
/// Значков на панели семь, и все они говорят иносказательно: волна — это монитор системы,
/// поднос — полка, диск со звёздочкой — сведения о томах. Человек, который зашёл сюда впервые,
/// узнаёт их не раньше, чем наведёт на каждый и дождётся подсказки. Подпись под значком снимает
/// этот вопрос навсегда — ценой высоты полосы, поэтому выбор оставлен человеку.
enum ToolbarLook: String, CaseIterable {

    case icons
    case iconsAndLabels
    case labels

    static let defaultsKey = "fcxl.toolbarLook"
    /// Разделители между смысловыми группами кнопок.
    static let separatorsKey = "fcxl.toolbarSeparators"

    var titleKey: String {
        switch self {
        case .icons:          return "settings.toolbar.icons"
        case .iconsAndLabels: return "settings.toolbar.iconsAndLabels"
        case .labels:         return "settings.toolbar.labels"
        }
    }

    /// Что стоит на кнопке при этом виде.
    var showsIcon: Bool { self != .labels }
    var showsLabel: Bool { self != .icons }

    /// Панель всегда показывает пункты как значки: кнопка с подписью — это своё вью пункта
    /// (значок и текст в одну строку), а вью панель рисует именно в этом режиме. Просить
    /// `.iconAndLabel` бессмысленно: в узкой полосе заголовка macOS подписи не рисует.
    var displayMode: NSToolbar.DisplayMode { .iconOnly }

    /// Каким стилем окно несёт панель: во всех видах — узкой полосой в строке заголовка.
    ///
    /// Подпись стоит справа от значка, в одной строке с ним, и название окна остаётся слева,
    /// у кнопок закрытия. Подписи ПОД значками отдельной строкой (`.expanded`) уводили
    /// заголовок в середину и делали окно выше — человеку это не понравилось.
    var windowStyle: NSWindow.ToolbarStyle { .unifiedCompact }

    /// Что выбрано сейчас; неизвестное значение — как было всегда, одни значки.
    static var chosen: ToolbarLook {
        ToolbarLook(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .icons
    }

    /// Разделители по умолчанию не показываются: панель и без них читается, а лишняя черта
    /// в чужом окне — это чужое решение.
    static var showsSeparators: Bool {
        UserDefaults.standard.object(forKey: separatorsKey) as? Bool ?? false
    }
}
