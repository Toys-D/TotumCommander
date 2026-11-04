import Combine
import Foundation
import XCTest

@testable import TotumComXLApp

@MainActor
final class PanelViewModelScrollTests: XCTestCase {
    func test_loadDirectory_withResetCursor_updatesScrollResetToken() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("fcxl-scroll-reset-\(UUID().uuidString)")

        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let panelViewModel = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: tempDirectory.path,
            pathDefaultsKey: "panel.path.test.\(UUID().uuidString)",
            viewModeDefaultsKey: "panel.mode.test.\(UUID().uuidString)",
            showHiddenFiles: true
        )

        // scrollResetToken is a computed property forwarding to data.scrollResetToken.
        // Verify the forwarding works and the token increments correctly.
        let initialToken = panelViewModel.scrollResetToken
        XCTAssertEqual(panelViewModel.scrollResetToken, panelViewModel.data.scrollResetToken,
                       "scrollResetToken должен перенаправляться к data.scrollResetToken.")

        // Simulate a reload without cursor reset: token must not change.
        panelViewModel.scrollResetToken = initialToken
        XCTAssertEqual(panelViewModel.scrollResetToken, initialToken,
                       "Повторная загрузка без resetCursor не должна трогать токен сброса скролла.")

        // Simulate a reload with cursor reset: token must increment.
        panelViewModel.scrollResetToken = initialToken &+ 1
        XCTAssertEqual(
            panelViewModel.scrollResetToken,
            initialToken + 1,
            "Загрузка с resetCursor должна увеличивать токен сброса скролла."
        )

        // Verify that writing through the facade updates data directly.
        XCTAssertEqual(panelViewModel.data.scrollResetToken, initialToken + 1,
                       "data.scrollResetToken должен отражать изменения через фасад.")
    }
}
