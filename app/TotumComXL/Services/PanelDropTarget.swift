import Foundation

/// Куда лечь тому, что бросили в панель.
///
/// «..» — это папка уровнем выше, и бросок на неё значит «положи туда»: так это в Total
/// Commander, так этого и ждут. Раньше строка «..» целью не считалась вовсе — во всех трёх
/// видах списка её отсекала проверка `name != ".."`, — и файлы оставались в текущей папке:
/// человек тащил их наверх, а они копировались на месте.
///
/// Исключение одно — архив. Внутри него «..» уже занята своим делом: бросок на неё
/// распаковывает записи наружу, в папку рядом с архивом. Второй смысл ей там не нужен.
///
/// Правило живёт здесь, а не в каждом виде списка, именно потому, что видов три: краткий,
/// подробный и эскизы. Раздельные проверки — это три случая разойтись.
enum PanelDropTarget {

    /// Годится ли эта строка в цель для броска.
    static func isDroppable(item: FileItem, insideArchive: Bool) -> Bool {
        guard item.isDirectory else { return false }
        if item.name == ".." { return !insideArchive }
        return true
    }

    /// Папка под курсором мыши — если на неё можно бросать.
    static func folder(at index: Int, in items: [FileItem], insideArchive: Bool) -> FileItem? {
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        return isDroppable(item: item, insideArchive: insideArchive) ? item : nil
    }

    /// Путь, куда кладём: папка под курсором, а если её нет — текущая.
    ///
    /// У «..» в `path` лежит как раз папка уровнем выше, поэтому отдельного разбора для
    /// неё не нужно — достаточно перестать её отбрасывать.
    static func destination(folder: FileItem?, currentPath: String) -> String {
        folder?.path ?? currentPath
    }
}
