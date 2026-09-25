import XCTest

@testable import TotumComXLApp

/// Системный вопрос «разрешить доступ к папке» выходил ДО первого окна программы: панель
/// читала запомненную папку прямо в своей инициализации, а окно показывалось позже. Человек
/// видел окно про Документы раньше, чем саму программу, и не понимал, чьё оно и о чём.
final class ProtectedFolderStartupTests: XCTestCase {

    private let home = "/Users/кто-то"

    private func waits(_ path: String) -> Bool {
        PanelViewModel.needsVisibleWindowBeforeReading(path, home: home)
    }

    func test_охраняемыеПапкиЖдутОкна() {
        XCTAssertTrue(waits("/Users/кто-то/Desktop"))
        XCTAssertTrue(waits("/Users/кто-то/Documents/Проект"))
        XCTAssertTrue(waits("/Users/кто-то/Downloads"))
        XCTAssertTrue(waits("/Users/кто-то/Library/Mobile Documents/com~apple~CloudDocs"))
    }

    func test_съёмныеИСетевыеТомаТоже() {
        XCTAssertTrue(waits("/Volumes/Флешка"))
        XCTAssertTrue(waits("/Volumes/SERVER_SO/Доки"))
    }

    func test_обычныеПапкиЧитаютсяСразу() {
        // Всё остальное должно работать как раньше — без задержки на такт.
        XCTAssertFalse(waits("/Users/кто-то"))
        XCTAssertFalse(waits("/Users/кто-то/Projects/code"))
        XCTAssertFalse(waits("/tmp/что-то"))
        XCTAssertFalse(waits("/Applications"))
    }

    func test_похожееИмяНеСчитается() {
        // «Documents-старые» — не «Documents».
        XCTAssertFalse(waits("/Users/кто-то/Documents-старые"))
        XCTAssertFalse(waits("/Users/кто-то/DesktopПапка"))
    }

    func test_чужойДомашнийКаталогНеПутается() {
        XCTAssertFalse(waits("/Users/другой/Documents"))
    }
}
