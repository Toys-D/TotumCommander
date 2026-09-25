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
