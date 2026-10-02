import XCTest
@testable import TotumComXLApp

/// ⌘` и кнопка терминала, когда терминалов несколько: видимый прячется или закрывается по
/// настройке, спрятанный возвращается, нет ни одного — открывается новый.
final class TerminalToggleTests: XCTestCase {

    private let one = UUID(), two = UUID()

    func test_whenTerminalVisible_shouldHideOrCloseBySetting() {
        XCTAssertEqual(TerminalToggle.step(mode: .hide, visible: [.left(one)], hidden: []), .hide(.left(one)))
        XCTAssertEqual(TerminalToggle.step(mode: .close, visible: [.left(one)], hidden: []), .close(.left(one)))
    }

    /// Видимый важнее спрятанного: первое нажатие убирает то, что на экране.
    func test_whenVisibleAndHiddenBoth_shouldActOnVisibleFirst() {
        XCTAssertEqual(TerminalToggle.step(mode: .hide, visible: [.bottom], hidden: [.right(two)]), .hide(.bottom))
    }

    /// Спрятанный возвращается в обоих режимах: ⌘` не убивает то, чего не видно.
    func test_whenOnlyHidden_shouldShowIt() {
        XCTAssertEqual(TerminalToggle.step(mode: .hide, visible: [], hidden: [.right(two)]), .show(.right(two)))
        XCTAssertEqual(TerminalToggle.step(mode: .close, visible: [], hidden: [.bottom]), .show(.bottom))
    }

    func test_whenNoTerminal_shouldOpen() {
        XCTAssertEqual(TerminalToggle.step(mode: .hide, visible: [], hidden: []), .open)
    }

    /// Возвращается последний спрятанный, если он ещё жив.
    func test_hiddenOrderPutsLastHiddenFirst() {
        let all: [TerminalSpot] = [.bottom, .left(one), .right(two)]
        XCTAssertEqual(TerminalToggle.hiddenOrder(all: all, lastHidden: .right(two)),
                       [.right(two), .bottom, .left(one)])
        XCTAssertEqual(TerminalToggle.hiddenOrder(all: all, lastHidden: .left(UUID())), all, "закрытый — как есть")
        XCTAssertEqual(TerminalToggle.hiddenOrder(all: all, lastHidden: nil), all)
    }

    func test_modeDefaultsToHide() throws {
        let suite = "fcxl.toggle.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TerminalToggleMode.current(defaults), .hide)
        defaults.set("close", forKey: TerminalToggleMode.defaultsKey)
        XCTAssertEqual(TerminalToggleMode.current(defaults), .close)
        defaults.set("мусор", forKey: TerminalToggleMode.defaultsKey)
        XCTAssertEqual(TerminalToggleMode.current(defaults), .hide)
    }
}
