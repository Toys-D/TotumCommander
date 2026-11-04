import XCTest

@testable import TotumComXLApp

/// Место рядом с панелью одно: просмотр и правка не должны ложиться друг на друга.
final class PanelSlotTests: XCTestCase {

    func testEditFromTheViewerClosesTheViewerFirst() {
        // F4 из просмотра: раньше редактор ложился поверх — заголовки двоились, и первый
        // Escape закрывал невидимый просмотрщик.
        XCTAssertEqual(PanelSlot.step(opening: .editor, current: .viewer), .closeViewerFirst)
    }

    func testViewFromTheEditorClosesTheEditorFirst() {
        // И не напрямую: несохранённое надо успеть спросить.
        XCTAssertEqual(PanelSlot.step(opening: .viewer, current: .editor), .closeEditorFirst)
    }

    func testAnEmptySlotIsOpenedStraightAway() {
        XCTAssertEqual(PanelSlot.step(opening: .viewer, current: .nobody), .openNow)
        XCTAssertEqual(PanelSlot.step(opening: .editor, current: .nobody), .openNow)
    }

    func testTheSameKindReplacesItself() {
        // Другой файл в том же просмотрщике — это не смена жильца.
        XCTAssertEqual(PanelSlot.step(opening: .viewer, current: .viewer), .openNow)
        XCTAssertEqual(PanelSlot.step(opening: .editor, current: .editor), .openNow)
    }

    func testTheViewerComesBackOnlyIfItSteppedAside() {
        XCTAssertTrue(PanelSlot.restoresViewer(steppedAside: true))
        XCTAssertFalse(PanelSlot.restoresViewer(steppedAside: false))
    }
}
