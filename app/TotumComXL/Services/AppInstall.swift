import Foundation

/// «Установить»: программа (.app) копируется в папку программ — то же, что перетащить её в
/// «Программы» в Finder, только одним пунктом меню. Копирует обычное копирование программы:
/// окно хода, вопрос при совпадении имени, отмена по ⌘Z. Подпись программы при этом цела:
/// ссылки внутри фреймворков и расширенные атрибуты переносятся как есть.
enum AppInstall {
    /// Куда ставить. Проверки подставляют свою папку, чтобы не писать в настоящую.
    nonisolated(unsafe) static var applicationsFolder = "/Applications"

    /// Где программы уже установлены: там пункт не нужен.
    static var installedRoots: [String] {
        [applicationsFolder, NSHomeDirectory() + "/Applications",
         "/System/Applications", "/System/Library/CoreServices"]
    }

    /// Предлагать ли «Установить»: это программа, и лежит она не среди установленных —
    /// в смонтированном образе, в «Загрузках», где угодно ещё.
    static func canInstall(_ item: FileItem) -> Bool {
        guard item.isAppBundle else { return false }
        let path = (item.path as NSString).standardizingPath
        return !installedRoots.contains { root in
            let folder = (root as NSString).standardizingPath
            return path == folder || path.hasPrefix(folder + "/")
        }
    }
}
