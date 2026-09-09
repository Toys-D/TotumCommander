import XCTest

@testable import TotumComXLApp

/// Tests for the `L(...)` localization helper — the fallback behaviour (unknown key returns the
/// key itself, so the UI never shows blank text) and the printf-style argument substitution.
/// These assert the wrapper's contract without depending on any specific translation string.
final class LocalizationTests: XCTestCase {

    func test_unknownKey_returnsKeyItself() {
        let key = "totally.unknown.key.\(UUID().uuidString)"
        XCTAssertEqual(L(key), key)
    }

    func test_format_substitutesStringArguments() {
        // Unknown key → the key is used verbatim as the format string → args interpolate.
        XCTAssertEqual(L("%@ and %@", "A", "B"), "A and B")
    }

    func test_format_withoutPlaceholders_ignoresArgs() {
        XCTAssertEqual(L("no placeholders here", "ignored"), "no placeholders here")
    }

    func test_format_numberArgument() {
        XCTAssertEqual(L("count: %d", 42), "count: 42")
    }
}
