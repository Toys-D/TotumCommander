import Foundation
import XCTest

@testable import TotumComXLApp

/// The xattr inspector: list what is pinned to a file, preview it honestly, strip one note
/// without touching the file itself.
final class XattrInspectorTests: XCTestCase {

    private var file: String!

    override func setUp() async throws {
        try await super.setUp()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-xattr-\(UUID().uuidString).bin")
        try Data("содержимое".utf8).write(to: url)
        file = url.path
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: file)
        try await super.tearDown()
    }

    private func plant(_ name: String, _ value: String) {
        XCTAssertEqual(setxattr(file, name, value, value.utf8.count, 0, 0), 0)
    }

    func test_list_returnsEveryAttribute_alphabetized() {
        plant("com.example.второй", "б")
        plant("com.example.первый", "а")

        let entries = XattrInspector.list(path: file)

        XCTAssertEqual(entries.map(\.name),
                       ["com.example.второй", "com.example.первый"].sorted())
        XCTAssertEqual(entries.first?.size, "б".utf8.count)
    }

    func test_cleanFile_answersEmptyList_notAnError() {
        XCTAssertTrue(XattrInspector.list(path: file).isEmpty)
        XCTAssertTrue(XattrInspector.list(path: "/нет/такого/файла").isEmpty)
    }

    func test_remove_stripsTheNote_andLeavesTheFile() throws {
        plant("com.example.метка", "x")
        XCTAssertTrue(XattrInspector.remove(path: file, name: "com.example.метка"))
        XCTAssertTrue(XattrInspector.list(path: file).isEmpty)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "содержимое",
                       "the file's own bytes must be untouched")
        // Removing what is already gone is not a failure — the wish is already true.
        XCTAssertTrue(XattrInspector.remove(path: file, name: "com.example.метка"))
    }

    // MARK: - The translator

    func test_friendly_quarantine_namesTheAgent() {
        let friendly = XattrInspector.friendly(
            name: "com.apple.quarantine",
            data: Data("0083;5f9b2c00;Safari;UUID".utf8))
        XCTAssertNotNil(friendly)
        XCTAssertTrue(friendly!.contains("Safari"), friendly!)
    }

    func test_friendly_whereFroms_showsTheURL() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["https://example.com/файл.zip"], format: .binary, options: 0)
        let friendly = XattrInspector.friendly(
            name: "com.apple.metadata:kMDItemWhereFroms", data: plist)
        XCTAssertTrue(friendly?.contains("example.com") == true)
    }

    func test_friendly_finderTags_dropTheColourNumber() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Красный\n4", "Работа"], format: .binary, options: 0)
        let friendly = XattrInspector.friendly(
            name: "com.apple.metadata:_kMDItemUserTags", data: plist)
        XCTAssertTrue(friendly?.contains("Красный") == true)
        XCTAssertFalse(friendly?.contains("4") == true, "the colour number is bookkeeping")
    }

    func test_friendly_zoneIdentifier_isTranslated_andItsTextIsNotHex() {
        let value = Data("[ZoneTransfer]\r\nZoneId=3".utf8)
        XCTAssertNotNil(XattrInspector.friendly(name: "Zone.Identifier", data: value))
        // The \r used to knock the preview into hex — it is ordinary text.
        XCTAssertTrue(XattrInspector.preview(of: value).contains("ZoneTransfer"))
    }

    func test_friendly_unknownAttribute_staysUntranslated() {
        XCTAssertNil(XattrInspector.friendly(name: "com.example.странное",
                                             data: Data("x".utf8)))
    }

    /// Every translated attribute also has its unfolding story; strangers have neither.
    func test_explanations_coverTheKnown_andOnlyTheKnown() {
        XCTAssertNotNil(XattrInspector.explanation(name: "com.apple.quarantine"))
        XCTAssertNotNil(XattrInspector.explanation(name: "Zone.Identifier"))
        XCTAssertNil(XattrInspector.explanation(name: "com.example.странное"))
    }

    // MARK: - Previews

    func test_preview_textStaysText_binaryGoesHex() {
        XCTAssertEqual(XattrInspector.preview(of: Data("привет".utf8)), "привет")

        let binary = Data([0x00, 0xff, 0x10, 0x80])
        let hex = XattrInspector.preview(of: binary)
        XCTAssertTrue(hex.hasPrefix("00 ff 10 80"), hex)
    }

    func test_preview_binaryPlist_announcesItself() {
        let plist = Data("bplist00…".utf8)
        XCTAssertTrue(XattrInspector.preview(of: plist).hasPrefix("binary plist"))
    }

    func test_preview_longText_isCutShort() {
        let long = String(repeating: "щ", count: 500)
        let preview = XattrInspector.preview(of: Data(long.utf8))
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertLessThan(preview.count, 210)
    }
}
