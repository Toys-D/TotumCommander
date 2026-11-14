import AppKit

/// Двойной щелчок по строке заголовка — то, что выбрано в Системных настройках ▸ Рабочий стол
/// и Dock: изменить масштаб, свернуть или ничего.
///
/// Обычно это делает сам AppKit. Но на macOS 27 узкая панель (`.unifiedCompact` — её держит
/// главное окно, чтобы заголовок не рос) двойной щелчок глотает: пробное окно без панели и с
/// обычной панелью разворачивается, с узкой — нет, и пустой, и с кнопками. Поэтому щелчок
/// ловится здесь и выполняется сам; дальше он не идёт, чтобы окно не развернулось и тут же не
/// свернулось обратно, когда AppKit это починит.
enum TitlebarDoubleClick {
    enum Action: Equatable { case zoom, minimize, none }

    /// `AppleActionOnDoubleClick`: «Maximize», «Minimize», «None»; «Fill» («Заполнить» на
    /// macOS 15+) ближе всего к развороту. Без неё — старый флажок «свернуть двойным щелчком».
    static func action(setting: String?, legacyMinimize: Bool) -> Action {
        switch setting {
        case "Minimize": return .minimize
        case "None": return .none
        case "Maximize", "Fill": return .zoom
        default: return legacyMinimize ? .minimize : .zoom
        }
    }

    /// Что выбрано в системе сейчас — спрашивается при каждом щелчке, настройку могли сменить.
    static var systemAction: Action {
        let defaults = UserDefaults.standard
        return action(setting: defaults.string(forKey: "AppleActionOnDoubleClick"),
                      legacyMinimize: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"))
    }

    /// Щелчок в строке заголовка (выше содержимого окна) и не по кнопке. Имя окна — текстовое
    /// поле, но по нему двойной щелчок разворачивает, как везде в macOS.
    static func isOnEmptyTitlebar(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.window === window else { return false }
        let point = event.locationInWindow
        guard point.y >= window.contentLayoutRect.maxY, point.y <= window.frame.height else { return false }
        guard let frameView = window.contentView?.superview,
              let hit = frameView.hitTest(point) else { return true }
        let onControl = sequence(first: hit, next: \.superview).contains {
            $0 is NSControl && !($0 is NSTextField)
        }
        return !onControl
    }

    /// Выполнить системное действие. true — щелчок забран, дальше его не отдавать.
    @discardableResult
    static func handle(_ event: NSEvent, in window: NSWindow, action: Action = systemAction) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 2,
              !window.styleMask.contains(.fullScreen),
              isOnEmptyTitlebar(event, in: window) else { return false }
        switch action {
        case .zoom: window.zoom(nil)
        case .minimize: window.miniaturize(nil)
        case .none: break
        }
        return true
    }
}
