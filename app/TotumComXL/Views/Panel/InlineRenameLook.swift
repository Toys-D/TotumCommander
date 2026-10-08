import AppKit

/// Как выглядит поле переименования имени — одно на все режимы списка.
///
/// Поле прозрачное: ни подложки, ни ободка — только каретка и выделение. Буквы цветом
/// текста, выделение цветом акцента с читаемыми на нём буквами: системная голубая
/// полоса под голубыми буквами и была той нечитаемостью. Шрифт — как у подписи строки
/// сейчас (с волной курсора): свои 12 pt делали имя меньше в самый момент правки.
enum InlineRenameLook {
    static func apply(to field: NSTextField, font: NSFont) {
        field.font = font
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.textColor = ink
        field.focusRingType = .none
    }

    /// Буквы и каретка поля: чёрные или белые — какие читаемее на том, что под полем (тот же
    /// замер контраста, что у надписей на акценте). Цвет живой: тема, курсор или фон сменились —
    /// буквы следом.
    static let ink = NSColor(name: "fcxlInlineRenameInk") { appearance in
        PanelAppearanceSettings.contrastingTextColor(
            on: ground(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua))
    }

    /// Что под полем. Строку на время правки курсором не красят ни в одном виде, но «красивый»
    /// курсор — свечение, его рисует сам список — остаётся под полем, и буквы ложатся на него.
    /// Полупрозрачное — вместе с фоном панели.
    static func ground(dark: Bool) -> NSColor {
        let defaults = UserDefaults.standard
        let panelHex = defaults.string(forKey: PanelAppearanceSettings.panelBackgroundKey(dark: dark)) ?? ""
        let panel = opaque(PanelAppearanceSettings.optionalNSColor(from: panelHex)
                           ?? (NSColor.controlBackgroundColor.usingColorSpace(.sRGB) ?? .white),
                           over: dark ? .black : .white)
        guard defaults.bool(forKey: PanelAppearanceSettings.beautyModeEnabledKey) else { return panel }
        return opaque(PanelAppearanceSettings.resolvedCursorBackground(), over: panel)
    }

    /// Цвет, положенный на подложку: прозрачность смешивается с тем, что под ним.
    private static func opaque(_ color: NSColor, over ground: NSColor) -> NSColor {
        guard let top = color.usingColorSpace(.sRGB), top.alphaComponent < 1,
              let bottom = ground.usingColorSpace(.sRGB) else { return color }
        let a = top.alphaComponent
        return NSColor(srgbRed: top.redComponent * a + bottom.redComponent * (1 - a),
                       green: top.greenComponent * a + bottom.greenComponent * (1 - a),
                       blue: top.blueComponent * a + bottom.blueComponent * (1 - a), alpha: 1)
    }

    /// Шрифт поля — тот, что у подписи строки сейчас, а не свой.
    static func font(matching labelFont: NSFont?) -> NSFont {
        labelFont ?? PanelAppearanceSettings.resolvedListFont(cursor: true)
    }

    /// Цвета выделенного текста: акцент и читаемые на нём буквы.
    static func selectionColors() -> (background: NSColor, text: NSColor) {
        let accent = PanelAppearanceSettings.accentNSColor
        return (accent, PanelAppearanceSettings.contrastingTextColor(on: accent))
    }

    /// Редактор появляется, когда поле уже стало первым ответчиком, — тогда и красим.
    static func styleEditor(of field: NSTextField) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        let colors = selectionColors()
        editor.selectedTextAttributes = [.backgroundColor: colors.background,
                                         .foregroundColor: colors.text]
        editor.insertionPointColor = ink
        editor.textColor = ink
    }

    /// Попал ли щелчок в поле, которое сейчас правят: в само поле или в его редактор.
    /// Такой щелчок — дело поля (поставить каретку), а не строки под ним.
    static func isInsideActiveEditor(_ hit: NSView?) -> Bool {
        var view = hit
        while let current = view {
            if current is NSTextView { return true }
            if let field = current as? NSTextField, field.currentEditor() != nil { return true }
            view = current.superview
        }
        return false
    }
}
