import XCTest
@testable import TotumComXLApp

/// Backspace после стёртой маски быстрого поиска не должен удалять файл и не должен
/// уводить на папку вверх: полсекунды он не действует, а зажатый — пока не отпустят.
final class BackspaceGraceTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    func test_безЗакрытойМаски_НеВмешивается() {
        var grace = BackspaceGrace()
        XCTAssertFalse(grace.swallows(isRepeat: false, now: t0))
        XCTAssertFalse(grace.swallows(isRepeat: true, now: t0))
    }

    func test_вПределахПаузы_Проглатывает() {
        var grace = BackspaceGrace()
        grace.filterClosed(at: t0)
        XCTAssertTrue(grace.swallows(isRepeat: false, now: t0.addingTimeInterval(0.1)))
        XCTAssertTrue(grace.swallows(isRepeat: false, now: t0.addingTimeInterval(0.49)))
    }

    func test_послеПаузы_Действует() {
        var grace = BackspaceGrace()
        grace.filterClosed(at: t0)
        XCTAssertFalse(grace.swallows(isRepeat: false, now: t0.addingTimeInterval(0.5)))
    }

    func test_зажатаяКлавиша_ПроглатываетсяПокаНеОтпустят() {
        var grace = BackspaceGrace()
        grace.filterClosed(at: t0)
        XCTAssertTrue(grace.swallows(isRepeat: true, now: t0.addingTimeInterval(0.3)))
        XCTAssertTrue(grace.swallows(isRepeat: true, now: t0.addingTimeInterval(2.0)),
                      "держат дольше паузы — всё ещё та же клавиша")
        XCTAssertFalse(grace.swallows(isRepeat: false, now: t0.addingTimeInterval(2.1)),
                       "отпустили и нажали заново — работает")
    }

    func test_послеПервогоНастоящегоНажатия_АвтоповторыРаботают() {
        var grace = BackspaceGrace()
        grace.filterClosed(at: t0)
        XCTAssertFalse(grace.swallows(isRepeat: false, now: t0.addingTimeInterval(1)))
        XCTAssertFalse(grace.swallows(isRepeat: true, now: t0.addingTimeInterval(1.03)),
                       "зажатый Backspace поднимает на несколько папок, как раньше")
    }

    func test_новоеЗакрытие_НоваяПауза() {
        var grace = BackspaceGrace()
        grace.filterClosed(at: t0)
        XCTAssertFalse(grace.swallows(isRepeat: false, now: t0.addingTimeInterval(1)))
        grace.filterClosed(at: t0.addingTimeInterval(5))
        XCTAssertTrue(grace.swallows(isRepeat: false, now: t0.addingTimeInterval(5.2)))
    }
}
