import XCTest
@testable import TotumComXLApp

/// Google Drive разрешает два файла с одним именем в папке — у нас это два элемента с одним
/// путём. Карта «путь → файл» на `uniqueKeysWithValues` роняла программу при перечитывании
/// такой папки (отчёт о падении 2026-09-25, 36 записей и 35 имён в корне Диска).
@MainActor
final class DuplicatePathsTests: XCTestCase {

    private func item(_ name: String, size: UInt64) -> FileItem {
        FileItem(path: "/д/" + name, name: name, fileExtension: "txt", size: size,
                 isDirectory: false, isHidden: false, isSymlink: false,
                 permissions: "-rw-r--r--", dateModified: Date())
    }

    func test_дваФайлаСОднимПутём_НеРонятКарту() {
        let map = PanelViewModel.metadataByPath([item("a.txt", size: 1), item("a.txt", size: 2),
                                                 item("b.txt", size: 3)])
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map["/д/a.txt"]?.size, 1, "берётся первый")
        XCTAssertEqual(map["/д/b.txt"]?.size, 3)
    }

    func test_родительскаяЗаписьНеВКарте() {
        let up = FileItem(path: "/д/..", name: "..", fileExtension: "", size: 0, isDirectory: true,
                          isHidden: false, isSymlink: false, permissions: "d", dateModified: Date())
        XCTAssertTrue(PanelViewModel.metadataByPath([up]).isEmpty)
    }
}
