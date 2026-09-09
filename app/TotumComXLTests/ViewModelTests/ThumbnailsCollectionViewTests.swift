import AppKit
import XCTest

@testable import TotumComXLApp

@MainActor
final class ThumbnailsCollectionViewTests: XCTestCase {
    func test_selectionIndexPaths_whenSet_shouldRemainEmpty() {
        let collectionView = ThumbnailsCollectionView()
        let indexPath = IndexPath(item: 3, section: 0)

        collectionView.selectionIndexPaths = [indexPath]

        XCTAssertTrue(collectionView.selectionIndexPaths.isEmpty)
    }

    func test_selectAndDeselectItems_shouldNotChangeSelection() {
        let collectionView = ThumbnailsCollectionView()
        let indexPath = IndexPath(item: 1, section: 0)

        collectionView.selectItems(at: [indexPath], scrollPosition: [])
        collectionView.deselectItems(at: [indexPath])

        XCTAssertTrue(collectionView.selectionIndexPaths.isEmpty)
    }
}
