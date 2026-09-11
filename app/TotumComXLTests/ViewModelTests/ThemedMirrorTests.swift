import AppKit
import XCTest
@testable import TotumComXLApp

/// Зеркало «цветов и переключателей по темам» берёт тему из настройки, а не из живого
/// NSApp.effectiveAppearance.
///
/// Настоящий баг: маска курсора (она рисуется только при «режиме красоты», а тот у
/// пользователя включён лишь в тёмной теме) не появлялась после перезапуска в тёмной
/// теме. Приложение форсирует тёмную поверх светлой системы, а effectiveAppearance
/// отставал на такт — зеркало копировало светлое значение «красоты» (выкл), и маска
/// исчезала до ручного переключения темы.
final class ThemedMirrorTests: XCTestCase {

    func test_принудительнаяТемаЗнаетСебяНезависимоОтЭкрана() {
        // Режим 2 (тёмная) поверх светлой системы — как при перезапуске.
        XCTAssertTrue(PanelAppearanceSettings.mirrorThemeIsDark(appearanceMode: 2, systemIsDark: false),
                      "форс-тёмная — тёмная, даже когда экран ещё светлый")
        XCTAssertFalse(PanelAppearanceSettings.mirrorThemeIsDark(appearanceMode: 1, systemIsDark: true),
                       "форс-светлая — светлая, даже когда экран тёмный")
    }

    func test_система_ИдётЗаЭкраном() {
        XCTAssertTrue(PanelAppearanceSettings.mirrorThemeIsDark(appearanceMode: 0, systemIsDark: true))
        XCTAssertFalse(PanelAppearanceSettings.mirrorThemeIsDark(appearanceMode: 0, systemIsDark: false))
    }

    /// Действующая «красота» после синхронизации совпадает с той, что записана для темы
    /// из настройки, — что и решает, появится ли маска курсора.
    @MainActor
    func test_синхронизацияБерётКрасотуВыбраннойТемы() {
        let d = UserDefaults.standard
        let keys = [PanelAppearanceSettings.appearanceModeKey,
                    PanelAppearanceSettings.beautyModeEnabledKey,
                    PanelAppearanceSettings.beautyModeEnabledLightKey,
                    PanelAppearanceSettings.beautyModeEnabledDarkKey]
        let saved = keys.map { (key: $0, value: d.object(forKey: $0)) }
        defer { for item in saved { if let v = item.value { d.set(v, forKey: item.key) } else { d.removeObject(forKey: item.key) } } }

        d.set(0, forKey: PanelAppearanceSettings.beautyModeEnabledLightKey)   // светлая: выкл
        d.set(1, forKey: PanelAppearanceSettings.beautyModeEnabledDarkKey)    // тёмная: вкл

        d.set(2, forKey: PanelAppearanceSettings.appearanceModeKey)           // форс-тёмная
        PanelAppearanceSettings.syncThemedColorsToEffective()
        XCTAssertTrue(d.bool(forKey: PanelAppearanceSettings.beautyModeEnabledKey),
                      "в тёмной теме красота включена — маска рисуется")

        d.set(1, forKey: PanelAppearanceSettings.appearanceModeKey)           // форс-светлая
        PanelAppearanceSettings.syncThemedColorsToEffective()
        XCTAssertFalse(d.bool(forKey: PanelAppearanceSettings.beautyModeEnabledKey),
                       "в светлой теме — выключена")
    }
}

/// Тема заголовка и панели инструментов — та же, что у панелей, и берётся так же.
///
/// Настоящий баг: система переключалась на тёмную, панели темнели, а заголовок оставался
/// прежнего, светлого цвета. Причина — заголовок спрашивал тему у САМОГО ОКНА, а внутри
/// KVO на NSApp.effectiveAppearance окно ещё отдаёт прежнюю. Замерено пробой: NSApp уже
/// darkAqua, окно всё ещё aqua, догоняет на следующем такте — и цвет ушедшей темы так и
/// оставался на заголовке до следующего повода перекрасить.
final class ChromeThemeTests: XCTestCase {

    private func chrome(window: NSAppearance.Name? = nil, mode: Int, systemIsDark: Bool) -> Bool {
        PanelAppearanceSettings.chromeThemeIsDark(
            windowAppearance: window.flatMap { NSAppearance(named: $0) },
            appearanceMode: mode, systemIsDark: systemIsDark)
    }

    /// То самое место: «по системе», система уже тёмная — обрамление тёмное, что бы там
    /// ни отвечало отстающее окно.
    func test_поСистеме_ТемаБерётсяУСистемы() {
        XCTAssertTrue(chrome(mode: 0, systemIsDark: true))
        XCTAssertFalse(chrome(mode: 0, systemIsDark: false))
    }

    func test_принудительнаяТема_ЗнаетСебяСразу() {
        XCTAssertFalse(chrome(mode: 1, systemIsDark: true), "форс-светлая на тёмной системе")
        XCTAssertTrue(chrome(mode: 2, systemIsDark: false), "форс-тёмная на светлой системе")
    }

    /// А если тема окна задана явно — она главнее: окно нарисовано именно в ней.
    func test_явнаяТемаОкна_Главнее() {
        XCTAssertTrue(chrome(window: .darkAqua, mode: 1, systemIsDark: false))
        XCTAssertFalse(chrome(window: .aqua, mode: 2, systemIsDark: true))
    }

    /// Обрамление и зеркало «по темам» не расходятся: иначе заголовок красится ключом
    /// одной темы, а панели — другой.
    func test_обрамлениеСовпадаетСЗеркалом() {
        for mode in [0, 1, 2] {
            for system in [true, false] {
                XCTAssertEqual(chrome(mode: mode, systemIsDark: system),
                               PanelAppearanceSettings.mirrorThemeIsDark(appearanceMode: mode,
                                                                         systemIsDark: system),
                               "режим \(mode), система \(system ? "тёмная" : "светлая")")
            }
        }
    }
}
