import Foundation

/// Где стоит терминал: нижняя полоса или вкладка левой либо правой панели.
enum TerminalSpot: Equatable {
    case bottom
    case left(UUID)
    case right(UUID)
}

/// Что делают ⌘` и кнопка терминала с видимым терминалом — настройка в разделе «Терминал».
enum TerminalToggleMode: String, CaseIterable {
    /// Убрать с глаз, команды работают дальше.
    case hide
    /// Закрыть и остановить всё, что запущено, — как было раньше.
    case close

    static let defaultsKey = "terminalToggleAction"

    static func current(_ defaults: UserDefaults = .standard) -> TerminalToggleMode {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .hide
    }
}

enum TerminalToggleStep: Equatable {
    case hide(TerminalSpot)
    case close(TerminalSpot)
    case show(TerminalSpot)
    case open
}

/// Решение ⌘`, когда терминалов может быть несколько.
enum TerminalToggle {
    /// `visible` — показанные, первым тот, где клавиатура; `hidden` — спрятанные, первым тот,
    /// что спрятали последним. Видимый прячется или закрывается по настройке; спрятанный
    /// возвращается в обоих режимах — ⌘` не останавливает то, чего не видно.
    static func step(mode: TerminalToggleMode, visible: [TerminalSpot],
                     hidden: [TerminalSpot]) -> TerminalToggleStep {
        if let spot = visible.first { return mode == .hide ? .hide(spot) : .close(spot) }
        if let spot = hidden.first { return .show(spot) }
        return .open
    }

    /// Спрятанные по порядку: последний спрятанный первым, если он ещё жив.
    static func hiddenOrder(all: [TerminalSpot], lastHidden: TerminalSpot?) -> [TerminalSpot] {
        guard let lastHidden, all.contains(lastHidden) else { return all }
        return [lastHidden] + all.filter { $0 != lastHidden }
    }
}
