import AppKit
import Carbon
import XCTest

@testable import TotumComXLApp

/// The trackpad's deep press: telling whether this Mac can feel one, and turning the stream of
/// pressure events into a single command.
final class ForceTouchTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: ForceTouchSupport.actionKey)
        super.tearDown()
    }

    /// The answer comes from the system, so it cannot be asserted outright — but it must be
    /// CONSISTENT: a usable device is one that can measure pressure and has not been switched
    /// off, and "available" means exactly that such a device exists.
    func testAvailabilityAgreesWithTheDevicesItIsBuiltFrom() {
        let devices = ForceTouchSupport.devices()
        let usable = devices.contains { $0.forceSupported && !$0.forceSuppressed }

        XCTAssertEqual(ForceTouchSupport.isAvailable, usable)
        for device in devices where device.isUsable {
            XCTAssertTrue(device.forceSupported)
            XCTAssertFalse(device.forceSuppressed)
        }
    }

    /// Hardware that can do it but was switched off is worth telling apart from hardware that
    /// cannot — the two need different words in the settings page.
    func testSuppressedIsNotTheSameAsUnsupported() {
        if ForceTouchSupport.isAvailable {
            XCTAssertFalse(ForceTouchSupport.isSuppressedBySystem,
                           "a usable trackpad cannot be suppressed at the same time")
        }
    }

    /// Without a trackpad that can feel it, the action is off whatever is stored — the setting
    /// must never claim a behaviour the hardware cannot deliver.
    func testTheActionIsOffWhenNoTrackpadCanFeelIt() {
        UserDefaults.standard.set(ForceTouchSupport.Action.open.rawValue,
                                  forKey: ForceTouchSupport.actionKey)
        if ForceTouchSupport.isAvailable {
            XCTAssertEqual(ForceTouchSupport.action, .open)
        } else {
            XCTAssertEqual(ForceTouchSupport.action, .off)
        }
    }

    func testAnUnknownStoredActionFallsBackToOpen() throws {
        try XCTSkipUnless(ForceTouchSupport.isAvailable, "no pressure-sensing trackpad here")
        UserDefaults.standard.set("nonsense", forKey: ForceTouchSupport.actionKey)
        XCTAssertEqual(ForceTouchSupport.action, .open)
    }

    // MARK: - One press, one command

    /// A pressure event arrives as a stream while the finger stays down. Acting on each one
    /// would open the folder again and again — only the CROSSING into stage 2 is the command.
    func testOnlyTheCrossingCounts() {
        var detector = DeepPressDetector()
        XCTAssertFalse(detector.crossedIntoDeepPress(FakePressure(stage: 0)))
        XCTAssertFalse(detector.crossedIntoDeepPress(FakePressure(stage: 1)))
        XCTAssertTrue(detector.crossedIntoDeepPress(FakePressure(stage: 2)),
                      "the press past the second detent")
        XCTAssertFalse(detector.crossedIntoDeepPress(FakePressure(stage: 2)),
                       "…and not again while the finger stays there")
    }

    /// Letting go and pressing again is a second command.
    func testPressingAgainCountsAgain() {
        var detector = DeepPressDetector()
        _ = detector.crossedIntoDeepPress(FakePressure(stage: 2))
        XCTAssertFalse(detector.crossedIntoDeepPress(FakePressure(stage: 0)))
        XCTAssertTrue(detector.crossedIntoDeepPress(FakePressure(stage: 2)))
    }

    /// An ordinary click never reaches the second detent, and must never be taken for one.
    func testAnOrdinaryClickIsNotADeepPress() {
        var detector = DeepPressDetector()
        for stage in [0, 1, 1, 0] {
            XCTAssertFalse(detector.crossedIntoDeepPress(FakePressure(stage: stage)))
        }
    }
}

/// An NSEvent cannot be built with a chosen stage, so the detector is fed a stand-in.
private final class FakePressure: NSEvent {
    private let fakeStage: Int
    init(stage: Int) {
        self.fakeStage = stage
        super.init()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
    override var stage: Int { fakeStage }
}

/// The probe behind "these F-keys are intercepted": Carbon's registration is the one honest
/// witness of a global hotkey held by another process.
final class FKeyAvailabilityTests: XCTestCase {

    /// A key nobody holds probes as free — and the probe itself lets go: running it twice must
    /// answer the same both times, or the probe would be the thief it looks for.
    func testTheProbeDoesNotKeepWhatItProbes() {
        let first = FKeyAvailability.takenKeys()
        let second = FKeyAvailability.takenKeys()
        XCTAssertEqual(first, second)
    }

    /// A key this test grabs must show up by name.
    func testAKeyHeldElsewhereIsReportedByName() throws {
        var ref: EventHotKeyRef?
        // F9 (101) — grabbed exclusively for the duration of this test.
        let status = RegisterEventHotKey(101, 0,
                                         EventHotKeyID(signature: OSType(0x54455354), id: 101),
                                         GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else {
            throw XCTSkip("F9 is already held by another program on this Mac")
        }
        defer { UnregisterEventHotKey(ref) }

        XCTAssertTrue(FKeyAvailability.takenKeys().contains("F9"),
                      "the grabbed key must be reported")
    }
}
