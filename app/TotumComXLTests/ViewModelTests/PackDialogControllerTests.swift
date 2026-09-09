import Foundation
import XCTest

@testable import TotumComXLApp

final class PackDialogControllerTests: XCTestCase {
    func test_archiveNameSelectionRange_whenNameHasCurrentExtension_shouldSelectBaseNameOnly() {
        let range = PackDialogController.archiveNameSelectionRange(
            for: "backup.zip",
            format: .zip
        )

        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, 6)
    }

    func test_archiveNameSelectionRange_whenNameHasCompoundExtension_shouldSelectBaseNameOnly() {
        let range = PackDialogController.archiveNameSelectionRange(
            for: "backup.tar.gz",
            format: .tarGz
        )

        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, 6)
    }

    func test_archiveNameSelectionRange_whenNameHasNoExtension_shouldSelectWholeName() {
        let range = PackDialogController.archiveNameSelectionRange(
            for: "backup",
            format: .zip
        )

        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, 6)
    }
}
