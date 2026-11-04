import AppKit
import XCTest

@testable import TotumComXLApp

/// File masks: the same `*`/`?` pattern drives the panel's quick filter and the Total Commander
/// Num+/Num− selection, so one rule can never disagree with the other.
@MainActor
final class SelectionMaskTests: XCTestCase {

    // MARK: - The matcher

    func testAMaskMatchesByExtension() {
        XCTAssertTrue(PanelViewModel.name("photo.png", matchesMask: "*.png"))
        XCTAssertTrue(PanelViewModel.name("PHOTO.PNG", matchesMask: "*.png"), "case does not matter")
        XCTAssertFalse(PanelViewModel.name("photo.png.bak", matchesMask: "*.png"),
                       "a mask is anchored — it is not a substring search")
        XCTAssertFalse(PanelViewModel.name("notes.txt", matchesMask: "*.png"))
    }

    func testTheQuestionMarkIsExactlyOneCharacter() {
        XCTAssertTrue(PanelViewModel.name("IMG_0042.jpg", matchesMask: "IMG_????.jpg"))
        XCTAssertFalse(PanelViewModel.name("IMG_42.jpg", matchesMask: "IMG_????.jpg"))
        XCTAssertFalse(PanelViewModel.name("IMG_00042.jpg", matchesMask: "IMG_????.jpg"))
    }

    /// The characters that are regex operators must be taken literally — a mask is not a regex.
    /// "report(1).*" used to leak its brackets into the pattern.
    func testRegexCharactersInAMaskAreLiteral() {
        XCTAssertTrue(PanelViewModel.name("report(1).txt", matchesMask: "report(1).*"))
        XCTAssertTrue(PanelViewModel.name("[draft] plan.md", matchesMask: "[draft]*"))
        XCTAssertTrue(PanelViewModel.name("a+b.txt", matchesMask: "a+b.*"))
        XCTAssertFalse(PanelViewModel.name("aab.txt", matchesMask: "a+b.*"),
                       "the plus is a plus, not 'one or more'")
        XCTAssertTrue(PanelViewModel.name("2026.08.10 отчёт.pdf", matchesMask: "2026.08.*"))
        XCTAssertFalse(PanelViewModel.name("2026x08x10.pdf", matchesMask: "2026.08.*"),
                       "the dot is a dot, not 'any character'")
    }

    /// A dot alone is not a mask — plain text must keep working as a substring search, which is
    /// what typing into the panel has always done.
    func testPlainTextIsNotAMask() {
        XCTAssertFalse(PanelViewModel.looksLikeMask("png"))
        XCTAssertFalse(PanelViewModel.looksLikeMask("отчёт 2026"))
        XCTAssertTrue(PanelViewModel.looksLikeMask("*.png"))
        XCTAssertTrue(PanelViewModel.looksLikeMask("IMG_????"))
    }

    // MARK: - Several patterns at once

    /// The request, verbatim: "*.png&*.pdf" must bring BOTH kinds. A file is never both at
    /// once, so the operator joins sets rather than conditions — which is how it is meant.
    func testTwoMasksBringBothKinds() {
        XCTAssertTrue(PanelViewModel.name("photo.png", matchesMask: "*.png&*.pdf"))
        XCTAssertTrue(PanelViewModel.name("scan.pdf", matchesMask: "*.png&*.pdf"))
        XCTAssertFalse(PanelViewModel.name("notes.txt", matchesMask: "*.png&*.pdf"))
    }

    /// Whichever separator the user reaches for reads the same way.
    func testEverySeparatorMeansAndAlso() {
        for expression in ["*.png&*.pdf", "*.png|*.pdf", "*.png,*.pdf",
                           "*.png;*.pdf", "*.png *.pdf", "*.png & *.pdf"] {
            XCTAssertTrue(PanelViewModel.name("photo.png", matchesMask: expression), expression)
            XCTAssertTrue(PanelViewModel.name("scan.pdf", matchesMask: expression), expression)
            XCTAssertFalse(PanelViewModel.name("notes.txt", matchesMask: expression), expression)
        }
    }

    /// "!" throws a pattern out instead of letting it in.
    func testAnExclamationExcludes() {
        XCTAssertTrue(PanelViewModel.name("photo.png", matchesMask: "*.png !копия*"))
        XCTAssertFalse(PanelViewModel.name("копия photo.png", matchesMask: "*.png !копия*"))
    }

    /// Only exclusions typed: everything else stays.
    func testExclusionsAloneKeepTheRest() {
        XCTAssertFalse(PanelViewModel.name("build.tmp", matchesMask: "!*.tmp"))
        XCTAssertTrue(PanelViewModel.name("notes.txt", matchesMask: "!*.tmp"))
    }

    /// A term without a wildcard is a piece of a name, exactly as typing into the panel has
    /// always worked — so "png|pdf" finds both without anyone writing stars.
    func testTermsWithoutWildcardsStayAPieceOfTheName() {
        XCTAssertTrue(PanelViewModel.name("screenshot.png.bak", matchesMask: "png|pdf"))
        XCTAssertTrue(PanelViewModel.name("scan.pdf", matchesMask: "png|pdf"))
        XCTAssertFalse(PanelViewModel.name("notes.txt", matchesMask: "png|pdf"))
    }

    /// The per-file "and" needs no operator: anchored masks compose by themselves.
    func testTheEverydayAndIsJustOneMask() {
        XCTAssertTrue(PanelViewModel.name("отчёт-2026.png", matchesMask: "*2026*.png"))
        XCTAssertFalse(PanelViewModel.name("отчёт-2025.png", matchesMask: "*2026*.png"))
        XCTAssertFalse(PanelViewModel.name("отчёт-2026.pdf", matchesMask: "*2026*.png"))
    }

    /// An expression is a mask even without a star — otherwise "png|pdf" would be hunted for
    /// as one literal name.
    func testAnOperatorAloneMakesItAnExpression() {
        XCTAssertTrue(PanelViewModel.looksLikeMask("png|pdf"))
        XCTAssertTrue(PanelViewModel.looksLikeMask("!tmp"))
        XCTAssertFalse(PanelViewModel.looksLikeMask("отчёт 2026"),
                       "a space alone is just words — that stays a plain search")
    }

    /// A space separates like every other operator, so two extensions typed plainly work.
    func testASpaceSeparatesPlainTermsToo() {
        XCTAssertTrue(PanelViewModel.name("photo.png", matchesMask: "png jpg"))
        XCTAssertTrue(PanelViewModel.name("scan.jpg", matchesMask: "png jpg"))
        XCTAssertFalse(PanelViewModel.name("notes.txt", matchesMask: "png jpg"))
    }

    /// The price of that, stated plainly: a name typed WITH a space reads as two searches and
    /// shows more than asked for. The wider list still holds the file, where a literal search
    /// for what the user meant as two patterns would have shown nothing at all.
    func testAWordPairReadsAsTwoSearches() {
        XCTAssertTrue(PanelViewModel.name("отчёт 2026.txt", matchesMask: "отчёт 2026"))
        XCTAssertTrue(PanelViewModel.name("отчёт 2025.txt", matchesMask: "отчёт 2026"),
                      "the word alone is enough — that is what a separator means")
        XCTAssertTrue(PanelViewModel.name("план 2026.txt", matchesMask: "отчёт 2026"))
        XCTAssertFalse(PanelViewModel.name("смета.txt", matchesMask: "отчёт 2026"))
    }

    // MARK: - Recent masks

    func testRecentMasksComeBackNewestFirstWithoutRepeats() {
        let key = "fcxl.selectionMaskRecent"
        let saved = UserDefaults.standard.stringArray(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        MaskSelectionDialog.remember("*.jpg")
        MaskSelectionDialog.remember("*.tmp")
        MaskSelectionDialog.remember("*.JPG")   // the same mask again, differently cased

        XCTAssertEqual(MaskSelectionDialog.recent.first, "*.JPG", "the newest is on top")
        XCTAssertEqual(MaskSelectionDialog.recent.count, 2, "and it did not become a second entry")
        MaskSelectionDialog.remember("   ")
        XCTAssertEqual(MaskSelectionDialog.recent.count, 2, "blank is not a mask")
    }
}

/// Filtering by Finder tag: `#красная` in the same box as every other mask.
final class TagFilterTests: XCTestCase {

    private func matches(_ mask: String, name: String = "файл.txt",
                         tags: [FinderTag]) -> Bool {
        PanelViewModel.MaskExpression(mask).matches(name, tags: tags)
    }

    /// The beginning of the name is enough, in either language — nobody types "Оранжевая" out.
    func testATagIsNamedByItsBeginning() {
        XCTAssertTrue(matches("#кр", tags: [.red]))
        XCTAssertTrue(matches("#red", tags: [.red]))
        XCTAssertFalse(matches("#кр", tags: [.blue]))
        XCTAssertFalse(matches("#кр", tags: []))
    }

    /// "#с" begins both синяя and серая — both are what was typed, so both pass.
    func testAnAmbiguousBeginningMeansAnyOfThem() {
        XCTAssertTrue(matches("#с", tags: [.blue]))
        XCTAssertTrue(matches("#с", tags: [.gray]))
        XCTAssertFalse(matches("#с", tags: [.red]))
    }

    /// The tag is stored as "Жёлтая", the colour is thought of as "жёлтый", and half the
    /// country types "е" where the name has "ё" — every one of those spellings is the same
    /// yellow.
    func testTheEndingAndTheYoAreForgiven() {
        XCTAssertTrue(matches("#желтый", tags: [.yellow]))
        XCTAssertTrue(matches("#жёлтый", tags: [.yellow]))
        XCTAssertTrue(matches("#желтая", tags: [.yellow]))
        XCTAssertTrue(matches("#зеленый", tags: [.green]))
        XCTAssertTrue(matches("#синий", tags: [.blue]))
        XCTAssertTrue(matches("#красный", tags: [.red]))
        XCTAssertFalse(matches("#желтый", tags: [.green]))
    }

    /// A bare # is "anything tagged at all".
    func testABareHashMeansAnyTag() {
        XCTAssertTrue(matches("#", tags: [.green]))
        XCTAssertFalse(matches("#", tags: []))
    }

    /// A #-name no colour is called falls back to a NAME search: files called with a # must
    /// stay findable, and "#перламутровая" names no tag but may well name a file.
    func testAnUnknownTagNameSearchesTheNameInstead() {
        XCTAssertFalse(matches("#перламутровая", tags: [.red, .blue, .green]))
        XCTAssertTrue(matches("#перламутровая", name: "эскиз #перламутровая.png", tags: []))
        XCTAssertFalse(PanelViewModel.MaskExpression("#перламутровая").usesTags,
                       "a name term must not make the filter wait on the tag scan")
    }

    /// `!#кр` — everything except the red-tagged, the same ! as everywhere in the mask box.
    func testATagCanBeExcluded() {
        XCTAssertFalse(matches("!#кр", tags: [.red]))
        XCTAssertTrue(matches("!#кр", tags: [.blue]))
        XCTAssertTrue(matches("!#кр", tags: []))
    }

    /// Tag terms mix with name terms by the box's own rule: separated means "either".
    func testTagsAndMasksMixLikeEverythingElse() {
        XCTAssertTrue(PanelViewModel.MaskExpression("*.png #кр")
            .matches("фото.png", tags: []))
        XCTAssertTrue(PanelViewModel.MaskExpression("*.png #кр")
            .matches("заметка.txt", tags: [.red]))
        XCTAssertFalse(PanelViewModel.MaskExpression("*.png #кр")
            .matches("заметка.txt", tags: [.blue]))
    }

    /// A file whose NAME holds a # is still found by substring, as it always was — only a term
    /// BEGINNING with # speaks of tags.
    func testAHashInsideANameIsStillJustAName() {
        XCTAssertFalse(PanelViewModel.looksLikeMask("file#1"))
        XCTAssertTrue(PanelViewModel.MaskExpression("file#1").matches("file#1.txt", tags: []))
        XCTAssertTrue(PanelViewModel.looksLikeMask("#кр"),
                      "a tag term IS mask syntax — the buttons light up for it")
    }

    /// The filter has to know when its answer depends on tags: the scan is asynchronous, and a
    /// filter typed before it lands must be re-run after.
    func testAnExpressionSaysWhetherItAsksAboutTags() {
        XCTAssertTrue(PanelViewModel.MaskExpression("#кр").usesTags)
        XCTAssertTrue(PanelViewModel.MaskExpression("!#кр").usesTags)
        XCTAssertFalse(PanelViewModel.MaskExpression("*.png").usesTags)
    }
}

/// The saved masks behind the bubble's star.
final class MaskPresetsTests: XCTestCase {

    private var saved: [String]?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.stringArray(forKey: MaskPresets.key)
        UserDefaults.standard.removeObject(forKey: MaskPresets.key)
    }

    override func tearDown() {
        UserDefaults.standard.set(saved, forKey: MaskPresets.key)
        super.tearDown()
    }

    /// Presets are pressed by remembered position, so saving keeps the order of saving.
    func testSavedMasksKeepTheirOrder() {
        MaskPresets.add("*.png")
        MaskPresets.add("*.pdf&!копия*")
        XCTAssertEqual(MaskPresets.masks, ["*.png", "*.pdf&!копия*"])
    }

    /// The star toggles: saved when it was not, forgotten when it was — and says which.
    func testTheStarTogglesAndAnswers() {
        XCTAssertTrue(MaskPresets.toggle("*.jpg"))
        XCTAssertTrue(MaskPresets.contains("*.jpg"))
        XCTAssertFalse(MaskPresets.toggle("*.jpg"))
        XCTAssertFalse(MaskPresets.contains("*.jpg"))
    }

    /// The same mask differently cased is the same mask — a second entry would be two chips
    /// doing one thing.
    func testCaseDoesNotMakeASecondPreset() {
        MaskPresets.add("*.PNG")
        MaskPresets.add("*.png")
        XCTAssertEqual(MaskPresets.masks.count, 1)
        XCTAssertTrue(MaskPresets.contains("*.png"))
    }

    func testBlankIsNotAPreset() {
        MaskPresets.add("   ")
        XCTAssertTrue(MaskPresets.masks.isEmpty)
    }

    /// Spaces around what was typed do not make it a different preset.
    func testTrimmingMakesTheSameMask() {
        MaskPresets.add("  *.png ")
        XCTAssertTrue(MaskPresets.contains("*.png"))
        MaskPresets.remove(" *.png  ")
        XCTAssertTrue(MaskPresets.masks.isEmpty)
    }
}
