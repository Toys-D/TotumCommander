import AppKit
import XCTest
@testable import TotumComXLApp

/// С каким размером открывается окно настроек.
///
/// Оно открывалось ровно минимальным — 660×580, — и в нагруженных разделах его приходилось
/// растягивать при каждом открытии. Теперь ширина стандартная, а высота — сколько даёт
/// экран за вычетом полей; размер, который человек выставил сам, помнится.
final class SettingsWindowSizeTests: XCTestCase {

    private let screen = NSSize(width: 1440, height: 870)   // 13-дюймовый ноутбук

    func test_открываетсяШиреМинимумаИВоВесьЭкранПоВысоте() {
        let size = SettingsWindowSizeGuard.openingSize(remembered: nil, screen: screen)
        XCTAssertEqual(size.width, SettingsWindowSizeGuard.openingWidth)
        XCTAssertGreaterThan(size.width, SettingsWindowSizeGuard.minimum.width + 100,
                             "заметно шире")
        XCTAssertEqual(size.height, screen.height - 2 * SettingsWindowSizeGuard.screenMargin,
                       "высота — экран минус поля сверху и снизу")
    }

    /// Чем выше экран, тем выше окно: на большом мониторе влезает больше.
    func test_наВысокомЭкранеОкноВыше() {
        let laptop = SettingsWindowSizeGuard.openingSize(remembered: nil, screen: screen)
        let desk = SettingsWindowSizeGuard.openingSize(remembered: nil,
                                                       screen: NSSize(width: 1728, height: 1080))
        XCTAssertEqual(desk.height, 1000, accuracy: 0.5)
        XCTAssertGreaterThan(desk.height, laptop.height)
        XCTAssertEqual(desk.width, laptop.width, "ширина от экрана не зависит")
    }

    /// Выставленный человеком размер — важнее стандартного.
    func test_запомненныйРазмерВажнееСтандартного() {
        let mine = NSSize(width: 1000, height: 760)
        XCTAssertEqual(SettingsWindowSizeGuard.openingSize(remembered: mine, screen: screen), mine)
    }

    /// На маленьком экране окно не вылезает за края: экран минус поля — но и не меньше
    /// минимума, ниже которого разделы складываются в кашу.
    func test_наМаленькомЭкранеУмещается() {
        let small = NSSize(width: 800, height: 600)
        let size = SettingsWindowSizeGuard.openingSize(remembered: NSSize(width: 1200, height: 900),
                                                       screen: small)
        XCTAssertEqual(size.width, 720, accuracy: 0.5, "ширина экрана минус поля")
        XCTAssertEqual(size.height, SettingsWindowSizeGuard.minimum.height, accuracy: 0.5,
                       "высота упёрлась в минимум, а не в экран")
    }

    /// Запись меньше минимума — мусор (старая, до поднятия минимума): она не должна
    /// прижимать окно к минимуму вместо стандартного размера.
    func test_запомненныйМеньшеМинимума_НеУчитывается() {
        let stale = NSSize(width: 594, height: 522)
        XCTAssertEqual(SettingsWindowSizeGuard.openingSize(remembered: stale, screen: screen),
                       SettingsWindowSizeGuard.openingSize(remembered: nil, screen: screen))
        let narrow = NSSize(width: 100, height: 900)
        XCTAssertEqual(SettingsWindowSizeGuard.openingSize(remembered: narrow, screen: screen),
                       SettingsWindowSizeGuard.openingSize(remembered: nil, screen: screen),
                       "одной стороны меньше минимума достаточно")
    }

    /// Запомненное переживает запись и чтение, а испорченное не принимается.
    func test_размерЗапоминаетсяИЧитается() {
        let saved = SettingsWindowSizeGuard.remembered
        defer { SettingsWindowSizeGuard.remembered = saved }
        SettingsWindowSizeGuard.remembered = NSSize(width: 900, height: 700)
        XCTAssertEqual(SettingsWindowSizeGuard.remembered, NSSize(width: 900, height: 700))
        SettingsWindowSizeGuard.remembered = nil
        XCTAssertNil(SettingsWindowSizeGuard.remembered)
        UserDefaults.standard.set("ерунда", forKey: SettingsWindowSizeGuard.rememberedKey)
        XCTAssertNil(SettingsWindowSizeGuard.remembered, "мусор в настройках — как будто ничего не помнится")
    }
}
