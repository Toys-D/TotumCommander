import XCTest

@testable import TotumComXLApp

/// Значок очереди: крутится и зеленеет, только когда байты правда идут. Очередь на паузе —
/// это не работа, и вертеться ей незачем.
final class QueueIconStateTests: XCTestCase {

    func test_триСостоянияОчереди() {
        XCTAssertEqual(QueueIconState.of(activeCount: 0, isProcessing: false), .idle)
        XCTAssertEqual(QueueIconState.of(activeCount: 0, isProcessing: true), .idle,
                       "задач нет — значку нечего показывать, что бы ни говорила служба")
        XCTAssertEqual(QueueIconState.of(activeCount: 3, isProcessing: false), .waiting)
        XCTAssertEqual(QueueIconState.of(activeCount: 1, isProcessing: true), .working)
    }

    func test_крутитсяТолькоВРаботе() {
        XCTAssertTrue(QueueIconState.working.spins)
        XCTAssertFalse(QueueIconState.waiting.spins, "на паузе значок стоит")
        XCTAssertFalse(QueueIconState.idle.spins)
    }
}

/// Подсветка текущей папки в центральном тоннеле.
final class TunnelCurrentFolderTests: XCTestCase {
    func testMarksExactPath() {
        XCTAssertTrue(TunnelStore.marksCurrent(folder: "/Users/x/Downloads",
                                               panel: "/Users/x/Downloads"))
    }

    func testIgnoresTrailingSlash() {
        XCTAssertTrue(TunnelStore.marksCurrent(folder: "/Applications",
                                               panel: "/Applications/"))
    }

    func testOtherFolderStaysDim() {
        XCTAssertFalse(TunnelStore.marksCurrent(folder: "/Users/x/Documents",
                                                panel: "/Users/x/Downloads"))
    }

    func testSubfolderIsNotTheFolderItself() {
        XCTAssertFalse(TunnelStore.marksCurrent(folder: "/Users/x/Downloads",
                                                panel: "/Users/x/Downloads/2026"))
    }

    func testEmptyPathMarksNothing() {
        XCTAssertFalse(TunnelStore.marksCurrent(folder: "/Applications", panel: ""))
    }
}
