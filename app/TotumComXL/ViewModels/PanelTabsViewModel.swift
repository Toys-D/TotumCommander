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

    func panelNavigated(to path: String) {
        guard !tabs[activeIndex].pinned else { return }
        guard !tabs[activeIndex].isTerminal else { return }
        guard !tabs[activeIndex].isRemote else { return }
        // Полка и Корзина — не место вкладки, а вид поверх неё: вкладка помнит последнюю
        // настоящую папку. Запомнив «/STACK», сетевая вкладка при возврате открывала полку
        // с дорогой назад из ЧУЖОЙ вкладки — и «выключить полку» уводило в TEMP.
        guard !DropStackStore.isStackPath(path), !TrashService.isTrashPath(path) else { return }
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
            let leaf = (path == net.mountRoot) ? net.share : URL(fileURLWithPath: path).lastPathComponent
            tabs[activeIndex].title = "\(net.computer): \(leaf)"
        } else if !tabs[activeIndex].isNetworkMount {
            // Normal local tab → current folder name. (A network-mount tab still at the
            // virtual browser root keeps its "Локальная сеть" title.)
            let lastComponent = URL(fileURLWithPath: path).lastPathComponent
            tabs[activeIndex].title = lastComponent.isEmpty ? path : lastComponent
        }
        persist()
    }

    /// Какой стать вкладке после перехода в другую папку.
    ///
    /// Вкладка сетевого тома, ушедшая на обычный диск, обязана перестать быть сетевой.
    /// Иначе она остаётся оранжевой и с чужим именем («SERVER_SO: E»), показывая файлы
    /// диска C, — а щелчок по тому в полосе дисков заводит рядом ВТОРУЮ такую же: поиск
    /// уже открытой вкладки идёт по пути тома и эту, ушедшую, не находит.
    ///
    /// Корень обзора сети — не уход: вкладка тома, вернувшаяся к списку компьютеров, ещё
    /// сетевая.
    nonisolated static func kindAfterNavigation(current: TabKind, isMount: Bool,
                                                isNetworkBrowser: Bool) -> TabKind {
        if isMount { return .networkMount }
        if current == .networkMount, !isNetworkBrowser { return .directory }
        return current
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

    func newTab(path: String) {
        let tab = PanelTab(path: path)
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

    func newNetworkMountTab(path: String, title: String) {
        let tab = PanelTab(path: path, title: title, kind: .networkMount)
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

    /// Close all tabs whose path is on the given volume root (used when ejecting a volume).
    /// Returns true if the active tab was closed and the caller should reload the panel.
    @discardableResult
    func closeTabsOnVolume(_ volumeRoot: String) -> Bool {
        let normRoot = normalizePath(volumeRoot)
        let activeID = tabs[activeIndex].id
        var activeClosed = false

        tabs.removeAll { tab in
            guard !tab.pinned else { return false }
            let normPath = normalizePath(tab.path)
            let isOnVolume = normPath == normRoot || normPath.hasPrefix(normRoot + "/")
            if isOnVolume && tab.id == activeID { activeClosed = true }
            return isOnVolume
        }

        // Ensure at least one tab remains
        if tabs.isEmpty {
            tabs = [PanelTab(path: NSHomeDirectory())]
            activeClosed = true
        }

        if activeIndex >= tabs.count {
            activeIndex = max(0, tabs.count - 1)
        }
        persist()
        return activeClosed
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
            let lastComponent = URL(fileURLWithPath: normalizedReplacement).lastPathComponent
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
