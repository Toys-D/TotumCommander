import AppKit

/// Контекстное меню файлов и папок — такое, каким его собрал человек.
///
/// Меню программы росло годами, и в нём три десятка пунктов: тому, кто десять раз на дню копирует
/// путь, приходится каждый раз проходить взглядом мимо распаковки, меток и хранилищ. Здесь человек
/// собирает меню сам: убирает что угодно — хоть всё, — добавляет любую команду программы из общего
/// списка (их полторы сотни, все они и так есть в строке меню), раскладывает по основной части и
/// по дополнительной под кнопкой «Ещё», задаёт порядок и ставит разделители.
///
/// Пока человек ничего не трогал, оба списка пусты и меню выглядит ровно так, как всегда, —
/// «По умолчанию» возвращает именно это состояние.
///
/// Имена записей трёх видов: штатный пункт меню зовётся ключом своей строки
/// (`context.rename`) — он не меняется при смене языка; команда строки меню — своим устойчивым
/// именем (`cmd:menuPack:`, см. [CommandRegistry.stableID]); разделитель — [separatorID],
/// и его в списке может быть сколько угодно.
@MainActor
final class ContextMenuLayout: ObservableObject {

    static let shared = ContextMenuLayout(defaults: underTest ? testDefaults : .standard)

    /// Проверки не смеют трогать настоящие настройки: своё меню человек собирал руками, а
    /// прогон тестов затирал бы его — так однажды уже пропал нарисованный курсор. Под XCTest
    /// полка своя и чистая на каждый прогон.
    private nonisolated static var underTest: Bool { NSClassFromString("XCTestCase") != nil }

    private nonisolated static let testDefaults: UserDefaults = {
        let suite = "fcxl.contextMenu.tests"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }()

    /// Основная часть меню в порядке, который задал человек. Пусто — меню как было всегда.
    static let mainKey = "contextMenu.main.v1"
    /// Дополнительная часть — под кнопкой «Ещё».
    static let extraKey = "contextMenu.extra.v1"
    /// Меню собрано человеком. Отдельно от списка нарочно: пустое меню — тоже его выбор,
    /// и по одной лишь пустоте списка его не отличить от «ничего не трогал».
    static let explicitKey = "contextMenu.custom.v1"

    /// Разделитель. Имя нарочно не уникально: разделителей в меню несколько.
    static let separatorID = "—"

    /// Имя самой строки «Ещё» — по нему её узнают и меню, и каталог.
    nonisolated static let moreID = "context.more"

    @Published private(set) var main: [String]
    @Published private(set) var extra: [String]
    /// Основная часть задана явно: показывать ровно её, ничего не добавляя от себя.
    @Published private(set) var isExplicit: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        main = defaults.stringArray(forKey: Self.mainKey) ?? []
        extra = defaults.stringArray(forKey: Self.extraKey) ?? []
        isExplicit = defaults.bool(forKey: Self.explicitKey)
    }

    /// Человек что-то менял — меню собирается по спискам, а не по-старому.
    var isCustomised: Bool { isExplicit || !extra.isEmpty }

    /// Что показывать в настройках: пока человек не трогал основную часть — нынешнее меню,
    /// за вычетом того, что он уже отправил под «Ещё».
    var shownMain: [String] {
        isExplicit ? main : ContextMenuCatalogue.defaultOrder.filter { !extra.contains($0) }
    }

    func contains(_ id: String) -> Bool { main.contains(id) || extra.contains(id) }

    // MARK: - Правка

    /// Записать основную часть явно — первый же шаг правки уводит от «как было».
    private func materialize() {
        guard !isExplicit else { return }
        setMain(shownMain)
    }

    /// Записать основную часть. Само по себе это и значит «меню собрано человеком»:
    /// список задан, и программа больше ничего в него не добавляет от себя.
    func setMain(_ ids: [String]) {
        main = ids
        defaults.set(ids, forKey: Self.mainKey)
        guard !isExplicit else { return }
        isExplicit = true
        defaults.set(true, forKey: Self.explicitKey)
    }

    func setExtra(_ ids: [String]) {
        extra = ids
        defaults.set(ids, forKey: Self.extraKey)
    }

    /// Добавить запись в конец нужной части. Пункт, уже стоящий в меню, не удваивается —
    /// кроме разделителя: их ставят по нескольку.
    func add(_ id: String, toExtra: Bool) {
        materialize()
        if id != Self.separatorID, contains(id) { return }
        if toExtra { setExtra(extra + [id]) } else { setMain(main + [id]) }
    }

    /// Убрать запись из меню совсем. Убрать можно всё, включая последний пункт: пустое меню —
    /// это тоже ответ, и «По умолчанию» вернёт прежнее.
    func remove(at index: Int, fromExtra: Bool) {
        materialize()
        var list = fromExtra ? extra : main
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        if fromExtra { setExtra(list) } else { setMain(list) }
    }

    /// Сдвинуть запись на шаг внутри своей части. За края список не рвётся.
    func move(at index: Int, up: Bool, inExtra: Bool) {
        materialize()
        var list = inExtra ? extra : main
        let target = up ? index - 1 : index + 1
        guard list.indices.contains(index), list.indices.contains(target) else { return }
        list.swapAt(index, target)
        if inExtra { setExtra(list) } else { setMain(list) }
    }

    /// Перенести запись из одной части в другую — в конец принимающей.
    func transfer(at index: Int, fromExtra: Bool) {
        materialize()
        var source = fromExtra ? extra : main
        guard source.indices.contains(index) else { return }
        let id = source.remove(at: index)
        if fromExtra {
            setExtra(source)
            setMain(main + [id])
        } else {
            setMain(source)
            setExtra(extra + [id])
        }
    }

    /// Вернуть меню к тому виду, с каким программа пришла.
    func reset() {
        isExplicit = false
        defaults.set(false, forKey: Self.explicitKey)
        main = []
        defaults.set([String](), forKey: Self.mainKey)
        setExtra([])
    }
}

/// Штатные пункты меню файлов и папок — те, что сборщик меню ставит верхним уровнем.
///
/// Порядок здесь тот же, в каком их ставит `buildFileContextMenu`, и за это отвечает проверка:
/// она собирает настоящее меню и сверяет имена. Вложенных пунктов (внутри «Инструменты файла»,
/// «Метки», «Создать ссылку») тут нет нарочно: их не переставить в подменю, а нужны они наверху —
/// человек берёт ту же команду из общего списка команд программы, там она есть.
enum ContextMenuCatalogue {

    struct Entry: Identifiable, Equatable {
        let id: String
        let symbol: String
        var title: String { L(id) }
    }

    /// Меню файлов и папок, как оно выглядит без правок человека, — с разделителями.
    static let defaultOrder: [String] = [
        "menu.selectSameType",
        ContextMenuLayout.separatorID,
        "context.open",
        "context.openWith",
        "vault.lock.menu",
        "vault.unlock.menu",
        "vault.forgetTouchID.menu",
        "vault.enableTouchID.menu",
        "context.diskImage.panel",
        "context.diskImage.finder",
        "context.enterAppBundle",
        "context.revealInFinder",
        "context.fileTools",
        ContextMenuLayout.separatorID,
        "context.tags",
        "stack.remove",
        "stack.clear",
        "stack.add",
        ContextMenuLayout.separatorID,
        "context.view",
        "context.edit",
        "context.rename",
        "context.multiRename",
        ContextMenuLayout.separatorID,
        "context.copy",
        "context.cut",
        "context.paste",
        "context.delete",
        ContextMenuLayout.separatorID,
        "context.pack",
        "context.unpack",
        "context.packInPlace",
        ContextMenuLayout.separatorID,
        "context.copyFilePath",
        "context.createLink",
        "context.followSymlink",
        "context.sendTo",
        "context.openInTerminal",
        ContextMenuLayout.separatorID,
        "context.changeAttributes",
        "context.properties",
    ]

    /// Значок пункта — тот же, что стоит в самом меню.
    static let symbols: [String: String] = [
        "menu.selectSameType": "square.on.square.dashed",
        "context.open": "arrow.right.circle",
        "context.openWith": "arrow.up.forward.app",
        "vault.lock.menu": "lock.fill",
        "vault.unlock.menu": "lock.open",
        "vault.forgetTouchID.menu": "touchid",
        "vault.enableTouchID.menu": "touchid",
        "context.enterAppBundle": "folder",
        "context.revealInFinder": "magnifyingglass",
        "context.fileTools": "wrench.and.screwdriver",
        "context.tags": "tag",
        "stack.remove": "tray.and.arrow.up",
        "stack.clear": "tray",
        "stack.add": "tray.and.arrow.down",
        "context.view": "eye",
        "context.edit": "pencil.line",
        "context.rename": "character.cursor.ibeam",
        "context.multiRename": "pencil.and.list.clipboard",
        "context.copy": "doc.on.doc",
        "context.cut": "scissors",
        "context.paste": "doc.on.clipboard",
        "context.delete": "trash",
        "context.pack": "archivebox",
        "context.unpack": "archivebox.fill",
        "context.packInPlace": "archivebox",
        "context.copyFilePath": "arrow.right.doc.on.clipboard",
        "context.createLink": "link",
        "context.followSymlink": "arrow.uturn.right",
        "context.sendTo": "paperplane",
        "context.openInTerminal": "terminal",
        "context.changeAttributes": "slider.horizontal.3",
        "context.properties": "info.circle",
        "context.diskImage.panel": "externaldrive",
        "context.diskImage.finder": "macwindow",
    ]

    /// Все штатные пункты — для списка в настройках, без разделителей.
    static var all: [Entry] {
        defaultOrder.filter { $0 != ContextMenuLayout.separatorID }
            .map { Entry(id: $0, symbol: symbols[$0] ?? "square") }
    }

    static func entry(_ id: String) -> Entry? { all.first { $0.id == id } }

    /// Значок для любой записи раскладки — штатного пункта, команды строки меню, разделителя.
    static func symbol(for id: String) -> String {
        if id == ContextMenuLayout.separatorID { return "minus" }
        return symbols[id] ?? "command"
    }
}

/// Строка «Ещё» — со спрятанной частью меню в кармане.
///
/// Меню рисует наше собственное окно, и спрятанное оно берёт прямо отсюда: дописывает
/// список на месте, не закрываясь. Раньше «Ещё» собирало меню заново и показывало его
/// второй раз — со стороны это выглядело как мигание, будто щёлкнул мимо.
final class ContextMoreMenuItem: NSMenuItem {

    /// Спрятанные строки в том порядке, в каком они встанут под «Ещё».
    var hiddenRows: [NSMenuItem] = []

    convenience init(hiddenRows: [NSMenuItem]) {
        self.init(title: L(ContextMenuLayout.moreID), action: nil, keyEquivalent: "")
        self.hiddenRows = hiddenRows
        identifier = NSUserInterfaceItemIdentifier(ContextMenuLayout.moreID)
        if let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
            image.isTemplate = true
            self.image = image
        }
    }
}

/// Чистый расчёт раскладки: что остаётся сразу, что уходит под «Ещё».
enum ContextMenuSplit {

    /// Строка построенного меню: разделитель или пункт со своим именем.
    enum Entry: Equatable {
        case separator
        case item(id: String?)
    }

    /// - Returns: номера строк для основной части и для дополнительной.
    ///   Основная сохраняет свой порядок и группировку; висячие и сдвоенные разделители
    ///   схлопываются — иначе от вынутого пункта оставалась бы пустая полоса.
    ///   Дополнительная идёт в порядке, который задал человек.
    static func split(entries: [Entry], extra: [String]) -> (main: [Int], extra: [Int]) {
        let hidden = Set(extra)
        var mainRaw: [Int] = []
        var extraByID: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            switch entry {
            case .separator:
                mainRaw.append(index)
            case .item(let id):
                if let id, hidden.contains(id) { extraByID[id] = index }
                else { mainRaw.append(index) }
            }
        }
        // Разделители, оставшиеся без соседей, убираются.
        var main: [Int] = []
        for index in mainRaw {
            if entries[index] == .separator {
                guard let last = main.last, entries[last] != .separator else { continue }
            }
            main.append(index)
        }
        while let last = main.last, entries[last] == .separator { main.removeLast() }
        return (main, extra.compactMap { extraByID[$0] })
    }

    /// Убрать висячие и сдвоенные разделители из собранного человеком списка: два подряд или
    /// разделитель с краю — это пустая полоса, а не деление.
    static func tidy(_ rows: [NSMenuItem]) -> [NSMenuItem] {
        var result: [NSMenuItem] = []
        for row in rows {
            if row.isSeparatorItem {
                guard let last = result.last, !last.isSeparatorItem else { continue }
            }
            result.append(row)
        }
        while let last = result.last, last.isSeparatorItem { result.removeLast() }
        return result
    }
}
