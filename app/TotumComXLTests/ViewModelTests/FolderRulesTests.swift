import Foundation
import XCTest

@testable import TotumComXLApp

/// Rules in the manner of Hazel. The engine is pure — files in, a plan out — so every rule here
/// is checked without a folder full of bait files, and the dates are pinned instead of waited for.
final class FolderRulesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)   // 2025-10-09 UTC

    private func file(_ name: String, size: UInt64 = 1024,
                      daysOld: Double = 0, isDirectory: Bool = false) -> FileItem {
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        return FileItem(path: "/дом/Загрузки/\(name)", name: name, fileExtension: ext,
                        size: size, isDirectory: isDirectory, isHidden: false, isSymlink: false,
                        permissions: isDirectory ? "drwxr-xr-x" : "-rw-r--r--",
                        dateModified: now.addingTimeInterval(-daysOld * 86_400))
    }

    private func rule(_ name: String, _ conditions: [RuleCondition],
                      action: RuleAction = RuleAction(), matchAll: Bool = true,
                      includeFolders: Bool = false) -> FolderRule {
        FolderRule(name: name, matchAll: matchAll, includeFolders: includeFolders,
                   conditions: conditions, action: action)
    }

    // MARK: - One condition at a time

    func testNameIsAskedInThePanelsOwnMaskLanguage() {
        let mask = RuleCondition(field: .name, test: .matches, text: "отчёт*")
        XCTAssertTrue(FolderRules.passes(file("отчёт за май.pdf"), condition: mask,
                                         now: now, tags: []))
        XCTAssertFalse(FolderRules.passes(file("счёт.pdf"), condition: mask, now: now, tags: []))

        let notMask = RuleCondition(field: .name, test: .notMatches, text: "отчёт*")
        XCTAssertTrue(FolderRules.passes(file("счёт.pdf"), condition: notMask, now: now, tags: []))
    }

    /// An empty mask is a rule nobody finished writing. Reading it as "everything" would turn it
    /// into a folder-wide sweep the moment it is saved.
    func testAnEmptyMaskMatchesNothing() {
        let empty = RuleCondition(field: .name, test: .matches, text: "   ")
        XCTAssertFalse(FolderRules.passes(file("что угодно.txt"), condition: empty,
                                          now: now, tags: []))
    }

    /// The listing spells an extension the way std::filesystem does — ".zip", dot included —
    /// and a rule that compared it raw against a typed "zip" matched nothing at all. This is the
    /// shape the panel actually hands in, so it is the shape the test uses.
    func testTheDotTheListingCarriesDoesNotBreakTheMatch() {
        let asTheListingGivesIt = FileItem(
            path: "/дом/Загрузки/Multiple files.zip", name: "Multiple files.zip",
            fileExtension: ".zip", size: 100, isDirectory: false, isHidden: false,
            isSymlink: false, permissions: "-rw-r--r--", dateModified: now)
        let condition = RuleCondition(field: .ext, test: .isOneOf, text: "zip, 7z, rar")
        XCTAssertTrue(FolderRules.passes(asTheListingGivesIt, condition: condition,
                                         now: now, tags: []))
        let unpack = FolderRule(name: "распаковать", matchAll: false, conditions: [condition],
                                action: { var a = RuleAction(); a.kind = .unpack; return a }())
        let plan = FolderRules.plan(items: [asTheListingGivesIt], rules: [unpack], now: now)
        XCTAssertEqual(plan.count, 1, "архив попадает в план")
        XCTAssertEqual(plan.first?.target, "/дом/Загрузки/Multiple files")
    }

    /// The list tidies itself as it is typed: a finished piece gets its dot and its comma, and
    /// the piece still under the cursor is left alone.
    func testTheExtensionListTidiesItselfWhileTyping() {
        XCTAssertEqual(FolderRules.tidiedExtensions("jpg "), ".jpg, ")
        XCTAssertEqual(FolderRules.tidiedExtensions(".jpg, jpeg "), ".jpg, .jpeg, ")
        XCTAssertEqual(FolderRules.tidiedExtensions("JPG;"), ".jpg, ", "регистр приводится к нижнему")
        XCTAssertEqual(FolderRules.tidiedExtensions("jpg, jpg "), ".jpg, ", "повтор не удваивается")
        XCTAssertEqual(FolderRules.tidiedExtensions("jpg, jpe"), "jpg, jpe",
                       "недописанное слово под курсором не трогается")
        XCTAssertEqual(FolderRules.tidiedExtensions(""), "")
        XCTAssertEqual(FolderRules.tidiedExtensions("  "), "", "одни пробелы — пустой список")
        // And whatever shape it ends up in, the matching still answers the same.
        let tidied = RuleCondition(field: .ext, test: .isOneOf,
                                   text: FolderRules.tidiedExtensions("jpg png "))
        XCTAssertTrue(FolderRules.passes(file("снимок.png"), condition: tidied, now: now, tags: []))
    }

    /// Typed first, switched to "Extension" afterwards: nothing was half-written at that
    /// moment, so the whole line is put in order at once.
    func testSwitchingAFieldToExtensionPutsWhatIsAlreadyThereInOrder() {
        XCTAssertEqual(FolderRules.normalizedExtensions("jpg jpeg"), ".jpg, .jpeg")
        XCTAssertEqual(FolderRules.normalizedExtensions(".JPG, jpeg"), ".jpg, .jpeg")
        XCTAssertEqual(FolderRules.normalizedExtensions("jpg"), ".jpg",
                       "одно расширение без разделителя тоже получает точку")
        XCTAssertEqual(FolderRules.normalizedExtensions("   "), "")
    }

    func testExtensionListTakesCommasSpacesAndALeadingDot() {
        let condition = RuleCondition(field: .ext, test: .isOneOf, text: ".jpg, png; JPEG")
        XCTAssertTrue(FolderRules.passes(file("снимок.png"), condition: condition,
                                         now: now, tags: []))
        XCTAssertTrue(FolderRules.passes(file("снимок.JPG"), condition: condition,
                                         now: now, tags: []), "регистр расширения не считается")
        XCTAssertFalse(FolderRules.passes(file("текст.txt"), condition: condition,
                                          now: now, tags: []))
    }

    func testKindUsesTheSameFamiliesTheViewerKnows() {
        let pictures = RuleCondition(field: .kind, test: .isOneOf, text: "image")
        XCTAssertTrue(FolderRules.passes(file("снимок.heic"), condition: pictures,
                                         now: now, tags: []))
        XCTAssertFalse(FolderRules.passes(file("книга.pdf"), condition: pictures,
                                          now: now, tags: []))
        let folders = RuleCondition(field: .kind, test: .isOneOf, text: "folder")
        XCTAssertTrue(FolderRules.passes(file("Архив", isDirectory: true), condition: folders,
                                         now: now, tags: []))
    }

    func testSizeIsAskedInMegabytes() {
        let big = RuleCondition(field: .size, test: .isBigger, number: 10)
        XCTAssertTrue(FolderRules.passes(file("кино.mp4", size: 11 * 1024 * 1024),
                                         condition: big, now: now, tags: []))
        XCTAssertFalse(FolderRules.passes(file("записка.txt", size: 900),
                                          condition: big, now: now, tags: []))
    }

    func testAgeIsAskedInDaysAgainstAPinnedNow() {
        let old = RuleCondition(field: .modified, test: .isOlder, number: 30)
        XCTAssertTrue(FolderRules.passes(file("старое.txt", daysOld: 31), condition: old,
                                         now: now, tags: []))
        XCTAssertFalse(FolderRules.passes(file("вчерашнее.txt", daysOld: 1), condition: old,
                                          now: now, tags: []))
        let fresh = RuleCondition(field: .modified, test: .isNewer, number: 7)
        XCTAssertTrue(FolderRules.passes(file("вчерашнее.txt", daysOld: 1), condition: fresh,
                                         now: now, tags: []))
    }

    /// A date the filesystem never gave us must not quietly count as "very old" and sweep the
    /// file into the Trash.
    func testAMissingDateAnswersNo() {
        let condition = RuleCondition(field: .created, test: .isOlder, number: 1)
        XCTAssertFalse(FolderRules.passes(file("без даты.txt"), condition: condition,
                                          now: now, tags: []))
    }

    func testTagIsAskedByName() {
        let condition = RuleCondition(field: .tag, test: .isOneOf, text: "Red, Green")
        XCTAssertTrue(FolderRules.passes(file("важное.txt"), condition: condition,
                                         now: now, tags: [.green]))
        XCTAssertFalse(FolderRules.passes(file("важное.txt"), condition: condition,
                                          now: now, tags: [.blue]))
    }

    // MARK: - A whole rule

    func testAllConditionsVersusAnyOfThem() {
        let conditions = [
            RuleCondition(field: .ext, test: .isOneOf, text: "jpg"),
            RuleCondition(field: .size, test: .isBigger, number: 5),
        ]
        let strict = rule("оба", conditions)
        let loose = rule("любое", conditions, matchAll: false)
        let smallPicture = file("снимок.jpg", size: 1024)
        XCTAssertFalse(FolderRules.matches(smallPicture, rule: strict, now: now))
        XCTAssertTrue(FolderRules.matches(smallPicture, rule: loose, now: now))
    }

    func testFoldersAreLeftAloneUnlessAskedFor() {
        let condition = [RuleCondition(field: .name, test: .matches, text: "*")]
        XCTAssertFalse(FolderRules.matches(file("Папка", isDirectory: true),
                                           rule: rule("всё", condition), now: now))
        XCTAssertTrue(FolderRules.matches(file("Папка", isDirectory: true),
                                          rule: rule("всё", condition, includeFolders: true),
                                          now: now))
    }

    func testARuleWithoutConditionsAndADisabledOneTakeNothing() {
        XCTAssertFalse(FolderRules.matches(file("что угодно.txt"), rule: rule("пустое", []),
                                           now: now))
        var off = rule("выключено", [RuleCondition(field: .name, test: .matches, text: "*")])
        off.isEnabled = false
        XCTAssertFalse(FolderRules.matches(file("что угодно.txt"), rule: off, now: now))
    }

    func testTheParentRowIsNeverTouched() {
        let up = FileItem(path: "/дом", name: "..", fileExtension: "", size: 0,
                          isDirectory: true, isHidden: false, isSymlink: false,
                          permissions: "drwxr-xr-x", dateModified: now)
        let everything = rule("всё", [RuleCondition(field: .name, test: .matches, text: "*")],
                              includeFolders: true)
        XCTAssertTrue(FolderRules.plan(items: [up], rules: [everything], now: now).isEmpty)
    }

    // MARK: - The plan

    /// Two rules wanting the same file would each move it; the second would then act on a file
    /// that is no longer where the plan said. The first one written wins.
    func testTheFirstMatchingRuleTakesTheFile() {
        var toPictures = RuleAction(); toPictures.kind = .move
        toPictures.destination = "/дом/Картинки"
        var toTrash = RuleAction(); toTrash.kind = .trash
        let rules = [
            rule("картинки", [RuleCondition(field: .ext, test: .isOneOf, text: "jpg")],
                 action: toPictures),
            rule("большое вон", [RuleCondition(field: .size, test: .isBigger, number: 0)],
                 action: toTrash),
        ]
        let plan = FolderRules.plan(items: [file("снимок.jpg")], rules: rules, now: now)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.action.kind, .move)
        XCTAssertEqual(plan.first?.ruleName, "картинки")
        XCTAssertEqual(plan.first?.target, "/дом/Картинки/снимок.jpg")
    }

    /// Sorting by date has to use the FILE's date. Sorting last year's photographs into this
    /// year's folder is the one thing such a rule must never do.
    func testTheDateSubfolderComesFromTheFileNotFromToday() {
        var action = RuleAction()
        action.kind = .move
        action.destination = "/дом/Картинки"
        action.subfolder = "yyyy/MM"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let old = file("прошлогоднее.jpg", daysOld: 400)
        let target = FolderRules.target(for: old, action: action, calendar: calendar)
        XCTAssertEqual(target, "/дом/Картинки/2024/09/прошлогоднее.jpg")
    }

    func testRenameUsesTheGroupRenameMasks() {
        var action = RuleAction()
        action.kind = .rename
        action.nameMask = "счёт-[N]"
        let target = FolderRules.target(for: file("2026.pdf"), action: action)
        XCTAssertEqual(target, "/дом/Загрузки/счёт-2026.pdf")
    }

    func testUnpackingGoesIntoAFolderNamedAfterTheArchive() {
        var action = RuleAction()
        action.kind = .unpack
        XCTAssertEqual(FolderRules.target(for: file("макеты.zip"), action: action),
                       "/дом/Загрузки/макеты")
    }

    func testTheActionsThatLeaveAFileWhereItIsNameNoTarget() {
        for kind in [RuleAction.Kind.trash, .tag, .shelf] {
            var action = RuleAction()
            action.kind = kind
            XCTAssertEqual(FolderRules.target(for: file("х.txt"), action: action), "",
                           "\(kind) не двигает файл")
        }
    }

    func testEveryFieldOffersOnlyTheTestsThatSuitIt() {
        for field in RuleCondition.Field.allCases {
            XCTAssertFalse(field.tests.isEmpty, "\(field) без единой проверки")
        }
        XCTAssertFalse(RuleCondition.Field.size.tests.contains(.matches),
                       "размер не сравнивают с маской")
        XCTAssertFalse(RuleCondition.Field.name.tests.contains(.isBigger))
    }
}

/// Keeping the rules. Order is the person's own arrangement and carries meaning — the first
/// match wins — so it has to survive being written down and read back.
final class FolderRuleStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: FolderRuleStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "fcxl.rules.\(UUID().uuidString)")
        store = FolderRuleStore(defaults: defaults)
    }

    private func rule(_ name: String, enabled: Bool = true) -> FolderRule {
        FolderRule(name: name, isEnabled: enabled,
                   conditions: [RuleCondition(field: .ext, test: .isOneOf, text: "jpg")])
    }

    func testNothingSavedIsAnEmptyList() {
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertTrue(store.active().isEmpty)
    }

    func testRulesSurviveWritingAndReadingInTheSameOrder() {
        var second = rule("второе")
        second.action.kind = .trash
        second.matchAll = false
        second.includeFolders = true
        store.replaceAll([rule("первое"), second])

        let read = store.all()
        XCTAssertEqual(read.map(\.name), ["первое", "второе"], "порядок — это смысл, он сохраняется")
        XCTAssertEqual(read.last?.action.kind, .trash)
        XCTAssertFalse(read.last?.matchAll ?? true)
        XCTAssertTrue(read.last?.includeFolders ?? false)
        XCTAssertEqual(read.first?.conditions.first?.text, ".jpg",
                       "сохранение приводит список расширений в законченный вид")
    }

    /// The last extension typed never meets a separator, so it never gets its dot while typing.
    /// Saving is where the list is finished — nobody should have to type a trailing comma.
    func testSavingFinishesTheLastExtension() {
        var rule = FolderRule(name: "картинки")
        rule.conditions = [
            RuleCondition(field: .ext, test: .isOneOf, text: ".jpg, .jpeg, png"),
            RuleCondition(field: .name, test: .matches, text: "отчёт за май"),
        ]
        store.replaceAll([rule])
        let read = store.all()
        XCTAssertEqual(read.first?.conditions.first?.text, ".jpg, .jpeg, .png")
        XCTAssertEqual(read.first?.conditions.last?.text, "отчёт за май",
                       "маска имени — не список расширений, её трогать нельзя")
    }

    func testOnlySwitchedOnRulesAreRun() {
        store.replaceAll([rule("работает"), rule("отдыхает", enabled: false)])
        XCTAssertEqual(store.active().map(\.name), ["работает"])
        XCTAssertEqual(store.all().count, 2, "выключенное правило не потеряно, только не работает")
    }
}
