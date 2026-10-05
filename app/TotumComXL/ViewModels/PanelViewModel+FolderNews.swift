import Foundation

/// Знак «новое внутри» у подпапок открытой папки — по ответам Spotlight (см. FolderNews).
extension PanelViewModel {

    /// Начать спрашивать Spotlight. Зовёт панель на экране.
    func watchFolderNews() {
        guard folderNewsQuery == nil else { return }
        let query = FolderNewsQuery()
        query.onUpdate = { [weak self] folder, news in
            self?.applyFolderNews(news, in: folder)
        }
        folderNewsQuery = query
        refreshFolderNews()
    }

    /// Следить за открытой папкой — или перестать и погасить знаки. После каждого перехода
    /// и после правки настроек: срок новизны, включение знака, само правило.
    func refreshFolderNews() {
        guard let query = folderNewsQuery else { return }
        let folder = currentPath
        guard FolderNews.isEnabled, let minutes = FolderNews.rule()?.freshMinutes,
              !insideArchive, !insideRemote, !state.insideTrash, !state.insideStack,
              !state.insideNetworkBrowser, !currentPathIsSlowVolume,
              !Self.isVirtualLocation(folder), FolderNews.canWatch(folder)
        else {
            query.stop()
            applyFolderNews([:], in: folder)
            return
        }
        query.follow(folder, period: minutes * 60)
    }

    /// Ответ Spotlight — в папки списка. Ответ о папке, из которой панель уже ушла,
    /// отбрасывается.
    func applyFolderNews(_ news: [String: FolderNews.Inside], in folder: String) {
        guard folder == currentPath else { return }
        folderNews = news
        folderNewsFolder = folder
        let patched = withFolderNews(allItems, in: folder)
        // Одним присваиванием: каждое присваивание списка заново его фильтрует.
        if patched != allItems { allItems = patched }
    }

    /// Те же элементы с датами нового внутри — по последнему ответу о этой папке.
    func withFolderNews(_ items: [FileItem], in folder: String) -> [FileItem] {
        guard folder == folderNewsFolder else { return items }
        return items.map { item in
            guard item.isDirectory, item.name != ".." else { return item }
            let news = folderNews[item.path]
            guard item.newestInside != news?.newest || item.newInsideCount != (news?.count ?? 0)
            else { return item }
            var copy = item
            copy.newestInside = news?.newest
            copy.newInsideCount = news?.count ?? 0
            return copy
        }
    }
}
