import Foundation

/// Куда ведёт «..» из папки, в которую вошли с полки.
///
/// Полка — не место, а список: папка на ней лежит по своему настоящему пути. Войти в неё
/// с полки — значит оказаться в настоящей папке, и «..» оттуда вело в её настоящего
/// родителя, а не обратно на полку. Человек же пришёл с полки и ждёт вернуться на полку.
///
/// Правило простое: пока панель стоит в той папке, в которую вошли с полки, или где-то
/// внутри неё, полка помнится; вышли за её пределы любым другим путём — забывается.
/// «..» из самой той папки ведёт на полку. Из вложенной — как обычно, на уровень выше:
/// и так шаг за шагом до той папки, а из неё уже на полку.
enum ShelfReturn {

    /// Считать ли этот переход входом с полки в её папку. Только когда панель стоит на
    /// полке и идёт в папку, которая на этой полке лежит: переход по адресу или во
    /// вкладку тоже уходит с полки, но полкой не считается.
    static func entry(onShelf: Bool, destination: String, shelved: [String]) -> String? {
        guard onShelf, shelved.contains(destination) else { return nil }
        return destination
    }

    /// Ведёт ли «..» отсюда на полку.
    static func leadsBackToShelf(currentPath: String, entry: String?) -> Bool {
        guard let entry, !entry.isEmpty else { return false }
        return normalized(currentPath) == normalized(entry)
    }

    /// Помнить ли полку после перехода в `destination`: да, пока остаёмся внутри той
    /// папки, в которую с полки вошли.
    static func keepsEntry(after destination: String, entry: String?) -> Bool {
        guard let entry, !entry.isEmpty else { return false }
        let target = normalized(destination)
        let root = normalized(entry)
        return target == root || target.hasPrefix(root + "/")
    }

    private static func normalized(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return trimmed
    }
}
