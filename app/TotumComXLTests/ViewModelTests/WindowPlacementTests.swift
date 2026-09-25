import AppKit
import XCTest
@testable import TotumComXLApp

/// Главное окно при запуске — по центру экрана, всегда.
///
/// Жалоба: программа открывалась в левом нижнем углу. В настройках лежала рамка с
/// прошлого экрана — {{-38, -359}, {1728, 1079}}, начало за экраном, — и система
/// втискивала окно в угол. Место больше не запоминается, только размер.
final class WindowPlacementTests: XCTestCase {

    private let visible = NSRect(x: 0, y: 0, width: 2056, height: 1285)
    private let minimum = NSSize(width: 980, height: 640)

    func test_рамкаСПрошлогоЭкранаВстаётПоЦентру() {
        let saved = NSRect(x: -38, y: -359, width: 1728, height: 1079)
        let frame = MainWindowController.launchFrame(saved: saved, visible: visible, minimum: minimum)
        XCTAssertEqual(frame.size, saved.size, "размер остаётся свой")
        XCTAssertEqual(frame.midX, visible.midX)
        XCTAssertEqual(frame.midY, visible.midY, accuracy: 0.5)
        XCTAssertTrue(visible.contains(frame), "целиком на экране")
    }

    func test_окноВоВесьСтарыйЭкранУжимаетсяДо90Процентов() {
        let saved = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let frame = MainWindowController.launchFrame(saved: saved, visible: visible, minimum: minimum)
        XCTAssertEqual(frame.width, floor(2056 * 0.9))
        XCTAssertEqual(frame.height, floor(1285 * 0.9))
        XCTAssertEqual(frame.midX, visible.midX)
        XCTAssertTrue(visible.contains(frame))
    }

    func test_слишкомМаленькаяРамкаРастётДоМинимума() {
        let saved = NSRect(x: 10, y: 10, width: 300, height: 200)
        let frame = MainWindowController.launchFrame(saved: saved, visible: visible, minimum: minimum)
        XCTAssertEqual(frame.size, minimum)
        XCTAssertEqual(frame.midX, visible.midX)
    }

    func test_наМаленькомЭкранеНеБольшеЭкрана() {
        let small = NSRect(x: 0, y: 0, width: 1024, height: 700)
        let frame = MainWindowController.launchFrame(saved: NSRect(x: 0, y: 0, width: 1728, height: 1079),
                                                     visible: small, minimum: minimum)
        XCTAssertLessThanOrEqual(frame.width, small.width)
        XCTAssertLessThanOrEqual(frame.height, small.height)
        XCTAssertTrue(small.contains(frame))
    }

    @MainActor
    func test_настоящееОкноВстаётПоЦентруСвоегоЭкрана() throws {
        let window = NSWindow(contentRect: NSRect(x: -38, y: -359, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.minSize = minimum
        MainWindowController.placeAtLaunch(window)
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        XCTAssertEqual(window.frame.midX, screen.visibleFrame.midX, accuracy: 1)
        XCTAssertEqual(window.frame.midY, screen.visibleFrame.midY, accuracy: 1)
        XCTAssertNil(UserDefaults.standard.string(forKey: "windowFrame"), "старая запись убрана")
    }
}
