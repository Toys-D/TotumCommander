import AppKit
import XCTest

@testable import TotumComXLApp

/// Clicking a file row must hand the keyboard to the list.
///
/// It did not, and nothing else did either: `onBecameActive` reaches `setActivePanel`, which
/// returns early for the panel that is ALREADY active, so `isActivePanel.didSet` never fires; and
/// the table refuses selection, so AppKit does not focus it on a click. Play a video in the
/// embedded viewer — the one preview you must click into — and focus stayed in the player. The
/// next arrow key found no owner, reached `noResponder:`, and macOS beeped with the cursor frozen.
@MainActor
final class PanelClickFocusTests: XCTestCase {

    private var window: NSWindow!
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-click-focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for name in ["один.txt", "два.txt", "три.txt", "четыре.txt"] {
            try "x".write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        // A programmatically created NSWindow releases itself on close while we still hold it —
        // that over-release is a crash, not a test failure.
        window?.orderOut(nil)
        window = nil
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        try super.tearDownWithError()
    }

    /// A panel in a real on-screen window, with its directory actually listed.
    private func makePanel() -> (PanelViewController, PanelViewModel) {
        let id = UUID().uuidString
        let vm = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: tmp.path,
            pathDefaultsKey: "panel.path.click.focus.\(id)",
            viewModeDefaultsKey: "panel.mode.click.focus.\(id)",
            showHiddenFiles: false)
        let tabsVM = PanelTabsViewModel(panelKey: "panel.tabs.click.focus.\(id)",
                                        initialPath: tmp.path)
        let vc = PanelViewController(viewModel: vm, tabsVM: tabsVM, side: .left)
        vc.loadViewIfNeeded()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(vc.view)
        vc.view.frame = window.contentView?.bounds ?? .zero
        window.makeKeyAndOrderFront(nil)
        // The panel the user clicks is by definition the active one — that is the whole premise:
        // the viewer covers the INACTIVE panel. handleKeyEvent refuses keys for an inactive panel.
        vc.isActivePanel = true
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))   // let the listing land
        return (vc, vm)
    }

    /// Stands in for the embedded viewer: a view OUTSIDE the panel that takes the keyboard, exactly
    /// as AVPlayerView and QLPreviewView do when the user clicks play.
    private func stealFocusFromOutsideThePanel() -> NSView {
        let thief = NSTextView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView?.addSubview(thief)
        window.makeFirstResponder(thief)
        return thief
    }

    // MARK: - The bug

    func testClickingAFileTakesTheKeyboardBackFromTheViewer() throws {
        let (vc, vm) = makePanel()
        try XCTSkipIf(vm.items.count < 3, "the listing did not arrive")

        let thief = stealFocusFromOutsideThePanel()
        XCTAssertTrue(window.firstResponder === thief, "precondition: focus is in the 'viewer'")

        // The one implementation of "user clicked a file row", the same one every view mode uses.
        vc.tableView.clickHandler?(1, [])

        XCTAssertTrue(window.firstResponder === vc.tableView,
                      "the click left the keyboard in the viewer — the next arrow key would beep")
    }

    /// The symptom the user actually reported: the cursor does not move.
    func testTheArrowKeyMovesTheCursorAfterAClick() throws {
        let (vc, vm) = makePanel()
        try XCTSkipIf(vm.items.count < 3, "the listing did not arrive")

        _ = stealFocusFromOutsideThePanel()
        vc.tableView.clickHandler?(1, [])
        let before = vm.cursorIndex

        let down = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125))
        let responder = try XCTUnwrap(window.firstResponder as? NSView)
        responder.keyDown(with: down)

        XCTAssertEqual(vm.cursorIndex, before + 1, "the cursor stayed put — this is the beep")
    }

    // MARK: - What must NOT lose focus

    /// The reclaim is conditional, and this pins the condition itself: focus already inside the
    /// panel is left alone. (It does NOT prove inline rename is safe — `handleRowClick` cancels a
    /// rename before reaching the reclaim, so that path is protected earlier and separately.)
    func testFocusAlreadyInsideThePanelIsLeftAlone() throws {
        let (vc, vm) = makePanel()
        try XCTSkipIf(vm.items.count < 3, "the listing did not arrive")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        vc.view.addSubview(field)
        window.makeFirstResponder(field)
        let editor = window.firstResponder      // the field's field editor, still inside the panel

        vc.reclaimListFocusIfLost()

        XCTAssertTrue(window.firstResponder === editor,
                      "focus inside the panel is the user's business, not ours to move")
    }

    /// Empty space below the last row is still a click in the list, and had the same gap.
    func testClickingBelowTheLastRowAlsoTakesTheKeyboardBack() throws {
        let (vc, vm) = makePanel()
        try XCTSkipIf(vm.items.count < 3, "the listing did not arrive")

        _ = stealFocusFromOutsideThePanel()
        vc.tableView.emptyAreaClickHandler?()

        XCTAssertTrue(window.firstResponder === vc.tableView)
    }

    /// The panel hidden behind the embedded viewer still has a frame and still sees clicks. It must
    /// never pull the keyboard out of the viewer that is covering it.
    func testAHiddenPanelNeverClaimsTheKeyboard() throws {
        let (vc, vm) = makePanel()
        try XCTSkipIf(vm.items.count < 3, "the listing did not arrive")

        let thief = stealFocusFromOutsideThePanel()
        vc.view.isHidden = true

        vc.reclaimListFocusIfLost()

        XCTAssertTrue(window.firstResponder === thief,
                      "a panel nobody can see must not take the keyboard")
    }
}
