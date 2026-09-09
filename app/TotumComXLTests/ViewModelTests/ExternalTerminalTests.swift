import Foundation
import XCTest

@testable import TotumComXLApp

/// The choice logic behind "Open in Terminal": the saved pick wins while it is installed,
/// a removed app falls back, and Apple's Terminal is the floor that is always there.
final class ExternalTerminalTests: XCTestCase {

    func test_savedChoice_winsWhileInstalled() {
        let picked = ExternalTerminal.chosen(
            savedRawValue: ExternalTerminal.iterm.rawValue,
            installed: [.terminal, .iterm, .warp])
        XCTAssertEqual(picked, .iterm)
    }

    func test_removedApp_fallsBackToTheFirstInstalled() {
        let picked = ExternalTerminal.chosen(
            savedRawValue: ExternalTerminal.kitty.rawValue,
            installed: [.terminal, .warp])
        XCTAssertEqual(picked, .terminal)
    }

    func test_garbageAndNil_fallBackTheSameWay() {
        XCTAssertEqual(ExternalTerminal.chosen(savedRawValue: "какая-то чушь",
                                               installed: [.warp]), .warp)
        XCTAssertEqual(ExternalTerminal.chosen(savedRawValue: nil,
                                               installed: [.iterm]), .iterm)
    }

    /// Even an impossible empty install list answers something — Apple's Terminal.
    func test_emptyInstallList_stillAnswersTerminal() {
        XCTAssertEqual(ExternalTerminal.chosen(savedRawValue: nil, installed: []), .terminal)
    }

    /// On any real Mac the Terminal is present — the picker can never be empty.
    func test_appleTerminal_isAlwaysInstalled() {
        XCTAssertTrue(ExternalTerminal.terminal.isInstalled)
        XCTAssertTrue(ExternalTerminal.installed.contains(.terminal))
    }

    func test_bundleIDsAndNames_areDistinct() {
        XCTAssertEqual(Set(ExternalTerminal.allCases.map(\.rawValue)).count,
                       ExternalTerminal.allCases.count)
        XCTAssertEqual(Set(ExternalTerminal.allCases.map(\.displayName)).count,
                       ExternalTerminal.allCases.count)
    }
}
