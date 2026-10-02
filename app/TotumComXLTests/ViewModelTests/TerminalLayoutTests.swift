import XCTest
@testable import TotumComXLApp

/// Раскладка частей терминала: деление, закрытие, геометрия и переходы — без окон и процессов.
final class TerminalLayoutTests: XCTestCase {

    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    // MARK: - Деление

    func test_whenSinglePaneSplit_shouldMakeTwoHalves() {
        let layout = TerminalLayout.pane(a).splitting(a, axis: .sideBySide, newPane: b)
        XCTAssertEqual(layout, .split(.sideBySide, [.pane(a), .pane(b)], [0.5, 0.5]))
        XCTAssertEqual(layout.panes, [a, b])
    }

    /// Та же ось у родителя — новая часть встаёт соседом и делит долю той, что делили.
    func test_whenSplitAlongParentAxis_shouldAddSiblingSharingTheFraction() {
        let layout = TerminalLayout.pane(a)
            .splitting(a, axis: .sideBySide, newPane: b)
            .splitting(a, axis: .sideBySide, newPane: c)
        XCTAssertEqual(layout, .split(.sideBySide, [.pane(a), .pane(c), .pane(b)], [0.25, 0.25, 0.5]))
    }

    /// Другая ось — часть превращается в разделение из двух половин, её доля сохраняется.
    func test_whenSplitAcrossParentAxis_shouldNestASplit() {
        let layout = TerminalLayout.pane(a)
            .splitting(a, axis: .sideBySide, newPane: b)
            .splitting(b, axis: .stacked, newPane: c)
        XCTAssertEqual(layout, .split(.sideBySide,
                                      [.pane(a), .split(.stacked, [.pane(b), .pane(c)], [0.5, 0.5])],
                                      [0.5, 0.5]))
        XCTAssertEqual(layout.panes, [a, b, c])
    }

    func test_whenSplittingUnknownPane_shouldChangeNothing() {
        let layout = TerminalLayout.pane(a)
        XCTAssertEqual(layout.splitting(b, axis: .stacked, newPane: c), layout)
    }

    // MARK: - Закрытие

    func test_whenLastPaneRemoved_shouldBeEmpty() {
        XCTAssertNil(TerminalLayout.pane(a).removing(a))
    }

    /// Доля закрытой части уходит соседу, разделение из одного ребёнка схлопывается.
    func test_whenPaneRemoved_shouldGiveFractionToNeighbourAndCollapse() {
        let three = TerminalLayout.split(.sideBySide, [.pane(a), .pane(b), .pane(c)], [0.2, 0.3, 0.5])
        XCTAssertEqual(three.removing(b), .split(.sideBySide, [.pane(a), .pane(c)], [0.5, 0.5]))
        XCTAssertEqual(three.removing(a), .split(.sideBySide, [.pane(b), .pane(c)], [0.5, 0.5]))
        let two = TerminalLayout.split(.stacked, [.pane(a), .pane(b)], [0.5, 0.5])
        XCTAssertEqual(two.removing(a), .pane(b))
    }

    /// Вложенное разделение той же оси вливается в родителя: три части рядом, а не две в двух.
    func test_whenCollapseLeavesSameAxisChild_shouldFlattenIntoParent() {
        let nested = TerminalLayout.split(.sideBySide, [
            .pane(a),
            .split(.stacked, [.pane(b), .split(.sideBySide, [.pane(c), .pane(d)], [0.5, 0.5])], [0.5, 0.5]),
        ], [0.5, 0.5])
        let result = nested.removing(b)
        XCTAssertEqual(result, .split(.sideBySide, [.pane(a), .pane(c), .pane(d)], [0.5, 0.25, 0.25]))
    }

    // MARK: - Геометрия

    func test_framesFillTheRectLeavingDividers() {
        let layout = TerminalLayout.split(.sideBySide, [
            .pane(a), .split(.stacked, [.pane(b), .pane(c)], [0.5, 0.5]),
        ], [0.5, 0.5])
        let geometry = layout.frames(in: CGRect(x: 0, y: 0, width: 201, height: 101), divider: 1)
        XCTAssertEqual(geometry.panes[a], CGRect(x: 0, y: 0, width: 100, height: 101))
        XCTAssertEqual(geometry.panes[b], CGRect(x: 101, y: 0, width: 100, height: 50))
        XCTAssertEqual(geometry.panes[c], CGRect(x: 101, y: 51, width: 100, height: 50))
        XCTAssertEqual(geometry.dividers.count, 2)
        let vertical = geometry.dividers.first { $0.axis == .sideBySide }
        XCTAssertEqual(vertical?.rect, CGRect(x: 100, y: 0, width: 1, height: 101))
        XCTAssertEqual(vertical?.path, [])
        let horizontal = geometry.dividers.first { $0.axis == .stacked }
        XCTAssertEqual(horizontal?.rect, CGRect(x: 101, y: 50, width: 100, height: 1))
        XCTAssertEqual(horizontal?.path, [1])
    }

    func test_whenDividerMoved_shouldResizeOnlyItsTwoNeighboursWithinLimits() {
        let layout = TerminalLayout.split(.sideBySide, [.pane(a), .pane(b), .pane(c)], [0.25, 0.25, 0.5])
        let rect = CGRect(x: 0, y: 0, width: 402, height: 100)
        // Разделитель между a и b — на x = 150 (доля a становится 150 / 400).
        let moved = layout.movingDivider(at: [], index: 0, to: 150, in: rect, divider: 1, minimum: 40)
        guard case .split(_, _, let f) = moved else { return XCTFail("не разделение") }
        XCTAssertEqual(f[0], 0.375, accuracy: 0.001)
        XCTAssertEqual(f[1], 0.125, accuracy: 0.001)
        XCTAssertEqual(f[2], 0.5, accuracy: 0.001)
        // Слишком далеко — b не меньше минимума.
        let clamped = layout.movingDivider(at: [], index: 0, to: 400, in: rect, divider: 1, minimum: 40)
        guard case .split(_, _, let g) = clamped else { return XCTFail("не разделение") }
        XCTAssertEqual(g[1] * 400, 40, accuracy: 0.5)
        XCTAssertEqual(g[0] + g[1], 0.5, accuracy: 0.001)
    }

    // MARK: - Переходы

    func test_neighbourIsTheClosestPaneInThatDirection() {
        let layout = TerminalLayout.split(.sideBySide, [
            .pane(a), .split(.stacked, [.pane(b), .pane(c)], [0.5, 0.5]),
        ], [0.5, 0.5])
        let frames = layout.frames(in: CGRect(x: 0, y: 0, width: 201, height: 101), divider: 1).panes
        XCTAssertEqual(TerminalLayout.neighbour(of: a, direction: .right, frames: frames), b, "верхняя справа")
        XCTAssertEqual(TerminalLayout.neighbour(of: c, direction: .left, frames: frames), a)
        XCTAssertEqual(TerminalLayout.neighbour(of: b, direction: .down, frames: frames), c)
        XCTAssertEqual(TerminalLayout.neighbour(of: c, direction: .up, frames: frames), b)
        XCTAssertNil(TerminalLayout.neighbour(of: a, direction: .left, frames: frames), "дальше края нет")
        XCTAssertNil(TerminalLayout.neighbour(of: a, direction: .up, frames: frames))
    }
}
