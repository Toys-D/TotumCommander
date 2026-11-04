import XCTest

@testable import TotumComXLApp

/// «Клавиши освобождены» должно значить, что они освобождены. Ответ складывался только из
/// списка ярлыков — то есть из того, что программа сама секунду назад и записала, — и выходил
/// утвердительным даже когда система список не перечитала и ярлык оставался живым.
final class SystemShortcutsHonestyTests: XCTestCase {

    func test_переучтеноИСписокЧист() {
        XCTAssertTrue(SystemShortcuts.freed(applied: true, stillHeld: []))
    }

    func test_системаНеПеречиталаЗначитНеОсвобождены() {
        XCTAssertFalse(SystemShortcuts.freed(applied: false, stillHeld: []))
    }

    func test_ярлыкОсталсяВСпискеЗначитНеОсвобождены() {
        XCTAssertFalse(SystemShortcuts.freed(applied: true, stillHeld: ["F11"]))
        XCTAssertFalse(SystemShortcuts.freed(applied: false, stillHeld: ["F11"]))
    }
}
