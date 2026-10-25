import AppKit
import XCTest
@testable import TotumComXLApp

/// Поле переименования: заметное поле ввода — подложка и рамка, — читаемое в обеих темах, в
/// шрифте строки, и щелчок по буквам остаётся в поле — ни таблица, ни монитор событий его не
/// перехватывают.
@MainActor
final class InlineRenameLookTests: XCTestCase {

    private func resolved(_ color: NSColor, in appearance: NSAppearance.Name) -> NSColor {
        var out = color
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    /// Правку видно сразу: у поля своя подложка и рамка, а буквы при входе в правку стоят там
    /// же, где стояли, — не съезжают на рамку.
    func test_полеВидноКакПолеВвода() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
        let field = InlineRenameTextField(frame: NSRect(x: 20, y: 20, width: 220, height: 22))
        field.stringValue = "снимок (1).jpeg"
        field.isEditable = true
        InlineRenameLook.apply(to: field, font: .systemFont(ofSize: 15))
        window.contentView?.addSubview(field)
        window.orderFront(nil)
        XCTAssertTrue(field.cell is InlineRenameCell)

        let rep = try XCTUnwrap(field.bitmapImageRepForCachingDisplay(in: field.bounds))
        field.cacheDisplay(in: field.bounds, to: rep)
        let mid = rep.pixelsHigh / 2
        let edge = try XCTUnwrap(rep.colorAt(x: 1, y: mid)?.usingColorSpace(.sRGB))
        let border = try XCTUnwrap(InlineRenameLook.boxBorder.usingColorSpace(.sRGB))
        let fill = try XCTUnwrap(InlineRenameLook.boxFill.usingColorSpace(.sRGB))
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                + abs(a.blueComponent - b.blueComponent)
        }
        XCTAssertLessThan(distance(edge, border), distance(edge, fill), "по краю — рамка, не подложка")

        let drawing = try XCTUnwrap(field.cell?.drawingRect(forBounds: field.bounds))
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let editing = editor.convert(editor.bounds, to: field)
        XCTAssertEqual(editing.minX, drawing.minX, accuracy: 0.5, "буквы не съезжают с началом правки")
        XCTAssertGreaterThan(editing.minX, 0, "буквы не лежат на рамке")
    }

    func test_текстЧитаемНаПодложкеВОбеихТемах() {
        let field = InlineRenameTextField(frame: .zero)
        InlineRenameLook.apply(to: field, font: .systemFont(ofSize: 15))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let text = resolved(field.textColor ?? .black, in: appearance)
            let box = resolved(InlineRenameLook.boxFill, in: appearance)
            XCTAssertGreaterThanOrEqual(PanelAppearanceSettings.contrast(between: text, and: box), 4.5,
                                        "буквы на подложке (\(appearance.rawValue))")
        }
    }

    /// Рамка — цвет акцента, если его видно; акцент того же оттенка, что курсор под полем, рамку
    /// бы спрятал, и тогда она чёрная или белая — какая виднее.
    func test_рамкаВиднаНаЛюбомКурсоре() {
        let grey = PanelAppearanceSettings.nsColor(from: "#59676FFF", fallback: .gray)
        let green = PanelAppearanceSettings.nsColor(from: "#2E8B57FF", fallback: .green)
        XCTAssertGreaterThanOrEqual(PanelAppearanceSettings.contrast(
            between: InlineRenameLook.border(accent: grey, on: grey), and: grey), 2,
                                    "акцент цвета курсора — рамка всё равно видна")
        let pale = PanelAppearanceSettings.nsColor(from: "#FFFDF0FF", fallback: .white)
        XCTAssertEqual(InlineRenameLook.border(accent: green, on: pale), green,
                       "видный акцент остаётся акцентом")
    }

    /// Под полем «красивый» курсор — свечение остаётся под строкой и на время правки: на тёмном
    /// буквы белые, на светлом — чёрные. Без него под полем фон панели, в том числе свой, тёмный.
    func test_буквыЧитаемыНаТом_чтоПодПолем() {
        let d = UserDefaults.standard
        let keys = [PanelAppearanceSettings.beautyModeEnabledKey, PanelAppearanceSettings.cursorUsesCustomColorKey,
                    PanelAppearanceSettings.cursorBackgroundColorHexKey,
                    PanelAppearanceSettings.panelBackgroundKey(dark: false)]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { d.set(value, forKey: key) } }
        d.set(true, forKey: PanelAppearanceSettings.cursorUsesCustomColorKey)

        d.set(true, forKey: PanelAppearanceSettings.beautyModeEnabledKey)
        for (cursor, expected) in [("#59676FFF", NSColor.white), ("#3A3F44FF", .white), ("#FFE680FF", .black)] {
            d.set(cursor, forKey: PanelAppearanceSettings.cursorBackgroundColorHexKey)
            XCTAssertEqual(resolved(InlineRenameLook.ink, in: .aqua), resolved(expected, in: .aqua),
                           "свечение курсора \(cursor)")
        }
        d.set(false, forKey: PanelAppearanceSettings.beautyModeEnabledKey)
        d.set("#2B2F33FF", forKey: PanelAppearanceSettings.panelBackgroundKey(dark: false))
        XCTAssertEqual(resolved(InlineRenameLook.ink, in: .aqua), resolved(.white, in: .aqua),
                       "свой тёмный фон панели в светлой теме — буквы белые")
    }

    func test_выделениеАкцентомСЧитаемымиБуквами() {
        let key = PanelAppearanceSettings.accentColorHexKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        for accent in ["#59676FFF", "#86A67CFF", "#FFD400FF"] {
            UserDefaults.standard.set(accent, forKey: key)
            let colors = InlineRenameLook.selectionColors()
            XCTAssertGreaterThanOrEqual(
                PanelAppearanceSettings.contrast(between: colors.text, and: colors.background), 4.5,
                "выделенные буквы читаемы на акценте \(accent)")
        }
    }

    func test_шрифтПоляРавенШрифтуСтроки() {
        let label = NSTextField(labelWithString: "имя")
        label.font = NSFont(name: "Menlo", size: 17) ?? .systemFont(ofSize: 17)
        let field = InlineRenameTextField(frame: .zero)
        InlineRenameLook.apply(to: field, font: InlineRenameLook.font(matching: label.font))
        XCTAssertEqual(field.font, label.font, "имя не должно мельчать в момент правки")
    }

    func test_щелчокВРедактореПоляУзнаётся() {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let editor = NSTextView(frame: .zero)
        row.addSubview(field)
        field.addSubview(editor)
        XCTAssertTrue(InlineRenameLook.isInsideActiveEditor(editor), "редактор внутри поля")
        XCTAssertFalse(InlineRenameLook.isInsideActiveEditor(row), "строка рядом — не поле")
        XCTAssertFalse(InlineRenameLook.isInsideActiveEditor(nil))
    }

    func test_таблицаПускаетЩелчокВПолеПереименования() {
        let table = PanelNSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let editor = NSTextView(frame: .zero)
        field.addSubview(editor)
        table.inlineRenameField = field
        XCTAssertTrue(table.validateProposedFirstResponder(field, for: nil))
        XCTAssertTrue(table.validateProposedFirstResponder(editor, for: nil),
                      "редактор внутри поля — тоже поле")
    }
}
