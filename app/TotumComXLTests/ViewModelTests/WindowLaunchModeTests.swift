import AppKit
import XCTest

@testable import TotumComXLApp

/// Как открывается окно при запуске: как оставили, обычным или развёрнутым на весь экран —
/// окном, как по двойному щелчку по заголовку, а не полноэкранным режимом macOS.
final class WindowLaunchModeTests: XCTestCase {

    private var saved: String?
    private let visible = NSRect(x: 0, y: 25, width: 1920, height: 1055)
    private let minimum = NSSize(width: 980, height: 640)

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.string(forKey: WindowLaunchMode.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(saved, forKey: WindowLaunchMode.defaultsKey)
        super.tearDown()
    }

    func test_поУмолчаниюКакВПрошлыйРаз() {
        UserDefaults.standard.removeObject(forKey: WindowLaunchMode.defaultsKey)
        XCTAssertEqual(WindowLaunchMode.chosen, .asLeft, "программа всегда открывалась как оставили")
        UserDefaults.standard.set("чепуха", forKey: WindowLaunchMode.defaultsKey)
        XCTAssertEqual(WindowLaunchMode.chosen, .asLeft)
        UserDefaults.standard.set(WindowLaunchMode.maximized.rawValue, forKey: WindowLaunchMode.defaultsKey)
        XCTAssertEqual(WindowLaunchMode.chosen, .maximized)
    }

    func test_развёрнутоеЗанимаетВесьЭкранОкном() {
        let small = NSRect(x: 300, y: 200, width: 1200, height: 800)
        XCTAssertEqual(WindowLaunchMode.maximized.frame(current: small, visible: visible, minimum: minimum), visible,
                       "рабочая область экрана: под строкой меню, над Dock")
    }

    func test_какВПрошлыйРазНеТрогаетОкно() {
        let left = NSRect(x: 300, y: 200, width: 1200, height: 800)
        XCTAssertEqual(WindowLaunchMode.asLeft.frame(current: left, visible: visible, minimum: minimum), left)
        XCTAssertEqual(WindowLaunchMode.asLeft.frame(current: visible, visible: visible, minimum: minimum), visible,
                       "развёрнутое так и остаётся развёрнутым — кадр помнит система")
    }

    func test_обычноеСжимаетТолькоРазвёрнутое() {
        let plain = NSRect(x: 300, y: 200, width: 1200, height: 800)
        XCTAssertEqual(WindowLaunchMode.normal.frame(current: plain, visible: visible, minimum: minimum), plain,
                       "обычное окно остаётся как было")
        let shrunk = WindowLaunchMode.normal.frame(current: visible, visible: visible, minimum: minimum)
        XCTAssertLessThan(shrunk.width, visible.width)
        XCTAssertLessThan(shrunk.height, visible.height)
        XCTAssertEqual(shrunk.midX, visible.midX, accuracy: 1, "по центру")
        XCTAssertEqual(shrunk.midY, visible.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(shrunk.width, minimum.width, "не меньше минимума окна")
        // Растянутое руками почти до краёв — тоже развёрнутое.
        let nearly = visible.insetBy(dx: 1, dy: 1)
        XCTAssertNotEqual(WindowLaunchMode.normal.frame(current: nearly, visible: visible, minimum: minimum), nearly)
    }

    func test_уКаждогоВариантаЕстьНазвание() {
        for mode in WindowLaunchMode.allCases {
            XCTAssertNotEqual(L(mode.titleKey), mode.titleKey, "нет перевода \(mode.titleKey)")
        }
    }
}
