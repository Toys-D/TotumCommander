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
