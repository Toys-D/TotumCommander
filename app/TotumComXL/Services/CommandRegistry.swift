import AppKit

/// One thing the palette can run.
struct PaletteCommand: Identifiable {
    let id = UUID()
    /// What the menu calls it.
    let title: String
    /// Which menu it came from — "Tools", "View" — so two similarly named commands are telling apart.
    let group: String
    /// «Сортировать по › » — путь вложенного меню; у обычной команды пусто.
    var prefix: String = ""
    /// "⌘⇧D" or empty. Shown so the palette teaches the shortcut rather than replacing it.
    let shortcut: String
    let symbolName: String?
    /// The menu item itself: running the command sends its own action to its own target, so the
    /// palette can never drift from what the menu does.
    let item: NSMenuItem

    /// Устойчивое имя команды — им её записывают в настройки и находят обратно.
    var stableID: String { CommandRegistry.stableID(of: item) ?? ("cmd:" + group + "▸" + title) }

    /// Название на этот самый миг.
    ///
    /// Проверка доступности успевает переписать слово в пунктах-переключателях —
    /// «Закрепить» становится «Открепить», «Запереть хранилище» — «Отпереть», — поэтому
    /// снимок, сделанный при обходе меню, годится для поиска, но не для показа.
    var currentTitle: String { prefix + item.title }
}

/// Everything the app can do, read from the menu bar it already has.
///
/// The alternative — a hand-written list of commands — starts out correct and then rots: a new menu
/// item is added, nobody remembers the palette, and the palette quietly lies about what the app can
/// do. Walking the real menu means the palette gains a command the moment the menu does, with the
/// right title in the right language, the real keyboard shortcut, and the same enabled/disabled
/// state the menu itself would show.
@MainActor
enum CommandRegistry {

    /// Menus whose contents are not "commands" in the palette sense.
    ///
    /// The app menu is macOS boilerplate (About, Services, Hide, Quit) and Window/Help are the
    /// system's own; offering them would bury the app's real commands under noise.
    private static let skippedTopLevelTitles: Set<String> = ["Window", "Help", "Окно", "Справка"]

    /// Menus macOS adds items of its own to, with the items that were there before it did.
    ///
    /// The system appends to the Edit menu the first time it is used — Start Dictation, Emoji &
    /// Symbols, the AutoFill submenu with Passwords and Contact. They are ordinary menu items, so a
    /// plain walk picks them up and the palette starts offering the system's commands as if they
    /// were the app's.
    ///
    /// The snapshot is kept PER MENU and only for the menus the system actually touches, rather
    /// than for the whole menu bar. That distinction is the point: a command added to any other
    /// menu later — a list of recent folders, say — is ours by construction and reaches the palette
    /// with nothing to remember. Snapshotting everything would have dropped such a command silently,
    /// which is the kind of failure nobody notices until the command is missing.
    /// Weak keys and weak members on purpose. This was a dictionary keyed by ObjectIdentifier —
    /// a raw address — and an address outlives nothing: once a snapshotted menu was deallocated,
    /// a NEW menu allocated at the same address inherited its snapshot and had every one of its
    /// commands filtered out as "system-added". The map dropping dead menus by itself is the fix.
    private static let systemExtended = NSMapTable<NSMenu, NSHashTable<NSMenuItem>>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)

    /// Declare a menu the system extends, freezing what it holds right now as "ours".
    static func markSystemExtended(_ menu: NSMenu) {
        let snapshot = NSHashTable<NSMenuItem>.weakObjects()
        for item in menu.items { snapshot.add(item) }
        systemExtended.setObject(snapshot, forKey: menu)
    }

    /// Did the app put this item here, or did macOS?
    private static func isOurs(_ item: NSMenuItem, in menu: NSMenu) -> Bool {
        guard let snapshot = systemExtended.object(forKey: menu) else { return true }
        return snapshot.contains(item)
    }

    /// The name to show for a top-level menu.
    ///
    /// Every top-level entry here is built as a bare NSMenuItem with its submenu attached, so the
    /// ITEM has no title — it reports AppKit's default, "NSMenuItem" — while the real name sits on
    /// the submenu. Reading the item was why every command claimed to live in a menu called
    /// "NSMenuItem", and why the Window and Help menus were never skipped.
    private static func name(of topLevel: NSMenuItem) -> String {
        let submenuTitle = topLevel.submenu?.title ?? ""
        return submenuTitle.isEmpty ? topLevel.title : submenuTitle
    }

    static func commands() -> [PaletteCommand] {
        // NSApplication.shared, а не NSApp: глобальная NSApp — неявно развёрнутый ноль,
        // пока приложение не создано, и первое же обращение из такого места (отрисовка
        // вида в проверке, ранний вызов) роняло программу насмерть. shared создаёт
        // приложение при первом касании и nil не бывает.
        guard let mainMenu = NSApplication.shared.mainMenu else { return [] }
        var found: [PaletteCommand] = []

        // The first top-level menu is the application menu, named after the app itself.
        for topLevel in mainMenu.items.dropFirst() {
            let group = name(of: topLevel)
            guard let submenu = topLevel.submenu,
                  !skippedTopLevelTitles.contains(group) else { continue }
            collect(from: submenu, group: group, into: &found)
        }
        return found
    }

    private static func collect(from menu: NSMenu, group: String, prefix: String = "",
                                into found: inout [PaletteCommand]) {
        for item in menu.items {
            if item.isSeparatorItem || item.isHidden || item.title.isEmpty { continue }
            // Not ours — macOS put it in this menu after the app had built it.
            if !isOurs(item, in: menu) { continue }
            if let submenu = item.submenu {
                // Вложенное меню остаётся в группе родителя, а его имя входит в название:
                // «Сортировать по › Имя» и «Столбцы › Имя» — разные команды, и палитра
                // обязана их различать. Стрелка не та, что делит группу и название в ключе
                // туннеля («▸»), — иначе ключ резался бы не там.
                collect(from: submenu, group: group, prefix: prefix + item.title + " › ",
                        into: &found)
                continue
            }
            guard let action = item.action else { continue }
            // Opening the palette from inside the palette is noise.
            if action == #selector(AppDelegate.showCommandPalette(_:)) { continue }
            found.append(PaletteCommand(title: prefix + item.title,
                                        group: group,
                                        prefix: prefix,
                                        shortcut: shortcutText(for: item),
                                        symbolName: item.image?.name(),
                                        item: item))
        }
    }

    /// Would the app act on this command right now? Asking the menu's own validator is what keeps
    /// the palette from offering "Extract archive" with nothing selected.
    static func isEnabled(_ command: PaletteCommand) -> Bool {
        let item = command.item
        guard let action = item.action else { return false }
        let target = NSApp.target(forAction: action, to: item.target, from: item) as AnyObject?
        if let validator = target as? NSMenuItemValidation {
            return validator.validateMenuItem(item)
        }
        return target != nil
    }

    /// Имя, которым команду можно записать в настройки и найти обратно.
    ///
    /// Название пункта не годится: оно меняется вместе с языком, и человек, переключивший
    /// программу на английский, потерял бы всё, что сам собрал в меню. Действие переживает и
    /// язык, и перестановки в коде; метка и вложенная строка различают пункты, делящие одно
    /// действие на всех, — девять папок «Перейти» ходят через один селектор.
    nonisolated static func stableID(of item: NSMenuItem) -> String? {
        guard let action = item.action else { return nil }
        var id = "cmd:" + NSStringFromSelector(action)
        if item.tag != 0 { id += "#\(item.tag)" }
        // Путь — с «~» вместо домашней папки: имя учётной записи в имени команды означало бы,
        // что переименовали учётку — и девять пунктов «Перейти» молча выпали из собранного меню.
        if let text = item.representedObject as? String {
            id += "#" + (text as NSString).abbreviatingWithTildeInPath
        }
        return id
    }

    /// Команда по её устойчивому имени; нет такой — nil (пункт исчез из меню).
    static func command(id: String) -> PaletteCommand? {
        commands().first { $0.stableID == id }
    }

    /// Похоже ли имя на команду строки меню — по нему меню решает, где искать пункт.
    nonisolated static func isCommandID(_ id: String) -> Bool { id.hasPrefix("cmd:") }

    /// Run it exactly as choosing it from the menu would.
    @discardableResult
    static func run(_ command: PaletteCommand) -> Bool {
        guard let action = command.item.action else { return false }
        return NSApp.sendAction(action, to: command.item.target, from: command.item)
    }

    /// "⌘⇧D" — the same glyphs the menu prints, so the palette teaches the shortcut.
    private static func shortcutText(for item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        var text = ""
        let flags = item.keyEquivalentModifierMask
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option)  { text += "⌥" }
        if flags.contains(.shift)   { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }

        // Function and navigation keys arrive as private-use scalars, which would print as tofu.
        let named: [Character: String] = [
            "\u{F704}": "F1", "\u{F705}": "F2", "\u{F706}": "F3", "\u{F707}": "F4",
            "\u{F708}": "F5", "\u{F709}": "F6", "\u{F70A}": "F7", "\u{F70B}": "F8",
            "\u{F70C}": "F9", "\u{F70D}": "F10", "\u{F70E}": "F11", "\u{F70F}": "F12",
            "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
            "\u{8}": "⌫", "\u{d}": "↩", "\u{9}": "⇥", "\u{1b}": "⎋", " ": "Space",
        ]
        if let key = item.keyEquivalent.first, let name = named[key] {
            return text + name
        }
        return text + item.keyEquivalent.uppercased()
    }
}

/// Ranking a query against a command name.
///
/// Plain "contains" is not enough for a palette: people type initials ("cf" for "Compare folders")
/// and fragments from the middle of a word. Matching is a subsequence test — every typed character
/// must appear in order — and the score rewards the matches that look deliberate: a run of adjacent
/// characters, a hit at the start of a word, a hit at the very beginning of the name.
enum CommandMatcher {

    /// nil means "does not match at all"; a bigger number is a better match.
    static func score(_ query: String, against text: String) -> Int? {
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(text.lowercased())
        guard needle.count <= haystack.count else { return nil }

        var score = 0
        var searchFrom = 0
        var previousIndex = -1

        for character in needle {
            guard let index = haystack[searchFrom...].firstIndex(of: character) else { return nil }
            if index == previousIndex + 1 { score += 8 }        // continues a run
            if index == 0 { score += 12 }                       // starts the name
            else if haystack[index - 1] == " " { score += 10 }  // starts a word
            else if haystack[index - 1] == "-" { score += 6 }
            previousIndex = index
            searchFrom = index + 1
        }
        // Among equally good matches, the shorter name is the one the user probably meant.
        return score + max(0, 24 - haystack.count)
    }

    /// The commands that match, best first. Ties keep the menu's own order, which is stable and
    /// already groups related commands together.
    static func rank(_ commands: [PaletteCommand], query: String) -> [PaletteCommand] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return commands }
        return commands
            .enumerated()
            .compactMap { position, command -> (PaletteCommand, Int, Int)? in
                // The group name counts too, so "tools" lists everything under Tools — but it
                // scores below a hit on the command's own name.
                let titleScore = score(query, against: command.title)
                let groupScore = score(query, against: command.group).map { $0 / 3 }
                guard let best = [titleScore, groupScore].compactMap({ $0 }).max() else { return nil }
                return (command, best, position)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }
}
