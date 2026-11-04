import AppKit
import XCTest

@testable import TotumComXLApp

/// Where the note about Telegram's stuck panel goes.
@MainActor
final class SharePanelHintTests: XCTestCase {

    private let note = NSSize(width: 260, height: 60)
    private let screen = NSRect(x: 0, y: 0, width: 1728, height: 1000)

    // MARK: - Finding the panel inside the window

    /// The framework's window is spread over the whole screen; the panel is the remote view
    /// drawn inside it. Going by the window put the note in the corner of the screen, nowhere
    /// near the thing it was explaining.
    func testThePanelIsTheViewInsideTheWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1728, height: 1000),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let content = NSView(frame: window.contentLayoutRect)
        let remote = FakeNSRemoteView(frame: NSRect(x: 600, y: 300, width: 460, height: 520))
        content.addSubview(remote)
        window.contentView = content

        let rect = SharePanelHint.panelRect(of: window)

        XCTAssertEqual(rect.size, remote.frame.size)
        XCTAssertNotEqual(rect.size, window.frame.size)
    }

    /// A view as large as the window is the window, not the panel — that is the case that used
    /// to send the note to the corner.
    func testAFullSizeViewIsNotThePanel() {
        let size = NSSize(width: 800, height: 600)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.addSubview(FakeNSRemoteView(frame: NSRect(origin: .zero, size: size)))
        XCTAssertNil(SharePanelHint.remoteView(in: content, windowSize: size))
    }

    /// With nothing recognisable inside, the window itself is NOT the answer: the framework's
    /// window covers the whole screen, and going by it is exactly what parked the note in the
    /// corner.
    ///
    /// Проверяется ровно это, без размера: дальше по цепочке идут ОБЩЕСИСТЕМНЫЕ списки окон,
    /// и ответ там зависит от того, что открыто на экране в эту секунду. Тест, который это
    /// проверял, падал через раз — на живой машине с запущенной программой.
    func testWithNothingToGoOnTheWindowItselfIsNotTheAnswer() {
        let window = NSWindow(contentRect: NSRect(x: 10, y: 20, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: true)

        XCTAssertNotEqual(SharePanelHint.panelRect(of: window), window.frame)
    }

    /// А место «по умолчанию» — середина экрана — проверяется само по себе.
    func testTheAssumedPlaceIsTheMiddleOfTheScreen() {
        let rect = SharePanelHint.assumedPanelRect(on: screen)
        XCTAssertEqual(rect.size, NSSize(width: 440, height: 560))
        XCTAssertEqual(rect.midX, screen.midX, accuracy: 0.5)
        XCTAssertEqual(rect.midY, screen.midY, accuracy: 0.5)
    }

    /// The share puts up three windows and only one of them is the size of the panel — the blur
    /// behind it. The other two cover the screen: the one the extension paints into, and the
    /// dimming. Taking a full-screen one is what left the note in the corner.
    func testThePanelIsTheSmallOneAmongTheFrameworksWindows() {
        let full = NSRect(x: 0, y: 0, width: 1728, height: 1079)
        let blur = NSRect(x: 700, y: 250, width: 430, height: 560)

        let found = SharePanelHint.panelRect(
            amongFrameworkWindows: [("SHKRemoteWindow", full), ("SHKDimAndShadowWindow", full),
                                    ("SHKBlurWindow", blur)],
            screen: full)

        XCTAssertEqual(found, blur)
    }

    /// When they all cover the screen there is nothing to pick, and the caller goes on looking
    /// rather than settling for a wrong answer.
    func testNoneOfThemIsThePanelWhenTheyAllCoverTheScreen() {
        let full = NSRect(x: 0, y: 0, width: 1728, height: 1079)
        XCTAssertNil(SharePanelHint.panelRect(
            amongFrameworkWindows: [("SHKRemoteWindow", full), ("SHKDimAndShadowWindow", full)],
            screen: full))
    }

    /// The blur is the one the framework sizes to the panel — it wins even over a smaller
    /// window that happens to be there.
    func testTheBlurIsTakenByName() {
        let screen = NSRect(x: 0, y: 0, width: 1728, height: 1079)
        let blur = NSRect(x: 700, y: 250, width: 430, height: 560)
        let smaller = NSRect(x: 10, y: 10, width: 200, height: 200)

        XCTAssertEqual(SharePanelHint.panelRect(
            amongFrameworkWindows: [("SHKSomething", smaller), ("SHKBlurWindow", blur)],
            screen: screen), blur)
    }

    /// Shadows and slivers are not panels either.
    func testSliversAreNotThePanel() {
        let screen = NSRect(x: 0, y: 0, width: 1728, height: 1079)
        let sliver = NSRect(x: 10, y: 10, width: 40, height: 900)
        let panel = NSRect(x: 700, y: 250, width: 430, height: 560)

        XCTAssertEqual(SharePanelHint.panelRect(
            amongFrameworkWindows: [("SHKShadow", sliver), ("SHKRemoteWindow", panel)],
            screen: screen), panel)
    }

    // MARK: - Standing beside it

    func testTheNoteStandsToTheRightOfThePanel() {
        let panel = NSRect(x: 600, y: 300, width: 460, height: 520)
        let origin = SharePanelHint.noteOrigin(noteSize: note, panelRect: panel, screen: screen)

        XCTAssertEqual(origin.x, panel.maxX + 12, "hard against the panel, not somewhere near")
        XCTAssertEqual(origin.y + note.height / 2, panel.midY, "level with the panel's middle")
    }

    /// A panel against the right edge leaves no room there; the note moves to its other side
    /// rather than hanging off the screen.
    func testItMovesToTheLeftWhenTheRightIsFull() {
        let panel = NSRect(x: 1300, y: 300, width: 400, height: 520)
        let origin = SharePanelHint.noteOrigin(noteSize: note, panelRect: panel, screen: screen)

        XCTAssertEqual(origin.x, panel.minX - 12 - note.width)
    }

    /// And when neither side has room, it still stays on screen.
    func testItNeverLeavesTheScreen() {
        let panel = NSRect(x: 0, y: 0, width: 1728, height: 1000)
        let origin = SharePanelHint.noteOrigin(noteSize: note, panelRect: panel, screen: screen)

        XCTAssertGreaterThanOrEqual(origin.x, screen.minX)
        XCTAssertLessThanOrEqual(origin.x + note.width, screen.maxX)
        XCTAssertGreaterThanOrEqual(origin.y, screen.minY)
        XCTAssertLessThanOrEqual(origin.y + note.height, screen.maxY)
    }

    /// A panel that runs off the top of the screen must not take the note with it.
    func testTheNoteStaysOnScreenVertically() {
        let panel = NSRect(x: 400, y: 800, width: 400, height: 1600)
        let origin = SharePanelHint.noteOrigin(noteSize: note, panelRect: panel, screen: screen)

        XCTAssertLessThanOrEqual(origin.y + note.height, screen.maxY)
        XCTAssertGreaterThanOrEqual(origin.y, screen.minY)
    }

    /// What counts as a panel at all: a small thing in the middle of the screen. The framework
    /// answers "the whole screen" while the panel is coming in, and that answer, taken at face
    /// value, is what kept the note in the corner.
    func testTheWholeScreenIsNotAPanel() {
        let screen = NSRect(x: 0, y: 0, width: 1728, height: 1079)

        XCTAssertFalse(SharePanelHint.looksLikeAPanel(screen, inside: screen))
        XCTAssertFalse(SharePanelHint.looksLikeAPanel(
            NSRect(x: 0, y: 0, width: 1720, height: 1070), inside: screen), "nearly all of it")
        XCTAssertFalse(SharePanelHint.looksLikeAPanel(
            NSRect(x: 0, y: 0, width: 40, height: 40), inside: screen), "a speck")
        XCTAssertTrue(SharePanelHint.looksLikeAPanel(
            NSRect(x: 640, y: 260, width: 430, height: 560), inside: screen))
    }
}

/// A stand-in for the view the extension draws into — the real one is an NSRemoteView.
private final class FakeNSRemoteView: NSView {}

/// Finding the panel through the window server: it is drawn by an extension in its own process,
/// and that process's window IS the panel — while the window hosting it, ours, covers the whole
/// screen and says nothing about where the panel sits.
@MainActor
final class SharePanelFromWindowServerTests: XCTestCase {

    private func entry(owner: String, pid: pid_t, rect: CGRect) -> [String: Any] {
        [kCGWindowOwnerName as String: owner,
         kCGWindowOwnerPID as String: pid,
         kCGWindowBounds as String: rect.dictionaryRepresentation as! [String: Any]]
    }

    /// The window server measures down from the top of the primary screen; AppKit up from its
    /// bottom. Getting this backwards puts the note as far from the panel as the panel is from
    /// the middle of the screen.
    func testTheWindowServersCoordinatesAreTurnedOver() {
        let flipped = SharePanelHint.flipFromWindowServer(
            CGRect(x: 100, y: 60, width: 400, height: 500), primaryTop: 1000)

        XCTAssertEqual(flipped, NSRect(x: 100, y: 440, width: 400, height: 500))
    }

    func testTheShareExtensionsWindowIsTheOneTaken() {
        let list = [entry(owner: "Finder", pid: 1, rect: CGRect(x: 0, y: 0, width: 900, height: 700)),
                    entry(owner: "TelegramShare", pid: 2,
                          rect: CGRect(x: 600, y: 200, width: 420, height: 540))]

        let rect = SharePanelHint.panelRect(inWindowList: list, ourProcess: 99, primaryTop: 1000)

        XCTAssertEqual(rect, NSRect(x: 600, y: 260, width: 420, height: 540))
    }

    /// Our own windows are in that list too, and the biggest of them would be a fine wrong
    /// answer.
    func testOurOwnWindowsAreSkipped() {
        let list = [entry(owner: "TotumComXL", pid: 42,
                          rect: CGRect(x: 0, y: 0, width: 1728, height: 1079))]
        XCTAssertNil(SharePanelHint.panelRect(inWindowList: list, ourProcess: 42, primaryTop: 1079))
    }

    /// A share extension puts small windows on screen as well — shadows, tooltips. The panel is
    /// the big one.
    func testTinyWindowsOfTheExtensionAreNotThePanel() {
        let list = [entry(owner: "TelegramShare", pid: 2,
                          rect: CGRect(x: 10, y: 10, width: 60, height: 40))]
        XCTAssertNil(SharePanelHint.panelRect(inWindowList: list, ourProcess: 99, primaryTop: 1000))
    }

    /// With no share extension on screen there is nothing to find, and the caller falls back to
    /// looking inside its own window.
    func testNothingIsFoundWhenNoPanelIsUp() {
        let list = [entry(owner: "Safari", pid: 7, rect: CGRect(x: 0, y: 0, width: 800, height: 600))]
        XCTAssertNil(SharePanelHint.panelRect(inWindowList: list, ourProcess: 99, primaryTop: 1000))
    }
}

/// Finding the panel when every window of the share covers the whole screen — which is what the
/// log showed: SHKRemoteWindow, SHKDimAndShadowWindow and SHKBlurWindow, all 1728×1079. The
/// panel is then drawn INSIDE them, and only the drawing says where.
@MainActor
final class SharePanelInsideAFullScreenWindowTests: XCTestCase {

    private func fullScreenWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1728, height: 1079),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1728, height: 1079))
        content.wantsLayer = true
        window.contentView = content
        return window
    }

    /// The layer that covers only part of the window is the panel.
    func testThePanelIsTheLayerThatCoversPartOfTheWindow() throws {
        let window = fullScreenWindow()
        let root = try XCTUnwrap(window.contentView?.layer)
        let backdrop = CALayer()
        backdrop.frame = window.contentView!.bounds       // the full-screen dimming
        let panel = CALayer()
        panel.frame = NSRect(x: 640, y: 260, width: 430, height: 560)
        root.addSublayer(backdrop)
        root.addSublayer(panel)

        let found = try XCTUnwrap(SharePanelHint.panelRectFromLayers(in: window))

        XCTAssertEqual(found, NSRect(x: 640, y: 260, width: 430, height: 560))
    }

    /// A panel holds rows, a search field, buttons — all of them layers, all of them smaller
    /// than it. The panel is the biggest of what could be one, never the smallest.
    func testThePanelWinsOverWhatIsDrawnInsideIt() throws {
        let window = fullScreenWindow()
        let root = try XCTUnwrap(window.contentView?.layer)
        let panel = CALayer()
        panel.frame = NSRect(x: 640, y: 260, width: 430, height: 560)
        let row = CALayer()
        row.frame = NSRect(x: 20, y: 40, width: 380, height: 200)
        panel.addSublayer(row)
        root.addSublayer(panel)

        XCTAssertEqual(try XCTUnwrap(SharePanelHint.panelRectFromLayers(in: window)),
                       NSRect(x: 640, y: 260, width: 430, height: 560))
    }

    /// A layer nested inside another is found too — the panel is not drawn at the top level.
    func testANestedLayerIsFound() throws {
        let window = fullScreenWindow()
        let root = try XCTUnwrap(window.contentView?.layer)
        let container = CALayer()
        container.frame = window.contentView!.bounds
        let panel = CALayer()
        panel.frame = NSRect(x: 500, y: 200, width: 400, height: 500)
        container.addSublayer(panel)
        root.addSublayer(container)

        XCTAssertEqual(try XCTUnwrap(SharePanelHint.panelRectFromLayers(in: window)),
                       NSRect(x: 500, y: 200, width: 400, height: 500))
    }

    /// Slivers and shadows are not the panel; nor is a window whose layers all cover it whole.
    func testNothingIsTakenFromLayersThatAreNotPanels() throws {
        let window = fullScreenWindow()
        let root = try XCTUnwrap(window.contentView?.layer)
        let sliver = CALayer()
        sliver.frame = NSRect(x: 0, y: 0, width: 1728, height: 40)
        root.addSublayer(sliver)

        XCTAssertNil(SharePanelHint.panelRectFromLayers(in: window))
    }

    /// And when nothing at all says where the panel is, the note stands beside the middle of the
    /// screen — where share panels are put — rather than in a corner.
    func testTheLastResortIsTheMiddleOfTheScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1728, height: 1079)
        let assumed = SharePanelHint.assumedPanelRect(on: screen)

        XCTAssertEqual(assumed.midX, screen.midX)
        XCTAssertEqual(assumed.midY, screen.midY)
        XCTAssertLessThan(assumed.width, screen.width / 2)
    }

    /// The note beside that assumed panel still lands in the middle of the screen, not at its
    /// edge — the whole point of the fallback.
    func testTheNoteThenStandsNearTheMiddle() {
        let screen = NSRect(x: 0, y: 0, width: 1728, height: 1079)
        let origin = SharePanelHint.noteOrigin(noteSize: NSSize(width: 260, height: 60),
                                               panelRect: SharePanelHint.assumedPanelRect(on: screen),
                                               screen: screen)

        XCTAssertGreaterThan(origin.x, screen.midX)
        XCTAssertLessThan(origin.x, screen.maxX - 200)
        XCTAssertEqual(origin.y + 30, screen.midY, accuracy: 1, "level with the middle")
    }
}
