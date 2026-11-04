import AppKit
import XCTest
@testable import TotumComXLApp

/// Конец перетаскивания вкладки узнаётся по отпущенной кнопке мыши, где бы её ни отпустили.
///
/// Жалоба: цветную вкладку перетащили — и она осталась серой с толстой обводкой. Это вид
/// «цели перетаскивания», а сбрасывался он только в performDrop, который приходит лишь при
/// отпускании ровно над вкладкой.
@MainActor
final class TabDragEndTests: XCTestCase {

    func test_кнопкаОтпущена() {
        XCTAssertTrue(TabDragEnd.isOver(pressedButtons: 0))
        XCTAssertFalse(TabDragEnd.isOver(pressedButtons: 1), "левая зажата — тащат")
        XCTAssertTrue(TabDragEnd.isOver(pressedButtons: 2), "правая — не перетаскивание")
        XCTAssertFalse(TabDragEnd.isOver(pressedButtons: 3))
    }

    /// В проверке мышь не зажата — сторож срабатывает на первом же такте и сбрасывает.
    func test_сторожСбрасываетПоОтпусканию() {
        let watcher = TabDragEndWatcher()
        var ended = 0
        watcher.watch { ended += 1 }
        XCTAssertTrue(watcher.isWatching)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(ended, 1, "конец перетаскивания замечен")
        XCTAssertFalse(watcher.isWatching, "и сторож остановлен")

        // Новое перетаскивание — новый сторож, прежний не сработает дважды.
        watcher.watch { ended += 10 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(ended, 11)
    }
}
