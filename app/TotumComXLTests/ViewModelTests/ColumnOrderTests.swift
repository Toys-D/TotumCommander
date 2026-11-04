import Foundation
import XCTest

@testable import TotumComXLApp

/// The column-order model behind drag-to-reorder headers: a saved order that can never
/// lose a column, and the pure move operation the drop delegate applies.
final class ColumnOrderTests: XCTestCase {

    // MARK: - Sanitizing

    func test_sanitized_neverLosesAColumn() {
        // A short saved order (older version knew fewer columns) gets the rest appended.
        let short: [PanelColumn] = [.size, .type]
        let fixed = PanelViewModel.sanitizedColumnOrder(short)
        XCTAssertEqual(fixed.prefix(2), [.size, .type])
        XCTAssertEqual(Set(fixed), Set(PanelViewModel.defaultColumnOrder),
                       "every known column must be present")
    }

    func test_sanitized_dropsDuplicatesAndName() {
        let messy: [PanelColumn] = [.size, .size, .name, .type, .size]
        let fixed = PanelViewModel.sanitizedColumnOrder(messy)
        XCTAssertEqual(fixed.filter { $0 == .size }.count, 1)
        XCTAssertFalse(fixed.contains(.name), "name is pinned outside the order")
    }

    func test_sanitized_emptyGivesTheDefault() {
        XCTAssertEqual(PanelViewModel.sanitizedColumnOrder([]),
                       PanelViewModel.defaultColumnOrder)
    }

    // MARK: - The move itself

    func test_move_placesBeforeTheTarget() {
        let order: [PanelColumn] = [.type, .size, .dateModified]
        XCTAssertEqual(
            PanelViewModel.columnOrder(order, moving: .dateModified, before: .type),
            [.dateModified, .type, .size])
    }

    func test_move_nilTargetGoesToTheEnd() {
        let order: [PanelColumn] = [.type, .size, .dateModified]
        XCTAssertEqual(
            PanelViewModel.columnOrder(order, moving: .type, before: nil),
            [.size, .dateModified, .type])
    }

    func test_move_ontoItself_changesNothing() {
        let order: [PanelColumn] = [.type, .size]
        XCTAssertEqual(PanelViewModel.columnOrder(order, moving: .size, before: .size), order)
    }

    // MARK: - Table identifiers

    /// Every column must map to a distinct table identifier — a clash would make
    /// applyColumnOrder move the same AppKit column twice and lose another entirely.
    func test_tableIDs_areDistinct() {
        let ids = PanelColumn.allCases.map(\.tableID)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
