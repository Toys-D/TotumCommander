import Foundation
import XCTest

@testable import TotumComXLApp

@MainActor
final class PanelViewModelContextMenuTests: XCTestCase {
    func test_whenContextMenuOnUnselectedItem_shouldActivateAndSelectOnlyThatItem() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("fcxl-context-menu-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let alphaURL = tempDirectory.appendingPathComponent("alpha.txt")
        let betaURL = tempDirectory.appendingPathComponent("beta.txt")
        try "a".write(to: alphaURL, atomically: true, encoding: .utf8)
        try "b".write(to: betaURL, atomically: true, encoding: .utf8)

        let panelViewModel = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: tempDirectory.path,
            pathDefaultsKey: "panel.path.context.test.\(UUID().uuidString)",
            viewModeDefaultsKey: "panel.mode.context.test.\(UUID().uuidString)",
            showHiddenFiles: true
        )

        // loadDirectory is async — populate items synchronously so the test
        // does not depend on the background Task completing.
        panelViewModel.allItems = [alphaURL, betaURL].compactMap { url in
            FileItem.fromPath(url.path)
        }

        guard let alphaIndex = panelViewModel.items.firstIndex(where: { $0.path == alphaURL.path }),
              let betaIndex = panelViewModel.items.firstIndex(where: { $0.path == betaURL.path }) else {
            XCTFail("Не удалось найти тестовые элементы в списке панели.")
            return
        }

        panelViewModel.setCursor(index: alphaIndex)
        panelViewModel.selectedPaths = [alphaURL.path]

        panelViewModel.activateItemForContextMenu(at: betaIndex)

        XCTAssertEqual(panelViewModel.cursorIndex, betaIndex)
        XCTAssertEqual(panelViewModel.anchorIndex, betaIndex)
        XCTAssertEqual(panelViewModel.selectedPaths, [betaURL.path])
    }
}
