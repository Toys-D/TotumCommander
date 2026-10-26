import AppKit

/// Как выглядит поле переименования имени — одно на все режимы списка.
///
/// Заметное поле ввода: своя подложка (светлая в светлой теме, тёмная в тёмной) и рамка
/// поверх строки, буквы цветом текста, выделение цветом акцента с читаемыми на нём буквами.
/// Раньше поле было прозрачным — только каретка и выделение, — и сливалось со строкой: курсор
/// того же цвета, что акцент, съедал и выделение, и кнопку «OK», и было не понять, идёт ли
/// уже правка. Шрифт — как у подписи строки сейчас (с волной курсора): свои 12 pt делали имя
/// меньше в самый момент правки.
enum InlineRenameLook {
    static func apply(to field: NSTextField, font: NSFont) {
        field.font = font
        field.isBordered = false
        field.isBezeled = false
        // Подложку и рамку рисует ячейка поля (InlineRenameCell), с отступом для букв.
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.textColor = boxInk
        field.focusRingType = .none
        field.needsDisplay = true
    }

    /// Подложка поля — как у любого поля ввода в этой теме.
    static let boxFill = NSColor.textBackgroundColor

    /// Буквы и каретка на подложке.
    static let boxInk = NSColor.labelColor

    /// Рамка поля: цвет акцента, если его видно на том, что под полем; иначе чёрная или белая —
    /// какая виднее. Акцент того же оттенка, что курсор, рамку бы спрятал.
    static let boxBorder = NSColor(name: "fcxlInlineRenameBorder") { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return border(accent: PanelAppearanceSettings.accentNSColor, on: ground(dark: dark))
    }

    /// Само правило рамки — отдельно, чтобы проверялось без настроек.
    static func border(accent: NSColor, on ground: NSColor) -> NSColor {
        PanelAppearanceSettings.contrast(between: accent, and: ground) >= 2
            ? accent : PanelAppearanceSettings.contrastingTextColor(on: ground)
    }

    /// Чёрное или белое — что читаемее на том, что под полем (тот же замер контраста, что у
    /// надписей на акценте): кнопка «OK» рядом с полем и запасная рамка. Цвет живой: тема,
    /// курсор или фон сменились — он следом.
    static let ink = NSColor(name: "fcxlInlineRenameInk") { appearance in
        PanelAppearanceSettings.contrastingTextColor(
            on: ground(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua))
    }

    /// Что под полем. Строку на время правки курсором не красят ни в одном виде, но «красивый»
    /// курсор — свечение, его рисует сам список — остаётся под полем, и буквы ложатся на него.
    /// Полупрозрачное — вместе с фоном панели.
    static func ground(dark: Bool) -> NSColor {
        UserDefaults.standard.bool(forKey: PanelAppearanceSettings.beautyModeEnabledKey)
            ? PanelAppearanceSettings.cursorGround(dark: dark)
            : PanelAppearanceSettings.panelGround(dark: dark)
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
        editor.insertionPointColor = boxInk
        editor.textColor = boxInk
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

/// Поле переименования во всех трёх видах списка: подложку и рамку рисует его ячейка.
class InlineRenameTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { InlineRenameCell.self }
        set {}
    }
}

/// Ячейка поля переименования: скруглённая подложка с рамкой и отступ для букв внутри — и
/// когда поле просто стоит, и когда в нём уже идёт правка.
final class InlineRenameCell: NSTextFieldCell {
    static let padX: CGFloat = 4
    static let padY: CGFloat = 1
    static let radius: CGFloat = 4
    static let lineWidth: CGFloat = 1.5

    /// Отступ для букв — только когда в поле есть для него место. Поле получает фокус раньше,
    /// чем раскладка даст ему размер (F2 делает первым ответчиком поле с нулевой рамкой), а
    /// `insetBy` на слишком малом прямоугольнике возвращает «пустой» с бесконечными
    /// координатами: AppKit превращал их в NaN и останавливал программу.
    static func padded(_ rect: NSRect) -> NSRect {
        guard rect.width > 2 * padX, rect.height > 2 * padY else { return rect }
        return rect.insetBy(dx: padX, dy: padY)
    }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        var size = super.cellSize(forBounds: rect)
        size.width += 2 * Self.padX
        size.height += 2 * Self.padY
        return size
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: Self.padded(rect))
    }

    // Редактор поля встаёт туда же, где стоят буквы без правки: иначе с началом правки текст
    // съезжал на отступ влево, на саму рамку.
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: Self.padded(rect), in: controlView,
                   editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: Self.padded(rect), in: controlView,
                     editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Рамку — только полю, у которого уже есть размер (см. padded).
        if cellFrame.width > Self.lineWidth, cellFrame.height > Self.lineWidth {
            let inset = Self.lineWidth / 2
            let box = NSBezierPath(roundedRect: cellFrame.insetBy(dx: inset, dy: inset),
                                   xRadius: Self.radius, yRadius: Self.radius)
            InlineRenameLook.boxFill.setFill()
            box.fill()
            InlineRenameLook.boxBorder.setStroke()
            box.lineWidth = Self.lineWidth
            box.stroke()
        }
        // Пока идёт правка, буквы рисует редактор поля — второй раз не надо.
        if (controlView as? NSTextField)?.currentEditor() == nil {
            drawInterior(withFrame: cellFrame, in: controlView)
        }
    }
}
