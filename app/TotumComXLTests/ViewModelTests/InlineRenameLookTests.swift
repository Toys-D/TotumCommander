import AppKit
import XCTest
@testable import TotumComXLApp

/// Поле переименования: прозрачное, читаемое в обеих темах, в шрифте строки, и щелчок по
/// буквам остаётся в поле — ни таблица, ни монитор событий его не перехватывают.
@MainActor
final class InlineRenameLookTests: XCTestCase {

    private func resolved(_ color: NSColor, in appearance: NSAppearance.Name) -> NSColor {
        var out = color
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    func test_полеПрозрачноеБезОбодка() {
        let field = NSTextField(frame: .zero)
        field.wantsLayer = true
        field.layer?.borderWidth = 3
        InlineRenameLook.apply(to: field, font: .systemFont(ofSize: 15))
        XCTAssertFalse(field.drawsBackground, "ни подложки")
        XCTAssertFalse(field.isBordered)
        XCTAssertFalse(field.isBezeled)
        XCTAssertEqual(field.layer?.borderWidth ?? 0, 3, "ободок поле не рисует — слой не трогается")
    }

    func test_текстЧитаемНаФонеПанелиВОбеихТемах() {
        let field = NSTextField(frame: .zero)
        InlineRenameLook.apply(to: field, font: .systemFont(ofSize: 15))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let text = resolved(field.textColor ?? .black, in: appearance)
            let ground = resolved(.windowBackgroundColor, in: appearance)
            XCTAssertGreaterThanOrEqual(PanelAppearanceSettings.contrast(between: text, and: ground), 4.5,
                                        "буквы на фоне панели (\(appearance.rawValue))")
        }
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
        let field = NSTextField(frame: .zero)
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
