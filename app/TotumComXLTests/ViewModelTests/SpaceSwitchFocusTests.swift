import XCTest

@testable import TotumComXLApp

/// Coming back from another desktop left the window behind whatever else was open there — and
/// the first fix went too far the other way, shouldering the app in front on EVERY switch. The
/// rule has to be narrow twice over: the user must have arrived at the desktop the window stands
/// on, AND the app must be the one macOS put in front there.
final class SpaceSwitchFocusTests: XCTestCase {

    func testTheWindowOnTheDesktopTheUserArrivedAtIsFronted() {
        XCTAssertTrue(MainWindowController.shouldReclaimFocus(
            isVisible: true, isMiniaturized: false, isOnActiveSpace: true, isAppActive: true))
    }

    /// The complaint that narrowed it: the window follows the user everywhere, so "arrived at its
    /// desktop" is true on every switch. If the app was NOT the one in front, it must stay where
    /// it was — behind whatever the user had covering it.
    func testAnAppThatWasNotInFrontStaysWhereItWas() {
        XCTAssertFalse(MainWindowController.shouldReclaimFocus(
            isVisible: true, isMiniaturized: false, isOnActiveSpace: true, isAppActive: false))
    }

    /// The regression guard: fronting a window that lives elsewhere would yank the user off the
    /// desktop they just chose — exactly what .moveToActiveSpace was added to stop.
    func testAWindowOnAnotherDesktopIsLeftAlone() {
        XCTAssertFalse(MainWindowController.shouldReclaimFocus(
            isVisible: true, isMiniaturized: false, isOnActiveSpace: false, isAppActive: true))
    }

    func testMinimisedStaysMinimised() {
        XCTAssertFalse(MainWindowController.shouldReclaimFocus(
            isVisible: true, isMiniaturized: true, isOnActiveSpace: true, isAppActive: true))
    }

    func testAClosedWindowIsNotResurrected() {
        XCTAssertFalse(MainWindowController.shouldReclaimFocus(
            isVisible: false, isMiniaturized: false, isOnActiveSpace: true, isAppActive: true))
    }
}
