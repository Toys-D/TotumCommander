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
        field.textColor = .labelColor
        field.focusRingType = .none
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
        editor.insertionPointColor = .labelColor
        editor.textColor = .labelColor
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
