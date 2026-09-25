import XCTest

@testable import TotumComXLApp

/// Tests for `PosixPermissions` — the pure model behind the properties window's permission
/// grid: mode ⇄ nine booleans ⇄ octal string ⇄ rwx symbolic. All deterministic, no filesystem.
final class PosixPermissionsTests: XCTestCase {

    // MARK: - mode → bits

    func test_mode644_ownerReadWrite_othersReadOnly() {
        let p = PosixPermissions(mode: 0o644)
        XCTAssertTrue(p.ownerRead); XCTAssertTrue(p.ownerWrite); XCTAssertFalse(p.ownerExecute)
        XCTAssertTrue(p.groupRead); XCTAssertFalse(p.groupWrite); XCTAssertFalse(p.groupExecute)
        XCTAssertTrue(p.otherRead); XCTAssertFalse(p.otherWrite); XCTAssertFalse(p.otherExecute)
    }

    func test_mode755_ownerAll_othersReadExecute() {
        let p = PosixPermissions(mode: 0o755)
        XCTAssertTrue(p.ownerRead && p.ownerWrite && p.ownerExecute)
        XCTAssertTrue(p.groupRead && !p.groupWrite && p.groupExecute)
        XCTAssertTrue(p.otherRead && !p.otherWrite && p.otherExecute)
    }

    /// Type and setuid/sticky bits above 0o777 must be ignored — only the low nine matter here.
    func test_highBitsIgnored() {
        XCTAssertEqual(PosixPermissions(mode: 0o100644).mode, 0o644)
        XCTAssertEqual(PosixPermissions(mode: 0o4755).mode, 0o755)
    }

    // MARK: - bits → mode / octal

    func test_modeRoundTrip() {
        for raw in [0o000, 0o644, 0o755, 0o777, 0o600, 0o444, 0o711] {
            XCTAssertEqual(PosixPermissions(mode: raw).mode, raw)
        }
    }

    func test_octalStringIsAlwaysThreeDigits() {
        XCTAssertEqual(PosixPermissions(mode: 0o644).octalString, "644")
        XCTAssertEqual(PosixPermissions(mode: 0o7).octalString, "007")
        XCTAssertEqual(PosixPermissions(mode: 0o0).octalString, "000")
    }

    // MARK: - octal string → bits

    func test_parseOctalString() {
        XCTAssertEqual(PosixPermissions(octalString: "644")?.mode, 0o644)
        XCTAssertEqual(PosixPermissions(octalString: " 755 ")?.mode, 0o755, "surrounding spaces are trimmed")
        XCTAssertEqual(PosixPermissions(octalString: "7")?.mode, 0o007, "short strings are right-aligned")
    }

    func test_parseOctalString_rejectsGarbage() {
        XCTAssertNil(PosixPermissions(octalString: ""))
        XCTAssertNil(PosixPermissions(octalString: "8"), "8 is not an octal digit")
        XCTAssertNil(PosixPermissions(octalString: "9x"))
        XCTAssertNil(PosixPermissions(octalString: "1234"), "more than three digits")
        XCTAssertNil(PosixPermissions(octalString: "rwx"))
    }

    func test_octalParseThenFormatRoundTrips() {
        for s in ["000", "644", "755", "777", "600", "700"] {
            XCTAssertEqual(PosixPermissions(octalString: s)?.octalString, s)
        }
    }

    // MARK: - symbolic (ls -l) string

    func test_symbolicString() {
        XCTAssertEqual(PosixPermissions(mode: 0o644).symbolic, "rw-r--r--")
        XCTAssertEqual(PosixPermissions(mode: 0o755).symbolic, "rwxr-xr-x")
        XCTAssertEqual(PosixPermissions(mode: 0o777).symbolic, "rwxrwxrwx")
        XCTAssertEqual(PosixPermissions(mode: 0o000).symbolic, "---------")
    }

    // MARK: - editing a single bit

    func test_flippingOneCheckboxChangesOnlyThatBit() {
        var p = PosixPermissions(mode: 0o644)   // rw-r--r--
        p.groupWrite = true                      // → rw-rw-r--
        XCTAssertEqual(p.octalString, "664")
        p.otherExecute = true                    // → rw-rw-r-x
        XCTAssertEqual(p.symbolic, "rw-rw-r-x")
    }
}
