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
