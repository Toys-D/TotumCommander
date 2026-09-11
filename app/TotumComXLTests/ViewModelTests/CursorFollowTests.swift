import XCTest
@testable import TotumComXLApp

/// Когда список подкручивается к курсору.
///
/// Это была жалоба: листаешь список вниз, курсор стоит на «..», и раз в пятнадцать
/// секунд — на такте перекраски — список прыгает обратно к курсору.
final class CursorFollowTests: XCTestCase {

    func test_переездКурсора_ПрокручиваетСразу() {
        var follow = CursorFollow()
        XCTAssertTrue(follow.step(wanted: true, canScroll: true))
        XCTAssertFalse(follow.pending, "просьба исполнена")
    }

    /// Главное: обычное обновление вида прокрутку не трогает, сколько бы их ни пришло.
    func test_обновлениеБезПереезда_ПрокруткуНеТрогает() {
        var follow = CursorFollow()
        for _ in 0..<50 {
            XCTAssertFalse(follow.step(wanted: false, canScroll: true))
        }
    }

    /// Список ещё пуст — идти некуда; просьба ждёт файлов и исполняется один раз.
    func test_когдаИдтиНекуда_ПросьбаЖдётФайлов() {
        var follow = CursorFollow()
        XCTAssertFalse(follow.step(wanted: true, canScroll: false))
        XCTAssertTrue(follow.pending)
        XCTAssertFalse(follow.step(wanted: false, canScroll: false), "всё ещё некуда")
        XCTAssertTrue(follow.step(wanted: false, canScroll: true), "файлы пришли — идём")
        XCTAssertFalse(follow.step(wanted: false, canScroll: true), "и только один раз")
    }

    /// Смена папки — тоже повод: курсор может стоять далеко внизу списка.
    func test_сменаПапки_ЭтоТожеПовод() {
        var follow = CursorFollow()
        XCTAssertTrue(follow.step(wanted: true, canScroll: true))
        XCTAssertFalse(follow.step(wanted: false, canScroll: true))
        XCTAssertTrue(follow.step(wanted: true, canScroll: true), "новая папка — снова идём")
    }
}
