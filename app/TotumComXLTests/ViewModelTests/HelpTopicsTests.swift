import Foundation
import XCTest

@testable import TotumComXLApp

/// The help window renders localisation KEYS. A key nobody translated shows the key itself on
/// screen — "git.help.letters.body" in place of the explanation — and nothing in the build says
/// so. This is the thing that says so.
final class HelpTopicsTests: XCTestCase {

    /// Keys defined in one of the app's .strings files.
    private func keys(inLanguage language: String) throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // ViewModelTests
            .deletingLastPathComponent()    // TotumComXLTests
            .deletingLastPathComponent()    // app
        let file = root.appendingPathComponent(
            "TotumComXL/Resources/\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: file, encoding: .utf8)
        var found: Set<String> = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"") else { continue }
            let rest = trimmed.dropFirst()
            guard let end = rest.firstIndex(of: "\"") else { continue }
            found.insert(String(rest[rest.startIndex..<end]))
        }
        return found
    }

    func testEveryHelpKeyIsWrittenInBothLanguages() throws {
        let russian = try keys(inLanguage: "ru")
        let english = try keys(inLanguage: "en")
        XCTAssertGreaterThan(russian.count, 500, "файл строк прочитан")

        for topic in HelpTopic.all {
            var needed = [topic.titleKey]
            if let intro = topic.introKey { needed.append(intro) }
            for (title, body) in topic.sections { needed += [title, body] }
            for key in needed {
                XCTAssertTrue(russian.contains(key), "нет русского текста для «\(key)»")
                XCTAssertTrue(english.contains(key), "нет английского текста для «\(key)»")
            }
        }
    }

    /// Sections are looked up by key; two topics sharing one would show the same text twice.
    func testNoTopicRepeatsASection() {
        for topic in HelpTopic.all {
            let bodies = topic.sections.map(\.1)
            XCTAssertEqual(Set(bodies).count, bodies.count, "в «\(topic.id)» раздел повторяется")
        }
        let ids = HelpTopic.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "две темы с одним именем")
    }
}
