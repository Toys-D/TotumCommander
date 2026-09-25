import AppKit
import XCTest

@testable import TotumComXLApp

/// Проверка обновлений: сравнение версий, разбор ответа GitHub, раз в три дня, и только слово о
/// новой версии — без сети в тестах и без настоящих настроек.
@MainActor
final class UpdateCheckerTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "fcxl.updates.tests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func answer(tag: String) -> Data {
        Data("""
        {"tag_name": "\(tag)", "html_url": "https://github.com/Toys-D/TotumCommander/releases/tag/\(tag)",
         "name": "Totum Commander", "draft": false, "prerelease": false}
        """.utf8)
    }

    func test_сравнениеВерсий() {
        XCTAssertTrue(UpdateChecker.isNewer("1.1", than: "1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0", than: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1", than: "1.0.9"), "1.1 новее 1.0.9 — не построчно")
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"), "недостающие части — нули")
        XCTAssertFalse(UpdateChecker.isNewer("v1.0", than: "1.0"), "тег с v — та же версия")
        XCTAssertFalse(UpdateChecker.isNewer("0.9", than: "1.0"))
    }

    func test_ответGitHubРазбирается() throws {
        let release = try XCTUnwrap(UpdateChecker.release(from: answer(tag: "v1.1")))
        XCTAssertEqual(release.version, "1.1")
        XCTAssertEqual(release.url.absoluteString, "https://github.com/Toys-D/TotumCommander/releases/tag/v1.1")
        XCTAssertNil(UpdateChecker.release(from: Data("not json".utf8)))
        XCTAssertNil(UpdateChecker.release(from: Data("{}".utf8)))
    }

    func test_разВТриДня() {
        let now = Date()
        XCTAssertTrue(UpdateChecker.isDue(now: now, last: nil), "ни разу не проверялось")
        XCTAssertFalse(UpdateChecker.isDue(now: now, last: now.addingTimeInterval(-2 * 24 * 3600)), "два дня — рано")
        XCTAssertFalse(UpdateChecker.isDue(now: now, last: now.addingTimeInterval(-71 * 3600)))
        XCTAssertTrue(UpdateChecker.isDue(now: now, last: now.addingTimeInterval(-73 * 3600)), "три дня прошли")
        XCTAssertEqual(UpdateChecker.interval, 3 * 24 * 3600)
    }

    func test_новаяВерсияЗамеченаИЗапомнена() async {
        defaults.set("1.0", forKey: UpdateChecker.pretendVersionKey)
        let checker = UpdateChecker(defaults: defaults) { [self] in answer(tag: "v1.1") }
        XCTAssertNil(checker.available, "до проверки ничего не известно")

        var notices = 0
        let token = NotificationCenter.default.addObserver(
            forName: .fcxlUpdateAvailabilityChanged, object: nil, queue: nil) { _ in notices += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let found = await checker.checkNow()
        XCTAssertEqual(found?.version, "1.1")
        XCTAssertEqual(checker.available?.version, "1.1")
        XCTAssertNotNil(checker.lastChecked)
        XCTAssertEqual(notices, 1, "окно узнаёт о перемене один раз")
        XCTAssertEqual(defaults.string(forKey: UpdateChecker.latestVersionKey), "1.1")

        // Следующий запуск помнит ответ и без сети.
        let later = UpdateChecker(defaults: defaults) { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(later.available?.version, "1.1")
    }

    func test_таЖеВерсияНеНовость() async {
        defaults.set("1.0", forKey: UpdateChecker.pretendVersionKey)
        let checker = UpdateChecker(defaults: defaults) { [self] in answer(tag: "v1.0") }
        _ = await checker.checkNow()
        XCTAssertNil(checker.available)
        XCTAssertNotNil(checker.lastChecked, "проверка была, просто новее нет")
    }

    func test_безСетиНичегоНеМеняется() async {
        defaults.set("1.0", forKey: UpdateChecker.pretendVersionKey)
        let checker = UpdateChecker(defaults: defaults) { throw URLError(.notConnectedToInternet) }
        _ = await checker.checkNow()
        XCTAssertNil(checker.available)
        XCTAssertNil(checker.lastChecked, "неудача не считается проверкой — завтра спросим снова")
    }

    // MARK: - первый выход в сеть — только с разрешения

    func test_первыйРазСпрашиваетИБезРазрешенияВСетьНеИдёт() async {
        var fetched = 0
        let checker = UpdateChecker(defaults: defaults) { [self] in fetched += 1; return answer(tag: "v9.0") }
        var asked = 0
        checker.askPermission = { asked += 1; return false }
        await checker.checkIfDue()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(fetched, 0, "отказ — ни одного запроса")
        XCTAssertFalse(UpdateChecker.isEnabled(defaults), "ответ лёг в настройку из «Основных»")
        XCTAssertTrue(defaults.bool(forKey: UpdateChecker.askedKey))
    }

    func test_разрешилиИПроверкаИдётСразу() async {
        defaults.set("1.0", forKey: UpdateChecker.pretendVersionKey)
        var fetched = 0
        let checker = UpdateChecker(defaults: defaults) { [self] in fetched += 1; return answer(tag: "v9.0") }
        checker.askPermission = { true }
        await checker.checkIfDue()
        XCTAssertEqual(fetched, 1)
        XCTAssertTrue(UpdateChecker.isEnabled(defaults))
        XCTAssertEqual(checker.available?.version, "9.0")
    }

    func test_ктоУжеРешилВНастройкахВопросаНеВидит() async {
        defaults.set(true, forKey: UpdateChecker.enabledKey)
        var fetched = 0
        let checker = UpdateChecker(defaults: defaults) { [self] in fetched += 1; return answer(tag: "v9.0") }
        checker.askPermission = { XCTFail("вопрос лишний"); return false }
        await checker.checkIfDue()
        XCTAssertEqual(fetched, 1)
    }

    func test_спрашиваетОдинРаз() async {
        let checker = UpdateChecker(defaults: defaults) { [self] in answer(tag: "v9.0") }
        var asked = 0
        checker.askPermission = { asked += 1; return false }
        await checker.checkIfDue()
        await checker.checkIfDue()
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(UpdateChecker.needsQuestion(defaults))
    }

    func test_выключеноВНастройкахНеСпрашивает() async {
        defaults.set(false, forKey: UpdateChecker.enabledKey)
        var asked = 0
        let checker = UpdateChecker(defaults: defaults) { [self] in asked += 1; return answer(tag: "v9.0") }
        await checker.checkIfDue()
        XCTAssertEqual(asked, 0)
        XCTAssertNil(checker.available)
    }

    func test_значокНастроекСТочкойИБез() {
        let plain = MainWindowController.settingsSymbol(updateAvailable: false)
        let dotted = MainWindowController.settingsSymbol(updateAvailable: true)
        XCTAssertTrue(plain.isTemplate, "без обновления — обычный системный значок")
        XCTAssertFalse(dotted.isTemplate, "с точкой — свой цвет, не перекрашивается панелью")
        XCTAssertGreaterThan(dotted.size.width, plain.size.width, "точка выступает за угол")
    }
}
