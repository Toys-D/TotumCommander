import XCTest
@testable import TotumComXLApp

/// Просьба остановиться, живущая отдельно от вида.
///
/// О ходе переноса спрашивают из того потока, где он идёт. Раньше кнопка «Отмена» в
/// просмотрщике писала в состояние SwiftUI, а загрузка читала его из чужого потока —
/// гонка, из-за которой просьба до неё не доходила: кнопка была, отмены не было.
final class CancelBoxTests: XCTestCase {

    func test_поднятыйФлагВиденСразу() {
        let box = CancelBox()
        XCTAssertFalse(box.raised)
        box.raise()
        XCTAssertTrue(box.raised)
    }

    /// Поднимают из одного потока, читают из другого — ровно так, как это происходит
    /// на деле: кнопка на главном, загрузка на своём.
    func test_флагВиденИзДругогоПотока() {
        let box = CancelBox()
        let raised = expectation(description: "флаг поднят")
        let seen = expectation(description: "и увиден")

        DispatchQueue.global().async {
            box.raise()
            raised.fulfill()
        }
        wait(for: [raised], timeout: 2)

        DispatchQueue.global().async {
            if box.raised { seen.fulfill() }
        }
        wait(for: [seen], timeout: 2)
    }

    /// Коробки не общие: отменённый показ не отменяет следующий.
    func test_новаяКоробкаНеНаследуетОтмену() {
        let first = CancelBox()
        first.raise()
        let second = CancelBox()
        XCTAssertTrue(first.raised)
        XCTAssertFalse(second.raised, "новый показ начинается с чистого листа")
    }
}
