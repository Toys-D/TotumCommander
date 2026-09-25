import AppKit
import XCTest
@testable import TotumComXLApp

/// Метки Git в светлой теме темнее, чем в тёмной: системный оранжевый на светлой строке
/// не читался. Картинки меток в обеих темах — в FCXL_LOOK_DIR.
final class GitBadgeLookTests: XCTestCase {

    private func luminance(_ color: NSColor, under appearance: NSAppearance.Name) -> CGFloat {
        var result: CGFloat = 0
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB) ?? color
            result = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        return result
    }

    /// Замок хранилища — одного роста со значком ветки: пометки в одной колонке и одной семьи.
    /// Строка списка с замком и веткой рядом — в папку FCXL_LOOK_DIR, посмотреть глазами.
    @MainActor
    func test_ячейкаСЗамкомИВеткойСохраняетсяДляПросмотра() throws {
        guard let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] else { return }
        let base = NSFont.systemFont(ofSize: 13)
        var badge = GitBadge()
        badge.branch = "main"
        badge.dirty = true
        let rows: [(String, Bool?, GitBadge?)] = [
            ("TOYDDDD.sparsebundle", true, nil),
            ("Сейф закрыт.sparsebundle", false, badge),
            ("DIA", nil, badge),
            ("Очень длинное имя папки, которое не помещается в строку.sparsebundle", true, badge),
        ]
        for (name, scheme) in [("cell-light", NSAppearance.Name.aqua), ("cell-dark", .darkAqua)] {
            let column = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: CGFloat(rows.count) * 24 + 8))
            column.appearance = NSAppearance(named: scheme)
            column.wantsLayer = true
            column.layer?.backgroundColor = (scheme == .aqua ? NSColor.white : NSColor(white: 0.16, alpha: 1)).cgColor
            for (index, row) in rows.enumerated() {
                let cell = NameCellView()
                cell.frame = NSRect(x: 4, y: 4 + CGFloat(rows.count - 1 - index) * 24, width: 352, height: 22)
                cell.label.font = base
                let ink: NSColor = scheme == .aqua ? .black : .white
                cell.label.attributedStringValue = NSAttributedString(string: row.0, attributes: [.font: base, .foregroundColor: ink])
                cell.setGit(row.2, font: base, gutter: 0)
                cell.setVaultLock(row.1.map { GitBadgeChip.vaultLockImage(unlocked: $0, font: base, ink: ink) } ?? nil)
                column.addSubview(cell)
            }
            column.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(column.bitmapImageRepForCachingDisplay(in: column.bounds))
            column.cacheDisplay(in: column.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
        }
    }

    func test_замокХранилищаОдногоРостаСВеткой() throws {
        let base = NSFont.systemFont(ofSize: 13)
        let size = GitBadgeChip.markSymbolPointSize(for: base)
        let closed = try XCTUnwrap(GitBadgeChip.vaultLockImage(unlocked: false, font: base, ink: .black))
        let open = try XCTUnwrap(GitBadgeChip.vaultLockImage(unlocked: true, font: base, ink: .black))
        XCTAssertEqual(closed.size.height, ceil(size), accuracy: 0.5)
        XCTAssertEqual(open.size.height, closed.size.height, "открытый и закрытый — одного роста")
        XCTAssertGreaterThan(open.size.width, closed.size.width - 0.5, "дужка открытого отведена вбок")

        // Краткий вид и миниатюры держат замок в строке имени — тем же размером.
        let inline = PanelViewController.vaultAttributedName("сейф", font: base, color: .black, unlocked: false)
        var found: CGFloat = 0
        inline.enumerateAttribute(.attachment, in: NSRange(location: 0, length: inline.length)) { value, _, _ in
            if let a = value as? NSTextAttachment { found = a.bounds.height }
        }
        XCTAssertEqual(found, size, accuracy: 0.5)
    }

    func test_вСветлойТемеМеткиТемнееЧемВТёмной() {
        for mark in [GitMark.modified, .added, .deleted, .renamed, .untracked, .conflicted, .ignored] {
            let color = GitBadgeChip.color(for: mark)
            let light = luminance(color, under: .aqua)
            let dark = luminance(color, under: .darkAqua)
            XCTAssertLessThan(light, dark, "\(mark): светлая \(light) против тёмной \(dark)")
        }
    }

    func test_вСветлойТемеЦветЗатемнёнНаЗаданнуюДолю() {
        // Эталон считается ПОД светлой темой: systemOrange сам двойной, и смешанный вне
        // темы он взял бы оттенок той темы, какая случилась у процесса на этот момент.
        var expected: CGFloat = 0
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let blended = NSColor.systemOrange.blended(withFraction: GitBadgeChip.lightThemeDarkening, of: .black)!
            let c = blended.usingColorSpace(.sRGB)!
            expected = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        XCTAssertEqual(luminance(GitBadgeChip.color(for: .modified), under: .aqua), expected, accuracy: 0.001)
        XCTAssertEqual(luminance(GitBadgeChip.color(for: .modified), under: .darkAqua),
                       luminance(.systemOrange, under: .darkAqua), accuracy: 0.001,
                       "в тёмной теме — системный цвет как был")
    }

    func test_картинкиМетокВОбеихТемах() throws {
        guard let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] else { return }
        let font = NSFont.systemFont(ofSize: 14)
        for (name, appearance, background) in [("git-светлая", NSAppearance.Name.aqua, NSColor(white: 0.85, alpha: 1)),
                                               ("git-тёмная", .darkAqua, NSColor(white: 0.2, alpha: 1))] {
            let marks: [GitMark] = [.modified, .added, .deleted, .renamed, .untracked, .conflicted, .ignored]
            let image = NSImage(size: NSSize(width: 30 * marks.count + 10, height: 30), flipped: false) { rect in
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    background.setFill(); rect.fill()
                    for (i, mark) in marks.enumerated() {
                        GitBadgeChip.markText(mark, font: font).draw(at: NSPoint(x: 10 + 30 * i, y: 8))
                    }
                }
                return true
            }
            let data = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
        }
    }
}
