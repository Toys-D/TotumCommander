import XCTest
@testable import TotumComXLApp

/// Pure tests for the temp-name staging planner. No disk: assert on the emitted step list.
final class RenameExecutionPlannerTests: XCTestCase {
    private let planner = RenameExecutionPlanner()
    private func temp(_ i: Int) -> String { ".fcxl-tmp-\(i)" }

    func testDirectRenamesNoConflict() {
        let steps = planner.plan([.init(source: "/d/a.txt", final: "/d/x.txt"),
                                  .init(source: "/d/b.txt", final: "/d/y.txt")], tempSuffix: temp)
        XCTAssertEqual(steps, [.init(from: "/d/a.txt", to: "/d/x.txt"),
                               .init(from: "/d/b.txt", to: "/d/y.txt")])
    }
    func testCaseOnlyStaged() {
        let steps = planner.plan([.init(source: "/d/a.txt", final: "/d/A.txt")], tempSuffix: temp)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].from, "/d/a.txt")
        XCTAssertEqual(steps[0].to, "/d/.fcxl-tmp-0")
        XCTAssertEqual(steps[1], .init(from: "/d/.fcxl-tmp-0", to: "/d/A.txt"))
    }
    func testCycleStaged() {
        let steps = planner.plan([.init(source: "/d/a", final: "/d/b"),
                                  .init(source: "/d/b", final: "/d/a")], tempSuffix: temp)
        // both participate; both staged then both moved to finals
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(Set(steps.suffix(2)), Set([.init(from: "/d/.fcxl-tmp-0", to: "/d/b"),
                                                  .init(from: "/d/.fcxl-tmp-1", to: "/d/a")]))
    }

    // MARK: - Учёт временных имён (Ledger)

    private func swap() -> [RenameExecutionPlanner.Step] {
        // [a→tmp0, b→tmp1, tmp0→b, tmp1→a]
        planner.plan([.init(source: "/d/a", final: "/d/b"),
                      .init(source: "/d/b", final: "/d/a")], tempSuffix: temp)
    }

    func test_учётПропускаетШагСВременногоИмениКоторогоНеПоявилось() {
        let steps = swap()
        var ledger = RenameExecutionPlanner.Ledger(steps: steps)
        ledger.record(steps[0], succeeded: false)

        XCTAssertTrue(ledger.shouldSkip(steps[2]), "tmp0 не появился — шага с него нет")
        XCTAssertFalse(ledger.shouldSkip(steps[3]))
        XCTAssertNil(ledger.nextStranded())
    }

    func test_учётПредлагаетСначалаПрежнееИмяПотомНовое() {
        // Цепочка a→b, b→c: [a→tmp0, b→c, tmp0→b]
        let steps = planner.plan([.init(source: "/d/a", final: "/d/b"),
                                  .init(source: "/d/b", final: "/d/c")], tempSuffix: temp)
        var ledger = RenameExecutionPlanner.Ledger(steps: steps)
        ledger.record(steps[0], succeeded: true)
        ledger.record(steps[1], succeeded: true)

        let stranded = ledger.nextStranded()
        XCTAssertEqual(stranded?.temp, "/d/.fcxl-tmp-0")
        XCTAssertEqual(stranded?.candidates, ["/d/a", "/d/b"])
    }

    func test_учётНеПредлагаетИмяКотороеДержитДругойФайлПакета() {
        let steps = swap()
        var ledger = RenameExecutionPlanner.Ledger(steps: steps)
        ledger.record(steps[0], succeeded: true)
        XCTAssertEqual(ledger.nextStranded()?.candidates, ["/d/a"], "b ещё на своём месте — его имя занято")

        ledger.record(steps[1], succeeded: true)
        ledger.record(steps[2], succeeded: true)   // бывший a встал на имя b
        let stranded = ledger.nextStranded()
        XCTAssertEqual(stranded?.temp, "/d/.fcxl-tmp-1")
        XCTAssertEqual(stranded?.candidates, ["/d/a"], "прежнее имя b занято — остаётся новое")
    }

    func test_учётЗабываетФайлКоторыйВернулиИлиОставили() {
        let steps = swap()
        var ledger = RenameExecutionPlanner.Ledger(steps: steps)
        ledger.record(steps[0], succeeded: true)
        ledger.record(steps[1], succeeded: true)

        let first = try? XCTUnwrap(ledger.nextStranded())
        ledger.settled(first!, at: "/d/a")
        let second = try? XCTUnwrap(ledger.nextStranded())
        XCTAssertEqual(second?.temp, "/d/.fcxl-tmp-1")
        ledger.abandon(second!)
        XCTAssertNil(ledger.nextStranded())
    }

    func test_учётНазываетФайлПрежнимИменемАНеВременным() {
        let steps = swap()
        let ledger = RenameExecutionPlanner.Ledger(steps: steps)
        XCTAssertEqual(ledger.displayName(for: steps[0]), "a")
        XCTAssertEqual(ledger.displayName(for: steps[2]), "a")
        XCTAssertEqual(ledger.displayName(for: steps[3]), "b")
    }

    func test_учётПриСменеРегистраПредлагаетИмяОдинРаз() {
        let steps = planner.plan([.init(source: "/d/a.txt", final: "/d/A.txt")], tempSuffix: temp)
        var ledger = RenameExecutionPlanner.Ledger(steps: steps)
        ledger.record(steps[0], succeeded: true)
        XCTAssertEqual(ledger.nextStranded()?.candidates, ["/d/a.txt"])
    }
}
