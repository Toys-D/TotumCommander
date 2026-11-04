import XCTest

@testable import TotumComXLApp

/// Заметки выпуска в разделе «Обновления»: из двуязычного текста GitHub — половина на языке
/// программы, разложенная на группы, пункты и абзацы.
final class ReleaseNotesTests: XCTestCase {

    private let current = """
    ## What's new

    **Printing**
    - One print for the whole app.
    - Several files go as one job.

    ---

    ## Что нового

    **Печать**
    - Одна печать на всю программу.
    - Несколько файлов — **одним** заданием.
    """

    /// Так писались ранние выпуски: без черты, абзацы с жирным началом.
    private let early = """
    ## What's new in 1.6.2

    **The Settings window opens tall.** Its height is now the screen height.

    ## Что нового в 1.6.2

    **Окно настроек открывается во всю высоту.** Высота теперь равна высоте экрана.

    Если у вас 1.4 или новее, выпуск приходит через кнопку.
    """

    func test_русскаяПоловина() {
        XCTAssertEqual(ReleaseNotes.lines(of: current, russian: true), [
            .group("Печать"),
            .item("Одна печать на всю программу."),
            .item("Несколько файлов — **одним** заданием.")
        ])
    }

    func test_английскаяПоловина() {
        XCTAssertEqual(ReleaseNotes.lines(of: current, russian: false), [
            .group("Printing"),
            .item("One print for the whole app."),
            .item("Several files go as one job.")
        ])
    }

    func test_раннийВидБезЧерты() {
        XCTAssertEqual(ReleaseNotes.lines(of: early, russian: true), [
            .text("**Окно настроек открывается во всю высоту.** Высота теперь равна высоте экрана."),
            .text("Если у вас 1.4 или новее, выпуск приходит через кнопку.")
        ])
        XCTAssertEqual(ReleaseNotes.lines(of: early, russian: false), [
            .text("**The Settings window opens tall.** Its height is now the screen height.")
        ])
    }

    func test_текстНаОдномЯзыкеПоказываетсяЦеликом() {
        let plain = "- Fixed a crash.\n- Faster copy."
        XCTAssertEqual(ReleaseNotes.lines(of: plain, russian: true), [.item("Fixed a crash."), .item("Faster copy.")])
        XCTAssertTrue(ReleaseNotes.lines(of: "", russian: true).isEmpty)
    }
}
