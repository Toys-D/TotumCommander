import AppKit

/// Контекстные меню туннеля — AppKit, в стиле программы: значок у каждого пункта,
/// подсветка цветом акцента.
///
/// SwiftUI-меню на macOS значки из Label не рисует, и после переезда туннеля на SwiftUI
/// меню пропорций стало голым текстом. Здесь меню собираются так же, как контекстное
/// меню панели, — той же addStyledItem, тем же applyAccentStyle.
@MainActor
enum TunnelContextMenu {

    private static var tunnel: TunnelStore { TunnelStore.shared }

    // MARK: - Пропорции и обмен панелей

    /// Меню пустого места туннеля. Картинки говорят, что делает строка: две половины
    /// прямоугольника, и ЗАЛИТАЯ половина — та панель, которой достаётся место.
    static func split(for view: CenterDividerView) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.addStyledItem(title: L("divider.center"), symbolName: "rectangle.split.2x1") {
            view.onSetRatio?(0.5)
        }
        menu.addItem(.separator())
        let ratios: [(String, CGFloat, String)] = [
            ("30 / 70", 0.3, "rectangle.righthalf.filled"),
            ("40 / 60", 0.4, "rectangle.righthalf.inset.filled"),
            ("60 / 40", 0.6, "rectangle.lefthalf.inset.filled"),
            ("70 / 30", 0.7, "rectangle.lefthalf.filled")
        ]
        for (title, ratio, symbol) in ratios {
            menu.addStyledItem(title: title, symbolName: symbol) { view.onSetRatio?(ratio) }
        }
        menu.addItem(.separator())
        menu.addStyledItem(title: L("divider.swap"), symbolName: "arrow.left.arrow.right") {
            view.onSwap()
        }
        // Стрелка показывает, куда ИДЁТ папка: левая — в правую панель, и обратно.
        menu.addStyledItem(title: L("divider.syncLeft"), symbolName: "arrow.right.to.line") {
            view.onSyncLeftToRight?()
        }
        menu.addStyledItem(title: L("divider.syncRight"), symbolName: "arrow.left.to.line") {
            view.onSyncRightToLeft?()
        }
        menu.applyAccentStyle()
        return menu
    }

    // MARK: - Папка

    static func folder(_ folder: TunnelStore.Folder, activePanelPath: String) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        menu.addStyledItem(title: L("tunnel.menu.changeIcon"), symbolName: "square.grid.2x2") {
            pickIcon(current: folder.icon) { tunnel.setFolderIcon(path: folder.path, icon: $0) }
        }
        menu.addStyledItem(title: L("tunnel.menu.rename"), symbolName: "character.cursor.ibeam") {
            askLabel(current: folder.label) { tunnel.setFolderLabel(path: folder.path, label: $0) }
        }
        menu.addStyledItem(title: L("tunnel.menu.moveUp"), symbolName: "arrow.up") {
            tunnel.moveFolder(path: folder.path, up: true)
        }
        menu.items.last?.isEnabled = tunnel.folders.first?.path != folder.path
        menu.addStyledItem(title: L("tunnel.menu.moveDown"), symbolName: "arrow.down") {
            tunnel.moveFolder(path: folder.path, up: false)
        }
        menu.items.last?.isEnabled = tunnel.folders.last?.path != folder.path
        menu.addStyledItem(title: L("tunnel.menu.removeFolder"), symbolName: "minus.circle",
                           isDestructive: true) {
            tunnel.removeFolder(path: folder.path)
        }
        menu.addItem(.separator())
        // Папка, в которой человек прямо сейчас стоит, — самый частый кандидат в туннель:
        // добавляется одним пунктом, без окон и перетаскиваний.
        menu.addStyledItem(title: L("tunnel.menu.addActiveFolder"), symbolName: "folder.badge.plus") {
            _ = tunnel.addFolder(path: activePanelPath)
        }
        menu.addStyledItem(title: L("tunnel.menu.resetFolders"), symbolName: "arrow.counterclockwise") {
            tunnel.resetFolders()
        }
        menu.applyAccentStyle()
        return menu
    }

    // MARK: - Операция

    static func action(_ action: TunnelStore.Action) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        menu.addStyledItem(title: L("tunnel.menu.changeIcon"), symbolName: "square.grid.2x2") {
            pickIcon(current: action.icon) { tunnel.setActionIcon(key: action.key, icon: $0) }
        }
        menu.addStyledItem(title: L("tunnel.menu.rename"), symbolName: "character.cursor.ibeam") {
            askLabel(current: action.label) { tunnel.setActionLabel(key: action.key, label: $0) }
        }
        menu.addStyledItem(title: L("tunnel.menu.moveUp"), symbolName: "arrow.up") {
            tunnel.moveAction(key: action.key, up: true)
        }
        menu.items.last?.isEnabled = tunnel.actions.first?.key != action.key
        menu.addStyledItem(title: L("tunnel.menu.moveDown"), symbolName: "arrow.down") {
            tunnel.moveAction(key: action.key, up: false)
        }
        menu.items.last?.isEnabled = tunnel.actions.last?.key != action.key
        menu.addStyledItem(title: L("tunnel.menu.removeAction"), symbolName: "minus.circle",
                           isDestructive: true) {
            tunnel.removeAction(key: action.key)
        }
        menu.addItem(.separator())
        menu.addItem(addActionItem())
        menu.addStyledItem(title: L("tunnel.menu.resetActions"), symbolName: "arrow.counterclockwise") {
            tunnel.resetActions()
        }
        menu.applyAccentStyle()
        return menu
    }

    /// «Добавить операцию» — команды из строки меню, разложенные по её же группам, каждая со
    /// своим значком. Список берётся из того же реестра, что и палитра (Cmd+P): новая
    /// команда программы попадает сюда сама, без отдельной регистрации.
    private static func addActionItem() -> NSMenuItem {
        let parent = NSMenuItem(title: L("tunnel.menu.addAction"), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        let groups = CommandRegistry.commands().reduce(into: [String: [PaletteCommand]]()) {
            $0[$1.group, default: []].append($1)
        }
        let submenu = NSMenu(title: "")
        for group in groups.keys.sorted() {
            let groupItem = NSMenuItem(title: group, action: nil, keyEquivalent: "")
            let groupMenu = NSMenu(title: group)
            for command in groups[group] ?? [] {
                groupMenu.addStyledItem(title: command.title,
                                        symbolName: command.symbolName ?? "bolt") {
                    _ = tunnel.addMenuAction(group: group, title: command.title,
                                             icon: command.symbolName)
                }
            }
            groupItem.submenu = groupMenu
            submenu.addItem(groupItem)
        }
        parent.submenu = submenu
        return parent
    }

    // MARK: - Окна

    private static func pickIcon(current: String, apply: @escaping (String) -> Void) {
        fcxlPresentModal {
            guard let icon = TunnelIconPickerController.show(current: current) else { return }
            apply(icon)
        }
    }

    /// Своя подпись под значком: длинное название команды в узком туннеле режется, а
    /// «Упаковать» или «Zip» помещается. Пустая подпись возвращает исходную.
    private static func askLabel(current: String, apply: @escaping (String) -> Void) {
        fcxlPresentModal {
            guard let label = DialogService.shared.showTextInput(
                title: L("tunnel.rename.title"), message: L("tunnel.rename.message"),
                defaultValue: current) else { return }
            apply(label)
        }
    }
}
