import AppKit

/// Сочетание клавиш так, как его держит пункт меню: клавиша (`keyEquivalent`) и
/// модификаторы.
///
/// Клавиша команды — это и есть сочетание её пункта в строке меню: палитра (⌘P), туннель
/// и подсказки берут его оттуда сами. Поэтому переназначение меняет только пункты меню, а
/// не заводит второй, параллельный список клавиш, который разошёлся бы с меню.
struct KeyCombo: Hashable {
    /// Как `keyEquivalent`: буква — строчная, F-клавиши и стрелки — служебные символы.
    var key: String
    var modifiers: NSEvent.ModifierFlags

    static let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        // Заглавная буква в `keyEquivalent` значит «с Shift» — пишем это явно, чтобы
        // ⇧⌘D из меню и ⇧⌘D с клавиатуры были одним сочетанием.
        var mods = modifiers.intersection(Self.relevant)
        var key = key
        if key.count == 1, let scalar = key.unicodeScalars.first,
           CharacterSet.uppercaseLetters.contains(scalar) {
            mods.insert(.shift)
            key = key.lowercased()
        }
        self.key = key
        self.modifiers = mods
    }

    static func == (a: KeyCombo, b: KeyCombo) -> Bool {
        a.key == b.key && a.modifiers.rawValue == b.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }

    init?(item: NSMenuItem) {
        guard !item.keyEquivalent.isEmpty else { return nil }
        self.init(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
    }

    /// Нажатие как сочетание. `charactersIgnoringModifiers` не учитывает ⌥ и ⌃, но учитывает
    /// Shift — заглавную букву разбирает init.
    init?(event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
        self.init(key: characters, modifiers: event.modifierFlags)
    }

    /// Нажатие, которое нельзя сделать сочетанием: голая буква или цифра без ⌘ и ⌃ — это
    /// набор имени для поиска по списку, стрелки и Tab водят курсор.
    var isAssignable: Bool {
        if Self.functionKeys.keys.contains(key) { return true }
        let navigation: Set<String> = ["\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}", "\u{9}", "\u{1b}"]
        if navigation.contains(key) { return !modifiers.isEmpty }
        return modifiers.contains(.command) || modifiers.contains(.control)
            || (modifiers.contains(.option) && key.count == 1 && !key.isEmpty)
    }

    static let functionKeys: [String: String] = [
        "\u{F704}": "F1", "\u{F705}": "F2", "\u{F706}": "F3", "\u{F707}": "F4",
        "\u{F708}": "F5", "\u{F709}": "F6", "\u{F70A}": "F7", "\u{F70B}": "F8",
        "\u{F70C}": "F9", "\u{F70D}": "F10", "\u{F70E}": "F11", "\u{F70F}": "F12",
    ]

    /// «⌥F7», «⇧⌘D» — теми же знаками, что печатает меню.
    var text: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let named: [String: String] = Self.functionKeys.merging([
            "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
            "\u{F72C}": "PgUp", "\u{F72D}": "PgDn", "\u{F729}": "Home", "\u{F72B}": "End",
            "\u{8}": "⌫", "\u{7f}": "⌫", "\u{F728}": "⌦", "\u{d}": "↩", "\u{3}": "⌤",
            "\u{9}": "⇥", "\u{1b}": "⎋", " ": "Space",
        ]) { a, _ in a }
        return text + (named[key] ?? key.uppercased())
    }

    /// Запись в настройки: «модификаторы:клавиша».
    var stored: String { "\(modifiers.rawValue):\(key)" }

    init?(stored: String) {
        guard let colon = stored.firstIndex(of: ":"),
              let raw = UInt(stored[..<colon]) else { return nil }
        let key = String(stored[stored.index(after: colon)...])
        guard !key.isEmpty else { return nil }
        self.init(key: key, modifiers: NSEvent.ModifierFlags(rawValue: raw))
    }

    static func function(_ number: Int, _ modifiers: NSEvent.ModifierFlags = []) -> KeyCombo {
        KeyCombo(key: AppDelegate.fkey(number), modifiers: modifiers)
    }
}

/// Готовые наборы. Набор — это не полный список, а отличия от сочетаний программы:
/// остальные команды остаются на своих клавишах.
enum KeyProfile: String, CaseIterable {
    case totum, totalCommander, midnightCommander, custom

    var titleKey: String { "settings.keys.profile.\(rawValue)" }

    /// Что меняет набор: команда (её устойчивое имя, см. CommandRegistry.stableID) → сочетание.
    var changes: [String: KeyCombo] {
        switch self {
        case .totum, .custom:
            return [:]
        case .totalCommander:
            return [
                "cmd:menuSearch:": .function(7, .option),
                "cmd:menuRename:": .function(6, .shift),
                "cmd:menuPack:": .function(5, .option),
                "cmd:menuUnpack:": .function(9, .option),
                "cmd:menuRefresh:": KeyCombo(key: "r", modifiers: .control),
                "cmd:menuSwapPanels:": KeyCombo(key: "u", modifiers: .control),
                "cmd:handleFavoriteFolders:": KeyCombo(key: "d", modifiers: .control),
                "cmd:menuProperties:": KeyCombo(key: "\r", modifiers: .option),
                "cmd:menuNewTab:": KeyCombo(key: "t", modifiers: .control),
                "cmd:menuCloseTab:": KeyCombo(key: "w", modifiers: .control),
            ]
        case .midnightCommander:
            return [
                "cmd:menuRename:": .function(6, .shift),
                "cmd:menuRefresh:": KeyCombo(key: "r", modifiers: .control),
                "cmd:menuSwapPanels:": KeyCombo(key: "u", modifiers: .control),
                "cmd:menuTerminal:": KeyCombo(key: "o", modifiers: .control),
                "cmd:handleFavoriteFolders:": KeyCombo(key: "\\", modifiers: .control),
                "cmd:menuSearch:": KeyCombo(key: "s", modifiers: [.control, .option]),
            ]
        }
    }

    /// Профили, которые можно выбрать; «Свой» появляется сам, когда человек что-то поменял.
    static let choosable: [KeyProfile] = [.totum, .totalCommander, .midnightCommander]
}

/// Свои сочетания: где они хранятся, как ложатся на строку меню и какие клавиши панель
/// больше не должна понимать по-старому.
@MainActor
enum KeyBindings {
    static let storeKey = "fcxl.keyBindings"
    static let profileKey = "fcxl.keyProfile"

    /// Команды, которые сюда не пускаются: у выхода своя настройка «⌘Q закрывает
    /// программу», и сочетание ему ставит она.
    static let excluded: Set<String> = ["cmd:terminate:"]

    static var defaults: UserDefaults = .standard

    // MARK: - Хранение

    /// Замены: команда → сочетание; nil — команда осталась без клавиши.
    static var overrides: [String: KeyCombo?] {
        get {
            let raw = defaults.dictionary(forKey: storeKey) as? [String: String] ?? [:]
            var result: [String: KeyCombo?] = [:]
            for (id, value) in raw { result[id] = value.isEmpty ? .some(nil) : KeyCombo(stored: value) }
            return result
        }
        set {
            var raw: [String: String] = [:]
            for (id, combo) in newValue { raw[id] = combo?.stored ?? "" }
            if raw.isEmpty { defaults.removeObject(forKey: storeKey) } else { defaults.set(raw, forKey: storeKey) }
        }
    }

    static var profile: KeyProfile {
        get { KeyProfile(rawValue: defaults.string(forKey: profileKey) ?? "") ?? .totum }
        set { defaults.set(newValue.rawValue, forKey: profileKey) }
    }

    // MARK: - Сочетания программы

    /// Сочетания, с которыми программа приходит, — с только что собранной строки меню,
    /// а не с живой: на живой уже лежат замены.
    private static var cachedDefaults: [String: KeyCombo]?

    static var programDefaults: [String: KeyCombo] {
        if let cachedDefaults { return cachedDefaults }
        let made = bindings(in: AppDelegate.buildMainMenu())
        cachedDefaults = made
        return made
    }

    /// Все пункты меню с сочетаниями, по устойчивым именам.
    static func bindings(in menu: NSMenu) -> [String: KeyCombo] {
        var result: [String: KeyCombo] = [:]
        walk(menu) { item, id in
            if let combo = KeyCombo(item: item), result[id] == nil { result[id] = combo }
        }
        return result
    }

    private static func walk(_ menu: NSMenu, _ visit: (NSMenuItem, String) -> Void) {
        for item in menu.items {
            if let id = CommandRegistry.stableID(of: item), !excluded.contains(id) { visit(item, id) }
            if let sub = item.submenu { walk(sub, visit) }
        }
    }

    /// Сочетание команды сейчас: своё, если задано, иначе программы.
    static func current(for id: String, overrides: [String: KeyCombo?]? = nil,
                        defaults base: [String: KeyCombo]? = nil) -> KeyCombo? {
        let overrides = overrides ?? self.overrides
        if let own = overrides[id] { return own }
        return (base ?? programDefaults)[id]
    }

    // MARK: - Применение

    /// Положить сочетания на строку меню. Каждый пункт получает своё или программы —
    /// так «вернуть» тоже работает: убранная замена возвращает пункту его клавишу.
    static func apply(to menu: NSMenu? = NSApplication.shared.mainMenu) {
        guard let menu else { return }
        let overrides = self.overrides
        let base = programDefaults
        walk(menu) { item, id in
            guard overrides[id] != nil || base[id] != nil else { return }
            let combo = current(for: id, overrides: overrides, defaults: base)
            item.keyEquivalent = combo?.key ?? ""
            item.keyEquivalentModifierMask = combo?.modifiers ?? []
        }
    }

    /// Дать команде сочетание (nil — убрать). Если оно было у другой команды, та его
    /// теряет; её имя возвращается, чтобы сказать об этом человеку.
    @discardableResult
    static func assign(_ combo: KeyCombo?, to id: String) -> String? {
        var overrides = self.overrides
        let base = programDefaults
        var loser: String?
        if let combo {
            let everyone = Set(base.keys).union(overrides.keys)
            for other in everyone where other != id && current(for: other, overrides: overrides, defaults: base) == combo {
                overrides[other] = .some(nil)
                loser = other
            }
        }
        if combo == base[id] { overrides.removeValue(forKey: id) } else { overrides[id] = .some(combo) }
        self.overrides = overrides
        profile = overrides.isEmpty ? .totum : .custom
        apply()
        return loser
    }

    /// Набор целиком: прежние замены уходят, ложатся замены набора.
    static func choose(_ chosen: KeyProfile) {
        overrides = [:]
        for (id, combo) in chosen.changes {
            var current = overrides
            let base = programDefaults
            for other in Set(base.keys).union(current.keys)
            where other != id && self.current(for: other, overrides: current, defaults: base) == combo {
                current[other] = .some(nil)
            }
            current[id] = .some(combo)
            overrides = current
        }
        profile = chosen
        apply()
    }

    static func resetAll() {
        overrides = [:]
        profile = .totum
        apply()
    }

    // MARK: - Панель

    /// Клавиши, которые панель понимает сама (F5 — копировать и т. д.), дублируют пункты
    /// меню. Если команда переехала на другое сочетание, её прежняя клавиша должна
    /// замолчать — иначе F5 копировал бы и после того, как человек отдал копирование ⌃C.
    static func isReleased(_ event: NSEvent) -> Bool {
        let overrides = self.overrides
        guard !overrides.isEmpty, let combo = KeyCombo(event: event) else { return false }
        let base = programDefaults
        for (id, original) in base where original == combo {
            if let own = overrides[id], own != original { return true }
        }
        return false
    }
}
