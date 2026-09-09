import XCTest
@testable import TotumComXLApp

/// Pure tests for RenameMaskEngine — tag expansion, counter, date/metadata, search/replace,
/// case, subfolder split, status. No UI, no disk: every input is a synthetic
/// RenameMaskEngine.Input with fixed date/size.
final class RenameMaskEngineTests: XCTestCase {

    private let engine = RenameMaskEngine()

    private func input(_ name: String,
                       path: String? = nil,
                       isDir: Bool = false,
                       modified: Date = Date(timeIntervalSince1970: 1_767_000_000), // 2025-12-29 11:20 UTC
                       size: UInt64 = 2048,
                       width: Int? = nil, height: Int? = nil) -> RenameMaskEngine.Input {
        RenameMaskEngine.Input(path: path ?? "/tmp/\(name)", name: name, isDirectory: isDir,
                               modified: modified, created: modified, size: size,
                               width: width, height: height)
    }

    /// Run the whole pipeline for a set of names, return just the target names in order.
    private func run(_ names: [String], _ rule: RenameRule) -> [String] {
        engine.preview(names.map { input($0) }, rule: rule).map { $0.newName }
    }

    func testNoTagsPassesLiteralThrough() {
        var c = RenameMaskEngine.CounterState(listIndex: 0)
        XCTAssertEqual(engine.expand(mask: "hello", input: input("a.txt"), index: 0,
                                     rule: RenameRule(), counter: &c), "hello")
    }

    func testBasicNameAndExtension() {
        XCTAssertEqual(run(["report.pdf", "photo.JPG"], RenameRule()),
                       ["report.pdf", "photo.JPG"])
    }

    func testNameOnlyDropsExtensionWhenExtMaskEmpty() {
        var r = RenameRule(); r.extMask = ""
        XCTAssertEqual(run(["report.pdf"], r), ["report"])   // no trailing dot
    }

    func testDotfileWholeNameIsExtension() {
        // ".gitignore": [N] empty, [E] == "gitignore"
        var r = RenameRule(); r.nameMask = "x[N]"; r.extMask = "[E]"
        XCTAssertEqual(run([".gitignore"], r), ["x.gitignore"])
    }

    func testNoExtensionGivesEmptyE() {
        var r = RenameRule(); r.nameMask = "[N]-[E]"; r.extMask = ""
        XCTAssertEqual(run(["README"], r), ["README-"])
    }

    func testRanges() {
        let n = "abcdefgh"
        func nm(_ mask: String) -> String {
            var r = RenameRule(); r.nameMask = mask; r.extMask = ""
            return run(["\(n).x"], r).first ?? ""
        }
        XCTAssertEqual(nm("[N1]"),    "a")      // single from start
        XCTAssertEqual(nm("[N2-5]"),  "bcde")   // range from start
        XCTAssertEqual(nm("[N2,3]"),  "bcd")    // start + length
        XCTAssertEqual(nm("[N3-]"),   "cdefgh") // start to end
        XCTAssertEqual(nm("[N-1]"),   "h")      // last char
        XCTAssertEqual(nm("[N-2-1]"), "gh")     // both from end (2nd-last..last)
        XCTAssertEqual(nm("[N-3,2]"), "fg")     // from end + length
        XCTAssertEqual(nm("[N2--2]"), "bcdefg") // start-from-start (2) .. end-from-end (2nd-last)
        XCTAssertEqual(nm("[N-3-]"),  "fgh")    // 3rd-last to end
        XCTAssertEqual(nm("[N5-99]"), "efgh")   // out of range end -> clipped
        XCTAssertEqual(nm("[N20]"),   "")       // out of range single -> empty
    }

    func testWholeNameRangeAndA() {
        var r = RenameRule(); r.nameMask = "[A]"; r.extMask = ""
        XCTAssertEqual(run(["report.pdf"], r), ["report.pdf"])       // [A] = name WITH ext
        r.nameMask = "[1-3]"
        XCTAssertEqual(run(["report.pdf"], r), ["rep"])              // [#-#] over whole name incl ext
    }

    func testPathTags() {
        func nm(_ mask: String, path: String) -> String {
            var r = RenameRule(); r.nameMask = mask; r.extMask = ""
            return engine.preview([input("file.txt", path: path)], rule: r).first!.newName
        }
        XCTAssertEqual(nm("[P]", path: "/a/photos/file.txt"), "photos")
        XCTAssertEqual(nm("[G]", path: "/a/photos/file.txt"), "a")
        XCTAssertEqual(nm("[B0]", path: "/a/b/c/file.txt"), "c")   // parent
        XCTAssertEqual(nm("[B1]", path: "/a/b/c/file.txt"), "b")   // grandparent
        XCTAssertEqual(nm("[B+0]", path: "/a/b/c/file.txt"), "a")  // from root
        XCTAssertEqual(nm("[P1-3]", path: "/a/photos/file.txt"), "pho")  // range on parent name
    }

    func testIgnoreDotsInFolderName() {
        var r = RenameRule(); r.nameMask = "[I][N]"; r.extMask = "[E]"
        // a folder "2024.trip" with [I] keeps its dot: [N] = whole name, [E] empty
        XCTAssertEqual(engine.preview([input("2024.trip", isDir: true)], rule: r).first!.newName,
                       "2024.trip")
    }

    func testCounterBasic() {
        var r = RenameRule(); r.nameMask = "img[C]"; r.extMask = "[E]"
        r.counterStart = 1; r.counterStep = 1; r.counterDigits = 2
        XCTAssertEqual(run(["a.jpg", "b.jpg", "c.jpg"], r), ["img01.jpg", "img02.jpg", "img03.jpg"])
    }
    func testCounterInlineParams() {
        var r = RenameRule(); r.nameMask = "[C10+5:3]"; r.extMask = ""
        XCTAssertEqual(run(["a", "b", "c"], r), ["010", "015", "020"])
    }
    func testCounterInheritsDialogWhenPartialInline() {
        var r = RenameRule(); r.nameMask = "[C:3]"; r.extMask = ""
        r.counterStart = 4; r.counterStep = 2; r.counterDigits = 1
        XCTAssertEqual(run(["a", "b"], r), ["004", "006"])   // width from inline, start/step from dialog
    }
    func testLastCounterValueLowercaseC() {
        var r = RenameRule(); r.nameMask = "[C]-[c]"; r.extMask = ""
        r.counterStart = 1; r.counterStep = 1; r.counterDigits = 1
        XCTAssertEqual(run(["a", "b"], r), ["1-1", "2-2"])   // [c] reuses the value without advancing
    }

    func testLetterCounter() {
        var r = RenameRule(); r.nameMask = "[Ca]"; r.extMask = ""
        XCTAssertEqual(run(["1","2","3"], r), ["a","b","c"])
    }
    func testLetterCounterWraps() {
        var r = RenameRule(); r.nameMask = "[Ca]"; r.extMask = ""
        let names = (0..<28).map { "\($0)" }
        let out = run(names, r)
        XCTAssertEqual(out[25], "z"); XCTAssertEqual(out[26], "aa"); XCTAssertEqual(out[27], "ab")
    }
    func testFractionalCounterBuckets() {
        var r = RenameRule(); r.nameMask = "[C+1/3]"; r.extMask = ""
        r.counterStart = 1
        // advance by 1 every 3 files: 1,1,1,2,2,2,3
        XCTAssertEqual(run((0..<7).map{"\($0)"}, r), ["1","1","1","2","2","2","3"])
    }

    func testDateTags() {
        // Engine uses a UTC calendar in tests so components are stable.
        let utc = RenameMaskEngine(calendar: {
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
        }())
        let d = Date(timeIntervalSince1970: 1_767_000_000)   // 2025-12-29 09:20:00 UTC
        // Bracket date tags stamp `now`, not the file's date — so inject `d` as now here. The file
        // itself carries a different date (2000-01-01) to prove the tags don't read it.
        let fileDate = Date(timeIntervalSince1970: 946_684_800)  // 2000-01-01
        let inp = RenameMaskEngine.Input(path: "/t/a.txt", name: "a.txt", isDirectory: false,
                                         modified: fileDate, created: fileDate, size: 0, width: nil, height: nil)
        func nm(_ mask: String) -> String {
            var r = RenameRule(); r.nameMask = mask; r.extMask = ""
            return utc.preview([inp], rule: r, now: d).first!.newName
        }
        XCTAssertEqual(nm("[Y]"), "2025")
        XCTAssertEqual(nm("[y]"), "25")
        XCTAssertEqual(nm("[M]"), "12")
        XCTAssertEqual(nm("[D]"), "29")
        XCTAssertEqual(nm("[h]"), "09")
        XCTAssertEqual(nm("[m]"), "20")
        XCTAssertEqual(nm("[YMD]"), "20251229")
        XCTAssertEqual(nm("[hms]"), "092000")
    }

    func testWriteDateTagUsesFileDate() {
        // [=tc.writedate] must read the FILE's modification date, not `now`.
        let utc = RenameMaskEngine(calendar: {
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
        }())
        let fileDate = Date(timeIntervalSince1970: 1_767_000_000)   // 2025-12-29 UTC
        let now = Date(timeIntervalSince1970: 946_684_800)          // 2000-01-01
        let inp = RenameMaskEngine.Input(path: "/t/a.txt", name: "a.txt", isDirectory: false,
                                         modified: fileDate, created: fileDate, size: 0, width: nil, height: nil)
        var r = RenameRule(); r.nameMask = "[=tc.writedate]"; r.extMask = ""
        XCTAssertEqual(utc.preview([inp], rule: r, now: now).first!.newName, "20251229")
    }

    func testMetadataTags() {
        let inp = RenameMaskEngine.Input(path: "/t/pic.png", name: "pic.png", isDirectory: false,
            modified: Date(timeIntervalSince1970: 1_767_000_000),
            created: Date(timeIntervalSince1970: 1_767_000_000),
            size: 2048, width: 800, height: 600)
        func nm(_ mask: String) -> String {
            var r = RenameRule(); r.nameMask = mask; r.extMask = ""
            return engine.preview([inp], rule: r).first!.newName
        }
        XCTAssertEqual(nm("[=tc.size]"), "2048")
        XCTAssertEqual(nm("[=tc.size.kbytes]"), "2")
        XCTAssertEqual(nm("[=tc.width]x[=tc.height]"), "800x600")
        XCTAssertEqual(nm("[=tc.fullname]"), "pic.png")
    }
    func testMissingMetadataRendersEmpty() {
        var r = RenameRule(); r.nameMask = "a[=tc.width]b"; r.extMask = ""
        XCTAssertEqual(run(["x.txt"], r), ["ab"])   // no width -> empty
    }

    func testPlainReplaceAll() {
        var r = RenameRule(); r.nameMask = "[N]"; r.extMask = "[E]"; r.search = "_"; r.replace = "-"
        XCTAssertEqual(run(["a_b_c.txt"], r), ["a-b-c.txt"])
    }
    func testReplaceOnce() {
        var r = RenameRule(); r.search = "_"; r.replace = "-"; r.replaceOnce = true
        XCTAssertEqual(run(["a_b_c.txt"], r), ["a-b_c.txt"])
    }
    func testPipePairs() {
        var r = RenameRule(); r.search = "cat|dog"; r.replace = "fish|bird"
        XCTAssertEqual(run(["cat_dog.txt"], r), ["fish_bird.txt"])
    }
    func testRegexBackref() {
        var r = RenameRule(); r.useRegex = true; r.search = "(\\d+)-(\\d+)"; r.replace = "$2-$1"
        XCTAssertEqual(run(["12-34.txt"], r), ["34-12.txt"])
    }
    func testRegexRespectCaseOff() {
        var r = RenameRule(); r.useRegex = true; r.search = "img"; r.replace = "X"; r.respectCase = false
        XCTAssertEqual(run(["IMG.jpg"], r), ["X.jpg"])
    }
    func testMalformedRegexIsError() {
        var r = RenameRule(); r.useRegex = true; r.search = "("; r.replace = "x"
        let p = engine.preview([input("a.txt")], rule: r).first!
        if case .error = p.status {} else { XCTFail("expected error status") }
    }
    func testCaseModes() {
        func c(_ m: CaseMode, _ name: String) -> String {
            var r = RenameRule(); r.caseMode = m; return run([name], r).first!
        }
        XCTAssertEqual(c(.lower, "AbC.TXT"), "abc.txt")
        XCTAssertEqual(c(.upper, "AbC.txt"), "ABC.TXT")
        XCTAssertEqual(c(.firstUpper, "hELLO.txt"), "Hello.txt")
        XCTAssertEqual(c(.eachWord, "hello world.txt"), "Hello World.txt")   // extension untouched
    }

    func testStatusUnchanged() {
        let p = engine.preview([input("a.txt")], rule: RenameRule()).first!
        XCTAssertEqual(p.status, .unchanged)
    }
    func testStatusDuplicate() {
        var r = RenameRule(); r.nameMask = "same"; r.extMask = "txt"
        let ps = engine.preview([input("a.x"), input("b.x")], rule: r)
        XCTAssertEqual(ps[0].status, .duplicate); XCTAssertEqual(ps[1].status, .duplicate)
    }
    func testStatusIllegalCharAndEmpty() {
        var r = RenameRule(); r.nameMask = "a:b"; r.extMask = "txt"
        if case .error = engine.preview([input("x.y")], rule: r).first!.status {} else { XCTFail() }
        var e = RenameRule(); e.nameMask = ""; e.extMask = ""
        if case .error = engine.preview([input("x.y")], rule: e).first!.status {} else { XCTFail() }
    }
    func testSubfolderSeparatorIsAllowed() {
        var r = RenameRule(); r.nameMask = "sub/[N]"; r.extMask = "[E]"
        let p = engine.preview([input("a.txt")], rule: r).first!
        XCTAssertEqual(p.newName, "sub/a.txt"); XCTAssertEqual(p.status, .ok)
    }
    func testDotDotRejected() {
        var r = RenameRule(); r.nameMask = "../[N]"; r.extMask = "[E]"
        if case .error = engine.preview([input("a.txt")], rule: r).first!.status {} else { XCTFail() }
    }

    func testInlineCaseSwitches() {
        func nm(_ mask: String, _ name: String = "aBcDe.txt") -> String {
            var r = RenameRule(); r.nameMask = mask; r.extMask = ""
            return run([name], r).first ?? ""
        }
        XCTAssertEqual(nm("[U][N]"), "ABCDE")          // sticky upper over the name
        XCTAssertEqual(nm("[L][N]"), "abcde")          // sticky lower
        XCTAssertEqual(nm("[U][N1-2][n][N3-]"), "ABcDe") // upper first two, then back to normal
        XCTAssertEqual(nm("[F][N]"), "ABcDe")          // one-shot: only first char upper
        XCTAssertEqual(nm("[f][N]", "ABCDE.txt"), "aBCDE") // one-shot: only first char lower
        XCTAssertEqual(nm("x[U]y[n]z"), "xYz")          // switches affect literals too
    }
}
