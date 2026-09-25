import Foundation
import XCTest

@testable import TotumComXLApp

@MainActor
final class PanelViewModelBriefNavigationTests: XCTestCase {
    func test_briefMode_whenHorizontalMoveInsideBounds_shouldJumpByRowsPerColumn() throws {
        let panelViewModel = makePanelViewModel()
        panelViewModel.viewMode = .brief
        panelViewModel.allItems = makeItems(count: 12)
        panelViewModel.setCursor(index: 2)

        panelViewModel.moveCursorRight(rowsPerColumn: 5)
        XCTAssertEqual(panelViewModel.cursorIndex, 7)

        panelViewModel.moveCursorLeft(rowsPerColumn: 5)
        XCTAssertEqual(panelViewModel.cursorIndex, 2)
    }

    func test_briefMode_whenHorizontalMoveOutOfBounds_shouldClampToListEdges() throws {
        let panelViewModel = makePanelViewModel()
        panelViewModel.viewMode = .brief
        panelViewModel.allItems = makeItems(count: 12)

        panelViewModel.setCursor(index: 2)
        panelViewModel.moveCursorLeft(rowsPerColumn: 5)
        XCTAssertEqual(panelViewModel.cursorIndex, 0)

        panelViewModel.setCursor(index: 9)
        panelViewModel.moveCursorRight(rowsPerColumn: 5)
        XCTAssertEqual(panelViewModel.cursorIndex, 11)
    }

    private func makePanelViewModel() -> PanelViewModel {
        PanelViewModel(
            service: CoreBridgeService(),
            initialPath: NSHomeDirectory(),
            pathDefaultsKey: "panel.path.brief.nav.test.\(UUID().uuidString)",
            viewModeDefaultsKey: "panel.mode.brief.nav.test.\(UUID().uuidString)",
            showHiddenFiles: true
        )
    }

    private func makeItems(count: Int) -> [FileItem] {
        (0..<count).map { index in
            FileItem(
                path: "/tmp/fcxl-brief-nav-\(index)",
                name: "item-\(index).txt",
                fileExtension: "txt",
                size: UInt64(index),
                isDirectory: false,
                isHidden: false,
                isSymlink: false,
                permissions: "-rw-r--r--",
                dateModified: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
    }
}
