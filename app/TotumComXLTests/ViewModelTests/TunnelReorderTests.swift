import XCTest
@testable import TotumComXLApp

/// Перетаскивание кнопки внутри туннеля: где призрак и к какому месту он ближе.
final class TunnelReorderTests: XCTestCase {

    /// Три места по 30 пунктов, одно под другим: центры 15, 45, 75.
    private let ids = ["a", "b", "c"]
    private var frames: [String: CGRect] {
        ["a": CGRect(x: 0, y: 0, width: 80, height: 30),
         "b": CGRect(x: 0, y: 30, width: 80, height: 30),
         "c": CGRect(x: 0, y: 60, width: 80, height: 30)]
    }

    private func grab(_ id: String, at mouseY: CGFloat) throws -> TunnelReorder {
        try XCTUnwrap(TunnelReorder(section: .folders, id: id, ids: ids,
                                    frames: frames, mouseY: mouseY))
    }

    func test_призракВисит_ГдеВзяли_АНеПоЦентру() throws {
        // Взяли верхнюю кнопку у нижнего края (y=25, центр 15) и повели на 30 вниз.
        var drag = try grab("a", at: 25)
        XCTAssertEqual(drag.ghostCenter, 15)
        drag.follow(mouseY: 55)
        XCTAssertEqual(drag.ghostCenter, 45, "призрак сдвинулся ровно на столько, на сколько мышь")
    }

    func test_местоНазначения_БлижайшееПоЦентру() throws {
        var drag = try grab("a", at: 15)
        XCTAssertEqual(drag.targetIndex, 0)
        drag.follow(mouseY: 29)
        XCTAssertEqual(drag.targetIndex, 0, "до середины соседа — своё место")
        drag.follow(mouseY: 31)
        XCTAssertEqual(drag.targetIndex, 1, "перевалили середину — место соседа")
        drag.follow(mouseY: 70)
        XCTAssertEqual(drag.targetIndex, 2)
    }

    func test_призракНеУлетаетИзСвоейЧасти() throws {
        var drag = try grab("b", at: 45)
        drag.follow(mouseY: 500)
        XCTAssertEqual(drag.ghostCenter, 75, "ниже последнего места не бывает")
        XCTAssertEqual(drag.targetIndex, 2)
        drag.follow(mouseY: -500)
        XCTAssertEqual(drag.ghostCenter, 15, "выше первого — тоже")
        XCTAssertEqual(drag.targetIndex, 0)
    }

    /// Папка извне встаёт туда, где её отпустили: перед кнопкой, чья середина ниже точки.
    func test_местоБроска_ПередБлижайшейСнизуКнопкой() {
        let slots = ids.compactMap { frames[$0] }
        XCTAssertEqual(TunnelDrop.insertionIndex(y: 10, slots: slots), 0)
        XCTAssertEqual(TunnelDrop.insertionIndex(y: 20, slots: slots), 1, "ниже середины первой — под неё")
        XCTAssertEqual(TunnelDrop.insertionIndex(y: 50, slots: slots), 2)
        XCTAssertEqual(TunnelDrop.insertionIndex(y: 500, slots: slots), 3, "ниже всех — в конец")
        XCTAssertEqual(TunnelDrop.insertionIndex(y: 10, slots: []), 0, "пустой список — первой")
    }

    func test_чертаВставки_ВЗазореНадМестом() {
        let slots = ids.compactMap { frames[$0] }
        XCTAssertEqual(TunnelDrop.lineY(index: 0, slots: slots, gap: 2), -1)
        XCTAssertEqual(TunnelDrop.lineY(index: 1, slots: slots, gap: 2), 29)
        XCTAssertEqual(TunnelDrop.lineY(index: 3, slots: slots, gap: 2), 91, "в конец — под последней")
        XCTAssertNil(TunnelDrop.lineY(index: 0, slots: [], gap: 2), "без кнопок черты нет")
    }

    func test_безРамокЗахватаНет() {
        var few = frames
        few.removeValue(forKey: "c")
        XCTAssertNil(TunnelReorder(section: .actions, id: "a", ids: ids, frames: few, mouseY: 10),
                     "кнопка ещё не отчиталась о рамке — тащить нечего")
        XCTAssertNil(TunnelReorder(section: .actions, id: "x", ids: ids, frames: frames, mouseY: 10),
                     "чужая кнопка")
        XCTAssertNil(TunnelReorder(section: .actions, id: "a", ids: [], frames: [:], mouseY: 10))
    }
}
