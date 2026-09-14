import AppKit
import XCTest
@testable import TotumComXLApp

/// С каким размером открывается окно настроек.
///
/// Оно открывалось ровно минимальным — 660×580, — и в нагруженных разделах его приходилось
/// растягивать при каждом открытии. Теперь открывается шире и чуть выше, а размер, который
/// человек выставил сам, помнится.
final class SettingsWindowSizeTests: XCTestCase {

    private let screen = NSSize(width: 1440, height: 870)   // 13-дюймовый ноутбук

    func test_открываетсяШиреИВышеМинимума() {
        let size = SettingsWindowSizeGuard.openingSize(remembered: nil, screen: screen)
        XCTAssertEqual(size, SettingsWindowSizeGuard.opening)
        XCTAssertGreaterThan(size.width, SettingsWindowSizeGuard.minimum.width + 100,
                             "заметно шире")
        XCTAssertGreaterThan(size.height, SettingsWindowSizeGuard.minimum.height, "и чуть выше")
    }

    /// Выставленный человеком размер — важнее стандартного.
    func test_запомненныйРазмерВажнееСтандартного() {
        let mine = NSSize(width: 1000, height: 760)
        XCTAssertEqual(SettingsWindowSizeGuard.openingSize(remembered: mine, screen: screen), mine)
    }

    /// На маленьком экране окно не вылезает за края: не больше девяти десятых экрана —
    /// но и не меньше минимума, ниже которого разделы складываются в кашу.
    func test_наМаленькомЭкранеУмещается() {
        let small = NSSize(width: 800, height: 600)
        let size = SettingsWindowSizeGuard.openingSize(remembered: NSSize(width: 1200, height: 900),
                                                       screen: small)
        XCTAssertEqual(size.width, 720, accuracy: 0.5, "девять десятых ширины экрана")
        XCTAssertEqual(size.height, SettingsWindowSizeGuard.minimum.height, accuracy: 0.5,
                       "высота упёрлась в минимум, а не в экран")
    }

    func test_запомненныйМеньшеМинимума_ПоднимаетсяДоМинимума() {
        let tiny = NSSize(width: 100, height: 100)
        XCTAssertEqual(SettingsWindowSizeGuard.openingSize(remembered: tiny, screen: screen),
                       SettingsWindowSizeGuard.minimum)
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
