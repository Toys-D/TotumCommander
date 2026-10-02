import AppKit

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

/// Ячейка списка, умеющая рисовать рамку «сюда можно бросить».
@MainActor
protocol DropRingCell: AnyObject {
    var isDropTarget: Bool { get set }
}

/// Рамка «сюда можно бросить» на папке под перетаскиваемым файлом — в кратком виде и в
/// миниатюрах.
///
/// Рамка — свойство вида ячейки, а виды ячеек переиспользуются под разные файлы. Раньше её
/// снимали по номеру позиции, с того вида, что стоит там СЕЙЧАС. Перезагрузка списка посреди
/// переноса (перекраска по свежести раз в 15 с, изменения в папке) уносила вид с рамкой на
/// другой файл, и там рамка оставалась навсегда, перескакивая при каждом удалении. Теперь
/// ячейка решает сама при каждой настройке, а смена цели проходит по всем ячейкам списка.
enum DropRing {
    /// Рамка — только на той самой папке: та же позиция и тот же путь. Одной позиции мало:
    /// после перезагрузки на ней может стоять уже другой файл.
    static func shows(index: Int, path: String, targetIndex: Int?, targetPath: String?) -> Bool {
        index == targetIndex && path == targetPath
    }

    /// Привести рамки всех ячеек списка к цели: видимым — по правилу, остальным (ждущим
    /// переиспользования внутри списка) — снять.
    @MainActor
    static func apply(in collectionView: NSCollectionView, shows: (IndexPath) -> Bool) {
        var decided = Set<ObjectIdentifier>()
        for item in collectionView.visibleItems() {
            guard let cell = item.view as? DropRingCell else { continue }
            decided.insert(ObjectIdentifier(item.view))
            let should = collectionView.indexPath(for: item).map(shows) ?? false
            if cell.isDropTarget != should { cell.isDropTarget = should }
        }
        for view in collectionView.subviews where !decided.contains(ObjectIdentifier(view)) {
            if let cell = view as? DropRingCell, cell.isDropTarget { cell.isDropTarget = false }
        }
    }
}

