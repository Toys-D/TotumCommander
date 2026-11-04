import Foundation
import SwiftUI

@MainActor
final class PanelTabsViewModel: ObservableObject {
    @Published private(set) var tabs: [PanelTab]
    @Published private(set) var activeIndex: Int = 0
    @Published var loadingTabIDs: Set<UUID> = []

    private let storageKey: String
    /// Separate key from `storageKey` on purpose: tabs saved by builds that didn't record the
    /// active tab still decode, they just come back on the first tab.
    private let activeTabIDKey: String

    var activeTab: PanelTab { tabs[min(activeIndex, max(tabs.count - 1, 0))] }

    /// Подключённые тома: по ним видно, ушла ли вкладка на внешний или сетевой диск.
    /// Подменяется в тестах.
    var mountTable: () -> [OperationDisks.Mount] = OperationDisks.mountTable

    /// Откуда уходит панель: папка и файл под курсором в ней.
    struct Departure: Equatable {
        let path: String
        let cursorPath: String?
    }

    // MARK: - Tab loading spinner

    /// Show the spinner on a tab, with a hard safety timeout.
    ///
    /// Every caller clears the flag from the tail of an async task, so a task that
    /// never finishes — a wedged connect, a listing that hangs — left the spinner
    /// turning forever and the tab looking permanently busy. The timeout guarantees
    /// the spinner always goes away; it also logs, so a stuck load leaves a trace
    /// instead of just spinning.
    func beginLoading(_ id: UUID, tag: String, timeout: TimeInterval = 30) {
        loadingTabIDs.insert(id)
        cplog("[SPIN] + \(tag) tab=\(id.uuidString.prefix(8))")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, self.loadingTabIDs.contains(id) else { return }
            cplog("[SPIN] !! TIMEOUT after \(timeout)s — force-clearing \(tag) "
                  + "tab=\(id.uuidString.prefix(8)) (the load never finished)")
            self.loadingTabIDs.remove(id)
        }
    }

    func endLoading(_ id: UUID, tag: String) {
        guard loadingTabIDs.contains(id) else { return }
        cplog("[SPIN] - \(tag) tab=\(id.uuidString.prefix(8))")
        loadingTabIDs.remove(id)
    }

    init(panelKey: String, initialPath: String) {
        storageKey = "panelTabs_\(panelKey)"
        activeTabIDKey = "panelTabs_\(panelKey)_activeTabID"
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([PanelTab].self, from: data),
           !saved.isEmpty {
            // Filter out terminal, remote, and network mount tabs — they don't persist across sessions
            let directoryTabs = saved.filter { !$0.isTerminal && !$0.isRemote && !$0.isNetworkMount }
            tabs = directoryTabs.isEmpty ? [PanelTab(path: initialPath)] : directoryTabs
        } else {
            tabs = [PanelTab(path: initialPath)]
        }

        // Restore the active tab BY IDENTITY, never by a saved index: the filtering above drops
        // terminal/remote/network tabs, so positions shift between sessions and a stored index
        // would point at a different tab (or out of range). Anything unrecognised — no record
        // yet, or the active tab was one of the dropped kinds — leaves activeIndex at 0.
        if let idString = UserDefaults.standard.string(forKey: activeTabIDKey),
           let id = UUID(uuidString: idString),
           let index = tabs.firstIndex(where: { $0.id == id }) {
            activeIndex = index
        }
    }

    // MARK: - Navigation

    func panelNavigated(to path: String, leaving departure: Departure? = nil) {
        guard !tabs[activeIndex].pinned else { return }
        guard !tabs[activeIndex].isTerminal else { return }
        guard !tabs[activeIndex].isRemote else { return }
        // Полка и Корзина — не место вкладки, а вид поверх неё: вкладка помнит последнюю
        // настоящую папку. Запомнив «/STACK», сетевая вкладка при возврате открывала полку
        // с дорогой назад из ЧУЖОЙ вкладки — и «выключить полку» уводило в TEMP.
        guard !DropStackStore.isStackPath(path), !TrashService.isTrashPath(path) else { return }
        rememberReturn(of: activeIndex, to: path, leaving: departure)
        tabs[activeIndex].path = path
        let mount = NetworkMountInfo.info(forPath: path)
        let kind = Self.kindAfterNavigation(
            current: tabs[activeIndex].kind, isMount: mount != nil,
            isNetworkBrowser: NetworkBrowserService.isNetworkPath(path))
        if kind != tabs[activeIndex].kind {
            tabs[activeIndex].kind = kind
            // Оранжевый ставили мы сами вместе с видом вкладки — вместе с ним и снимаем.
            // Свой цвет, выбранный человеком, не трогаем.
            if kind == .directory, tabs[activeIndex].colorHex == PanelTab.remoteDefaultColorHex {
                tabs[activeIndex].colorHex = nil
            }
        }
        if let net = mount {
            // Inside a mounted SMB share → "COMPUTER: folder" (e.g. "SERVER_SO: Доки").
            let leaf = (path == net.mountRoot) ? net.share : (path as NSString).lastPathComponent
            tabs[activeIndex].title = "\(net.computer): \(leaf)"
        } else if !tabs[activeIndex].isNetworkMount {
            // Normal local tab → current folder name. (A network-mount tab still at the
            // virtual browser root keeps its "Локальная сеть" title.)
            let lastComponent = (path as NSString).lastPathComponent
            tabs[activeIndex].title = lastComponent.isEmpty ? path : lastComponent
        }
        persist()
    }

    /// Корень внешнего или сетевого тома, на котором лежит путь, или корень обзора сети; nil —
    /// свой диск. По таблице томов из памяти ядра, без обращения к дискам.
    static func awayRoot(of path: String, mounts: [OperationDisks.Mount]) -> String? {
        if NetworkBrowserService.isNetworkPath(path) { return NetworkBrowserService.networkRoot }
        return mounts
            .filter { $0.point.hasPrefix("/Volumes/") && (path == $0.point || path.hasPrefix($0.point + "/")) }
            .max { $0.point.count < $1.point.count }?
            .point
    }

    /// Ушла со своего диска на внешний, сетевой или в обзор сети — запомнить, откуда и с какого
    /// файла; вернулась на свой — забыть. С одного внешнего на другой память та же: вернуться
    /// надо туда, где работа с дисками началась.
    private func rememberReturn(of index: Int, to newPath: String, leaving departure: Departure?) {
        let mounts = mountTable()
        let oldPath = tabs[index].path
        guard Self.awayRoot(of: newPath, mounts: mounts) != nil else {
            tabs[index].returnPath = nil
            tabs[index].returnCursorPath = nil
            tabs[index].openedFromTabID = nil
            return
        }
        guard Self.awayRoot(of: oldPath, mounts: mounts) == nil, tabs[index].openedFromTabID == nil else { return }
        tabs[index].returnPath = oldPath
        tabs[index].returnCursorPath = departure?.path == oldPath ? departure?.cursorPath : nil
    }

    /// Какой стать вкладке после перехода в другую папку.
    ///
    /// Вкладка сетевого тома, ушедшая на обычный диск (вверх из корня тома, по избранному,
    /// по набранному пути), обязана перестать быть сетевой. Иначе она остаётся оранжевой и с
    /// чужим именем («SERVER_SO: E»), показывая файлы диска C, — а поиск уже открытой вкладки
    /// тома идёт по пути и эту, ушедшую, не находит. Щелчок по диску в полосе томов сюда не
    /// ведёт: он открывает диск в соседней местной вкладке (`localVolumeOpensElsewhere`).
    ///
    /// Корень обзора сети — не уход: вкладка тома, вернувшаяся к списку компьютеров, ещё
    /// сетевая.
    nonisolated static func kindAfterNavigation(current: TabKind, isMount: Bool,
                                                isNetworkBrowser: Bool) -> TabKind {
        if isMount { return .networkMount }
        if current == .networkMount, !isNetworkBrowser { return .directory }
        return current
    }

    /// Щелчок по местному диску из этой вкладки: открыть диск в соседней местной, а эту
    /// оставить. Так живёт хранилище — и сетевой том так же: иначе оранжевая вкладка
    /// превращалась в обычную («dimas»), следующий щелчок по тому заводил рядом новую
    /// оранжевую, и с каждым переключением вкладок становилось на одну больше.
    nonisolated static func localVolumeOpensElsewhere(from tab: PanelTab, insideRemote: Bool) -> Bool {
        insideRemote || tab.isNetworkMount
    }

    // MARK: - Tab actions

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        activeIndex = index
        // Switching tabs is the main way the active tab changes — it has to be recorded, or
        // the next launch highlights whichever tab happens to be first while the panel loads
        // the folder the user actually left off in.
        persist()
    }

    func saveViewMode(at index: Int, mode: String) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].savedViewMode = mode
        persist()
    }

    func pinViewMode(at index: Int, mode: String) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].savedViewMode = mode
        tabs[index].viewModePinned = true
        persist()
    }

    func unpinViewMode(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].savedViewMode = nil
        tabs[index].viewModePinned = false
        persist()
    }

    func renameTab(at index: Int, to newTitle: String) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].title = newTitle
        persist()
    }

    /// Update the stored path for a specific tab (e.g. save remote current path when switching away).
    func updateTabPath(at index: Int, to newPath: String) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].path = newPath
    }

    /// Ближайшая обычная вкладка к данной — сначала слева, потом справа. Нужна, когда из
    /// вкладки хранилища щёлкают по местному диску: хранилище остаётся жить в своей вкладке,
    /// а диск открывается в соседней местной. `nil` — местных вкладок нет.
    func nearestLocalTabIndex(from index: Int) -> Int? {
        let isLocal = { (i: Int) in self.tabs.indices.contains(i) && self.tabs[i].kind == .directory }
        for step in 1..<max(tabs.count, 2) {
            if isLocal(index - step) { return index - step }
            if isLocal(index + step) { return index + step }
        }
        return nil
    }

    /// Ближайшая вкладка, которая не терминал — куда вернуться, пряча терминал.
    func nearestFileTabIndex(from index: Int) -> Int? {
        let isFile = { (i: Int) in self.tabs.indices.contains(i) && !self.tabs[i].isTerminal }
        for step in 1..<max(tabs.count, 2) {
            if isFile(index - step) { return index - step }
            if isFile(index + step) { return index + step }
        }
        return nil
    }

    func newTab(path: String, openedFrom origin: UUID? = nil) {
        var tab = PanelTab(path: path)
        tab.openedFromTabID = origin
        tabs.insert(tab, at: activeIndex + 1)
        activeIndex += 1
        persist()
    }

    func newTerminalTab(directory: String) {
        let tab = PanelTab(path: directory, kind: .terminal)
        tabs.insert(tab, at: activeIndex + 1)
        activeIndex += 1
        persist()
    }

    /// Вкладка сетевого тома, уже открытая на этом томе: один том — одна вкладка, иначе
    /// каждый вход в общую папку плодил бы новую.
    func indexOfNetworkMountTab(onVolume root: String) -> Int? {
        tabs.firstIndex { $0.isNetworkMount && ($0.path == root || $0.path.hasPrefix(root + "/")) }
    }

    func newNetworkMountTab(path: String, title: String, openedFrom origin: UUID? = nil) {
        var tab = PanelTab(path: path, title: title, kind: .networkMount)
        tab.openedFromTabID = origin
        tabs.insert(tab, at: activeIndex + 1)
        activeIndex += 1
        persist()
    }

    func newRemoteTab(title: String, connectionID: UUID) {
        let tab = PanelTab(path: "/", title: title, kind: .remote, remoteConnectionID: connectionID)
        tabs.insert(tab, at: activeIndex + 1)
        activeIndex += 1
        persist()
    }

    func closeRemoteTabs() {
        tabs.removeAll { $0.isRemote && !$0.pinned }
        // Ensure at least one tab remains — an all-remote panel would otherwise leave `tabs`
        // empty and crash on the next `activeTab` (tabs[0]).
        if tabs.isEmpty {
            tabs = [PanelTab(path: NSHomeDirectory())]
        }
        if activeIndex >= tabs.count {
            activeIndex = max(0, tabs.count - 1)
        }
        persist()
    }

    /// Что сделать панели, когда том пропал.
    struct VolumeExit: Equatable {
        /// Сделать активной эту вкладку — ту, из которой открыли вкладку диска.
        var activate: UUID?
        /// Активная вкладка вернулась на своё место — её папку надо перечитать.
        var reloadActive = false
        /// Файл, на который встать на месте возврата.
        var cursorPath: String?
        /// Вкладки, которые закрыть: открытые под диск и незакреплённые без памяти.
        var close: [UUID] = []
    }

    /// Том пропал (извлекли кнопкой, из Finder, отключили компьютер в сети). Вкладка, ушедшая на
    /// него, возвращается туда, откуда пришла, курсором на тот же файл; открытая под него — в
    /// списке на закрытие, а активной станет та, из которой её открыли. Вкладки без памяти —
    /// как раньше: незакреплённые закрываются. Пути вернувшихся вкладок меняются здесь же;
    /// переключение и закрытие делает панель (`closeTabs`).
    func leaveVolume(_ volumeRoot: String) -> VolumeExit {
        let root = normalizePath(volumeRoot)
        func isOn(_ path: String) -> Bool {
            let normalized = normalizePath(path)
            return normalized == root || normalized.hasPrefix(root + "/")
        }
        let activeID = activeTab.id
        var exit = VolumeExit()
        for index in tabs.indices where !tabs[index].isRemote && !tabs[index].isTerminal && isOn(tabs[index].path) {
            let tab = tabs[index]
            if let origin = tab.openedFromTabID,
               let originTab = tabs.first(where: { $0.id == origin }), !isOn(originTab.path) {
                exit.close.append(tab.id)
                if tab.id == activeID { exit.activate = origin }
            } else if let back = tab.returnPath, !isOn(back) {
                if tab.id == activeID {
                    exit.reloadActive = true
                    exit.cursorPath = tab.returnCursorPath
                }
                comeBack(index)
            } else if !tab.pinned {
                exit.close.append(tab.id)
            }
        }
        // Вкладка, к которой возвращаемся, по дороге к диску могла зайти в обзор сети — она
        // тоже возвращается туда, где работа началась.
        let landing = exit.activate ?? activeID
        if !exit.close.contains(landing), let index = tabs.firstIndex(where: { $0.id == landing }),
           NetworkBrowserService.isNetworkPath(tabs[index].path), tabs[index].returnPath != nil {
            if exit.activate == nil { exit.reloadActive = true }
            exit.cursorPath = tabs[index].returnCursorPath
            comeBack(index)
        }
        persist()
        return exit
    }

    /// Вернуть вкладку туда, откуда она ушла на диск, и забыть дорогу.
    private func comeBack(_ index: Int) {
        guard let back = tabs[index].returnPath else { return }
        tabs[index].path = back
        let lastComponent = (back as NSString).lastPathComponent
        tabs[index].title = lastComponent.isEmpty ? back : lastComponent
        if tabs[index].kind == .networkMount {
            tabs[index].kind = .directory
            if tabs[index].colorHex == PanelTab.remoteDefaultColorHex { tabs[index].colorHex = nil }
        }
        tabs[index].returnPath = nil
        tabs[index].returnCursorPath = nil
        tabs[index].openedFromTabID = nil
    }

    /// Закрыть вкладки по списку, не теряя активную. true — закрылась и активная: панели надо
    /// показать ту, что стала активной вместо неё.
    @discardableResult
    func closeTabs(_ ids: [UUID]) -> Bool {
        guard !ids.isEmpty else { return false }
        let activeID = activeTab.id
        tabs.removeAll { ids.contains($0.id) }
        if tabs.isEmpty { tabs = [PanelTab(path: NSHomeDirectory())] }
        if let index = tabs.firstIndex(where: { $0.id == activeID }) {
            activeIndex = index
            persist()
            return false
        }
        activeIndex = min(activeIndex, tabs.count - 1)
        persist()
        return true
    }

    func closeTab(at index: Int) {
        guard tabs.count > 1, index >= 0 && index < tabs.count else { return }
        guard !tabs[index].pinned else { return }
        tabs.remove(at: index)
        if activeIndex >= tabs.count {
            activeIndex = tabs.count - 1
        } else if activeIndex > index {
            activeIndex -= 1
        }
        persist()
    }

    func togglePin(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        tabs[index].pinned.toggle()
        persist()
    }

    func closeOthers(keeping index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        let kept = tabs[index]
        // Kill terminal processes for tabs being closed
        for (i, tab) in tabs.enumerated() where i != index && !tab.pinned && tab.isTerminal {
            TerminalProcessRegistry.shared.terminate(tabID: tab.id)
        }
        var newTabs = tabs.enumerated().compactMap { i, tab -> PanelTab? in
            if i == index || tab.pinned { return tab }
            return nil
        }
        if newTabs.isEmpty { newTabs = [kept] }
        tabs = newTabs
        activeIndex = tabs.firstIndex(where: { $0.id == kept.id }) ?? 0
        persist()
    }

    func closeAllUnpinned() {
        // Kill terminal processes for unpinned terminal tabs being closed
        for tab in tabs where !tab.pinned && tab.isTerminal {
            // Don't kill the active tab if it's the only one left and unpinned
            TerminalProcessRegistry.shared.terminate(tabID: tab.id)
        }
        let pinned = tabs.filter { $0.pinned }
        if pinned.isEmpty {
            // Keep at least the active tab
            let kept = tabs[activeIndex]
            tabs = [kept]
            activeIndex = 0
        } else {
            let activeID = tabs[activeIndex].id
            tabs = pinned
            activeIndex = tabs.firstIndex(where: { $0.id == activeID }) ?? 0
        }
        persist()
    }

    func setTabColor(at index: Int, colorHex: String?) {
        guard index >= 0 && index < tabs.count else { return }
        tabs[index].colorHex = colorHex
        persist()
    }

    func moveTab(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0 && source < tabs.count,
              destination >= 0 && destination < tabs.count else { return }
        let movedTab = tabs.remove(at: source)
        tabs.insert(movedTab, at: destination)
        if activeIndex == source {
            activeIndex = destination
        } else if source < activeIndex && destination >= activeIndex {
            activeIndex -= 1
        } else if source > activeIndex && destination <= activeIndex {
            activeIndex += 1
        }
        persist()
    }

    func relocatePaths(fromVolumeRoot volumeRoot: String, to replacementPath: String) {
        let normalizedRoot = normalizePath(volumeRoot)
        let normalizedReplacement = normalizePath(replacementPath)
        guard normalizedRoot != normalizedReplacement else { return }

        var changed = false
        for index in tabs.indices {
            let tabPath = normalizePath(tabs[index].path)
            guard tabPath == normalizedRoot || tabPath.hasPrefix(normalizedRoot + "/") else {
                continue
            }
            tabs[index].path = normalizedReplacement
            let lastComponent = (normalizedReplacement as NSString).lastPathComponent
            tabs[index].title = lastComponent.isEmpty ? normalizedReplacement : lastComponent
            changed = true
        }

        if changed {
            persist()
        }
    }

    // MARK: - Persistence

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(tabs) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        if tabs.indices.contains(activeIndex) {
            UserDefaults.standard.set(tabs[activeIndex].id.uuidString, forKey: activeTabIDKey)
        }
    }
}
