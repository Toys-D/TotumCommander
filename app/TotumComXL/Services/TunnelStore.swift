import Foundation

/// Содержимое центрального туннеля: папки сверху, операции снизу.
///
/// Раньше и то и другое было прошито в коде, и человеку оставалось смотреть на чужой
/// выбор. Теперь туннель его собственный: набор по умолчанию — как боковая панель
/// Finder, но любую папку можно убрать правой кнопкой, добавить перетаскиванием, а
/// значок выбрать из библиотеки. С операциями так же: убрать лишние, добавить любую
/// команду программы — список берётся из того же реестра, что и палитра команд, поэтому
/// новая команда попадает сюда сама, без отдельной регистрации.
@MainActor
final class TunnelStore: ObservableObject {

    static let shared = TunnelStore()

    // MARK: - Папка туннеля

    /// Совпадает ли папка тоннеля с тем местом, где сейчас стоит активная панель.
    /// Сравниваем приведённые пути: панель может отдать путь с хвостовой чертой или
    /// через «~», и тогда обычное равенство строк молча ничего бы не подсветило.
    nonisolated static func marksCurrent(folder: String, panel: String) -> Bool {
        guard !folder.isEmpty, !panel.isEmpty else { return false }
        return (folder as NSString).standardizingPath == (panel as NSString).standardizingPath
    }

    struct Folder: Codable, Equatable, Identifiable {
        var path: String
        /// Значок SF Symbols — тот, что человек выбрал, или подобранный по умолчанию.
        var icon: String
        /// Своя подпись. nil — подпись выводится из пути: у известных системных папок
        /// переводится, у остальных берётся имя. Хранить переведённое нельзя: смена языка
        /// заморозила бы старые надписи.
        var customLabel: String?

        var id: String { path }

        init(path: String, icon: String, customLabel: String? = nil) {
            self.path = path
            self.icon = icon
            self.customLabel = customLabel
        }

        var label: String {
            if let customLabel, !customLabel.isEmpty { return customLabel }
            if let known = TunnelStore.knownFolders[path] { return L(known.label) }
            return (path as NSString).lastPathComponent
        }

        var shortLabel: String {
            if let customLabel, !customLabel.isEmpty { return customLabel }
            if let known = TunnelStore.knownFolders[path] { return L(known.short) }
            return (path as NSString).lastPathComponent
        }
    }

    /// Системные папки: перевод подписи живёт у нас, а не в сохранённых данных.
    static let knownFolders: [String: (label: String, short: String)] = {
        let home = NSHomeDirectory()
        return [
            "/Applications": ("quickLink.applications", "quickLink.short.applications"),
            home + "/Desktop": ("quickLink.desktop", "quickLink.short.desktop"),
            home + "/Documents": ("quickLink.documents", "quickLink.short.documents"),
            home + "/Downloads": ("quickLink.downloads", "quickLink.short.downloads"),
            home + "/Movies": ("quickLink.movies", "quickLink.short.movies"),
            home + "/Music": ("quickLink.music", "quickLink.short.music"),
            home + "/Pictures": ("quickLink.pictures", "quickLink.short.pictures")
        ]
    }()

    /// Набор по умолчанию — как боковая панель Finder: пользовательские папки все, сверху
    /// вниз. AirDrop и «Недавние» из неё — не папки, им в списке путей делать нечего.
    static var defaultFolders: [Folder] {
        let home = NSHomeDirectory()
        return [
            Folder(path: "/Applications", icon: "a.square.fill"),
            // Монитор, как было всегда: рабочий стол — это то, что на экране.
            Folder(path: home + "/Desktop", icon: "desktopcomputer"),
            Folder(path: home + "/Documents", icon: "doc"),
            Folder(path: home + "/Downloads", icon: "arrow.down.circle"),
            Folder(path: home + "/Movies", icon: "film"),
            Folder(path: home + "/Music", icon: "music.note"),
            Folder(path: home + "/Pictures", icon: "photo")
        ]
    }

    // MARK: - Операция туннеля

    struct Action: Codable, Equatable, Identifiable {
        /// «builtin:copy» — своя операция с готовым обработчиком; «menu:Группа▸Название» —
        /// команда из строки меню, та же, что в палитре. Название и есть ключ: устойчивых
        /// номеров у пунктов меню не существует.
        var key: String
        var icon: String
        /// Для команд меню — их название; свои операции переводятся при показе.
        var customLabel: String?

        var id: String { key }

        init(key: String, icon: String, customLabel: String? = nil) {
            self.key = key
            self.icon = icon
            self.customLabel = customLabel
        }

        var isBuiltin: Bool { key.hasPrefix("builtin:") }

        /// Название команды меню без группы — для подписи под значком.
        var menuTitle: String? {
            guard key.hasPrefix("menu:") else { return nil }
            let body = String(key.dropFirst("menu:".count))
            guard let split = body.range(of: "▸") else { return body }
            return String(body[split.upperBound...])
        }

        var label: String {
            if let customLabel, !customLabel.isEmpty { return customLabel }
            if let builtin = TunnelStore.builtinActions[key] { return L(builtin.label) }
            return menuTitle ?? key
        }

        var shortLabel: String {
            if let customLabel, !customLabel.isEmpty { return customLabel }
            if let builtin = TunnelStore.builtinActions[key] { return L(builtin.short) }
            return menuTitle ?? key
        }
    }

    /// Свои операции: подписи и подсказки — те же строки, что были у прошитых кнопок.
    static let builtinActions: [String: (label: String, short: String, help: String)] = [
        "builtin:copy": ("divider.label.copy", "divider.short.copy", "button.f5.copy"),
        "builtin:move": ("divider.label.move", "divider.short.move", "button.f6.move"),
        "builtin:delete": ("divider.label.delete", "divider.short.delete", "button.f8.delete"),
        "builtin:mkdir": ("divider.label.mkdir", "divider.short.mkdir", "button.f7.mkdir"),
        "builtin:view": ("divider.label.view", "divider.short.view", "button.f3.view"),
        "builtin:edit": ("divider.label.edit", "divider.short.edit", "button.f4.edit")
    ]

    static var defaultActions: [Action] {
        [
            Action(key: "builtin:copy", icon: "doc.on.doc"),
            Action(key: "builtin:move", icon: "arrow.right"),
            Action(key: "builtin:delete", icon: "trash"),
            Action(key: "builtin:mkdir", icon: "folder.badge.plus"),
            Action(key: "builtin:view", icon: "eye"),
            Action(key: "builtin:edit", icon: "pencil")
        ]
    }

    // MARK: - Хранение

    static let foldersKey = "tunnel.folders.v1"
    static let actionsKey = "tunnel.actions.v1"

    @Published private(set) var folders: [Folder]
    @Published private(set) var actions: [Action]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loadedFolders = Self.load([Folder].self, from: defaults, key: Self.foldersKey)
            ?? Self.defaultFolders
        // Короткоживущий значок Рабочего стола из сборки 2112: выбрать его рукой было
        // нельзя (в библиотеке его нет), значит он только из тогдашнего набора — молча
        // возвращаем привычный монитор.
        if let index = loadedFolders.firstIndex(where: {
            $0.icon == "menubar.dock.rectangle"
        }) {
            loadedFolders[index].icon = "desktopcomputer"
        }
        folders = loadedFolders
        actions = Self.load([Action].self, from: defaults, key: Self.actionsKey)
            ?? Self.defaultActions
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults,
                                           key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func saveFolders() {
        defaults.set(try? JSONEncoder().encode(folders), forKey: Self.foldersKey)
    }

    private func saveActions() {
        defaults.set(try? JSONEncoder().encode(actions), forKey: Self.actionsKey)
    }

    // MARK: - Папки: правка

    /// Добавить папку. Не папка или уже есть — честное «нет», чтобы вызывающий мог
    /// не притворяться, будто что-то произошло.
    @discardableResult
    func addFolder(path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        guard !folders.contains(where: { $0.path == path }) else { return false }
        folders.append(Folder(path: path, icon: "folder"))
        saveFolders()
        return true
    }

    /// Добавить папку на это место — так кладёт перетаскивание: куда бросили, там и стоит.
    /// Уже стоящая папка не отвергается, а переезжает на новое место.
    @discardableResult
    func addFolder(path: String, at index: Int) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        if let existing = folders.firstIndex(where: { $0.path == path }) {
            // Место вставки считалось со старой кнопкой в списке; без неё всё ниже сдвигается.
            let target = min(max(index > existing ? index - 1 : index, 0), folders.count - 1)
            moveFolder(path: path, to: target)
            return true
        }
        folders.insert(Folder(path: path, icon: "folder"), at: min(max(index, 0), folders.count))
        saveFolders()
        return true
    }

    func removeFolder(path: String) {
        folders.removeAll { $0.path == path }
        saveFolders()
    }

    /// Сдвинуть папку на шаг. За края список не рвётся — просьба просто не исполняется.
    func moveFolder(path: String, up: Bool) {
        guard let index = folders.firstIndex(where: { $0.path == path }) else { return }
        let target = up ? index - 1 : index + 1
        guard folders.indices.contains(target) else { return }
        folders.swapAt(index, target)
        saveFolders()
    }

    /// Поставить папку на место с этим номером — так кладёт перетаскивание.
    /// Мимо списка или на своё же место — ничего не происходит.
    func moveFolder(path: String, to target: Int) {
        guard let index = folders.firstIndex(where: { $0.path == path }),
              folders.indices.contains(target), index != target else { return }
        let folder = folders.remove(at: index)
        folders.insert(folder, at: target)
        saveFolders()
    }

    /// Своя подпись папке. Пустая — вернуть подпись по умолчанию.
    func setFolderLabel(path: String, label: String) {
        guard let index = folders.firstIndex(where: { $0.path == path }) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        folders[index].customLabel = trimmed.isEmpty ? nil : trimmed
        saveFolders()
    }

    func setFolderIcon(path: String, icon: String) {
        guard let index = folders.firstIndex(where: { $0.path == path }) else { return }
        folders[index].icon = icon
        saveFolders()
    }

    func resetFolders() {
        folders = Self.defaultFolders
        saveFolders()
    }

    // MARK: - Операции: правка

    /// Добавить команду меню. Ключ — «Группа▸Название», как её знает палитра. Значок —
    /// тот, что у команды в меню: «Упаковать» приходит с коробкой, а не с молнией.
    @discardableResult
    func addMenuAction(group: String, title: String, icon: String? = nil) -> Bool {
        let key = "menu:\(group)▸\(title)"
        guard !actions.contains(where: { $0.key == key }) else { return false }
        actions.append(Action(key: key, icon: icon ?? "bolt", customLabel: title))
        saveActions()
        return true
    }

    func removeAction(key: String) {
        actions.removeAll { $0.key == key }
        saveActions()
    }

    func moveAction(key: String, up: Bool) {
        guard let index = actions.firstIndex(where: { $0.key == key }) else { return }
        let target = up ? index - 1 : index + 1
        guard actions.indices.contains(target) else { return }
        actions.swapAt(index, target)
        saveActions()
    }

    func moveAction(key: String, to target: Int) {
        guard let index = actions.firstIndex(where: { $0.key == key }),
              actions.indices.contains(target), index != target else { return }
        let action = actions.remove(at: index)
        actions.insert(action, at: target)
        saveActions()
    }

    /// Своя подпись операции. Пустая — вернуть: у своих операций переводную, у команд
    /// меню — их название.
    func setActionLabel(key: String, label: String) {
        guard let index = actions.firstIndex(where: { $0.key == key }) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        actions[index].customLabel = trimmed.isEmpty ? nil : trimmed
        saveActions()
    }

    func setActionIcon(key: String, icon: String) {
        guard let index = actions.firstIndex(where: { $0.key == key }) else { return }
        actions[index].icon = icon
        saveActions()
    }

    func resetActions() {
        actions = Self.defaultActions
        saveActions()
    }
}

/// Библиотека значков для туннеля: из чего человек выбирает значок папке или операции.
///
/// Курируемый набор по разделам, а не все тысячи SF Symbols: в окне выбора должно быть
/// видно всё сразу, без поиска по чужому каталогу. Первый раздел — операции программы:
/// упаковать, распаковать, сравнить, переименовать — чтобы значок подбирался по смыслу.
/// Сверх того окно показывает значки команд из живой строки меню, которых здесь нет:
/// новая команда приносит свой значок сама.
enum TunnelIconLibrary {

    struct Section {
        /// Ключ перевода заголовка.
        let title: String
        let icons: [String]
    }

    static let sections: [Section] = [
        Section(title: "tunnel.icons.operations", icons: [
            "doc.on.doc", "arrow.right.doc.on.clipboard", "trash", "trash.slash",
            "folder.badge.plus", "doc.badge.plus", "eye", "pencil.line",
            "character.cursor.ibeam", "textformat.abc", "archivebox", "archivebox.fill",
            "doc.zipper", "shippingbox", "square.stack.3d.down.right", "scissors",
            "link", "link.badge.plus", "arrowshape.turn.up.right", "doc.on.doc.fill",
            "info.circle", "lock.rectangle", "magnifyingglass", "doc.text.magnifyingglass",
            "arrow.clockwise", "sum", "number", "arrow.left.arrow.right",
            "square.split.2x1", "square.stack", "rotate.right", "doc.richtext",
            "text.viewfinder", "photo.badge.arrow.down", "wand.and.rays", "slider.horizontal.3",
            "lock", "lock.open", "lock.shield", "lock.doc",
            "key", "tag", "paperplane", "printer",
            "square.and.arrow.up", "square.and.arrow.down", "arrow.up.doc", "arrow.down.doc",
            "tray.and.arrow.down", "tray.and.arrow.up", "checkmark.circle", "xmark.circle",
            "plus.square.dashed", "minus.square", "arrow.triangle.2.circlepath",
            "square.on.square.dashed", "arrow.uturn.backward", "arrow.uturn.forward",
            "checklist", "bolt"
        ]),
        Section(title: "tunnel.icons.view", icons: [
            "list.bullet", "rectangle.grid.1x2", "photo.on.rectangle", "square.grid.3x3",
            "circle.grid.2x2", "arrow.up.arrow.down", "tablecells", "eye.slash",
            "arrow.triangle.branch", "terminal", "waveform.path.ecg", "internaldrive",
            "tray.full", "clock.arrow.2.circlepath", "circle.lefthalf.filled", "command",
            "gearshape", "star", "pin", "rectangle.stack",
            "plus.rectangle", "xmark.rectangle", "arrow.up", "chevron.left",
            "chevron.right", "rectangle.split.2x1", "rectangle.lefthalf.inset.filled.arrow.left",
            "arrow.right.to.line", "arrow.left.to.line", "arrow.uturn.right", "arrow.right.circle",
            "questionmark.circle"
        ]),
        Section(title: "tunnel.icons.folders", icons: [
            "folder", "folder.fill", "folder.badge.person.crop", "folder.badge.gearshape",
            "tray", "house", "building.2", "briefcase",
            "graduationcap", "externaldrive", "server.rack", "desktopcomputer",
            "a.square.fill", "arrow.down.circle"
        ]),
        Section(title: "tunnel.icons.documents", icons: [
            "doc", "doc.text", "book", "books.vertical",
            "newspaper", "note.text", "pencil", "highlighter",
            "paperclip", "signature", "list.bullet.rectangle", "calendar"
        ]),
        Section(title: "tunnel.icons.media", icons: [
            "photo", "photo.stack", "camera", "paintpalette",
            "film", "video", "music.note", "waveform",
            "speaker.wave.2", "headphones", "mic", "tv"
        ]),
        Section(title: "tunnel.icons.tech", icons: [
            "chevron.left.forwardslash.chevron.right", "cpu", "memorychip", "network",
            "globe", "antenna.radiowaves.left.and.right", "cloud", "wifi",
            "iphone", "laptopcomputer", "keyboard", "printer.fill"
        ]),
        Section(title: "tunnel.icons.people", icons: [
            "person", "person.2", "heart", "gamecontroller",
            "cart", "gift", "airplane", "car",
            "wrench.and.screwdriver", "hammer", "bicycle", "fork.knife"
        ]),
        Section(title: "tunnel.icons.misc", icons: [
            "flag", "bell", "clock", "flame",
            "leaf", "moon", "sun.max", "sparkles",
            "circle", "square", "triangle", "diamond"
        ])
    ]

    /// Все значки библиотеки подряд — для проверок и старых мест.
    static var icons: [String] { sections.flatMap(\.icons) }

    /// Значки команд из живой строки меню, которых в библиотеке нет: новая команда
    /// программы приносит свой значок сама, без правки этого списка.
    @MainActor
    static func menuIcons() -> [String] {
        let known = Set(icons)
        var seen = Set<String>()
        return CommandRegistry.commands().compactMap(\.symbolName).filter { symbol in
            !known.contains(symbol) && seen.insert(symbol).inserted
        }
    }
}
