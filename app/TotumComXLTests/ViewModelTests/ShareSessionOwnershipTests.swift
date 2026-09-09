import AppKit
import XCTest

@testable import TotumComXLApp

/// The pair a share session forms with its service: an NSSharingService keeps its delegate
/// alive, so a session that only leaves the list would still hold itself — and its service —
/// for the life of the app.
@MainActor
final class ShareSessionOwnershipTests: XCTestCase {

    private func settle() {
        let turn = expectation(description: "one turn of the main queue")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 2)
    }

    /// This is the fact the teardown is built on. If a future macOS stops retaining the
    /// delegate, this test says so — and the extra care can go.
    func testTheServiceKeepsItsDelegateAlive() {
        let service = NSSharingService(title: "T", image: NSImage(), alternateImage: nil,
                                       handler: {})
        weak var delegateObject: SharingServiceMenuTarget?
        autoreleasepool {
            let target = SharingServiceMenuTarget(service: service, items: [], sourceWindow: nil)
            delegateObject = target
            service.delegate = target
        }
        XCTAssertNotNil(delegateObject,
                        "the header calls the delegate weak; AppKit holds it all the same")
        service.delegate = nil
    }

    /// So a finished session must leave nothing behind: neither the object nor the service it
    /// was pointing at.
    func testAFinishedSessionLetsGoOfItsService() {
        weak var weakService: NSSharingService?
        weak var weakSession: SharingServiceMenuTarget?

        autoreleasepool {
            let service = NSSharingService(title: "T", image: NSImage(), alternateImage: nil,
                                           handler: {})
            weakService = service
            let target = SharingServiceMenuTarget(service: service, items: [], sourceWindow: nil)
            weakSession = target
            target.beginSession()
            target.sharingService(service, didShareItems: [])
        }
        settle()

        XCTAssertNil(weakSession)
        XCTAssertNil(weakService, "the service outlived the session that owned it")
    }
}
