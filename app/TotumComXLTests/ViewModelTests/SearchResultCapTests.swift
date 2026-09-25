import Foundation
import XCTest

@testable import TotumComXLApp

/// The drawing ceiling on search results. A duplicates run over a home folder once answered
/// with 662 821 files and the app beachballed inside SwiftUI's list tree — the answer must be
/// cut to what can be drawn, and the dialog must say that it was cut.
final class SearchResultCapTests: XCTestCase {

    private func hit(_ n: Int) -> SearchHit {
        SearchHit(path: "/x/файл\(n).txt", name: "файл\(n).txt",
                  lineNumber: nil, column: nil, lineContent: nil,
                  dateModified: nil, size: 1, isDirectory: false)
    }

    func test_shortList_passesThroughUntouched() {
        let hits = (0..<10).map(hit)
        let capped = AdvancedSearchViewModel.capped(hits, limit: 100)
        XCTAssertEqual(capped.hits.count, 10)
        XCTAssertEqual(capped.total, 0, "nothing was cut — the status line must stay quiet")
    }

    func test_longList_isCut_andReportsWhatItReallyWas() {
        let hits = (0..<5000).map(hit)
        let capped = AdvancedSearchViewModel.capped(hits, limit: 2000)
        XCTAssertEqual(capped.hits.count, 2000)
        XCTAssertEqual(capped.total, 5000)
        XCTAssertEqual(capped.hits.first?.name, "файл0.txt", "the cut keeps the head, in order")
    }

    func test_exactlyAtTheLimit_isNotCalledCut() {
        let capped = AdvancedSearchViewModel.capped((0..<2000).map(hit), limit: 2000)
        XCTAssertEqual(capped.total, 0)
    }

    // MARK: - Duplicates are counted in files, not groups

    private func group(_ n: Int, files: Int) -> DuplicateGroup {
        DuplicateGroup(size: 100, hash: "h\(n)",
                       files: (0..<files).map { "/x/группа\(n)/копия\($0).bin" })
    }

    func test_duplicateGroups_areCutByFileCount_neverSplit() {
        let groups = (0..<100).map { group($0, files: 7) }   // 700 files
        let capped = AdvancedSearchViewModel.capped(groups, limit: 50)
        XCTAssertEqual(capped.total, 700)
        let shown = capped.groups.reduce(0) { $0 + $1.files.count }
        XCTAssertGreaterThanOrEqual(shown, 50, "the group straddling the limit is kept whole")
        XCTAssertLessThan(shown, 50 + 7, "and only that one — no more")
        for kept in capped.groups {
            XCTAssertEqual(kept.files.count, 7, "a group must never be shown half")
        }
    }

    func test_fewDuplicates_passThroughUntouched() {
        let groups = (0..<3).map { group($0, files: 2) }
        let capped = AdvancedSearchViewModel.capped(groups, limit: 2000)
        XCTAssertEqual(capped.groups.count, 3)
        XCTAssertEqual(capped.total, 0)
    }

    /// The index engine harvests less than the dialog can hold — a round trip per item.
    func test_spotlightHarvestCap_staysUnderTheDialogCeiling() {
        XCTAssertLessThanOrEqual(SpotlightSearchService.defaultCap,
                                 AdvancedSearchViewModel.maxShownResults)
    }

    // MARK: - Flattening results into table rows

    func test_fileModes_giveOneRowPerHit_noHeaders() {
        let rows = SearchResultRows.build(mode: .byName, results: (0..<3).map(hit), duplicates: [])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.compactMap(\.path).count, 3, "no row may be an unselectable caption")
    }

    /// Duplicates get a caption before each group, and a caption is NOT a result: it carries
    /// no path, which is what keeps "select all" and the arrow keys off it.
    func test_duplicates_getACaptionPerGroup_whichIsNotSelectable() {
        let groups = [group(1, files: 2), group(2, files: 3)]
        let rows = SearchResultRows.build(mode: .duplicates, results: [], duplicates: groups)

        XCTAssertEqual(rows.count, 2 + 5, "two captions and five files")
        XCTAssertNil(rows.first?.path, "a group starts with its caption")
        XCTAssertEqual(rows.compactMap(\.path).count, 5)
        XCTAssertEqual(rows.compactMap(\.path).first, "/x/группа1/копия0.bin")
    }

    func test_emptyResults_giveNoRows() {
        XCTAssertTrue(SearchResultRows.build(mode: .byName, results: [], duplicates: []).isEmpty)
        XCTAssertTrue(SearchResultRows.build(mode: .duplicates, results: [], duplicates: []).isEmpty)
    }
}

/// The exclusion field: what the user types, and what it must protect.
final class SearchExclusionTests: XCTestCase {

    func test_bothSeparatorsSplit_andBlanksAreDropped() {
        XCTAssertEqual(AdvancedSearchViewModel.excludeList(" node_modules ; .cache, *.tmp ;; "),
                       ["node_modules", ".cache", "*.tmp"])
        XCTAssertTrue(AdvancedSearchViewModel.excludeList("   ").isEmpty)
        XCTAssertTrue(AdvancedSearchViewModel.excludeList(" ; , ").isEmpty)
    }

    /// The Spotlight sieve works on the path, because the index does its own walking and
    /// cannot be told to skip a folder.
    func test_pathSieve_looksAtEveryComponent() {
        let patterns = ["node_modules", "*.tmp"]
        XCTAssertTrue(AdvancedSearchViewModel.pathIsExcluded(
            "/Users/x/.cache/pkg/node_modules/deep/file.js", patterns: patterns))
        XCTAssertTrue(AdvancedSearchViewModel.pathIsExcluded(
            "/Users/x/scratch.tmp", patterns: patterns))
        XCTAssertFalse(AdvancedSearchViewModel.pathIsExcluded(
            "/Users/x/проект/файл.swift", patterns: patterns))
    }

    /// A pattern without a wildcard must match a whole component — the same rule the C++ walk
    /// follows, so both engines answer about the same tree.
    func test_wordPattern_doesNotSwallowLongerNames() {
        XCTAssertFalse(AdvancedSearchViewModel.pathIsExcluded("/x/rebuild.log/f", patterns: ["build"]))
        XCTAssertTrue(AdvancedSearchViewModel.pathIsExcluded("/x/build/f", patterns: ["build"]))
    }

    /// A relative path is checked the same way as an absolute one — the walk inside the MCP
    /// bridge hands out relative paths, and dropping their first component silently spared the
    /// very folder that had to be skipped.
    func test_relativePathsAreCheckedToo() {
        XCTAssertTrue(AdvancedSearchViewModel.pathIsExcluded("node_modules/deep/f.js",
                                                             patterns: ["node_modules"]))
        XCTAssertTrue(AdvancedSearchViewModel.pathIsExcluded("проект/.cache/f",
                                                             patterns: [".cache"]))
        XCTAssertFalse(AdvancedSearchViewModel.pathIsExcluded("проект/файл.swift",
                                                              patterns: ["node_modules"]))
    }

    func test_noPatterns_excludeNothing() {
        XCTAssertFalse(AdvancedSearchViewModel.pathIsExcluded("/x/node_modules/f", patterns: []))
    }
}
