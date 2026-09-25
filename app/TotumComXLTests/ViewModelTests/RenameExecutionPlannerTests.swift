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
}
