import Foundation
import Network

/// What makes one file survive a bad line: it lands in a `.part` file and takes its real name
/// only when whole, and a broken link is picked up where it stopped instead of started over.
///
/// The rules live here, apart from the plumbing, because they are the part worth arguing
/// about — and the part that can be tested without a server on the other end. The service
/// hands in three closures (how much is already there, how to throw it away, how to transfer
/// from an offset) and gets back either a finished file or the error that stopped it.
enum ResumableTransfer {

    /// The name a half-finished file wears. Ordinary enough to see in a panel and to delete
    /// by hand, distinctive enough that nothing else claims it.
    static let partSuffix = ".part"

    /// Three tries in all — the first one plus two more. Enough for a Wi-Fi hiccup or a
    /// server that drops idle connections; not so many that a dead link keeps a queue busy
    /// for a minute before admitting defeat.
    static let attempts = 3

    /// Growing pauses: a link that failed twice in a row rarely comes back within a second,
    /// and a person who noticed the Wi-Fi died needs time to do something about it.
    static func pause(afterAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case 1: return 5
        case 2: return 15
        default: return 30
        }
    }

    /// How long the bytes may stand still before the person is told. The link is not yet
    /// declared dead — the transport waits out its own silence watchdog first — but a frozen
    /// bar with a shrinking "time left" underneath is a lie, and this is what replaces it.
    static let stallPatience: TimeInterval = 5

    /// Watches the byte counter for a transfer that has stopped moving without failing.
    ///
    /// Lives here rather than in the progress dialog because only the transfer knows what
    /// "not moving" means: the callback keeps firing once a second with the same number, and
    /// nothing else in the app can tell that apart from a slow file.
    final class StallWatch: @unchecked Sendable {
        enum Word { case nothing, say(String), quiet }

        private let lock = NSLock()
        private var lastBytes: Int64 = -1
        private var lastMoved = Date()
        private var speaking = false

        /// Call from the progress callback, on whatever thread it arrives.
        func note(bytes: Int64, now: Date = Date()) -> Word {
            lock.lock()
            defer { lock.unlock() }

            if bytes != lastBytes {
                lastBytes = bytes
                lastMoved = now
                guard speaking else { return .nothing }
                speaking = false
                return .quiet            // moving again — take the line down
            }
            guard !speaking, now.timeIntervalSince(lastMoved) >= stallPatience else {
                return .nothing
            }
            speaking = true
            return .say(L("transfer.trouble.stalled"))
        }
    }

    /// What to do with whatever is already at the destination.
    enum Decision: Equatable {
        /// Nothing usable there — the transfer begins at zero and the leftovers go.
        case startOver
        /// Continue from this many bytes.
        case resume(from: Int64)
        /// Every byte is already across; only the rename is left. This is the crash that
        /// happens between the last byte and the rename — rare, and cheap to honour.
        case alreadyComplete

        var offset: Int64 {
            if case .resume(let from) = self { return from }
            return 0
        }
    }

    /// - Parameters:
    ///   - partSize: bytes already at the destination, zero when there is nothing.
    ///   - totalSize: the size of the whole file, or zero when the far end would not say.
    ///   - canResume: whether this backend can continue at all.
    static func decide(partSize: Int64, totalSize: Int64, canResume: Bool) -> Decision {
        guard canResume, partSize > 0 else { return .startOver }
        guard totalSize > 0 else {
            // Without a known size there is no way to tell a leftover from a finished file,
            // and continuing blindly could splice two different versions together.
            return .startOver
        }
        if partSize > totalSize { return .startOver }   // the far side changed under us
        if partSize == totalSize { return .alreadyComplete }
        return .resume(from: partSize)
    }

    /// Whether the same transfer is worth trying again. A cancel is not a failure; a missing
    /// file or a refused permission will not become available by asking twice. Broken links,
    /// timeouts and dead connections are exactly what retrying is for.
    static func worthRetrying(_ error: Error) -> Bool {
        guard let remote = error as? RemoteFileSystemError else { return false }
        switch remote {
        case .transferCancelled, .pathNotFound, .permissionDenied, .authenticationFailed,
             .loginRefused:
            return false
        case .notConnected, .connectionFailed, .timeout, .transferFailed,
             .operationFailed, .protocolError, .resumeRefused:
            return true
        }
    }

    static func isResumeRefused(_ error: Error) -> Bool {
        guard let remote = error as? RemoteFileSystemError else { return false }
        if case .resumeRefused = remote { return true }
        return false
    }

    /// Carry one file across, continuing and retrying as the rules above say.
    ///
    /// - Parameters:
    ///   - sizeSoFar: how many bytes are at the destination right now — asked again before
    ///     every attempt, because the last one may have moved the mark forward.
    ///   - discard: throw away what is there (used when continuing is impossible).
    ///   - isCancelled: the person pressed Cancel; no retry follows.
    ///   - transfer: do the transfer from the given offset.
    ///   - announce: what to tell the person while the transfer is in trouble — the link is
    ///     gone and this is waiting rather than working. Nil means the trouble is over.
    ///     A silent gap of five seconds is indistinguishable from a hang.
    ///   - linkIsBack: one quick knock on the server's door, asked on every tick of the
    ///     countdown. The moment it answers, the rest of the wait is pointless and is
    ///     skipped — the pauses are a ceiling for a dead line, not a sentence to sit out.
    ///   - revive: rebuild the link from scratch, called between attempts and never before
    ///     the first. It must not trust any "am I connected" flag: after a break the core
    ///     knows the socket is dead while the wrapper above it still says connected, and a
    ///     revive that believes the wrapper does nothing — which is exactly how a restored
    ///     network changed nothing.
    static func run(totalSize: Int64,
                    canResume: Bool,
                    attempts: Int = ResumableTransfer.attempts,
                    sizeSoFar: () async -> Int64,
                    discard: () async -> Void,
                    isCancelled: () -> Bool = { false },
                    pausing: (TimeInterval) async -> Void = ResumableTransfer.sleep,
                    announce: (String?) async -> Void = { _ in },
                    linkIsBack: @escaping () async -> Bool = { false },
                    revive: () async -> Void = {},
                    transfer: (Int64) async throws -> Void) async throws {
        var attempt = 0
        var mayResume = canResume

        while true {
            let partSize = await sizeSoFar()
            let decision = decide(partSize: partSize, totalSize: totalSize, canResume: mayResume)
            if decision == .alreadyComplete { return }
            // Nothing there means nothing to throw away — and on an upload "throw away" is a
            // round trip to the server, not a line of local bookkeeping.
            if decision == .startOver, partSize > 0 { await discard() }

            do {
                try await transfer(decision.offset)
                await announce(nil)
                return
            } catch {
                // A cancel is the person's decision, not a failure of the link.
                if isCancelled() { await announce(nil); throw error }

                attempt += 1
                let refused = isResumeRefused(error)
                if refused {
                    // This server cannot continue anything. Drop what we have and let the
                    // next pass start from zero — asking it again the same way never works.
                    mayResume = false
                    await discard()
                }
                guard worthRetrying(error), attempt < attempts else {
                    await announce(nil)
                    throw error
                }

                // Count the wait down out loud. A silent five-second gap in a progress window
                // is indistinguishable from a hang, and the person deserves to know that the
                // link went away rather than that the program did.
                var secondsLeft = Int(pause(afterAttempt: attempt).rounded())
                while secondsLeft > 0 {
                    await announce(L("transfer.trouble.waiting", secondsLeft,
                                     attempt + 1, attempts))
                    // The knock OVERLAPS the second instead of following it: knocked after
                    // slept, every tick quietly stretched to two or three seconds and the
                    // countdown on screen lied about its own speed.
                    async let knock = linkIsBack()
                    await pausing(1)
                    let answered = await knock
                    if isCancelled() { await announce(nil); throw error }
                    // The server answered — the rest of this wait would be sat out for
                    // nothing. This is what makes a returned Wi-Fi pick up in a couple of
                    // seconds instead of after the full pause.
                    if answered { break }
                    secondsLeft -= 1
                }
                await announce(refused
                    ? L("transfer.trouble.restarting", attempt + 1, attempts)
                    : L("transfer.trouble.reconnecting", attempt + 1, attempts))
                await revive()
            }
        }
    }

    /// One quick knock on the server's door: does ANYTHING answer at host:port?
    ///
    /// TCP only, no login — the question during a countdown is "is the network back", and
    /// for that a completed handshake is the whole answer. Fails fast while there is no
    /// route (Wi-Fi off) and within `timeout` against a silent far end. The budget is one
    /// second because the knock rides ALONGSIDE a one-second tick: a longer knock would
    /// stretch the tick, and the countdown must not lie about its own speed.
    static func serverAnswers(host: String, port: UInt16,
                              timeout: TimeInterval = 1) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let lock = NSLock()
            var finished = false
            let finish: (Bool) -> Void = { answer in
                lock.lock()
                let first = !finished
                finished = true
                lock.unlock()
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: answer)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                // .waiting is Network.framework for "no route right now" — that IS the
                // answer, and sitting in it until the timeout would slow every tick.
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }

    static func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - The `.part` file itself

    static func partPath(for destination: String) -> String { destination + partSuffix }

    /// Size of a file that may not exist — zero then, which is exactly what the rules want.
    static func sizeOnDisk(_ path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
