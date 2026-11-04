import Foundation

/// Выбор, что помнится на каждую тему: у светлой свой, у тёмной свой. Панели читают один
/// рабочий ключ — зеркало выбора той темы, что на экране.
///
/// Так помнятся картинки папок, стиль значков файлов и их контур: ключи разные, правило одно.
/// Значение — любое, что хранится в настройках (строка, да/нет).
struct ThemedChoice {
    /// Рабочий ключ — его читают панели.
    let working: String
    let light: String
    let dark: String
    /// Что стоит на экране, пока не выбрано ничего.
    let fallback: Any

    func key(dark: Bool) -> String { dark ? self.dark : light }

    /// Выбрать для темы на экране. Другая тема, своего ещё не помнившая, запоминает то, что
    /// показывала до сих пор: выбор в одной теме другую не трогает.
    func choose(_ value: Any, dark: Bool, in defaults: UserDefaults) {
        let other = key(dark: !dark)
        if defaults.object(forKey: other) == nil {
            defaults.set(defaults.object(forKey: working) ?? fallback, forKey: other)
        }
        defaults.set(value, forKey: key(dark: dark))
        defaults.set(value, forKey: working)
    }

    /// Тема сменилась — запомненное для неё на экран; не запомнено — остаётся то, что было.
    func mirror(dark: Bool, in defaults: UserDefaults) {
        guard let remembered = defaults.object(forKey: key(dark: dark)) as? NSObject,
              !remembered.isEqual(defaults.object(forKey: working)) else { return }
        defaults.set(remembered, forKey: working)
    }
}
