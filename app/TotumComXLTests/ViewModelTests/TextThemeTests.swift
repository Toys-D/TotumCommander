import XCTest

@testable import TotumComXLApp

/// Тема текста в просмотре (F3) и редакторе (F4): системная — как программа, или своя.
final class TextThemeTests: XCTestCase {

    func test_системная_идётЗаПрограммой() {
        XCTAssertTrue(TextTheme.system.isDark(appIsDark: true))
        XCTAssertFalse(TextTheme.system.isDark(appIsDark: false))
        XCTAssertEqual(TextTheme.system.monacoTheme(appIsDark: true), "vs-dark")
        XCTAssertEqual(TextTheme.system.monacoTheme(appIsDark: false), "vs")
    }

    func test_своиТемы_неЗависятОтПрограммы() {
        for appDark in [true, false] {
            XCTAssertEqual(TextTheme.light.monacoTheme(appIsDark: appDark), "vs")
            XCTAssertEqual(TextTheme.dark.monacoTheme(appIsDark: appDark), "vs-dark")
            XCTAssertEqual(TextTheme.contrast.monacoTheme(appIsDark: appDark), "hc-black")
            XCTAssertFalse(TextTheme.light.isDark(appIsDark: appDark))
            XCTAssertTrue(TextTheme.dark.isDark(appIsDark: appDark))
            XCTAssertTrue(TextTheme.contrast.isDark(appIsDark: appDark))
        }
    }

    /// По умолчанию — системная; прежний выбор редактора (имена тем Monaco) понимается.
    func test_запомненное_иПрежниеИмена() {
        let suite = "fcxl.texttheme.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TextTheme.stored(forKey: "k", in: defaults), .system)
        for (old, theme) in [("vs-dark", TextTheme.dark), ("vs", .light), ("hc-black", .contrast),
                             ("light", .light), ("contrast", .contrast), ("ерунда", .system)] {
            defaults.set(old, forKey: "k")
            XCTAssertEqual(TextTheme.stored(forKey: "k", in: defaults), theme, old)
        }
        TextTheme.dark.store(forKey: "k", in: defaults)
        XCTAssertEqual(defaults.string(forKey: "k"), "dark")
    }

    func test_уКаждойТемыСвоёНазвание() {
        let titles = TextTheme.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, TextTheme.allCases.count)
        XCTAssertFalse(titles.contains { $0.hasPrefix("textTheme.") }, "названия переведены")
    }
}

/// Редактор F4: выбор темы запоминается, «Системная» перекрашивается вслед за программой.
@MainActor
final class EditorTextThemeTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "fcxl.editortheme.tests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    func test_поУмолчаниюСистемная() {
        let options = EditorViewOptions(defaults: makeDefaults())
        XCTAssertEqual(options.theme, TextTheme.system.rawValue)
        XCTAssertEqual(options.monacoTheme, TextTheme.appIsDark ? "vs-dark" : "vs")
    }

    func test_выборЗапоминаетсяИУходитВРедактор() {
        let defaults = makeDefaults()
        let options = EditorViewOptions(defaults: defaults)
        var sent: [String] = []
        options.onThemeChange = { sent.append($0) }
        options.theme = TextTheme.contrast.rawValue
        XCTAssertEqual(defaults.string(forKey: TextTheme.editorKey), "contrast")
        XCTAssertEqual(options.monacoTheme, "hc-black")
        XCTAssertEqual(sent, ["hc-black"])
        XCTAssertEqual(EditorViewOptions(defaults: defaults).theme, "contrast", "следующее окно помнит")
    }

    func test_прежнийВыборРедактораПонимается() {
        let defaults = makeDefaults()
        defaults.set("vs", forKey: TextTheme.editorKey)
        XCTAssertEqual(EditorViewOptions(defaults: defaults).theme, TextTheme.light.rawValue)
    }

    /// Тема программы сменилась: системная перекрашивается, своя — нет.
    func test_сменаТемыПрограммы() {
        let options = EditorViewOptions(defaults: makeDefaults())
        var sent = 0
        options.onThemeChange = { _ in sent += 1 }
        NotificationCenter.default.post(name: .fcxlAppearanceChanged, object: nil)
        XCTAssertEqual(sent, 1, "системная идёт за программой")
        options.theme = TextTheme.dark.rawValue
        sent = 0
        NotificationCenter.default.post(name: .fcxlAppearanceChanged, object: nil)
        XCTAssertEqual(sent, 0, "своя тема остаётся своей")
    }
}
