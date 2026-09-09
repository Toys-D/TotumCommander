import XCTest

@testable import TotumComXLApp

/// Набранный знак не должен пропадать из поля, пока SwiftUI возвращает привязку обратно.
final class FieldEchoTests: XCTestCase {

    func testOwnTypingComesBackAsEcho() {
        var echo = FCXLFieldEcho()
        echo.pushed("п")
        XCTAssertTrue(echo.isEcho(of: "п"))
    }

    func testAValueNobodyTypedIsAnOutsideChange() {
        var echo = FCXLFieldEcho()
        echo.pushed("п")
        XCTAssertFalse(echo.isEcho(of: "вставленный тег"))
    }

    func testEchoLaggingTwoKeystrokesBehindIsStillEcho() {
        // Человек успел нажать «а», «б» и «в», пока шло эхо первого знака: переписать поле
        // значением «а» значило бы стереть «бв».
        var echo = FCXLFieldEcho()
        echo.pushed("а"); echo.pushed("аб"); echo.pushed("абв")
        XCTAssertTrue(echo.isEcho(of: "а"))
    }

    func testOlderEchoesAreForgottenOnceALaterOneArrives() {
        var echo = FCXLFieldEcho()
        echo.pushed("а"); echo.pushed("аб")
        XCTAssertTrue(echo.isEcho(of: "аб"))
        // «а» осталось позади: если привязка снова станет «а», это уже чужая правка.
        XCTAssertFalse(echo.isEcho(of: "а"))
    }

    func testTheSameEchoIsNotAcceptedTwice() {
        var echo = FCXLFieldEcho()
        echo.pushed("пароль")
        XCTAssertTrue(echo.isEcho(of: "пароль"))
        XCTAssertFalse(echo.isEcho(of: "пароль"))
    }

    func testALongTypingSessionDoesNotGrowForever() {
        var echo = FCXLFieldEcho()
        var text = ""
        for ch in "очень длинный пароль, набранный по одному знаку" {
            text.append(ch)
            echo.pushed(text)
        }
        // Самое старое забыто, последнее — узнаётся.
        XCTAssertFalse(echo.isEcho(of: "о"))
        XCTAssertTrue(echo.isEcho(of: text))
    }
}
