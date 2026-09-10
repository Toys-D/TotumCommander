import XCTest

@testable import TotumComXLApp

/// Цветовые профили для Ghostscript. Во встроенную копию они не попадали вовсе, а путь к
/// ним Ghostscript принимает только с косой чертой на конце.
final class PostScriptColourArgsTests: XCTestCase {

    func test_путьЗаканчиваетсяКосойЧертой() {
        XCTAssertEqual(PostScriptRenderer.colourArguments(iccProfilesDir: "/a/iccprofiles"),
                       ["-sICCProfilesDir=/a/iccprofiles/"])
    }

    func test_лишнейЧертыНеПоявляется() {
        XCTAssertEqual(PostScriptRenderer.colourArguments(iccProfilesDir: "/a/iccprofiles/"),
                       ["-sICCProfilesDir=/a/iccprofiles/"])
    }

    func test_безПрофилейДоводовНет() {
        // Ghostscript должен работать и без них — просто без управления цветом.
        XCTAssertTrue(PostScriptRenderer.colourArguments(iccProfilesDir: nil).isEmpty)
        XCTAssertTrue(PostScriptRenderer.colourArguments(iccProfilesDir: "").isEmpty)
    }
}
