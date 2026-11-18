import AppKit

/// Тема текста в просмотре (F3) и в редакторе (F4).
///
/// «Системная» идёт за темой программы — а та по умолчанию за macOS — и перекрашивается сразу,
/// когда тема меняется. Остальные держат свой вид, какой бы ни была тема программы: кто-то
/// читает код на тёмном при светлой программе, кто-то наоборот. У просмотра и редактора выбор
/// свой: читать удобно одним, править — другим.
enum TextTheme: String, CaseIterable {
    case system, light, dark, contrast

    /// Где запомнен выбор.
    static let viewerKey = "fcxl.viewer.textTheme"
    static let editorKey = "fcxl.editor.textTheme"

    var title: String { L("textTheme.\(rawValue)") }

    var symbol: String {
        switch self {
        case .system: return "desktopcomputer"
        case .light: return "sun.max"
        case .dark: return "moon"
        case .contrast: return "circle.righthalf.filled"
        }
    }

    /// Тёмный ли текст при такой теме программы.
    func isDark(appIsDark: Bool) -> Bool {
        switch self {
        case .system: return appIsDark
        case .light: return false
        case .dark, .contrast: return true
        }
    }

    /// Тема редактора Monaco.
    func monacoTheme(appIsDark: Bool) -> String {
        switch self {
        case .contrast: return "hc-black"
        default: return isDark(appIsDark: appIsDark) ? "vs-dark" : "vs"
        }
    }

    /// Тёмная ли сейчас программа — по её собственной теме, а не по окну: окно меняет вид
    /// чуть позже, чем приходит весть о смене темы.
    @MainActor
    static var appIsDark: Bool {
        // .shared, а не NSApp: до первого обращения NSApp пуст (так падали проверки, запущенные отдельно).
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func stored(forKey key: String, in defaults: UserDefaults = .standard) -> TextTheme {
        guard let raw = defaults.string(forKey: key) else { return .system }
        if let theme = TextTheme(rawValue: raw) { return theme }
        // Редактор раньше помнил имя темы Monaco.
        switch raw {
        case "vs-dark": return .dark
        case "vs": return .light
        case "hc-black": return .contrast
        default: return .system
        }
    }

    func store(forKey key: String, in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: key)
    }
}

extension NSScrollView {
    /// Покрасить текст в прокрутке по теме: системная — ничего своего, вид программы; своя —
    /// своё оформление и свой фон. Буквы, номера строк и выделение берут цвета оформления
    /// (`textColor`, `secondaryLabelColor`), поэтому меняются вместе с ним.
    @MainActor
    func applyTextTheme(_ theme: TextTheme) {
        switch theme {
        case .system:
            appearance = nil
            drawsBackground = false
        case .light, .dark, .contrast:
            appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
            drawsBackground = true
            backgroundColor = Self.background(for: theme)
        }
        documentView?.needsDisplay = true
        needsDisplay = true
    }

    /// Фон своей темы — тот же, что у редактора (EditorChrome), чтобы F3 и F4 читались одинаково.
    static func background(for theme: TextTheme) -> NSColor {
        switch theme {
        case .light: return NSColor(srgbRed: 1, green: 1, blue: 254 / 255, alpha: 1)
        case .contrast: return .black
        case .dark, .system: return NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1)
        }
    }
}
