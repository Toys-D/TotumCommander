import AppKit

/// Команды строки меню — все, что программа умеет, и ничего кроме.
///
/// Строка меню — единственный источник для палитры (Cmd+P) и для операций туннеля:
/// команды, которой нет в меню, для них не существует. Раньше в меню была десятая часть
/// умений программы — остальное жило только на клавишах, кнопках и в контекстном меню,
/// и палитра о нём молчала.
///
/// Каждый обработчик зовёт ровно тот код, что и прежние пути: F5 из меню — это тот же
/// handleCopy(), что из футера; «Показать в Finder» — тот же метод панели, что и в
/// контекстном меню. Поэтому меню не может разойтись с тем, что делают кнопки.
@MainActor
extension MainWindowController {

    private var panel: PanelViewController { splitVC.activePanelVC }
    private var vm: PanelViewModel { splitVC.activePanelViewModel }
    private var tabs: PanelTabsViewModel {
        panel.side == .left ? splitVC.leftTabsVM : splitVC.rightTabsVM
    }

    // MARK: - Файл

    @objc func menuOpen(_ sender: Any?) { panel.openCursorItem() }
    @objc func menuOpenWith(_ sender: Any?) { panel.openWithDialogForCursor() }
    @objc func menuRevealInFinder(_ sender: Any?) { panel.revealTargetsInFinder() }

    /// Папка под курсором — в ней; иначе текущая, как из фонового меню панели.
    @objc func menuOpenInTerminal(_ sender: Any?) {
        let cursor = panel.cursorFile
        let path = (cursor?.isDirectory == true ? cursor?.path : nil) ?? vm.currentPath
        panelDidRequestOpenInTerminal(panel, path: path)
    }

    /// F9 панель принимает сама; из меню — та же дверь, что у кнопки футера.
    @objc func menuSearch(_ sender: Any?) { triggerSearch() }
    @objc func menuMkdir(_ sender: Any?) { handleMkdir() }
    @objc func menuCreateTextFile(_ sender: Any?) { panelDidRequestCreateTextFile(panel) }
    @objc func menuView(_ sender: Any?) { handleView() }
    @objc func menuEdit(_ sender: Any?) { handleEdit() }
    /// F2 — как в панели: пока идёт перенос, F2 отправляет его в очередь; иначе переименование.
    @objc func menuRename(_ sender: Any?) {
        if ProgressController.canSendToQueue {
            ProgressController.sendFirstToQueue()
        } else {
            handleRename()
        }
    }
    @objc func menuCopy(_ sender: Any?) { handleCopy() }
    @objc func menuMove(_ sender: Any?) { handleMove() }
    @objc func menuDelete(_ sender: Any?) { handleDelete() }

    @objc func menuDeletePermanently(_ sender: Any?) {
        let items = panel.selectedOrCursorItems()
        guard !items.isEmpty else { return }
        panelDidRequestDeletePermanently(panel, items: items)
    }

    @objc func menuPack(_ sender: Any?) {
        panelDidRequestPack(panel, items: panel.selectedOrCursorItems())
    }

    /// Та же дорога и то же правило, что у Cmd+F9 и контекстного меню: все выделенные
    /// архивы, иначе — тот, что под курсором.
    @objc func menuUnpack(_ sender: Any?) {
        let archives = panel.selectedOrCursorItems().filter { vm.isArchiveFile($0) }
        guard !archives.isEmpty else { return }
        panelDidRequestExtract(panel, items: archives)
    }

    @objc func menuPackInPlace(_ sender: Any?) {
        let formats = ArchiveFormat.allCases
        guard let tag = (sender as? NSMenuItem)?.tag, formats.indices.contains(tag) else { return }
        panelDidRequestPackInPlace(panel, items: panel.selectedOrCursorItems(),
                                   format: formats[tag])
    }

    @objc func menuCreateSymlink(_ sender: Any?) {
        guard let item = panel.cursorFile else { return }
        panelDidRequestCreateSymlink(panel, item: item)
    }

    @objc func menuCreateAlias(_ sender: Any?) {
        guard let item = panel.cursorFile else { return }
        panelDidRequestCreateAlias(panel, item: item)
    }

    @objc func menuCreateHardlink(_ sender: Any?) {
        guard let item = panel.cursorFile else { return }
        panelDidRequestCreateHardlink(panel, item: item)
    }

    @objc func menuCopyFilePath(_ sender: Any?) { panel.copyCursorPathToClipboard() }
    @objc func menuCopyFolderPath(_ sender: Any?) { panel.copyFolderPathToClipboard() }

    @objc func menuChangeAttributes(_ sender: Any?) {
        let items = panel.selectedOrCursorItems()
        guard !items.isEmpty else { return }
        panelDidRequestChangeAttributes(panel, items: items)
    }

    @objc func menuProperties(_ sender: Any?) {
        guard let item = panel.cursorFile else { return }
        panelDidRequestProperties(panel, item: item)
    }

    // MARK: - Вкладки

    @objc func menuNewTab(_ sender: Any?) { panel.handleNewTab() }
    @objc func menuCloseTab(_ sender: Any?) { panel.handleCloseTab(tabs.activeIndex) }

    @objc func menuCloseOtherTabs(_ sender: Any?) {
        tabs.closeOthers(keeping: tabs.activeIndex)
        panel.handleSelectTab(tabs.activeIndex)
    }

    @objc func menuCloseUnpinnedTabs(_ sender: Any?) {
        tabs.closeAllUnpinned()
        panel.handleSelectTab(tabs.activeIndex)
    }

    @objc func menuTogglePinTab(_ sender: Any?) { tabs.togglePin(at: tabs.activeIndex) }

    @objc func menuRenameTab(_ sender: Any?) {
        let index = tabs.activeIndex
        guard tabs.tabs.indices.contains(index) else { return }
        let current = tabs.tabs[index].title
        fcxlPresentModal { [weak self] in
            guard let self,
                  let name = DialogService.shared.showTextInput(
                    title: L("tabs.rename"), message: "", defaultValue: current),
                  !name.isEmpty else { return }
            tabs.renameTab(at: index, to: name)
        }
    }

    @objc func menuNextTab(_ sender: Any?) { stepTab(by: 1) }
    @objc func menuPreviousTab(_ sender: Any?) { stepTab(by: -1) }

    private func stepTab(by step: Int) {
        let count = tabs.tabs.count
        guard count > 1 else { return }
        panel.handleSelectTab((tabs.activeIndex + step + count) % count)
    }

    /// tag — номер цвета в наборе вкладок; −1 — снять цвет.
    @objc func menuTabColor(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag else { return }
        let hex = TabColor.presets.indices.contains(tag) ? TabColor.presets[tag].hex : nil
        tabs.setTabColor(at: tabs.activeIndex, colorHex: hex)
    }

    // MARK: - Правка

    @objc func menuClearSelection(_ sender: Any?) { vm.clearSelection() }

    // MARK: - Вид

    static let menuViewModes: [ViewMode] = [.detailed, .brief, .thumbnails]
    static let menuSortFields: [PanelSortField] = [
        .name, .fileExtension, .type, .size, .dateModified, .dateCreated, .dateAdded,
        .owner, .permissions
    ]

    @objc func menuViewMode(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag,
              Self.menuViewModes.indices.contains(tag) else { return }
        vm.viewMode = Self.menuViewModes[tag]
    }

    /// Выбрать поле — по возрастанию; направление меняет отдельный пункт.
    @objc func menuSortBy(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag,
              Self.menuSortFields.indices.contains(tag) else { return }
        let field = Self.menuSortFields[tag]
        guard vm.sortField != field else { return }
        vm.toggleSort(by: field)
    }

    @objc func menuSortDescending(_ sender: Any?) { vm.toggleSort(by: vm.sortField) }

    @objc func menuToggleColumn(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag,
              PanelColumn.allCases.indices.contains(tag) else { return }
        let column = PanelColumn.allCases[tag]
        vm.setColumnVisibility(column, isVisible: !vm.visibleColumns.contains(column))
    }

    @objc func menuToggleHiddenFiles(_ sender: Any?) { toggleHiddenFiles(sender) }
    @objc func menuToggleBranchView(_ sender: Any?) { vm.toggleBranchView() }
    @objc func menuRefresh(_ sender: Any?) { vm.loadDirectory(resetCursor: false) }
    @objc func menuFolderSizes(_ sender: Any?) { vm.calculateAllFolderSizes() }
    /// Та же дверь, что у кнопки футера и Cmd+`: куда открыть — решает настройка.
    @objc func menuTerminal(_ sender: Any?) { handleTerminalShortcut() }
    @objc func menuMonitor(_ sender: Any?) { toggleMonitor(sender) }
    @objc func menuDiskInfo(_ sender: Any?) { showDiskInfo(sender) }
    @objc func menuTrash(_ sender: Any?) { openTrash(sender) }
    @objc func menuShelf(_ sender: Any?) { openDropStack(sender) }
    @objc func menuQueue(_ sender: Any?) { queuePanelController.toggle() }
    @objc func menuToggleTheme(_ sender: Any?) { toggleTheme(sender) }

    // MARK: - Переход

    @objc func menuGoUp(_ sender: Any?) { vm.goUp() }
    @objc func menuGoBack(_ sender: Any?) { vm.goBack() }
    @objc func menuGoForward(_ sender: Any?) { vm.goForward() }

    /// Путь лежит в representedObject: одна команда на все папки перехода.
    @objc func menuGoFolder(_ sender: Any?) {
        guard let path = (sender as? NSMenuItem)?.representedObject as? String else { return }
        splitVC.openQuickLink(path)
    }

    @objc func menuEnterAppBundle(_ sender: Any?) { panel.enterAppBundleAtCursor() }
    @objc func menuFollowSymlink(_ sender: Any?) { panel.followSymlinkAtCursor() }

    @objc func menuSwitchPanel(_ sender: Any?) {
        splitVC.setActivePanel(panel.side == .left ? .right : .left)
    }

    @objc func menuSwapPanels(_ sender: Any?) { splitVC.swapPanels() }
    @objc func menuSyncLeftToRight(_ sender: Any?) { splitVC.syncLeftToRight() }
    @objc func menuSyncRightToLeft(_ sender: Any?) { splitVC.syncRightToLeft() }

    /// tag — доля левой панели в процентах.
    @objc func menuSetRatio(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, tag > 0 else { return }
        splitVC.setSplitRatio(CGFloat(tag) / 100, animated: true)
    }

    // MARK: - Инструменты

    @objc func menuToggleTag(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag,
              FinderTag.allCases.indices.contains(tag) else { return }
        panel.toggleTagOnTargets(FinderTag.allCases[tag])
    }

    @objc func menuClearTags(_ sender: Any?) { panel.clearTagsOnTargets() }
    @objc func menuRecognizeText(_ sender: Any?) { recognizeText(in: vm) }
    @objc func menuCleanMetadata(_ sender: Any?) { cleanPhotoMetadata(in: vm) }
    @objc func menuVaultToggle(_ sender: Any?) { panel.lockOrUnlockVaultAtCursor() }
    /// Та же дорога, что у F8 на .app: список всего, что осталось от программы.
    @objc func menuUninstall(_ sender: Any?) {
        guard let item = panel.cursorFile, AppUninstaller.programBundle(at: item.path) != nil else { return }
        uninstallApplication(at: item.path)
    }
    @objc func menuDiskImageOtherWay(_ sender: Any?) { panel.openDiskImageOtherWay() }

    // MARK: - Доступность

    /// Клавиатура у панели: ею правит список файлов, а не терминал и не поле ввода.
    private var panelOwnsKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        if responder is NSText { return false }      // переименование, крошки, терминал-поле
        return responder.isDescendant(of: panel.view)
    }

    /// Проверка идёт из-за нажатой клавиши, а не из-за открытого меню.
    private var validatingForKeystroke: Bool {
        NSApplication.shared.currentEvent?.type == .keyDown
    }

    /// Доступен ли пункт сейчас; nil — пункт не отсюда, пусть решает прежний код.
    ///
    /// Клавиша без ⌘ (F5, ^B, ^U) действует, только пока клавиатура у панели: иначе F-клавиши
    /// и ^B уходили бы из терминала и из поля переименования в файловые операции. Из меню
    /// мышью команда доступна всегда — там она относится к активной панели.
    func validateMenuCommand(_ item: NSMenuItem) -> Bool? {
        guard let action = item.action, Self.menuCommandSelectors.contains(action) else { return nil }
        if validatingForKeystroke, !item.keyEquivalent.isEmpty,
           !item.keyEquivalentModifierMask.contains(.command), !panelOwnsKeyboard {
            return false
        }
        let cursor = panel.cursorFile
        let local = isLocalPanel(vm)
        let targets = panel.selectedOrCursorItems()

        switch action {
        case #selector(menuOpen(_:)), #selector(menuView(_:)), #selector(menuProperties(_:)),
             #selector(menuCopyFilePath(_:)), #selector(menuRename(_:)):
            return cursor != nil
        case #selector(menuOpenWith(_:)):
            return cursor != nil && !vm.insideArchive
        case #selector(menuEdit(_:)):
            return cursor.map { !$0.isDirectory } ?? false
        case #selector(menuRevealInFinder(_:)):
            return cursor != nil && local
        case #selector(menuOpenInTerminal(_:)):
            return local && !vm.state.insideTrash && !vm.state.insideNetworkBrowser
        case #selector(menuMkdir(_:)), #selector(menuCreateTextFile(_:)):
            return !vm.insideArchive
        case #selector(menuCopy(_:)), #selector(menuMove(_:)), #selector(menuDelete(_:)),
             #selector(menuDeletePermanently(_:)):
            return !targets.isEmpty
        case #selector(menuPack(_:)), #selector(menuPackInPlace(_:)):
            return !vm.insideArchive && !targets.isEmpty
        case #selector(menuUnpack(_:)):
            return !vm.insideArchive && targets.contains { vm.isArchiveFile($0) }
        case #selector(menuCreateSymlink(_:)), #selector(menuCreateAlias(_:)):
            return cursor != nil && local
        case #selector(menuCreateHardlink(_:)):
            return local && (cursor.map { !$0.isDirectory } ?? false)
        case #selector(menuChangeAttributes(_:)):
            return local && !vm.state.insideTrash && !targets.isEmpty
        case #selector(menuCopyFolderPath(_:)), #selector(menuNewTab(_:)),
             #selector(menuTabColor(_:)), #selector(menuRefresh(_:)),
             #selector(menuTerminal(_:)), #selector(menuDiskInfo(_:)), #selector(menuTrash(_:)),
             #selector(menuShelf(_:)), #selector(menuQueue(_:)), #selector(menuToggleTheme(_:)),
             #selector(menuGoUp(_:)), #selector(menuGoFolder(_:)), #selector(menuSwitchPanel(_:)),
             #selector(menuSwapPanels(_:)), #selector(menuSyncLeftToRight(_:)),
             #selector(menuSyncRightToLeft(_:)), #selector(menuViewMode(_:)),
             #selector(menuSortBy(_:)), #selector(menuSortDescending(_:)),
             #selector(menuToggleHiddenFiles(_:)), #selector(menuRenameTab(_:)),
             #selector(menuSearch(_:)):
            refreshState(of: item)
            return true
        case #selector(menuCloseTab(_:)):
            let index = tabs.activeIndex
            return tabs.tabs.count > 1 && tabs.tabs.indices.contains(index)
                && !tabs.tabs[index].pinned
        case #selector(menuCloseOtherTabs(_:)), #selector(menuCloseUnpinnedTabs(_:)),
             #selector(menuNextTab(_:)), #selector(menuPreviousTab(_:)):
            return tabs.tabs.count > 1
        case #selector(menuTogglePinTab(_:)):
            guard tabs.tabs.indices.contains(tabs.activeIndex) else { return false }
            let tab = tabs.tabs[tabs.activeIndex]
            item.title = tab.pinned ? L("tabs.unpin") : L("tabs.pin")
            return !tab.isTerminal
        case #selector(menuClearSelection(_:)):
            return !vm.selectedPaths.isEmpty
        case #selector(menuToggleColumn(_:)):
            refreshState(of: item)
            return vm.viewMode == .detailed
        case #selector(menuToggleBranchView(_:)), #selector(menuFolderSizes(_:)):
            refreshState(of: item)
            return local
        case #selector(menuMonitor(_:)):
            item.state = panel.isMonitorMode ? .on : .off
            return true
        case #selector(menuGoBack(_:)):
            return vm.canGoBack
        case #selector(menuGoForward(_:)):
            return vm.canGoForward
        case #selector(menuEnterAppBundle(_:)):
            return cursor.map { vm.isAppBundle($0) } ?? false
        case #selector(menuFollowSymlink(_:)):
            return local && cursor?.isSymlink == true && cursor?.symlinkTarget != nil
        case #selector(menuSetRatio(_:)):
            item.state = abs(splitVC.currentSplitRatio - CGFloat(item.tag) / 100) < 0.005 ? .on : .off
            return true
        case #selector(menuToggleTag(_:)):
            let paths = targets.map(\.path)
            let tag = FinderTag.allCases.indices.contains(item.tag) ? FinderTag.allCases[item.tag] : nil
            item.state = (tag.map { t in !paths.isEmpty && paths.allSatisfy { FinderTagService.hasTag(t, at: $0) } } ?? false)
                ? .on : .off
            return local && !paths.isEmpty
        case #selector(menuClearTags(_:)):
            return local && !targets.isEmpty
        case #selector(menuRecognizeText(_:)):
            return local && (cursor.map { TextRecognitionService.canReadText(in: $0.path) } ?? false)
        case #selector(menuCleanMetadata(_:)):
            return local && (cursor.map { PhotoMetadataService.hasMetadata(path: $0.path) } ?? false)
        case #selector(menuVaultToggle(_:)):
            guard let cursor, local, VaultService.isVault(cursor.path) else { return false }
            item.title = VaultService.isUnlocked(cursor.path) ? L("vault.lock.menu")
                                                              : L("vault.unlock.menu")
            return true
        case #selector(menuUninstall(_:)):
            guard let cursor, local, !vm.state.insideTrash, !vm.state.insideStack,
                  !vm.state.insideNetworkBrowser,
                  !TrashService.isInsideTrashFolder(cursor.path) else { return false }
            return AppUninstaller.programBundle(at: cursor.path) != nil
        case #selector(menuDiskImageOtherWay(_:)):
            guard let cursor, !cursor.isDirectory, !vm.insideArchive,
                  DiskImageOpenMode.isDiskImage(cursor.path) else { return false }
            item.title = L(DiskImageOpenMode.chosen.opposite == .panel ? "context.diskImage.panel"
                                                                        : "context.diskImage.finder")
            return true
        default:
            return nil
        }
    }

    /// Галочки у переключателей: режим вида, поле сортировки, столбцы, скрытые, ветвь.
    private func refreshState(of item: NSMenuItem) {
        switch item.action {
        case #selector(menuViewMode(_:)):
            item.state = Self.menuViewModes.indices.contains(item.tag)
                && Self.menuViewModes[item.tag] == vm.viewMode ? .on : .off
        case #selector(menuSortBy(_:)):
            item.state = Self.menuSortFields.indices.contains(item.tag)
                && Self.menuSortFields[item.tag] == vm.sortField ? .on : .off
        case #selector(menuSortDescending(_:)):
            item.state = vm.sortAscending ? .off : .on
        case #selector(menuToggleColumn(_:)):
            item.state = PanelColumn.allCases.indices.contains(item.tag)
                && vm.visibleColumns.contains(PanelColumn.allCases[item.tag]) ? .on : .off
        case #selector(menuToggleHiddenFiles(_:)):
            item.state = showHiddenFiles ? .on : .off
        case #selector(menuToggleBranchView(_:)):
            item.state = vm.isBranchView ? .on : .off
        default:
            break
        }
    }

    /// Все команды этого файла — чтобы прежний validateMenuItem знал, какие пункты наши.
    static let menuCommandSelectors: Set<Selector> = [
        #selector(menuSearch(_:)),
        #selector(menuOpen(_:)), #selector(menuOpenWith(_:)), #selector(menuRevealInFinder(_:)),
        #selector(menuOpenInTerminal(_:)), #selector(menuMkdir(_:)), #selector(menuCreateTextFile(_:)),
        #selector(menuView(_:)), #selector(menuEdit(_:)), #selector(menuRename(_:)),
        #selector(menuCopy(_:)), #selector(menuMove(_:)), #selector(menuDelete(_:)),
        #selector(menuDeletePermanently(_:)), #selector(menuPack(_:)), #selector(menuUnpack(_:)),
        #selector(menuPackInPlace(_:)), #selector(menuCreateSymlink(_:)), #selector(menuCreateAlias(_:)),
        #selector(menuCreateHardlink(_:)), #selector(menuCopyFilePath(_:)), #selector(menuCopyFolderPath(_:)),
        #selector(menuChangeAttributes(_:)), #selector(menuProperties(_:)),
        #selector(menuNewTab(_:)), #selector(menuCloseTab(_:)), #selector(menuCloseOtherTabs(_:)),
        #selector(menuCloseUnpinnedTabs(_:)), #selector(menuTogglePinTab(_:)), #selector(menuRenameTab(_:)),
        #selector(menuNextTab(_:)), #selector(menuPreviousTab(_:)), #selector(menuTabColor(_:)),
        #selector(menuClearSelection(_:)),
        #selector(menuViewMode(_:)), #selector(menuSortBy(_:)), #selector(menuSortDescending(_:)),
        #selector(menuToggleColumn(_:)), #selector(menuToggleHiddenFiles(_:)),
        #selector(menuToggleBranchView(_:)), #selector(menuRefresh(_:)), #selector(menuFolderSizes(_:)),
        #selector(menuTerminal(_:)), #selector(menuMonitor(_:)), #selector(menuDiskInfo(_:)),
        #selector(menuTrash(_:)), #selector(menuShelf(_:)), #selector(menuQueue(_:)),
        #selector(menuToggleTheme(_:)),
        #selector(menuGoUp(_:)), #selector(menuGoBack(_:)), #selector(menuGoForward(_:)),
        #selector(menuGoFolder(_:)), #selector(menuEnterAppBundle(_:)), #selector(menuFollowSymlink(_:)),
        #selector(menuSwitchPanel(_:)), #selector(menuSwapPanels(_:)), #selector(menuSyncLeftToRight(_:)),
        #selector(menuSyncRightToLeft(_:)), #selector(menuSetRatio(_:)),
        #selector(menuToggleTag(_:)), #selector(menuClearTags(_:)), #selector(menuRecognizeText(_:)),
        #selector(menuCleanMetadata(_:)), #selector(menuVaultToggle(_:)), #selector(menuDiskImageOtherWay(_:)),
        #selector(menuUninstall(_:))
    ]
}

/// «Отправить» строится в момент открытия: службы общего доступа зависят от файла под
/// курсором, и заранее их не перечислить.
final class MenuSendToDelegate: NSObject, NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            guard let controller = (app.keyWindow ?? app.mainWindow)?.windowController
                    as? MainWindowController,
                  let item = controller.splitVC.activePanelVC.cursorFile,
                  !controller.splitVC.activePanelViewModel.insideArchive else { return }
            let built = controller.splitVC.activePanelVC.buildSendToMenu(for: item)
            let entries = built.items
            built.removeAllItems()
            for entry in entries { menu.addItem(entry) }
        }
    }
}
