import XCTest

@testable import TotumComXLApp

/// «Красивый режим» и слабое железо. Тёмная тема в наборе по умолчанию идёт с включёнными
/// размытием и свечением, а тянет их только Apple Silicon уровня Pro и выше. Проверка железа
/// стояла ровно в одной кнопке настроек — и человек на базовом M1, просто переключившись в
/// тёмную тему, получал заикающиеся панели и серую, недоступную кнопку.
final class BeautyModeCapabilityTests: XCTestCase {

    private let beauty = PanelAppearanceSettings.beautyModeEnabledKey

    func test_слабоеЖелезоНеПолучаетЭффектов() {
        XCTAssertFalse(PanelAppearanceSettings.effectiveThemedFlag(true, key: beauty,
                                                                    supportsBeauty: false))
    }

    func test_сильноеЖелезоПолучаетТоЧтоПросили() {
        XCTAssertTrue(PanelAppearanceSettings.effectiveThemedFlag(true, key: beauty,
                                                                   supportsBeauty: true))
    }

    func test_выключенноеОстаётсяВыключеннымВезде() {
        for supports in [true, false] {
            XCTAssertFalse(PanelAppearanceSettings.effectiveThemedFlag(false, key: beauty,
                                                                        supportsBeauty: supports))
        }
    }

    func test_другиеПереключателиЖелезоНеКасается() {
        // Свой цвет курсора, обводка и маска рисуются даром — их железо не ограничивает.
        for key in [PanelAppearanceSettings.cursorUsesCustomColorKey,
                    PanelAppearanceSettings.cursorOutlineEnabledKey,
                    CursorMaskStore.enabledKey] {
            XCTAssertTrue(PanelAppearanceSettings.effectiveThemedFlag(true, key: key,
                                                                       supportsBeauty: false), key)
        }
    }

    func test_запомненноеЖеланиеНеТеряется() {
        // Ключ темы (то, что человек выбрал) — не рабочий ключ: его правка не касается.
        XCTAssertTrue(PanelAppearanceSettings.effectiveThemedFlag(
            true, key: PanelAppearanceSettings.beautyModeEnabledDarkKey, supportsBeauty: false))
    }
}
