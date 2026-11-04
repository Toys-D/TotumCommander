import AppKit
import SwiftUI
import XCTest

@testable import TotumComXLApp

/// Проверка обновлений: сравнение версий, разбор ответа GitHub, при запуске и раз в три дня, и только слово о
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

    /// Ответ `releases` — список, новые сверху; черновик и предвыпуск в счёт не идут.
    private func list(_ tags: [String], draft: String? = nil, prerelease: String? = nil) -> Data {
        var items = tags.map { tag in
            """
            {"tag_name": "\(tag)", "html_url": "https://github.com/Toys-D/TotumCommander/releases/tag/\(tag)",
             "draft": false, "prerelease": false, "published_at": "2026-10-30T11:58:16Z",
             "body": "## What's new\\n\\n**Look**\\n- \(tag) en\\n\\n---\\n\\n## Что нового\\n\\n**Вид**\\n- \(tag) ru\\n"}
            """
        }
        if let draft {
            items.insert(#"{"tag_name": "\#(draft)", "html_url": "https://x/\#(draft)", "draft": true, "prerelease": false}"#, at: 0)
        }
        if let prerelease {
            items.insert(#"{"tag_name": "\#(prerelease)", "html_url": "https://x/\#(prerelease)", "draft": false, "prerelease": true}"#, at: 0)
        }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }

    func test_списокВыпусковРазбирается() throws {
        let releases = UpdateChecker.releases(from: list(["v1.11", "v1.12", "v1.10"], draft: "v2.0", prerelease: "v1.13"))
        XCTAssertEqual(releases.map(\.version), ["1.12", "1.11", "1.10"], "по версии, новые сверху; без черновика и предвыпуска")
        let first = try XCTUnwrap(releases.first)
        XCTAssertEqual(first.url.absoluteString, "https://github.com/Toys-D/TotumCommander/releases/tag/v1.12")
        XCTAssertTrue(first.notes.contains("v1.12 ru"))
        XCTAssertNotNil(first.published)
        XCTAssertEqual(UpdateChecker.releases(from: answer(tag: "v1.1")).map(\.version), ["1.1"],
                       "одиночный ответ — список из одного")
        XCTAssertTrue(UpdateChecker.releases(from: Data("not json".utf8)).isEmpty)
    }

    /// Сколько выпусков вышло после установленной версии — это число и стоит у раздела.
    func test_пропущенныеВерсииСчитаютсяИЗапоминаются() async {
        defaults.set("1.10", forKey: UpdateChecker.pretendVersionKey)
        let checker = UpdateChecker(defaults: defaults) { [self] in list(["v1.12", "v1.11", "v1.10", "v1.9"]) }
        _ = await checker.checkNow()
        XCTAssertEqual(checker.newer.map(\.version), ["1.12", "1.11"])
        XCTAssertEqual(checker.available?.version, "1.12", "ставится самый новый")
        XCTAssertTrue(checker.newer[1].notes.contains("v1.11 ru"), "у каждой версии свои заметки")

        // Следующий запуск помнит список и без сети.
        let later = UpdateChecker(defaults: defaults) { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(later.newer.map(\.version), ["1.12", "1.11"])

        // Обновились до 1.11 — осталась одна.
        defaults.set("1.11", forKey: UpdateChecker.pretendVersionKey)
        let updated = UpdateChecker(defaults: defaults) { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(updated.newer.map(\.version), ["1.12"])
    }

    /// Запись прошлой версии программы — только последний выпуск, без списка: одна новость.
    func test_стараяЗаписьБезСпискаДаётОднуВерсию() {
        defaults.set("1.10", forKey: UpdateChecker.pretendVersionKey)
        defaults.set("1.12", forKey: UpdateChecker.latestVersionKey)
        defaults.set("https://github.com/Toys-D/TotumCommander/releases/tag/v1.12", forKey: UpdateChecker.latestURLKey)
        let checker = UpdateChecker(defaults: defaults) { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(checker.newer.map(\.version), ["1.12"])
    }

    /// Свой раздел — перед «О программе»; число у него — сколько версий пропущено.
    func test_разделОбновленийИЧислоУНего() {
        XCTAssertEqual(Array(SettingsSection.allCases.suffix(2)), [.updates, .about])
        XCTAssertEqual(SettingsSection.updates.title, L("settings.section.updates"))
        XCTAssertNil(SettingsSidebar.badgeText(count: 0), "нет новых — нет и кружка")
        XCTAssertEqual(SettingsSidebar.badgeText(count: 1), "1")
        XCTAssertEqual(SettingsSidebar.badgeText(count: 12), "12")
        XCTAssertEqual(SettingsSidebar.badgeText(count: 120), "99+")
    }

    /// Раздел целиком, как его видит человек на 1.10, когда вышли 1.11 и 1.12: кружок «2» у
    /// раздела, красная «Обновить», заметки обеих версий. Обе темы; снимки — в FCXL_LOOK_DIR.
    func test_разделОбновленийВОбеихТемах() async throws {
        defaults.set("1.10", forKey: UpdateChecker.pretendVersionKey)
        defaults.set(true, forKey: UpdateChecker.enabledKey)
        let notes = """
        ## What's new

        **Printing**
        - One print for the whole app: File ▸ Print… (⌥⌘P).
        - Several selected files go to the printer as one job.

        ---

        ## Что нового

        **Печать**
        - Одна печать на всю программу: «Файл ▸ Печать…» (⌥⌘P) и «Печать…» в контекстном меню панели.
        - Несколько выбранных файлов уходят на принтер **одним заданием**.

        **Исправления**
        - Переименование по F2 больше не роняет программу.
        """
        let items: [[String: Any]] = [
            ["tag_name": "v1.12", "html_url": "https://x/v1.12", "draft": false, "prerelease": false,
             "published_at": "2026-10-30T11:58:16Z", "body": notes],
            ["tag_name": "v1.11", "html_url": "https://x/v1.11", "draft": false, "prerelease": false,
             "published_at": "2026-10-25T19:17:40Z",
             "body": "## What's new\n\n- Faster.\n\n---\n\n## Что нового\n\n- Быстрее распаковка одного файла из zip."],
            ["tag_name": "v1.10", "html_url": "https://x/v1.10", "draft": false, "prerelease": false]
        ]
        let body = try JSONSerialization.data(withJSONObject: items)
        let checker = UpdateChecker(defaults: defaults) { body }
        _ = await checker.checkNow()
        XCTAssertEqual(checker.newer.count, 2)

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let view = HStack(spacing: 0) {
                SettingsSidebar(selection: .constant(.updates), query: .constant(""), updates: checker)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text(SettingsSection.updates.title).font(.title2).fontWeight(.semibold)
                        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)
                    SettingsUpdatesView(updates: checker)
                }
            }
            .frame(width: 860, height: 760)
            .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: name)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)

            // Кружок с числом: насыщенно-красное в правой части полосы разделов.
            var red = 0
            let scale = CGFloat(rep.pixelsWide) / 860
            for x in Int(120 * scale)..<Int(200 * scale) {
                for y in 0..<rep.pixelsHigh {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if c.redComponent > 0.8, c.redComponent - max(c.greenComponent, c.blueComponent) > 0.4 { red += 1 }
                }
            }
            XCTAssertGreaterThan(red, Int(150 * scale * scale), "красный кружок у раздела — \(name.rawValue)")
            if let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"],
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: dir + "/обновления-\(name.rawValue).png"))
            }
            window.close()
        }
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

    /// При запуске — сразу, даже если трёх дней с прошлой проверки не прошло: новая версия
    /// видна в день выхода. Пока программа открыта — по-прежнему раз в три дня.
    func test_приЗапускеПроверяетСразу() async {
        defaults.set(true, forKey: UpdateChecker.enabledKey)
        defaults.set("1.0", forKey: UpdateChecker.pretendVersionKey)
        defaults.set(Date(), forKey: UpdateChecker.lastCheckKey)
        var fetched = 0
        let checker = UpdateChecker(defaults: defaults) { [self] in fetched += 1; return answer(tag: "v9.0") }
        await checker.checkIfDue()
        XCTAssertEqual(fetched, 0, "не при запуске — рано, три дня не прошли")
        await checker.checkIfDue(atLaunch: true)
        XCTAssertEqual(fetched, 1, "при запуске — сразу")
        XCTAssertEqual(checker.available?.version, "9.0")
    }

    func test_выключеноВНастройкахНеПроверяетИПриЗапуске() async {
        defaults.set(false, forKey: UpdateChecker.enabledKey)
        var fetched = 0
        let checker = UpdateChecker(defaults: defaults) { [self] in fetched += 1; return answer(tag: "v9.0") }
        checker.askPermission = { XCTFail("решено в настройках — вопрос лишний"); return false }
        await checker.checkIfDue(atLaunch: true)
        XCTAssertEqual(fetched, 0)
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

    /// Точка на шестерёнке — красная, как кнопка «Обновить до …», в обеих темах.
    func test_точкаОбновленияКраснаяВОбеихТемах() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let image = MainWindowController.settingsSymbol(updateAvailable: true,
                                                            appearance: NSAppearance(named: name))
            let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            // Середина точки: 3,5 pt от правого и верхнего краёв (у картинки ось y — сверху).
            let x = Int(CGFloat(rep.pixelsWide) * (1 - 3.5 / image.size.width))
            let y = Int(CGFloat(rep.pixelsHigh) * 3.5 / image.size.height)
            let dot = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(dot.redComponent, 0.85, "\(name.rawValue)")
            XCTAssertLessThan(dot.greenComponent, 0.4, "\(name.rawValue)")
            XCTAssertLessThan(dot.blueComponent, 0.4, "\(name.rawValue)")
            if let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"],
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: dir + "/шестерёнка-\(name.rawValue).png"))
            }
        }
    }
}
