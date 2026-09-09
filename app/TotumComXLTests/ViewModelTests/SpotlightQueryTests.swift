import Foundation
import XCTest

@testable import TotumComXLApp

/// Translating the F9 form into a Spotlight query, and sieving what the index hands back.
/// None of this needs an index — that is the point of keeping it separate from the query.
final class SpotlightQueryTests: XCTestCase {

    private func format(_ plan: SpotlightQueryBuilder.MaskPlan) -> String {
        plan.predicate?.predicateFormat ?? "<nil>"
    }

    // MARK: - The mask

    func test_emptyMaskAndStar_askForEverything() {
        for mask in ["", "*", "   ", "  *  "] {
            XCTAssertEqual(SpotlightQueryBuilder.maskPlan(mask), .everything, mask)
        }
    }

    func test_theFourShapesSpotlightHasAnOperatorFor() {
        XCTAssertTrue(format(SpotlightQueryBuilder.maskPlan("*отчёт*")).contains("CONTAINS[cd]"))
        XCTAssertTrue(format(SpotlightQueryBuilder.maskPlan("отчёт*")).contains("BEGINSWITH[cd]"))
        XCTAssertTrue(format(SpotlightQueryBuilder.maskPlan("*.txt")).contains("ENDSWITH[cd]"))
        // A bare word means "somewhere in the name", as everywhere else in this program.
        XCTAssertTrue(format(SpotlightQueryBuilder.maskPlan("отчёт")).contains("CONTAINS[cd]"))
        for mask in ["*отчёт*", "отчёт*", "*.txt", "отчёт"] {
            XCTAssertFalse(SpotlightQueryBuilder.maskPlan(mask).postFilter,
                           "\(mask) is expressible exactly — no sieve needed")
        }
    }

    /// A star in the middle has no Spotlight operator: ask for the longest literal (which
    /// cannot lose a match) and sieve the rest with the real fnmatch.
    func test_starInTheMiddle_widensAndAsksForASieve() {
        let plan = SpotlightQueryBuilder.maskPlan("отчёт*2026.pdf")
        XCTAssertTrue(plan.postFilter)
        XCTAssertTrue(format(plan).contains("2026.pdf"), format(plan))
        XCTAssertFalse(format(plan).contains("*"), "the wildcard must never reach the predicate")
    }

    func test_questionMark_alsoAsksForASieve() {
        let plan = SpotlightQueryBuilder.maskPlan("файл?.txt")
        XCTAssertTrue(plan.postFilter)
        XCTAssertTrue(format(plan).contains("файл") || format(plan).contains(".txt"))
    }

    /// Nothing to lean on — fetch and sieve. (The dialog refuses such a query anyway, but the
    /// builder must not invent a predicate out of wildcards.)
    func test_pureWildcards_leaveNoPredicate() {
        let plan = SpotlightQueryBuilder.maskPlan("*?*")
        XCTAssertNil(plan.predicate)
        XCTAssertTrue(plan.postFilter)
    }

    /// A mask carrying a quote must not build a malformed format string — NSPredicate answers
    /// those with an exception, which would take the whole app down.
    func test_quotesAndBackslashes_areData_notSyntax() {
        for mask in ["*\"кавычка\"*", "*back\\slash*", "*%K*", "*%@*"] {
            let plan = SpotlightQueryBuilder.maskPlan(mask)
            XCTAssertNotNil(plan.predicate, mask)
        }
    }

    func test_longestLiteralRun() {
        XCTAssertEqual(SpotlightQueryBuilder.longestLiteralRun("a*bbbb*cc"), "bbbb")
        XCTAssertEqual(SpotlightQueryBuilder.longestLiteralRun("*?*"), "")
    }

    // MARK: - The rest of the form

    func test_contentQuery_asksTheIndexForExtractedText() {
        let predicate = SpotlightQueryBuilder.contentPredicate("договор")
        XCTAssertTrue(predicate?.predicateFormat.contains("kMDItemTextContent") == true,
                      predicate?.predicateFormat ?? "nil")
        XCTAssertNil(SpotlightQueryBuilder.contentPredicate("   "))
    }

    func test_sizeAndDates_becomePredicates_notPostFilters() {
        XCTAssertEqual(SpotlightQueryBuilder.sizePredicates(minBytes: 0, maxBytes: 0).count, 0)
        XCTAssertEqual(SpotlightQueryBuilder.sizePredicates(minBytes: 10, maxBytes: 0).count, 1)
        XCTAssertEqual(SpotlightQueryBuilder.sizePredicates(minBytes: 10, maxBytes: 20).count, 2)

        let day = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SpotlightQueryBuilder.datePredicates(from: nil, to: nil).count, 0)
        XCTAssertEqual(SpotlightQueryBuilder.datePredicates(from: day, to: day).count, 2)
    }

    /// "To 5 May" must include everything written on 5 May, not stop at midnight.
    func test_dateTo_coversTheWholeChosenDay() {
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0,
                                         of: Date(timeIntervalSince1970: 1_800_000_000))!
        let predicate = SpotlightQueryBuilder.datePredicates(from: nil, to: noon).first
        XCTAssertTrue(predicate?.predicateFormat.contains("<") == true)
        let evening = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: noon)!
        XCTAssertTrue(predicate!.evaluate(with: [NSMetadataItemFSContentChangeDateKey: evening]),
                      "a file written the same evening must still be inside the range")
    }

    func test_wholeForm_combinesEveryPart() {
        let (predicate, sieve) = SpotlightQueryBuilder.predicate(
            mask: "*.pdf", contentQuery: "договор",
            minBytes: 1024, maxBytes: 0, dateFrom: nil, dateTo: nil)
        let text = try! XCTUnwrap(predicate).predicateFormat
        XCTAssertTrue(text.contains("kMDItemFSName"), text)
        XCTAssertTrue(text.contains("kMDItemTextContent"), text)
        XCTAssertTrue(text.contains("kMDItemFSSize"), text)
        XCTAssertFalse(sieve)
    }

    /// An empty form would ask the index for the whole disk — the caller must be told, not
    /// handed a predicate that matches everything.
    func test_emptyForm_yieldsNoPredicateAtAll() {
        let (predicate, _) = SpotlightQueryBuilder.predicate(
            mask: "*", contentQuery: "", minBytes: 0, maxBytes: 0, dateFrom: nil, dateTo: nil)
        XCTAssertNil(predicate)
    }

    // MARK: - Sieving results

    func test_hiddenPaths_areDroppedByUs_notLeftToTheIndex() {
        XCTAssertTrue(SpotlightQueryBuilder.isHidden(path: "/Users/x/.ssh/config"))
        XCTAssertTrue(SpotlightQueryBuilder.isHidden(path: "/Users/x/.профиль"))
        XCTAssertFalse(SpotlightQueryBuilder.isHidden(path: "/Users/x/файл.txt"))
        XCTAssertFalse(SpotlightQueryBuilder.isHidden(path: "/Users/x/папка/имя.с.точками.txt"))
    }

    func test_nameSieve_appliesTheMaskExactly() {
        XCTAssertTrue(SpotlightQueryBuilder.nameMatches(mask: "отчёт*2026.pdf",
                                                        name: "отчёт за 2026.pdf"))
        XCTAssertFalse(SpotlightQueryBuilder.nameMatches(mask: "отчёт*2026.pdf",
                                                         name: "отчёт за 2025.pdf"))
        XCTAssertTrue(SpotlightQueryBuilder.nameMatches(mask: "*.TXT", name: "письмо.txt"),
                      "masks are case-insensitive, as in the walking engine")
        XCTAssertTrue(SpotlightQueryBuilder.nameMatches(mask: "файл?.txt", name: "файл7.txt"))
        XCTAssertTrue(SpotlightQueryBuilder.nameMatches(mask: "*", name: "что угодно"))
    }

    /// macOS hands file names back DECOMPOSED — "ё" as е + combining diaeresis — while a mask
    /// typed on a keyboard is composed. A byte-wise fnmatch called those different and silently
    /// threw away correct hits; the sieve must fold them together.
    func test_nameSieve_matchesAcrossUnicodeNormalisation() {
        let composed = "отчёт за 2026.pdf".precomposedStringWithCanonicalMapping
        let decomposed = composed.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(composed.unicodeScalars), Array(decomposed.unicodeScalars),
                          "the two forms must really differ, or this test proves nothing")
        XCTAssertTrue(SpotlightQueryBuilder.nameMatches(mask: "отчёт*2026.pdf", name: decomposed))
        XCTAssertTrue(SpotlightQueryBuilder.nameMatches(mask: decomposed, name: composed))
    }

    // MARK: - Turning paths into results

    func test_hits_dropVanishedFiles_andHonourTheTypeFilter() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-spot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("файл.txt")
        try Data("содержимое".utf8).write(to: file)
        let gone = dir.appendingPathComponent("удалённый.txt").path

        let all = SpotlightSearchService.hits(from: [file.path, dir.path, gone],
                                              mask: "*", postFilter: false, typeFilter: .all)
        XCTAssertEqual(all.count, 2, "the path that no longer exists must not become a row")
        XCTAssertTrue(all.first?.isDirectory == true, "folders come first, as in the walk")
        XCTAssertEqual(all.last?.size, UInt64("содержимое".utf8.count))

        let filesOnly = SpotlightSearchService.hits(from: [file.path, dir.path],
                                                    mask: "*", postFilter: false,
                                                    typeFilter: .filesOnly)
        XCTAssertEqual(filesOnly.map(\.path), [file.path])

        let dirsOnly = SpotlightSearchService.hits(from: [file.path, dir.path],
                                                   mask: "*", postFilter: false,
                                                   typeFilter: .dirsOnly)
        XCTAssertEqual(dirsOnly.map(\.path), [dir.path])
    }

    func test_hits_applyTheSieveWhenThePredicateWasWidened() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-spot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keep = dir.appendingPathComponent("отчёт за 2026.pdf")
        let drop = dir.appendingPathComponent("отчёт за 2025.pdf")
        try Data().write(to: keep)
        try Data().write(to: drop)

        let sieved = SpotlightSearchService.hits(from: [keep.path, drop.path],
                                                 mask: "отчёт*2026.pdf",
                                                 postFilter: true, typeFilter: .all)
        XCTAssertEqual(sieved.map(\.name), ["отчёт за 2026.pdf"])
    }

    // MARK: - The index probe

    func test_indexProbe_readsMdutilsAnswer() {
        XCTAssertTrue(SpotlightIndexProbe.parseStatus("/:\n\tIndexing enabled. \n"))
        XCTAssertFalse(SpotlightIndexProbe.parseStatus("/Volumes/X:\n\tIndexing disabled.\n"))
        XCTAssertFalse(SpotlightIndexProbe.parseStatus(""))
    }
}
