import XCTest
@testable import TotumComXLApp

/// «..» из папки, в которую вошли с полки, ведёт обратно на полку.
///
/// Это была жалоба: положил папку на полку, зашёл в неё с полки, нажал «..» — и оказался
/// в настоящем родителе папки, а не на полке, откуда пришёл.
final class ShelfReturnTests: XCTestCase {

    private let shelved = ["/Users/dimas/Проекты/Сайт", "/Volumes/Диск/Фото"]

    func test_входСПолкиВЕёПапку_Запоминается() {
        XCTAssertEqual(ShelfReturn.entry(onShelf: true, destination: "/Users/dimas/Проекты/Сайт",
                                         shelved: shelved),
                       "/Users/dimas/Проекты/Сайт")
    }

    /// Уйти с полки можно и по адресу, и во вкладку — это не вход в папку полки.
    func test_уходСПолкиНеВЕёПапку_НеСчитается() {
        XCTAssertNil(ShelfReturn.entry(onShelf: true, destination: "/Users/dimas/Другое",
                                       shelved: shelved))
        XCTAssertNil(ShelfReturn.entry(onShelf: false, destination: "/Users/dimas/Проекты/Сайт",
                                       shelved: shelved), "панель и не стояла на полке")
    }

    /// Главное: из той самой папки «..» ведёт на полку.
    func test_изПапкиПолки_НаверхЗначитНаПолку() {
        XCTAssertTrue(ShelfReturn.leadsBackToShelf(currentPath: "/Users/dimas/Проекты/Сайт",
                                                   entry: "/Users/dimas/Проекты/Сайт"))
        XCTAssertTrue(ShelfReturn.leadsBackToShelf(currentPath: "/Users/dimas/Проекты/Сайт/",
                                                   entry: "/Users/dimas/Проекты/Сайт"),
                      "косая на конце не мешает")
    }

    /// Из вложенной папки «..» — как обычно, на уровень выше; на полку — только из той,
    /// в которую с неё вошли.
    func test_изВложенной_НаверхКакОбычно() {
        let entry = "/Users/dimas/Проекты/Сайт"
        XCTAssertFalse(ShelfReturn.leadsBackToShelf(currentPath: entry + "/css", entry: entry))
        XCTAssertTrue(ShelfReturn.keepsEntry(after: entry + "/css", entry: entry),
                      "но полка при этом помнится")
        XCTAssertTrue(ShelfReturn.keepsEntry(after: entry + "/css/дальше", entry: entry))
    }

    /// Вышли за пределы папки любым другим путём — полка забыта.
    func test_уходЗаПределы_ПолкаЗабывается() {
        let entry = "/Users/dimas/Проекты/Сайт"
        XCTAssertFalse(ShelfReturn.keepsEntry(after: "/Users/dimas/Проекты", entry: entry),
                       "настоящий родитель — уже не внутри")
        XCTAssertFalse(ShelfReturn.keepsEntry(after: "/Users/dimas/Проекты/Сайт2", entry: entry),
                       "похожее имя — не вложенность")
        XCTAssertFalse(ShelfReturn.keepsEntry(after: "/tmp", entry: entry))
    }

    func test_безЗаписи_НичегоНеПомнится() {
        XCTAssertFalse(ShelfReturn.leadsBackToShelf(currentPath: "/x", entry: nil))
        XCTAssertFalse(ShelfReturn.keepsEntry(after: "/x", entry: nil))
        XCTAssertFalse(ShelfReturn.leadsBackToShelf(currentPath: "", entry: ""))
    }
}
