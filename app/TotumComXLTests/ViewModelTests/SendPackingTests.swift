import AppKit
import XCTest

@testable import TotumComXLApp

/// An SVG on its way to Telegram is packed first: Telegram's share extension takes the file for
/// a picture, cannot draw it, and the message then sits at 0% for ever. Everything else goes as
/// it is.
@MainActor
final class SendPackingTests: XCTestCase {

    private var ops: FileOperationsService!
    private var tmp: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ops = FileOperationsService(bridgeService: CoreBridgeService())
        tmp = (FileManager.default.temporaryDirectory.path as NSString)
            .appendingPathComponent("fcxl-send-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(atPath: tmp) }
        FileOperationsService.cleanupSendDirectories()
        ops = nil
        tmp = nil
        try super.tearDownWithError()
    }

    private func makeItem(name: String, isDirectory: Bool = false) -> FileItem {
        FileItem(path: (tmp as NSString).appendingPathComponent(name), name: name,
                 fileExtension: (name as NSString).pathExtension,
                 size: 0, isDirectory: isDirectory, isHidden: false, isSymlink: false,
                 permissions: "-rw-r--r--", dateModified: Date())
    }

    // MARK: - Who gets packed

    func testAnSVGBoundForTelegramIsPacked() {
        XCTAssertTrue(PanelViewController.needsPackingBeforeSending(makeItem(name: "рисунок.svg"),
                                                                   messenger: "Telegram"))
    }

    /// The name comes from the system's list of messengers and the extension from the file — a
    /// capital letter in either must not decide whether the file arrives.
    func testTheCheckIgnoresLetterCase() {
        XCTAssertTrue(PanelViewController.needsPackingBeforeSending(makeItem(name: "Logo.SVG"),
                                                                   messenger: "telegram"))
    }

    /// Telegram sends ordinary pictures perfectly well; packing those would only annoy.
    func testOtherFilesGoAsTheyAre() {
        for name in ["photo.png", "notes.txt", "book.pdf", "archive.zip", "drawing.svgz"] {
            XCTAssertFalse(
                PanelViewController.needsPackingBeforeSending(makeItem(name: name),
                                                              messenger: "Telegram"),
                "\(name) has no reason to be packed")
        }
    }

    /// Only Telegram has this fault — everyone else gets the file itself.
    func testOtherMessengersGetTheFileItself() {
        for messenger in ["WhatsApp", "Viber", "Signal", "Mail"] {
            XCTAssertFalse(
                PanelViewController.needsPackingBeforeSending(makeItem(name: "рисунок.svg"),
                                                              messenger: messenger))
        }
    }

    /// A folder called `something.svg` is still a folder, and packing rules are decided
    /// elsewhere for those.
    func testAFolderIsNotPacked() {
        XCTAssertFalse(
            PanelViewController.needsPackingBeforeSending(makeItem(name: "assets.svg",
                                                                   isDirectory: true),
                                                          messenger: "Telegram"))
    }

    // MARK: - What is actually sent

    func testTheArchiveIsNamedAfterTheFileAndHoldsIt() throws {
        let svg = (tmp as NSString).appendingPathComponent("evaluated-studies.svg")
        let drawing = "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"10\" height=\"10\"/></svg>"
        try drawing.write(toFile: svg, atomically: true, encoding: .utf8)

        let archive = try ops.zipForSending(path: svg)

        XCTAssertEqual((archive as NSString).lastPathComponent, "evaluated-studies.zip",
                       "the chat should show the name the file had")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive))

        let entries = try CoreBridgeService().listArchiveEntries(archivePath: archive)
        XCTAssertEqual(entries.map(\.path), ["evaluated-studies.svg"],
                       "the archive holds the file itself, with no folders around it")

        // …and the bytes survive the trip.
        let unpacked = (tmp as NSString).appendingPathComponent("out")
        try FileManager.default.createDirectory(atPath: unpacked, withIntermediateDirectories: true)
        try CoreBridgeService().extractArchiveAll(archivePath: archive, destinationPath: unpacked,
                                                  overwriteExisting: true) { _, _, _, _, _, _ in }
        let restored = try String(contentsOfFile: (unpacked as NSString)
            .appendingPathComponent("evaluated-studies.svg"), encoding: .utf8)
        XCTAssertEqual(restored, drawing)
    }

    /// The archive is made somewhere of its own — never beside the original, which may sit on a
    /// read-only volume or in a folder the person is looking at.
    func testTheArchiveIsMadeAwayFromTheOriginal() throws {
        let svg = (tmp as NSString).appendingPathComponent("рисунок.svg")
        try "<svg/>".write(toFile: svg, atomically: true, encoding: .utf8)

        let archive = try ops.zipForSending(path: svg)

        XCTAssertNotEqual((archive as NSString).deletingLastPathComponent, tmp)
        XCTAssertTrue(archive.hasPrefix(NSTemporaryDirectory()))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (tmp as NSString).appendingPathComponent("рисунок.zip")))
    }

    /// They are kept while the app runs — the receiving app may still be reading one long after
    /// its panel closed — and go when it quits.
    func testTheArchivesAreClearedWhenTheAppQuits() throws {
        let svg = (tmp as NSString).appendingPathComponent("temp.svg")
        try "<svg/>".write(toFile: svg, atomically: true, encoding: .utf8)
        let archive = try ops.zipForSending(path: svg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive))

        FileOperationsService.cleanupSendDirectories()

        XCTAssertFalse(FileManager.default.fileExists(atPath: archive))
    }
}

/// Whose panel gets the note beside it.
@MainActor
final class SharePanelHintChoiceTests: XCTestCase {

    /// Telegram's panel does not close by its own button, here or in Finder — that is the one
    /// worth warning about.
    func testTelegramGetsTheNote() {
        XCTAssertTrue(PanelViewController.panelNeedsClosingHint(messenger: "Telegram"))
        XCTAssertTrue(PanelViewController.panelNeedsClosingHint(messenger: "telegram"))
    }

    /// Everyone else closes properly, and a warning that is always there is read by nobody.
    func testTheOthersDoNot() {
        for messenger in ["WhatsApp", "Viber", "Signal", "Slack", "Mail"] {
            XCTAssertFalse(PanelViewController.panelNeedsClosingHint(messenger: messenger))
        }
    }
}
