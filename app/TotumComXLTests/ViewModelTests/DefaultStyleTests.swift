import AppKit
import XCTest

@testable import TotumComXLApp

/// Программа открывается на чистой машине в авторском оформлении: набор едет внутри, ничего
/// личного в нём нет, а свой выбор человека он не перекрывает.
final class DefaultStyleTests: XCTestCase {

    /// Домен регистрации у процесса ОДИН на все UserDefaults: набор, зарегистрированный
    /// здесь, был виден и в `UserDefaults.standard` — и соседние тесты начинали читать
    /// авторские настройки вместо своих. Домен возвращается на место после каждого теста.
    private var savedRegistration: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        savedRegistration = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
    }

    override func tearDown() {
        UserDefaults.standard.setVolatileDomain(savedRegistration, forName: UserDefaults.registrationDomain)
        super.tearDown()
    }

    func test_наборЕстьИВНёмОформление() throws {
        let style = try XCTUnwrap(DefaultStyle.load(), "DefaultStyle.plist не найден в ресурсах")
        XCTAssertGreaterThan(style.count, 100)
        for key in ["interfaceColorHexLight", "interfaceColorHexDark", "titlebarColorHexLight",
                    "accentColorHex", "cursorBackgroundColorHex", "listFontSize", "iconScale",
                    "leftVisibleColumns", "fcxl.toolbarLook", "fcxl.fileColorRules"] {
            XCTAssertNotNil(style[key], "в наборе нет \(key)")
        }
    }

    func test_ничегоЛичногоВНабореНет() throws {
        let style = try XCTUnwrap(DefaultStyle.load())
        let personal = style.keys.filter(DefaultStyle.isPersonal)
        XCTAssertTrue(personal.isEmpty, "личные ключи в наборе: \(personal)")
        for key in ["leftPanelPath", "panelTabs_left", "fcxl.remoteConnections", "fcxl.appLanguage",
                    "fcxl.updates.lastCheck", "showHiddenFiles", "fcxl.folderRules",
                    "NSWindow Frame MainWindowFrame", "colorsPerThemeMigrated", "fcxl.windowLaunch"] {
            XCTAssertNil(style[key], "\(key) — личное, не для всех")
            XCTAssertTrue(DefaultStyle.isPersonal(key) || style[key] == nil)
        }
    }

    func test_зарегистрированныйНаборОтвечаетГдеПусто_иНеПерекрываетСвоё() throws {
        let suite = "fcxl.defaultstyle.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let style = try XCTUnwrap(DefaultStyle.load())
        let shippedInterface = try XCTUnwrap(style["interfaceColorHexLight"] as? String)

        defaults.set("#123456", forKey: "accentColorHex")   // свой выбор — до регистрации
        let count = DefaultStyle.register(into: defaults)
        XCTAssertGreaterThan(count, 100)
        XCTAssertEqual(defaults.string(forKey: "interfaceColorHexLight"), shippedInterface, "пусто — отвечает набор")
        XCTAssertEqual(defaults.string(forKey: "accentColorHex"), "#123456", "своё — не перекрыто")
        XCTAssertNil(defaults.string(forKey: "leftPanelPath"), "личного не появилось")
        // Стереть свой выбор — вернуться к набору, а не в пустоту.
        defaults.removeObject(forKey: "accentColorHex")
        XCTAssertEqual(defaults.string(forKey: "accentColorHex"), style["accentColorHex"] as? String)
    }

    /// Тема и маска курсора — тоже часть облика: набор включает светлую тему автора и
    /// саму маску, иначе включённый переключатель показывал бы голый курсор.
    func test_темаИМаскаКурсораВНаборе() throws {
        let style = try XCTUnwrap(DefaultStyle.load())
        XCTAssertEqual(style["appearanceMode"] as? Int, 1, "светлая тема, как у автора")
        XCTAssertEqual(style["fcxl.customCursorMaskEnabled"] as? Bool, true)
        XCTAssertEqual(style["fcxl.customCursorMaskEnabledLight"] as? Bool, true, "в светлой — нарисованный курсор")
        XCTAssertEqual(style["fcxl.customCursorMaskEnabledDark"] as? Bool, false, "в тёмной — выключен по умолчанию")
        XCTAssertNotNil(CursorMaskStore.shippedImage(), "DefaultCursorMask.png не найден")
        XCTAssertNotNil(CursorMaskStore.shippedArtworkImage(), "DefaultCursorMaskArtwork.png не найден")
        XCTAssertGreaterThan(CursorMaskStore.shippedImage()?.size.width ?? 0, 0)
    }

    /// Цвет интерфейса из набора — тот, что делает заголовок тёмным в светлой теме: значит,
    /// авторские цвета дошли до логики, которая по ним красит панель.
    func test_цветаНабораЧитаютсяКакНастоящие() throws {
        let style = try XCTUnwrap(DefaultStyle.load())
        for key in ["interfaceColorHexLight", "interfaceColorHexDark", "accentColorHex"] {
            let hex = try XCTUnwrap(style[key] as? String)
            XCTAssertNotNil(PanelAppearanceSettings.optionalNSColor(from: hex), "\(key) = \(hex) не читается как цвет")
        }
    }
}
