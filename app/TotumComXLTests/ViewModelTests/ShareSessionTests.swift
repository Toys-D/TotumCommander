import AppKit
import XCTest

@testable import TotumComXLApp

/// Sending a file to Telegram (or anything else with a share extension): the panel that opens
/// belongs to a window of ours, and the session behind it lives until the sharing is over.
@MainActor
final class ShareSessionTests: XCTestCase {

    /// Let the main queue run one turn: a session lets go of itself there, never inside the
    /// delegate callback that told it the sharing was over.
    private func settle() {
        let turn = expectation(description: "one turn of the main queue")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 2)
    }

    /// A service that does nothing when performed — enough to hold a session and answer as a
    /// delegate, without a panel appearing on screen.
    private func makeService() -> NSSharingService {
        NSSharingService(title: "Test", image: NSImage(), alternateImage: nil, handler: {})
    }

    /// The click that starts a share also closes the menu it came from, taking every strong
    /// reference to the session with it. If the session dies there, the panel is left with
    /// nothing behind it: the file never goes and the window stops answering.
    func testTheSessionOutlivesTheMenuItThatStartedIt() {
        let service = makeService()
        weak var session: SharingServiceMenuTarget?

        autoreleasepool {
            let target = SharingServiceMenuTarget(service: service, items: [], sourceWindow: nil)
            session = target
            target.beginSession()
        }

        XCTAssertNotNil(session, "the menu is gone and the share panel would be dead with it")
        session?.endSession()
        settle()
    }

    /// …and lives no longer than that. Once the service says the sharing is done, the session
    /// goes — otherwise every file ever sent stays in memory.
    func testTheSessionEndsWhenTheSharingSucceeds() {
        let service = makeService()
        weak var session: SharingServiceMenuTarget?

        autoreleasepool {
            let target = SharingServiceMenuTarget(service: service, items: [], sourceWindow: nil)
            session = target
            target.beginSession()
            target.sharingService(service, didShareItems: [])
        }
        settle()

        XCTAssertNil(session)
    }

    /// A share that fails — or is cancelled, which arrives the same way — must free it too.
    func testTheSessionEndsWhenTheSharingFails() {
        let service = makeService()
        weak var session: SharingServiceMenuTarget?

        autoreleasepool {
            let target = SharingServiceMenuTarget(service: service, items: [], sourceWindow: nil)
            session = target
            target.beginSession()
            target.sharingService(service, didFailToShareItems: [],
                                  error: CocoaError(.userCancelled))
        }
        settle()

        XCTAssertNil(session)
    }

    /// A service that never reports back would otherwise pile up for the life of the app.
    func testSessionsThatNeverReportBackDoNotPileUp() {
        let before = SharingServiceMenuTarget.liveSessionCount
        var opened: [SharingServiceMenuTarget] = []
        for _ in 0..<20 {
            let target = SharingServiceMenuTarget(service: makeService(), items: [],
                                                  sourceWindow: nil)
            target.beginSession()
            opened.append(target)
        }

        XCTAssertLessThanOrEqual(SharingServiceMenuTarget.liveSessionCount, 8 + before)
        for target in opened { target.endSession() }
        settle()
    }

    // MARK: - The window the panel belongs to

    /// The sharing framework asks whose window this is. Answering "none" is what left the panel
    /// unowned — it is the one thing the framework complained about in the log every time.
    func testThePanelIsAnchoredToTheWindowItWasOpenedFrom() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let service = makeService()
        let target = SharingServiceMenuTarget(service: service, items: [], sourceWindow: window)

        var scope = NSSharingService.SharingContentScope.full
        let answered = withUnsafeMutablePointer(to: &scope) {
            target.sharingService(service, sourceWindowForShareItems: [], sharingContentScope: $0)
        }

        XCTAssertTrue(answered === window)
        XCTAssertEqual(scope, .item, "one file is being shared, not the whole window")
    }

    /// The window can close while the panel is still up; the session must not hold it open.
    func testTheSessionDoesNotKeepTheWindowAlive() {
        weak var weakWindow: NSWindow?
        let service = makeService()
        var target: SharingServiceMenuTarget?

        autoreleasepool {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                  styleMask: [.titled], backing: .buffered, defer: true)
            weakWindow = window
            target = SharingServiceMenuTarget(service: service, items: [], sourceWindow: window)
        }

        XCTAssertNil(weakWindow)
        var scope = NSSharingService.SharingContentScope.full
        let answered = withUnsafeMutablePointer(to: &scope) {
            target?.sharingService(service, sourceWindowForShareItems: [], sharingContentScope: $0)
        }
        XCTAssertNil(answered ?? nil)
    }
}
