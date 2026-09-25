import AppKit
import XCTest

@testable import TotumComXLApp

/// The way out of a share panel that will not close.
///
/// The panel is another app's extension drawn inside a window of ours, and its own close button
/// answers to that app, not to us — on some machines it does not answer at all, from Finder
/// either. Esc is the app's own way out: find the window the sharing framework put up, and
/// close it.
@MainActor
final class SharePanelEscapeTests: XCTestCase {

    private var made: [NSWindow] = []

    override func tearDown() {
        for window in made { window.orderOut(nil) }
        made.removeAll()
        super.tearDown()
    }

    private func makeWindow(visible: Bool, content: NSView? = nil) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        if let content { window.contentView = content }
        if visible { window.orderFront(nil) }
        made.append(window)
        return window
    }

    private func ids(_ windows: [NSWindow]) -> Set<ObjectIdentifier> {
        Set(windows.map(ObjectIdentifier.init))
    }

    // MARK: - Which window is the panel

    func testAWindowThatWasAlreadyThereIsNeverClosed() {
        let existing = makeWindow(visible: true)
        let found = SharingServiceMenuTarget.panelWindows(in: [existing],
                                                          excluding: ids([existing]))
        XCTAssertTrue(found.isEmpty)
    }

    func testTheWindowThatAppearedIsTheOne() {
        let existing = makeWindow(visible: true)
        let panel = makeWindow(visible: true)
        let found = SharingServiceMenuTarget.panelWindows(in: [existing, panel],
                                                          excluding: ids([existing]))
        XCTAssertEqual(found.map(ObjectIdentifier.init), [ObjectIdentifier(panel)])
    }

    /// Windows are made before they are shown, and off-screen ones are not what Esc is for.
    func testAWindowNobodyCanSeeIsLeftAlone() {
        let hidden = makeWindow(visible: false)
        XCTAssertTrue(SharingServiceMenuTarget.panelWindows(in: [hidden], excluding: []).isEmpty)
    }

    /// Our own windows are never closed this way, whatever else is going on.
    func testTheAppsOwnWindowsAreNotTouched() {
        let ours = makeWindow(visible: true)
        let found = SharingServiceMenuTarget.panelWindows(in: [ours], excluding: [],
                                                          isOwn: { $0 === ours })
        XCTAssertTrue(found.isEmpty)
    }

    /// A window the app made itself is not a framework window — that is the whole basis of the
    /// rule, and it must hold for a plain AppKit window too.
    func testAPlainSystemWindowIsNotOurs() {
        XCTAssertFalse(SharingServiceMenuTarget.isOwnWindow(makeWindow(visible: false)))
    }

    /// A share puts up TWO windows: the panel and the darkening behind it. Closing only the one
    /// that looks like a panel is what left the app greyed out with nothing to click.
    func testTheDarkeningGoesWithThePanel() {
        let panel = makeWindow(visible: true, content: FakeRemoteView())
        let dimming = makeWindow(visible: true)          // a plain window, by nothing but its class
        let found = SharingServiceMenuTarget.panelWindows(in: [panel, dimming], excluding: [])
        XCTAssertEqual(Set(found.map(ObjectIdentifier.init)),
                       Set([panel, dimming].map(ObjectIdentifier.init)))
    }

    // MARK: - Telling the panel from the darkening

    func testThePanelIsTheFrameworksRemoteWindow() {
        XCTAssertTrue(SharingServiceMenuTarget.isPanelWindow(FakeSHKRemoteWindow()))
        XCTAssertFalse(SharingServiceMenuTarget.isPanelWindow(makeWindow(visible: false)))
    }

    /// The way out has to be the framework's own: closing the windows by hand leaves it
    /// thinking the share is still on, and then no later share opens at all. The method is not
    /// in the headers, so its presence is a fact worth checking rather than assuming — if a
    /// future macOS drops it, this test says so before a user finds out.
    func testTheFrameworkStillOffersItsOwnWayToDismissAShare() {
        let service = NSSharingService(title: "T", image: NSImage(), alternateImage: nil,
                                       handler: {})
        XCTAssertTrue(SharingServiceMenuTarget.hasFrameworkDismiss(service),
                      "no dismissWithCompletion: — the app is back to closing windows by hand")
    }

    /// And it has to be CALLED the way the framework expects. A completion block written as a
    /// bare closure is non-escaping, the framework holds it while the panel closes, and Swift
    /// stops the app dead: "non-escaping closure has escaped". This is that call, made against
    /// a service with no panel of its own — it must simply return.
    func testAskingTheFrameworkToDismissDoesNotBringTheAppDown() {
        let service = NSSharingService(title: "T", image: NSImage(), alternateImage: nil,
                                       handler: {})
        XCTAssertTrue(SharingServiceMenuTarget.askFrameworkToDismiss(service))
    }

    // MARK: - The keys that mean "stop"

    func testEscapeAndCommandPeriodBothCancel() {
        XCTAssertTrue(SharingServiceMenuTarget.isCancelKey(key(53)))
        XCTAssertTrue(SharingServiceMenuTarget.isCancelKey(key(47, modifiers: .command)))
    }

    func testAnOrdinaryFullStopIsNotACancel() {
        XCTAssertFalse(SharingServiceMenuTarget.isCancelKey(key(47)))
        XCTAssertFalse(SharingServiceMenuTarget.isCancelKey(key(47, modifiers: .shift)))
        XCTAssertFalse(SharingServiceMenuTarget.isCancelKey(key(36)))
    }

    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: code)!
    }
}

/// A stand-in for the remote view the framework puts inside the panel.
private final class FakeRemoteView: NSView {}

/// …and for the window it puts it in — the real one is `SHKRemoteWindow`.
private final class FakeSHKRemoteWindow: NSWindow {}
