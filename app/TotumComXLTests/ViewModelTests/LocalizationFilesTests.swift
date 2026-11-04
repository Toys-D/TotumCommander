import Foundation
import XCTest
@testable import TotumComXLApp

/// Файлы строк обязаны читаться Foundation целиком.
///
/// Одна неэкранированная кавычка в значении — и NSLocalizedString не читает ВЕСЬ файл:
/// каждая строка падает на русский запасной вариант, и программа «не переключается на
/// английский», хотя перевод на месте. Так и было: `"…for "%@"."` в en.lproj.
final class LocalizationFilesTests: XCTestCase {

    private var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TotumComXL/Resources")
    }

    private func table(_ language: String) throws -> [String: String] {
        let url = resources.appendingPathComponent("\(language).lproj/Localizable.strings")
        let dictionary = NSDictionary(contentsOf: url)
        XCTAssertNotNil(dictionary, "\(language).lproj/Localizable.strings не разбирается — ищите неэкранированную кавычку или пропущенную «;»")
        return try XCTUnwrap(dictionary as? [String: String])
    }

    func test_обаФайлаСтрокЧитаютсяИСовпадаютПоКлючам() throws {
        let ru = try table("ru")
        let en = try table("en")
        XCTAssertGreaterThan(ru.count, 2000)
        let missing = Set(ru.keys).subtracting(en.keys).sorted()
        let extra = Set(en.keys).subtracting(ru.keys).sorted()
        XCTAssertTrue(missing.isEmpty, "нет в en: \(missing)")
        XCTAssertTrue(extra.isEmpty, "лишние в en: \(extra)")
    }

    /// Каждый ключ, который код просит у L(), есть в обоих языках. Иначе на экран выходит сам
    /// ключ: так заголовок ошибки переименования был «rename.errorTitle», окно «Переименовать»
    /// — «rename.message», а окно настроек — «settings.title». Ключи, собранные на ходу из
    /// частей, так не проверить — только написанные целиком.
    func test_каждыйКлючИзКодаЕстьВОбоихЯзыках() throws {
        let ru = try table("ru")
        let en = try table("en")
        let sources = resources.deletingLastPathComponent()
        let call = try NSRegularExpression(pattern: #"\bL\("([^"\\]+)"\s*[,)]"#)
        var keys: [String: String] = [:]
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", let text = try? String(contentsOf: file, encoding: .utf8)
            else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in call.matches(in: text, range: range) {
                if let key = Range(match.range(at: 1), in: text).map({ String(text[$0]) }) {
                    keys[key] = file.lastPathComponent
                }
            }
        }
        XCTAssertGreaterThan(keys.count, 1000, "ключи из кода не нашлись — не тот путь к исходникам")
        let missing = keys.filter { ru[$0.key] == nil || en[$0.key] == nil }
            .map { "\($0.key) (\($0.value))" }.sorted()
        XCTAssertTrue(missing.isEmpty, "нет перевода: \(missing)")
    }

    /// Английский бандл из сборки отдаёт английское: именно этим путём идёт L() после
    /// выбора языка в настройках.
    func test_английскийБандлСборкиОтдаётАнглийское() throws {
        let path = try XCTUnwrap(AppResources.bundle.path(forResource: "en", ofType: "lproj"),
                                 "en.lproj в бандле сборки")
        let bundle = try XCTUnwrap(Bundle(path: path))
        let missing = "\u{0}__missing__\u{0}"
        XCTAssertEqual(NSLocalizedString("menu.file", bundle: bundle, value: missing, comment: ""), "File")
        XCTAssertEqual(NSLocalizedString("menu.help.guide", bundle: bundle, value: missing, comment: ""),
                       "Totum Commander Help")
        XCTAssertEqual(AppLanguage.english.resolvedCode, "en")
        XCTAssertEqual(AppLanguage.russian.resolvedCode, "ru")
    }

    /// Плейсхолдеры %@ и %d обязаны совпадать: иначе String(format:) на другом языке падает.
    func test_плейсхолдерыСовпадаютМеждуЯзыками() throws {
        let ru = try table("ru")
        let en = try table("en")
        func placeholders(_ s: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: "%(\\d+\\$)?\\d*(\\.\\d+)?l?[@dfsu]")
            return regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
                .map { String(s[Range($0.range, in: s)!]).replacingOccurrences(of: "%%", with: "") }
                .sorted()
        }
        var mismatched: [String] = []
        for (key, value) in ru {
            guard let other = en[key] else { continue }
            if placeholders(value) != placeholders(other) { mismatched.append(key) }
        }
        XCTAssertTrue(mismatched.isEmpty, "разные плейсхолдеры: \(mismatched.sorted())")
    }
}
