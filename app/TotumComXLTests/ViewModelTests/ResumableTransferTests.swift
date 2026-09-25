import XCTest

@testable import TotumComXLApp

/// The rules that let a transfer survive a bad line: what to do with a half-finished file,
/// when to try again, and when trying again is pointless. No server is involved — the whole
/// point of keeping these rules apart is that they can be argued with on a desk.
final class ResumableTransferTests: XCTestCase {

    // MARK: - What to do with what is already there

    func test_decide_nothingOnDisk_startsOver() {
        XCTAssertEqual(ResumableTransfer.decide(partSize: 0, totalSize: 1000, canResume: true),
                       .startOver)
    }

    func test_decide_halfAFile_continues() {
        XCTAssertEqual(ResumableTransfer.decide(partSize: 400, totalSize: 1000, canResume: true),
                       .resume(from: 400))
    }

    func test_decide_everyByteThere_onlyTheRenameIsLeft() {
        XCTAssertEqual(ResumableTransfer.decide(partSize: 1000, totalSize: 1000, canResume: true),
                       .alreadyComplete)
    }

    /// More on disk than the far end holds means the file changed while we were away; the
    /// two halves must never be spliced together.
    func test_decide_moreThanTheWholeFile_startsOver() {
        XCTAssertEqual(ResumableTransfer.decide(partSize: 1200, totalSize: 1000, canResume: true),
                       .startOver)
    }

    func test_decide_backendCannotResume_startsOver() {
        XCTAssertEqual(ResumableTransfer.decide(partSize: 400, totalSize: 1000, canResume: false),
                       .startOver)
    }

    /// Without a known size a leftover cannot be told from a finished file.
    func test_decide_unknownTotal_startsOver() {
        XCTAssertEqual(ResumableTransfer.decide(partSize: 400, totalSize: 0, canResume: true),
                       .startOver)
    }

    // MARK: - Which failures are worth another try

    func test_worthRetrying_brokenLinkYes_cancelNo() {
        XCTAssertTrue(ResumableTransfer.worthRetrying(RemoteFileSystemError.transferFailed("x")))
        XCTAssertTrue(ResumableTransfer.worthRetrying(RemoteFileSystemError.timeout))
        XCTAssertTrue(ResumableTransfer.worthRetrying(RemoteFileSystemError.notConnected))
        XCTAssertFalse(ResumableTransfer.worthRetrying(RemoteFileSystemError.transferCancelled))
    }

    /// A missing file and a refused permission do not heal by asking twice.
    func test_worthRetrying_hopelessFailuresAreNotRepeated() {
        XCTAssertFalse(ResumableTransfer.worthRetrying(RemoteFileSystemError.pathNotFound("/a")))
        XCTAssertFalse(ResumableTransfer.worthRetrying(RemoteFileSystemError.permissionDenied("/a")))
        XCTAssertFalse(ResumableTransfer.worthRetrying(RemoteFileSystemError.authenticationFailed("no")))
    }

    // MARK: - The run itself

    /// Records what the runner did, since the closures are called from an async context.
    private final class Run {
        var offsets: [Int64] = []
        var discards = 0
        var pauses: [TimeInterval] = []
        var announcements: [String?] = []
        var revives = 0
        var probes = 0
        var sizeOnDisk: Int64 = 0
        /// What the probe answers, per call; empty = always "still down".
        var probeAnswers: [Bool] = []

        /// The whole wait, however many ticks it was counted down in.
        var waited: TimeInterval { pauses.reduce(0, +) }
    }

    private func run(_ log: Run, total: Int64 = 1000, canResume: Bool = true,
                     attempts: Int = ResumableTransfer.attempts,
                     cancelled: @escaping () -> Bool = { false },
                     transfer: @escaping (Int64) async throws -> Void) async throws {
        try await ResumableTransfer.run(
            totalSize: total, canResume: canResume, attempts: attempts,
            sizeSoFar: { log.sizeOnDisk },
            discard: { log.discards += 1; log.sizeOnDisk = 0 },
            isCancelled: cancelled,
            pausing: { log.pauses.append($0) },     // no real waiting in a test
            announce: { log.announcements.append($0) },
            linkIsBack: {
                log.probes += 1
                return log.probes <= log.probeAnswers.count ? log.probeAnswers[log.probes - 1] : false
            },
            revive: { log.revives += 1 },
            transfer: { offset in
                log.offsets.append(offset)
                try await transfer(offset)
            }
        )
    }

    func test_run_cleanTransfer_startsAtZeroAndStops() async throws {
        let log = Run()
        try await run(log) { _ in }
        XCTAssertEqual(log.offsets, [0])
        XCTAssertEqual(log.waited, 0)
        XCTAssertEqual(log.revives, 0, "a clean transfer never tears its link down")
    }

    func test_run_alreadyComplete_doesNotTransferAtAll() async throws {
        let log = Run()
        log.sizeOnDisk = 1000
        try await run(log) { _ in XCTFail("nothing was left to transfer") }
        XCTAssertEqual(log.offsets, [])
    }

    /// The link drops after 400 bytes; the second attempt picks up exactly there.
    func test_run_brokenLink_continuesFromWhatArrived() async throws {
        let log = Run()
        var failed = false
        try await run(log) { _ in
            if !failed {
                failed = true
                log.sizeOnDisk = 400          // what made it across before the break
                throw RemoteFileSystemError.transferFailed("link went away")
            }
        }
        XCTAssertEqual(log.offsets, [0, 400])
        XCTAssertEqual(log.waited, 5)
        // Nothing was ever thrown away: the 400 bytes are the whole point.
        XCTAssertEqual(log.discards, 0)
        // The link is rebuilt from scratch before the second try — never before the first.
        // Trusting an "am I connected" flag here is what once made a restored network
        // change nothing: the core knew the socket was dead while the wrapper said fine.
        XCTAssertEqual(log.revives, 1)
    }

    /// Three tries in all, then the failure is the caller's to see.
    func test_run_givesUpAfterThreeTries() async throws {
        let log = Run()
        do {
            try await run(log) { _ in throw RemoteFileSystemError.transferFailed("dead") }
            XCTFail("a dead link must not be reported as success")
        } catch {
            XCTAssertEqual(log.offsets.count, 3)
            XCTAssertEqual(log.waited, 20)  // 5 + 15: waits come between tries, not after the last
        }
    }

    /// Cancel is the person's decision, not a failure of the line — nothing is retried.
    func test_run_cancelStopsImmediately() async throws {
        let log = Run()
        do {
            try await run(log, cancelled: { true }) { _ in
                throw RemoteFileSystemError.transferCancelled
            }
            XCTFail("a cancelled transfer must not look finished")
        } catch {
            XCTAssertEqual(log.offsets.count, 1)
            XCTAssertEqual(log.waited, 0)
        }
    }

    /// A server that cannot continue: what we hold is thrown away and the next try starts
    /// from zero instead of asking the same impossible question again.
    func test_run_serverRefusesToContinue_startsOverFromZero() async throws {
        let log = Run()
        log.sizeOnDisk = 400
        var refusedOnce = false
        try await run(log) { offset in
            if !refusedOnce {
                refusedOnce = true
                XCTAssertEqual(offset, 400)
                throw RemoteFileSystemError.resumeRefused("REST not understood")
            }
            XCTAssertEqual(offset, 0)
        }
        XCTAssertEqual(log.offsets, [400, 0])
        XCTAssertEqual(log.discards, 1)
    }

    /// The wait is counted down OUT LOUD: a silent five-second gap in a progress window is
    /// indistinguishable from a hang, and then it goes quiet again once bytes move.
    func test_run_theWaitIsSpokenAloudAndThenCleared() async throws {
        let log = Run()
        var failed = false
        try await run(log) { _ in
            if !failed {
                failed = true
                log.sizeOnDisk = 400
                throw RemoteFileSystemError.transferFailed("link went away")
            }
        }
        let spoken = log.announcements.compactMap { $0 }
        XCTAssertEqual(spoken.count, 6, "five seconds counted down, then the reconnect line")
        XCTAssertNotEqual(spoken[0], spoken[1], "the countdown must actually count")
        guard let lastWord = log.announcements.last else {
            return XCTFail("a silent wait is exactly what this must never be")
        }
        XCTAssertNil(lastWord, "the line is cleared once the transfer gets going again")
    }

    /// The pauses are a ceiling for a dead line, not a sentence: the moment the server
    /// answers the knock, the rest of the wait is skipped and the transfer retries NOW.
    func test_run_answeredKnockCutsTheWaitShort() async throws {
        let log = Run()
        log.probeAnswers = [true]          // the server answers the very first knock
        var failed = false
        try await run(log) { _ in
            if !failed {
                failed = true
                log.sizeOnDisk = 400
                throw RemoteFileSystemError.transferFailed("link went away")
            }
        }
        XCTAssertEqual(log.offsets, [0, 400])
        XCTAssertEqual(log.waited, 1, "one tick, not the whole five-second pause")
        XCTAssertEqual(log.revives, 1, "the link is still rebuilt before the retry")
    }

    /// A hopeless failure ends the transfer at once instead of burning the whole budget.
    func test_run_missingFileIsNotRetried() async throws {
        let log = Run()
        do {
            try await run(log) { _ in throw RemoteFileSystemError.pathNotFound("/gone") }
            XCTFail("a missing file must not be reported as success")
        } catch {
            XCTAssertEqual(log.offsets.count, 1)
        }
    }

    // MARK: - Telling the three endings apart

    func test_fromTransfer_recognisesTheServerRefusingToContinue() {
        let refusal = NSError(domain: "com.fcxl.network",
                              code: CoreErrorCode.notSupported.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: "Server refused to continue"])
        guard case .resumeRefused = RemoteFileSystemError.fromTransfer(refusal) else {
            return XCTFail("a refusal to continue must not look like a broken link")
        }
    }

    func test_fromTransfer_recognisesCancelAndPlainFailure() {
        let cancel = NSError(domain: "com.fcxl.network", code: CoreErrorCode.cancelled.rawValue,
                             userInfo: [NSLocalizedDescriptionKey: "Cancelled"])
        guard case .transferCancelled = RemoteFileSystemError.fromTransfer(cancel) else {
            return XCTFail("a cancel must stay a cancel")
        }

        let broken = NSError(domain: "com.fcxl.network",
                             code: CoreErrorCode.networkError.rawValue,
                             userInfo: [NSLocalizedDescriptionKey: "Connection reset"])
        guard case .transferFailed = RemoteFileSystemError.fromTransfer(broken) else {
            return XCTFail("a broken link must stay retriable")
        }
    }

    /// A number from someone else's domain means something entirely different.
    func test_coreErrorCode_ignoresForeignDomains() {
        let foreign = NSError(domain: "NSPOSIXErrorDomain", code: 6, userInfo: nil)
        XCTAssertNil(CoreErrorCode.of(foreign))
        let ours = NSError(domain: "com.fcxl.error", code: 6, userInfo: nil)
        XCTAssertEqual(CoreErrorCode.of(ours), .notSupported)
    }

    // MARK: - The `.part` twin

    func test_partPath_sitsBesideTheRealName() {
        XCTAssertEqual(ResumableTransfer.partPath(for: "/tmp/report.pdf"), "/tmp/report.pdf.part")
    }

    func test_sizeOnDisk_missingFileIsZeroNotAnError() throws {
        XCTAssertEqual(ResumableTransfer.sizeOnDisk("/tmp/there-is-no-such-file-here.part"), 0)

        let path = NSTemporaryDirectory() + "fcxl-part-test-\(UUID().uuidString)"
        try Data(count: 321).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(ResumableTransfer.sizeOnDisk(path), 321)
    }
}
