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

    /// Размещение «в активной панели»: терминал соседней панели не в счёт — нажатие в правой
    /// панели при терминале слева открывает терминал справа, а не прячет левый. Нижняя полоса
    /// в счёт всегда; при других размещениях — всё как было.
    func test_activePanelPlacementIgnoresTheOtherPanelsTerminal() {
        let spots: [TerminalSpot] = [.left(one), .bottom, .right(two)]
        XCTAssertEqual(TerminalToggle.relevant(spots, placement: "activePanel", activeSide: .right),
                       [.bottom, .right(two)])
        XCTAssertEqual(TerminalToggle.relevant(spots, placement: "activePanel", activeSide: .left),
                       [.left(one), .bottom])
        XCTAssertEqual(TerminalToggle.relevant(spots, placement: "bottom", activeSide: .right), spots)
        XCTAssertEqual(TerminalToggle.relevant(spots, placement: "leftPanel", activeSide: .right), spots)

        let visible = TerminalToggle.relevant([.left(one)], placement: "activePanel", activeSide: .right)
        XCTAssertEqual(TerminalToggle.step(mode: .hide, visible: visible, hidden: []), .open,
                       "в правой панели терминала нет — открыть, а не прятать левый")
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
    /// Прокрутка терминала — по знаку системы: смещение больше нуля (пальцы вниз при
    /// «естественной» прокрутке) ведёт к началу, как в любом списке macOS. Флажок переворачивает.
    func test_прокруткаИдётВСторонуСистемы() {
        var scroll = TerminalScroll()
        XCTAssertGreaterThan(scroll.lines(deltaY: 3, precise: false, lineHeight: 15, reversed: false), 0)
        XCTAssertLessThan(scroll.lines(deltaY: -3, precise: false, lineHeight: 15, reversed: false), 0)
        XCTAssertLessThan(scroll.lines(deltaY: 3, precise: false, lineHeight: 15, reversed: true), 0,
                          "флажок «в обратную сторону»")
    }

    /// Тачпад шлёт точки мелкими долями: строка набегает из нескольких смещений, без рывков и
    /// без потерь. Щелчок колеса — всегда хотя бы строка.
    func test_тачпадКопитДолиСтроки_КолесоНеМеньшеСтроки() {
        var scroll = TerminalScroll()
        XCTAssertEqual(scroll.lines(deltaY: 10, precise: true, lineHeight: 15, reversed: false), 0)
        XCTAssertEqual(scroll.lines(deltaY: 10, precise: true, lineHeight: 15, reversed: false), 1,
                       "двадцать точек — строка, остаток копится")
        XCTAssertEqual(scroll.lines(deltaY: 40, precise: true, lineHeight: 15, reversed: false), 3)
        scroll.reset()
        XCTAssertEqual(scroll.pending, 0)
        XCTAssertEqual(scroll.lines(deltaY: 0.2, precise: false, lineHeight: 15, reversed: false), 1)
        XCTAssertEqual(scroll.lines(deltaY: -0.2, precise: false, lineHeight: 15, reversed: false), -1)
        XCTAssertEqual(scroll.lines(deltaY: 0, precise: true, lineHeight: 15, reversed: false), 0)
    }

}
