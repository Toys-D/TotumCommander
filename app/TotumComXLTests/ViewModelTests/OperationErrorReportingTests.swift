import XCTest

@testable import TotumComXLApp

/// Which failures deserve a window and which do not.
///
/// This existed as four copy-pasted lines at each call site, and the copy that mattered most was
/// simply missing: copying into a folder that does not exist showed the real explanation and then
/// a second window announcing "cancelled by user" — something the user had not done.
///
/// Only the decision is tested. Actually showing a dialog runs a modal loop with nobody to close
/// it, which is why this layer has to be a pure function to be testable at all.
final class OperationErrorReportingTests: XCTestCase {

    private func cancellation() -> Error {
        NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError,
                userInfo: [NSLocalizedDescriptionKey: "Операция отменена пользователем"])
    }

    // MARK: - Stays quiet

    func testAUserCancellationIsNotWorthAWindow() {
        XCTAssertTrue(DialogService.isCancellation(cancellation()))
    }

    /// The service reports "I already told them" the same way it reports a refusal, so both have
    /// to be recognised — otherwise every explained problem gets a redundant second window.
    func testAnAlreadyExplainedProblemIsRecognisedToo() {
        let alreadyShown = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        XCTAssertTrue(DialogService.isCancellation(alreadyShown))
    }

    // MARK: - Deserves a window

    func testARealFileErrorIsReported() {
        let noSuchFile = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        XCTAssertFalse(DialogService.isCancellation(noSuchFile))
    }

    func testAPermissionErrorIsReported() {
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        XCTAssertFalse(DialogService.isCancellation(denied))
    }

    func testADiskFullErrorIsReported() {
        let full = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertFalse(DialogService.isCancellation(full))
    }

    /// POSIX code 158 happens to equal NSUserCancelledError. Matching on the number alone would
    /// swallow a genuine failure from another domain and leave the user with no explanation.
    func testTheSameNumberInAnotherDomainIsStillAFailure() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: NSUserCancelledError)
        XCTAssertFalse(DialogService.isCancellation(posix))

        let ownDomain = NSError(domain: "FileOperationsService", code: NSUserCancelledError)
        XCTAssertFalse(DialogService.isCancellation(ownDomain))
    }

    /// Swift's own cancellation is not the Cocoa one; it must not be mistaken for it.
    func testSwiftCancellationErrorIsNotTheCocoaOne() {
        XCTAssertFalse(DialogService.isCancellation(CancellationError()))
    }

    func testTheAppsOwnErrorsAreReported() {
        XCTAssertFalse(DialogService.isCancellation(
            RemoteFileSystemError.operationFailed("server said no")))
        XCTAssertFalse(DialogService.isCancellation(
            RemoteFileSystemError.connectionFailed("no route to host")))
    }
}
