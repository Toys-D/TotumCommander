import XCTest
@testable import TotumComXLApp

/// Куда лечь тому, что бросили в панель.
///
/// Это была жалоба: выделяешь файлы, тащишь на «..» — и они копируются в ТУ ЖЕ папку,
/// а не наверх. Строку «..» отсекала проверка `name != ".."` во всех трёх видах списка,
/// цель выходила пустой, а пустая цель — это текущая папка.
final class PanelDropTargetTests: XCTestCase {

    private func item(_ name: String, path: String, isDirectory: Bool = true) -> FileItem {
        FileItem(path: path, name: name, fileExtension: "", size: 0, isDirectory: isDirectory,
                 isHidden: false, isSymlink: false, permissions: "", dateModified: Date())
    }

    /// Главное: «..» — цель, и в её пути лежит папка уровнем выше.
    func test_двеТочки_ЭтоЦельИЭтоУровеньВыше() {
        let up = item("..", path: "/Users/dimas/Documents")
        XCTAssertTrue(PanelDropTarget.isDroppable(item: up, insideArchive: false))
        XCTAssertEqual(PanelDropTarget.destination(folder: up,
                                                   currentPath: "/Users/dimas/Documents/TEMP"),
                       "/Users/dimas/Documents")
    }

    func test_обычнаяПапка_Цель() {
        let folder = item("Проекты", path: "/Users/dimas/Документы/Проекты")
        XCTAssertTrue(PanelDropTarget.isDroppable(item: folder, insideArchive: false))
    }

    func test_файлНеЦель() {
        let file = item("отчёт.pdf", path: "/tmp/отчёт.pdf", isDirectory: false)
        XCTAssertFalse(PanelDropTarget.isDroppable(item: file, insideArchive: false))
    }

    /// Внутри архива «..» занята своим делом — распаковать наружу; вторым смыслом её не
    /// нагружаем.
    func test_внутриАрхива_ДвеТочкиНеЦель() {
        let up = item("..", path: "/tmp/архив")
        XCTAssertFalse(PanelDropTarget.isDroppable(item: up, insideArchive: true))
        let folder = item("вложенная", path: "вложенная")
        XCTAssertTrue(PanelDropTarget.isDroppable(item: folder, insideArchive: true),
                      "обычная папка внутри архива целью остаётся")
    }

    func test_поНомеруСтроки() {
        let items = [item("..", path: "/Users/dimas"),
                     item("Папка", path: "/Users/dimas/Документы/Папка"),
                     item("файл.txt", path: "/Users/dimas/Документы/файл.txt", isDirectory: false)]
        XCTAssertEqual(PanelDropTarget.folder(at: 0, in: items, insideArchive: false)?.path,
                       "/Users/dimas")
        XCTAssertEqual(PanelDropTarget.folder(at: 1, in: items, insideArchive: false)?.name, "Папка")
        XCTAssertNil(PanelDropTarget.folder(at: 2, in: items, insideArchive: false), "файл — не цель")
        XCTAssertNil(PanelDropTarget.folder(at: 99, in: items, insideArchive: false), "нет такой строки")
        XCTAssertNil(PanelDropTarget.folder(at: -1, in: items, insideArchive: false))
    }

    /// Мимо строк — значит в текущую папку, как и было.
    func test_безЦели_ТекущаяПапка() {
        XCTAssertEqual(PanelDropTarget.destination(folder: nil, currentPath: "/tmp/здесь"),
                       "/tmp/здесь")
    }
}
