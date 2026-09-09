import XCTest
@testable import TotumComXLApp

/// Сколько кнопок туннеля показать, когда высоты не хватает; остальные — в «Ещё».
final class TunnelOverflowTests: XCTestCase {

    /// Кнопка 30, зазор 10: место — 40 на кнопку; 400 высоты — 10 мест.
    private func plan(_ available: CGFloat, folders: Int, actions: Int) -> TunnelOverflow.Plan {
        TunnelOverflow.plan(available: available, itemHeight: 30, spacing: 10, folders: folders, actions: actions)
    }

    func test_всёВлезает_НичегоНеПрячется() {
        let p = plan(1000, folders: 8, actions: 6)
        XCTAssertEqual(p, .all(folders: 8, actions: 6))
        XCTAssertFalse(p.foldersHidden); XCTAssertFalse(p.actionsHidden)
    }

    func test_неВлезает_МестоДелитсяПополам() {
        // 10 мест на 14 кнопок: по 5 каждой секции, обе прячут хвост в «Ещё».
        let p = plan(400, folders: 8, actions: 6)
        XCTAssertEqual(p.folders, 5); XCTAssertEqual(p.actions, 5)
        XCTAssertTrue(p.foldersHidden); XCTAssertTrue(p.actionsHidden)
    }

    func test_секцииКоторойНужноМеньше_ОтдаётсяСколькоНужно() {
        // Папок 3 — им всё, операциям остальные 7 из 10.
        let p = plan(400, folders: 3, actions: 8)
        XCTAssertEqual(p.folders, 3); XCTAssertFalse(p.foldersHidden)
        XCTAssertEqual(p.actions, 7); XCTAssertTrue(p.actionsHidden)
        // И наоборот.
        let q = plan(400, folders: 9, actions: 2)
        XCTAssertEqual(q.actions, 2); XCTAssertFalse(q.actionsHidden)
        XCTAssertEqual(q.folders, 8); XCTAssertTrue(q.foldersHidden)
    }

    func test_совсемНетМеста_НичегоНеПоказывается() {
        let p = plan(0, folders: 5, actions: 5)
        XCTAssertEqual(p.folders, 0); XCTAssertEqual(p.actions, 0)
        XCTAssertTrue(p.foldersHidden); XCTAssertTrue(p.actionsHidden)
        XCTAssertEqual(plan(-50, folders: 5, actions: 5).folders, 0, "отрицательная высота — как ноль")
    }

    func test_зазорСчитаетсяМеждуКнопками_АНеПослеПоследней() {
        // 3 кнопки по 30 с двумя зазорами по 10 = 110 — влезают ровно в 110.
        XCTAssertEqual(plan(110, folders: 2, actions: 1), .all(folders: 2, actions: 1))
        XCTAssertTrue(plan(109, folders: 2, actions: 1).foldersHidden || plan(109, folders: 2, actions: 1).actionsHidden)
    }
}
