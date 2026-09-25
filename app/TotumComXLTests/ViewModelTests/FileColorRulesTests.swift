import AppKit
import XCTest
@testable import TotumComXLApp

/// Цвета имён по типам файлов и по свежести.
final class FileColorRulesTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "fcxl.tests.colors.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    /// Хранилище с набором по умолчанию — так его видит человек при первом запуске.
    private func store() -> FileColorRulesStore {
        FileColorRulesStore(defaults: defaults, key: "rules")
    }

    /// Пустое хранилище: для проверок, где правила задаются по одному и чужие мешают.
    private func emptyStore() -> FileColorRulesStore {
        let store = store()
        store.replaceAll([])
        return store
    }

    private func file(_ name: String, age: TimeInterval = 3600 * 24 * 30,
                      addedAge: TimeInterval? = nil) -> FileItem {
        let when = Date().addingTimeInterval(-age)
        let added = Date().addingTimeInterval(-(addedAge ?? age))
        return FileItem(path: "/тест/" + name, name: name,
                        fileExtension: (name as NSString).pathExtension,
                        size: 1, isDirectory: false, isHidden: false, isSymlink: false,
                        isAlias: false, symlinkTarget: nil, hardlinkCount: 1,
                        permissions: "rw-r--r--", dateModified: when, dateCreated: when,
                        dateAdded: added, owner: "dimas", entryCount: 0)
    }

    // MARK: - По типу

    func testTheFirstMatchingRuleColoursTheName() {
        let store = emptyStore()
        store.add(FileColorRule(mask: "*.zip;*.7z", colorHex: "#AF52DE"))
        store.add(FileColorRule(mask: "*", colorHex: "#FF3B30"))

        let archive = store.color(for: file("бэкап.zip"), base: .labelColor)
        let other = store.color(for: file("заметка.txt"), base: .labelColor)
        XCTAssertEqual(archive.map(PanelAppearanceSettings.hexString(from:)), "#AF52DEFF",
                       "архив покрашен своим правилом")
        XCTAssertEqual(other.map(PanelAppearanceSettings.hexString(from:)), "#FF3B30FF",
                       "остальное досталось общему правилу")
    }

    func testAFileNobodyClaimsKeepsTheOrdinaryColour() {
        let store = emptyStore()
        store.add(FileColorRule(mask: "*.zip", colorHex: "#AF52DE"))
        XCTAssertNil(store.color(for: file("песня.mp3"), base: .labelColor),
                     "нет правила — цвет обычный")
    }

    func testASwitchedOffRuleDoesNotColourAnything() {
        let store = emptyStore()
        store.add(FileColorRule(mask: "*.zip", colorHex: "#AF52DE",
                                isEnabled: false))
        XCTAssertNil(store.color(for: file("бэкап.zip"), base: .labelColor))
    }

    // MARK: - Свежесть

    /// Правило со сроком красит только молодые файлы, а старым не мешает достаться
    /// правилу ниже.
    func testFreshnessOnlyColoursYoungFiles() {
        let store = emptyStore()
        store.add(FileColorRule(mask: "", colorHex: "#34C759",
                                freshMinutes: 24 * 60))
        store.add(FileColorRule(mask: "*.zip", colorHex: "#AF52DE"))

        XCTAssertEqual(store.color(for: file("новый.zip", age: 60), base: .labelColor)
                        .map(PanelAppearanceSettings.hexString(from:)),
                       "#34C759FF", "минуту назад — свежий")
        XCTAssertEqual(store.color(for: file("старый.zip", age: 3600 * 48), base: .labelColor)
                        .map(PanelAppearanceSettings.hexString(from:)), "#AF52DEFF",
                       "через двое суток красит уже правило про архивы")
    }

    /// Скопированный файл приносит с собой старые даты создания и изменения — а в ЭТОЙ
    /// папке он новый. Иначе только что перенесённая фотография с прошлогодней камеры
    /// красилась бы как картинка, а не как новинка.
    func testAFileCopiedInIsNewHereEvenIfItsContentsAreOld() {
        let store = emptyStore()
        store.add(FileColorRule(mask: "", colorHex: "#FFFFFF", freshMinutes: 24 * 60))
        store.add(FileColorRule(mask: "*.png", colorHex: "#007AFF"))

        let copied = file("снимок.png", age: 3600 * 24 * 365, addedAge: 120)
        XCTAssertEqual(store.color(for: copied, base: .labelColor)
                        .map(PanelAppearanceSettings.hexString(from:)), "#FFFFFFFF",
                       "в папке он появился две минуты назад — значит новый")

        let old = file("снимок2.png", age: 3600 * 24 * 365, addedAge: 3600 * 24 * 10)
        XCTAssertEqual(store.color(for: old, base: .labelColor)
                        .map(PanelAppearanceSettings.hexString(from:)), "#007AFFFF",
                       "лежит здесь десять дней — обычная картинка")
    }

    /// Гаснущий цвет: час назад ярче, чем двадцать часов назад, и обе доли — между
    /// цветом правила и обычным.
    func testAFadingColourGetsWeakerWithAge() {
        let rule = FileColorRule(mask: "", colorHex: "#34C759",
                                 freshMinutes: 24 * 60, fades: true)
        let justNow = rule.strength(age: 60)
        let anHour = rule.strength(age: 3600)
        let almostGone = rule.strength(age: 3600 * 23)
        let expired = rule.strength(age: 3600 * 25)

        XCTAssertGreaterThan(justNow, 0.99, "только что появился — почти в полную силу")
        XCTAssertLessThan(anHour, justNow, "через час бледнее")
        XCTAssertLessThan(almostGone, anHour, "к концу суток совсем бледный")
        XCTAssertGreaterThan(almostGone, 0, "но ещё виден")
        XCTAssertEqual(expired, 0, "после срока не красит вовсе")
    }

    /// Без угасания цвет держится ровно до конца срока и пропадает разом — как в
    /// Total Commander.
    func testWithoutFadingTheColourHoldsToTheEnd() {
        let rule = FileColorRule(mask: "", colorHex: "#34C759",
                                 freshMinutes: 24 * 60, fades: false)
        XCTAssertEqual(rule.strength(age: 60), 1)
        XCTAssertEqual(rule.strength(age: 3600 * 23), 1, "и за час до конца — та же сила")
        XCTAssertEqual(rule.strength(age: 3600 * 25), 0)
    }

    /// Смешивание идёт К ОБЫЧНОМУ цвету, а не к прозрачности: имя не должно бледнеть до
    /// нечитаемости на любом фоне.
    func testFadingBlendsTowardsTheOrdinaryColour() {
        let green = NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)
        let black = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
        let half = FileColorRulesStore.blend(green, into: black, amount: 0.5)
        XCTAssertEqual(half.greenComponent, 0.5, accuracy: 0.01)
        XCTAssertEqual(half.alphaComponent, 1, accuracy: 0.01, "прозрачность не трогается")

        let full = FileColorRulesStore.blend(green, into: black, amount: 1)
        XCTAssertEqual(full.greenComponent, 1, accuracy: 0.01)
    }

    // MARK: - Светлая и тёмная тема

    /// То, что читается на белом, на чёрном теряется — цвет запоминается для каждой темы.
    func testEachThemeKeepsItsOwnColour() {
        let store = emptyStore()
        store.add(FileColorRule(mask: "*.zip", colorHex: "#A2845E", darkColorHex: "#C0A080"))

        XCTAssertEqual(store.color(for: file("бэкап.zip"), base: .labelColor, dark: false)
                        .map(PanelAppearanceSettings.hexString(from:)), "#A2845EFF")
        XCTAssertEqual(store.color(for: file("бэкап.zip"), base: .labelColor, dark: true)
                        .map(PanelAppearanceSettings.hexString(from:)), "#C0A080FF")
    }

    /// Тёмного цвета нет — светлый годится и там: так читаются правила, записанные до
    /// разделения тем, и новые, где человек второй цвет не задавал.
    func testWithoutADarkColourTheLightOneIsUsed() {
        let rule = FileColorRule(mask: "*.zip", colorHex: "#A2845E")
        XCTAssertEqual(rule.color(dark: true).map(PanelAppearanceSettings.hexString(from:)),
                       "#A2845EFF")
    }

    func testRulesWrittenBeforeThemesSplitStillRead() throws {
        let old = """
        [{"id":"\(UUID().uuidString)","mask":"*.zip","colorHex":"#A2845E",\
        "isEnabled":true,"fades":false}]
        """.replacingOccurrences(of: "\\\n        ", with: "")
        defaults.set(Data(old.utf8), forKey: "rules")

        let rule = try XCTUnwrap(store().rules.first)
        XCTAssertEqual(rule.darkColorHex, "", "второго цвета там не было")
        XCTAssertEqual(rule.color(dark: true).map(PanelAppearanceSettings.hexString(from:)),
                       "#A2845EFF", "и правило по-прежнему красит")
    }

    /// В готовом наборе цвета разведены по темам — иначе половина из них на тёмном фоне
    /// сливается.
    func testTheStarterSetHasBothThemes() {
        for rule in FileColorRulesStore.starterRules {
            XCTAssertFalse(rule.colorHex.isEmpty, "светлый цвет задан")
            XCTAssertFalse(rule.darkColorHex.isEmpty, "и тёмный тоже")
            XCTAssertNotEqual(rule.colorHex, rule.darkColorHex,
                              "они не совпадают — иначе разделять было незачем")
        }
    }

    // MARK: - Маски

    func testMasksWorkTheWayTheShellWouldMatchThem() {
        let rule = FileColorRule(mask: "*.[ch];*.swift", colorHex: "#30D158")
        XCTAssertTrue(rule.matches(fileName: "navigator.c"))
        XCTAssertTrue(rule.matches(fileName: "Panel.swift"))
        XCTAssertTrue(rule.matches(fileName: "PANEL.SWIFT"), "регистр не важен")
        XCTAssertFalse(rule.matches(fileName: "navigator.cpp"))
    }

    func testAnEmptyMaskMeansEveryFile() {
        let rule = FileColorRule(mask: "  ", colorHex: "#34C759",
                                 freshMinutes: 60)
        XCTAssertTrue(rule.matches(fileName: "что угодно.bin"),
                      "пустая маска ловит всё — она для правил про срок")
    }

    // MARK: - Хранение и набор

    /// Набор ставится сам при первом запуске: цвета в программе были всегда, и пустой
    /// список означал бы, что они вдруг пропали.
    func testTheStarterSetArrivesOnItsOwnAndSurvivesARestart() {
        let first = store()
        XCTAssertFalse(first.rules.isEmpty, "на чистой машине правила уже есть")
        let count = first.rules.count

        let second = store()
        XCTAssertEqual(second.rules.count, count, "набор записан")
        XCTAssertEqual(second.rules.first?.freshMinutes, 24 * 60,
                       "свежесть стоит первой — иначе её перебьёт правило по типу")
    }

    func testTheStarterSetIsUsable() {
        let store = store()
        XCTAssertNotNil(store.color(for: file("образ.dmg"), base: .labelColor))
        XCTAssertNotNil(store.color(for: file("фото.heic"), base: .labelColor))
        XCTAssertNotNil(store.color(for: file("книга.epub"), base: .labelColor))
        XCTAssertNil(store.color(for: file("непонятно.qqq"), base: .labelColor),
                     "чего нет в наборе — обычным цветом")
        XCTAssertTrue(store.hasFreshnessRule, "в наборе есть правило про свежесть")
    }

    /// Срок пишется в минутах, а показывается в самой крупной круглой единице.
    func testTheUnitShownIsTheRoundestOne() {
        XCTAssertEqual(FreshnessUnit.best(for: 20), .minutes)
        XCTAssertEqual(FreshnessUnit.best(for: 90), .minutes, "полтора часа — это 90 минут")
        XCTAssertEqual(FreshnessUnit.best(for: 120), .hours)
        XCTAssertEqual(FreshnessUnit.best(for: 60 * 24), .days)
        XCTAssertEqual(FreshnessUnit.best(for: 60 * 36), .hours, "полтора суток — 36 часов")
    }

    /// Правила, записанные когда срок хранился в часах, читаются как были.
    func testRulesWrittenWhenTheLimitWasInHoursStillRead() throws {
        let old = """
        [{"id":"\(UUID().uuidString)","mask":"","colorHex":"#34C759",\
        "isEnabled":true,"fades":true,"freshHours":6}]
        """.replacingOccurrences(of: "\\\n        ", with: "")
        defaults.set(Data(old.utf8), forKey: "rules")

        let rule = try XCTUnwrap(store().rules.first)
        XCTAssertEqual(rule.freshMinutes, 360, "шесть часов стали тремястами шестьюдесятью минутами")
        XCTAssertEqual(rule.strength(age: 3600), 1 - 1.0 / 6, accuracy: 0.01,
                       "и гаснет по тому же сроку")
    }

    /// Шаг перекраски привязан к самому короткому сроку: при пятиминутном правиле
    /// десятиминутный таймер не успевал сработать ни разу — цвет держался до тех пор,
    /// пока человек сам не щёлкал по панели.
    func testTheRepaintStepFollowsTheShortestLimit() {
        let store = emptyStore()
        XCTAssertNil(store.repaintInterval, "гаснуть нечему — и перекрашивать незачем")

        store.add(FileColorRule(mask: "", colorHex: "#FFFFFF", freshMinutes: 5, fades: true))
        XCTAssertEqual(store.repaintInterval, 15, "пять минут — шаг пятнадцать секунд")

        store.replaceAll([FileColorRule(mask: "", colorHex: "#FFFFFF",
                                        freshMinutes: 24 * 60, fades: true)])
        XCTAssertEqual(store.repaintInterval, 600, "сутки — раз в десять минут, чаще незачем")

        store.replaceAll([FileColorRule(mask: "", colorHex: "#FFFFFF",
                                        freshMinutes: 60, fades: true)])
        XCTAssertEqual(store.repaintInterval, 180, "час — раз в три минуты")

        store.replaceAll([FileColorRule(mask: "", colorHex: "#FFFFFF",
                                        freshMinutes: 60, fades: false)])
        XCTAssertEqual(store.repaintInterval, 600,
                       "правило не гаснет — хватает редкой проверки на истечение срока")
    }

    func testGarbageReadsAsNothingNotAsACrash() {
        defaults.set(Data("не json".utf8), forKey: "rules")
        XCTAssertTrue(store().rules.isEmpty)
    }
}
