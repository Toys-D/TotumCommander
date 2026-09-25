import Combine
import Foundation
import XCTest

@testable import TotumComXLApp

@MainActor
final class PanelDataTests: XCTestCase {

    // MARK: - Initial State

    func test_initialState_hasEmptyItems() {
        let data = PanelData()
        XCTAssertTrue(data.items.isEmpty)
    }

    func test_initialState_hasCursorAtZero() {
        let data = PanelData()
        XCTAssertEqual(data.cursorIndex, 0)
    }

    func test_initialState_hasEmptySelection() {
        let data = PanelData()
        XCTAssertTrue(data.selectedPaths.isEmpty)
    }

    func test_initialState_hasSortByName() {
        let data = PanelData()
        XCTAssertEqual(data.sortField, .name)
        XCTAssertTrue(data.sortAscending)
    }

    // MARK: - cursorItem

    func test_cursorItem_returnsNilWhenItemsEmpty() {
        let data = PanelData()
        XCTAssertNil(data.cursorItem)
    }

    func test_cursorItem_returnsCorrectItem() {
        let data = PanelData()
        let item = FileItem(
            path: "/test/file.txt",
            name: "file.txt",
            fileExtension: "txt",
            size: 100,
            isDirectory: false,
            isHidden: false,
            isSymlink: false,
            permissions: "",
            dateModified: Date()
        )
        data.publishDisplayItems([item])
        data.cursorIndex = 0
        XCTAssertEqual(data.cursorItem?.path, "/test/file.txt")
    }

    func test_cursorItem_returnsNilWhenIndexOutOfBounds() {
        let data = PanelData()
        let item = FileItem(
            path: "/test/file.txt",
            name: "file.txt",
            fileExtension: "txt",
            size: 100,
            isDirectory: false,
            isHidden: false,
            isSymlink: false,
            permissions: "",
            dateModified: Date()
        )
        data.publishDisplayItems([item])
        data.cursorIndex = 5
        XCTAssertNil(data.cursorItem)
    }

    func test_cursorItem_returnsNilWhenNegativeIndex() {
        let data = PanelData()
        let item = FileItem(
            path: "/test/file.txt",
            name: "file.txt",
            fileExtension: "txt",
            size: 100,
            isDirectory: false,
            isHidden: false,
            isSymlink: false,
            permissions: "",
            dateModified: Date()
        )
        data.publishDisplayItems([item])
        data.cursorIndex = -1
        XCTAssertNil(data.cursorItem)
    }

    // MARK: - dataDidChange subject

    func test_settingItems_firesDataDidChange() {
        let data = PanelData()
        var cancellables = Set<AnyCancellable>()
        let expectation = XCTestExpectation(description: "dataDidChange fired")

        data.dataDidChange
            .sink { expectation.fulfill() }
            .store(in: &cancellables)

        data.publishDisplayItems([])

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - cursorDidChange subject

    func test_settingCursorIndex_firesCursorDidChange() {
        let data = PanelData()
        var cancellables = Set<AnyCancellable>()
        let expectation = XCTestExpectation(description: "cursorDidChange fired")

        data.cursorDidChange
            .sink { expectation.fulfill() }
            .store(in: &cancellables)

        data.cursorIndex = 1

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - selectionDidChange subject

    func test_settingSelectedPaths_firesSelectionDidChange() {
        let data = PanelData()
        var cancellables = Set<AnyCancellable>()
        let expectation = XCTestExpectation(description: "selectionDidChange fired")

        data.selectionDidChange
            .sink { expectation.fulfill() }
            .store(in: &cancellables)

        data.selectedPaths = ["/test/file.txt"]

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - scrollResetRequested subject

    func test_settingScrollResetToken_firesScrollResetRequested() {
        let data = PanelData()
        var cancellables = Set<AnyCancellable>()
        let expectation = XCTestExpectation(description: "scrollResetRequested fired")

        data.scrollResetRequested
            .sink { expectation.fulfill() }
            .store(in: &cancellables)

        data.scrollResetToken = 1

        wait(for: [expectation], timeout: 1.0)
    }
}
