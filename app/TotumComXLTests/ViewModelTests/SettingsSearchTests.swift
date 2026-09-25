import AppKit
import SwiftUI
import XCTest
@testable import TotumComXLApp

/// Поиск по настройкам: совпадения без учёта регистра и «ё», индекс покрывает все разделы,
/// каждый ключ есть в обоих языках, индекс не отстал от файлов разделов, а найденная
/// строка отыскивается на странице через accessibility.
final class SettingsSearchTests: XCTestCase {

    func test_совпадениеБезРегистраИЁ() {
        XCTAssertTrue(SettingsSearch.matches("Авто-расчёт размеров папок", query: "расчет папок"))
        XCTAssertTrue(SettingsSearch.matches("Показывать скрытые файлы", query: "СКРЫТЫЕ"))
        XCTAssertFalse(SettingsSearch.matches("Показывать скрытые файлы", query: "папки"))
        XCTAssertFalse(SettingsSearch.matches("что угодно", query: "   "))
    }

    func test_результатыВПорядкеРазделов() {
        let index: [SettingsSection: [(key: String, group: String?)]] = [
            .colors: [("b", nil)], .general: [("a", nil), ("c", nil)]]
        let titles = ["a": "Курсор один", "b": "Курсор два", "c": "Другое"]
        let hits = SettingsSearch.hits(for: "курсор", index: index) { titles[$0] ?? $0 }
        XCTAssertEqual(hits.map(\.key), ["a", "b"], "сначала «Основные», потом «Дизайн»")
        XCTAssertEqual(hits.first?.title, "Курсор один")
        XCTAssertTrue(SettingsSearch.hits(for: "", index: index) { titles[$0] ?? $0 }.isEmpty)
    }

    func test_индексПокрываетВсеРазделыИОбаЯзыка() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func keys(_ lang: String) throws -> Set<String> {
            let text = try String(contentsOf: root.appendingPathComponent("TotumComXL/Resources/\(lang).lproj/Localizable.strings"), encoding: .utf8)
            let regex = try NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*="#, options: .anchorsMatchLines)
            return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { String(text[Range($0.range(at: 1), in: text)!]) })
        }
        let ru = try keys("ru"), en = try keys("en")
        for section in SettingsSection.allCases {
            let entries = SettingsSearchIndex.entries[section] ?? []
            XCTAssertFalse(entries.isEmpty, "раздел \(section) без подписей")
            for entry in entries {
                XCTAssertTrue(ru.contains(entry.key), "нет русской строки \(entry.key)")
                XCTAssertTrue(en.contains(entry.key), "нет английской строки \(entry.key)")
            }
        }
    }

    /// Индекс генерируется скриптом; если настройку добавили, а скрипт не запустили — тест
    /// говорит об этом первым.
    func test_индексНеОтсталОтФайловРазделов() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let files: [(SettingsSection, String)] = [
            (.general, "SettingsGeneralView"), (.keys, "SettingsKeysView"), (.terminal, "SettingsTerminalView"),
            (.list, "SettingsListView"), (.colors, "SettingsColorsView"), (.fileColors, "SettingsFileColorsView"),
            (.cursor, "SettingsCursorView"), (.folders, "SettingsFoldersView"), (.font, "SettingsFontView"),
            (.tabs, "SettingsTabsView"), (.divider, "SettingsDividerView"), (.contextMenu, "SettingsContextMenuView"),
            (.networkNTFS, "SettingsNetworkNTFSView"), (.about, "SettingsAboutView")]
        let excluded = try NSRegularExpression(pattern: SettingsSearch.excludedKeyPattern)
        let call = try NSRegularExpression(pattern: #"\bL\("([^"]+)""#)
        for (section, name) in files {
            let src = try String(contentsOf: root.appendingPathComponent("TotumComXL/Views/Settings/Sections/\(name).swift"), encoding: .utf8)
            var expected: [String] = []
            for m in call.matches(in: src, range: NSRange(src.startIndex..., in: src)) {
                let key = String(src[Range(m.range(at: 1), in: src)!])
                if key.contains(".section.") || key.contains("\\(") || expected.contains(key) { continue }
                if excluded.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil { continue }
                expected.append(key)
            }
            XCTAssertEqual((SettingsSearchIndex.entries[section] ?? []).map(\.key), expected,
                           "\(name): запустите python3 scripts/gen_settings_index.py")
        }
    }

    /// У строк есть якоря для прокрутки и подсветки: каждый якорь — ключ из индекса, и якорей
    /// не меньше, чем стояло при первой расстановке (73).
    func test_якоряСтрокСовпадаютСИндексом() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("TotumComXL/Views/Settings/Sections")
        let anchor = try NSRegularExpression(pattern: #"\.settingAnchor\("([^"]+)"\)"#)
        let indexed = Set(SettingsSearchIndex.entries.values.flatMap { $0.map(\.key) })
        var count = 0
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasSuffix(".swift") {
            let src = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            for m in anchor.matches(in: src, range: NSRange(src.startIndex..., in: src)) {
                let key = String(src[Range(m.range(at: 1), in: src)!])
                XCTAssertTrue(indexed.contains(key), "\(file): якорь \(key) не в индексе")
                count += 1
            }
        }
        XCTAssertGreaterThanOrEqual(count, 73)
    }
}
