import AppKit

/// Подсказки в правом меню: пункт, ради которого этот файл или это место и существует,
/// подсвечивается зелёным — как «Распаковать» у архива. Человек ещё не прочитал меню, а уже
/// видит, что здесь можно сделать.
///
/// Правило — чистая функция от обстановки, чтобы её проверял тест; сама раскраска — отдельный
/// проход по готовому меню, до applyAccentStyle, который берёт цвет из заголовка.
enum ContextMenuHints {
    static let color = NSColor.systemGreen

    struct Situation: Equatable {
        /// Файл под курсором — архив (и мы не внутри архива).
        var isArchive = false
        /// Панель показывает полку.
        var onShelf = false
        /// Панель показывает Корзину.
        var inTrash = false
        /// Под курсором файл, а не папка.
        var isFile = false
        /// Есть программа, которая откроет этот файл двойным щелчком.
        var hasOpener = true
        /// Символическая ссылка, у которой известна цель.
        var isSymlink = false
        var isVault = false
        var vaultUnlocked = false
        /// В буфере лежат файлы.
        var clipboardHasFiles = false
        /// Сколько файлов выбрано (или один под курсором).
        var selectionCount = 1
        /// Под курсором PDF или картинка — для них есть инструменты; и сколько таких выбрано.
        var isPDF = false
        var pdfCount = 0
        var isImage = false
        var imageCount = 0
    }

    /// Имена пунктов, которые стоит подсветить.
    static func tinted(_ s: Situation) -> Set<String> {
        var ids = Set<String>()
        if s.isArchive { ids.insert("context.unpack") }
        if s.onShelf { ids.formUnion(["stack.remove", "stack.clear"]) }
        if s.inTrash { ids.insert("trash.restore") }
        if s.isFile, !s.hasOpener { ids.insert("context.openWith") }
        if s.isSymlink { ids.insert("context.followSymlink") }
        if s.isVault { ids.insert(s.vaultUnlocked ? "vault.lock.menu" : "vault.unlock.menu") }
        if s.clipboardHasFiles { ids.insert("context.paste") }
        if s.selectionCount > 1 { ids.insert("context.multiRename") }
        // Инструменты: зелёная дверь в подменю, а внутри — только то, что стало возможным
        // из-за выбора: слить несколько PDF, собрать PDF из нескольких картинок. Красить
        // всё подменю разом значило бы не подсказать ничего.
        if s.isPDF || s.isImage { ids.insert("context.fileTools") }
        if s.pdfCount > 1 { ids.insert("context.pdfMerge") }
        if s.imageCount > 1 { ids.insert("context.pdfMake") }
        return ids
    }

    /// Покрасить пункты с этими именами, и в подменю тоже: раскладка могла унести пункт
    /// под «Ещё», а подсказка от этого не пропадает.
    static func apply(_ ids: Set<String>, to menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { apply(ids, to: submenu) }
            guard let id = item.identifier?.rawValue, ids.contains(id) else { continue }
            item.attributedTitle = NSAttributedString(string: item.title,
                                                      attributes: [.foregroundColor: color])
        }
    }

    /// Есть ли у файла программа по умолчанию. Для папок, архивов и облака вопрос не
    /// стоит — считаем, что есть, чтобы не подсвечивать «Открыть с помощью» впустую.
    static func hasOpener(forFileAt path: String) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path)) != nil
    }
}
