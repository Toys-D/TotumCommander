import Combine
import Foundation
import XCTest

@testable import TotumComXLApp

@MainActor
final class PanelStateTests: XCTestCase {

    // MARK: - Initial State

    func test_initialState_hasCorrectDefaults() {
        let state = PanelState()

        XCTAssertEqual(state.currentPath, "")
        XCTAssertEqual(state.viewMode, .detailed)
        XCTAssertFalse(state.insideArchive)
        XCTAssertNil(state.archivePath)
        XCTAssertFalse(state.isActivelyRemote)
        XCTAssertNil(state.remoteSession)
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.launchingFilePath)
        XCTAssertFalse(state.isLoading)
    }

    // MARK: - Published Change

    func test_settingCurrentPath_publishesChange() {
        let state = PanelState()
        var cancellables = Set<AnyCancellable>()
        let expectation = XCTestExpectation(description: "currentPath published change")

        state.$currentPath
            .dropFirst()
            .sink { newValue in
                if newValue == "/Users/test" {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        state.currentPath = "/Users/test"

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Breadcrumbs (local path)

    func test_breadcrumbs_forDocumentsPath_returnsCorrectComponents() {
        let state = PanelState()
        state.currentPath = "/Users/test/Documents"

        let crumbs = state.breadcrumbs

        XCTAssertEqual(crumbs.count, 4, "Expected 4 breadcrumbs: /, Users, test, Documents")
        XCTAssertEqual(crumbs[0].name, "/")
        XCTAssertEqual(crumbs[0].path, "/")
        XCTAssertEqual(crumbs[1].name, "Users")
        XCTAssertEqual(crumbs[1].path, "/Users")
        XCTAssertEqual(crumbs[2].name, "test")
        XCTAssertEqual(crumbs[2].path, "/Users/test")
        XCTAssertEqual(crumbs[3].name, "Documents")
        XCTAssertEqual(crumbs[3].path, "/Users/test/Documents")
    }

    func test_breadcrumbs_forRootPath_returnsOnlyRoot() {
        let state = PanelState()
        state.currentPath = "/"

        let crumbs = state.breadcrumbs

        XCTAssertEqual(crumbs.count, 1)
        XCTAssertEqual(crumbs[0].name, "/")
        XCTAssertEqual(crumbs[0].path, "/")
    }

    // MARK: - insideRemote computed

    func test_insideRemote_matchesIsActivelyRemote() {
        let state = PanelState()
        XCTAssertFalse(state.insideRemote)
        state.isActivelyRemote = true
        XCTAssertTrue(state.insideRemote)
    }
}
