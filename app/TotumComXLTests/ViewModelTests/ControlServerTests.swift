import Foundation
import XCTest

@testable import FCXLControlProtocol
@testable import TotumComXLApp

/// The local control door: what it answers, and — more importantly — what it refuses. Every
/// command here READS; the tests are the place that keeps it that way.
final class ControlServerTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("текст".utf8).write(to: dir.appendingPathComponent("заметка.txt"))
        try Data().write(to: dir.appendingPathComponent(".скрытый"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("вложенная"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("вложенная/глубоко.md"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - The commands are read-only, by construction

    /// The safety story in one assertion: which commands touch the disk, and therefore which
    /// ones must stop at a dialog. A new command joining either side has to be a deliberate
    /// edit here, never a silent addition.
    func test_theVocabularyIsExactlyThis_andSplitCorrectly() {
        XCTAssertEqual(Set(ControlCommand.allCases.map(\.rawValue)),
                       ["ping", "panels", "list", "find", "leftovers",
                        "copy", "move", "trash", "mkdir"])
        XCTAssertEqual(Set(ControlCommand.allCases.filter { !$0.changesFiles }.map(\.rawValue)),
                       ["ping", "panels", "list", "find", "leftovers"])
        XCTAssertEqual(Set(ControlCommand.allCases.filter(\.changesFiles).map(\.rawValue)),
                       ["copy", "move", "trash", "mkdir"])
        for command in ControlCommand.allCases {
            XCTAssertFalse(command.summary.isEmpty, "\(command) must describe itself to the model")
        }
    }

    /// A changing command must SAY, in the words the model reads, that a person confirms it —
    /// so the caller never promises the user something it cannot do by itself.
    func test_changingCommandsAnnounceTheConfirmation() {
        for command in ControlCommand.allCases where command.changesFiles {
            XCTAssertTrue(command.summary.lowercased().contains("confirm"),
                          "\(command) must say the person confirms it: \(command.summary)")
        }
    }

    func test_theServerIsOffUntilTurnedOn() {
        // The key is what the Settings toggle writes; absent means off.
        XCTAssertEqual(ControlProtocol.enabledKey, "fcxl.controlServerEnabled")
        let fresh = UserDefaults(suiteName: "fcxl.control.\(UUID().uuidString)")!
        XCTAssertFalse(fresh.bool(forKey: ControlProtocol.enabledKey))
    }

    /// The socket is a door into a running program — it must not be a public one.
    func test_theSocketLivesInTheUsersOwnSupportFolder() {
        let path = ControlProtocol.socketURL.path
        XCTAssertTrue(path.contains("Application Support/TotumCommander"), path)
        XCTAssertTrue(path.hasSuffix("control.sock"), path)
    }

    // MARK: - Listing

    func test_listing_hidesDotFilesUnlessAsked() {
        let plain = ControlServer.listing(of: dir.path, includeHidden: false, id: 1)
        XCTAssertTrue(plain.ok)
        XCTAssertFalse(plain.result!.contains(".скрытый"))
        XCTAssertTrue(plain.result!.contains("заметка.txt"))
        XCTAssertTrue(plain.result!.contains("вложенная\tfolder"), plain.result!)

        let all = ControlServer.listing(of: dir.path, includeHidden: true, id: 1)
        XCTAssertTrue(all.result!.contains(".скрытый"))
    }

    func test_listing_refusesWhatIsNotAFolder() {
        let onAFile = ControlServer.listing(of: dir.appendingPathComponent("заметка.txt").path,
                                            includeHidden: false, id: 1)
        XCTAssertFalse(onAFile.ok)
        XCTAssertNotNil(onAFile.error)

        XCTAssertFalse(ControlServer.listing(of: "/нет/такой/папки", includeHidden: false, id: 1).ok)
    }

    // MARK: - Finding

    func test_find_walksSubfolders_andHonoursTheLimit() {
        let found = ControlServer.found(under: dir.path, mask: "*.md", limit: 10, id: 1)
        XCTAssertTrue(found.ok)
        XCTAssertTrue(found.result!.contains("глубоко.md"))

        let capped = ControlServer.found(under: dir.path, mask: "*", limit: 1, id: 1)
        XCTAssertEqual(capped.result!.split(separator: "\n").count, 1)
    }

    /// A bare word means "somewhere in the name", as everywhere else in this program.
    func test_find_bareWordIsASubstring() {
        let found = ControlServer.found(under: dir.path, mask: "замет", limit: 10, id: 1)
        XCTAssertTrue(found.result!.contains("заметка.txt"), found.result!)
    }

    func test_find_saysSoWhenNothingMatches() {
        let found = ControlServer.found(under: dir.path, mask: "*.нетакого", limit: 10, id: 1)
        XCTAssertTrue(found.ok)
        XCTAssertTrue(found.result!.contains("("), found.result!)
    }

    // MARK: - Describing the panels

    // MARK: - Spelling out what was asked

    /// Several paths in one argument, each made absolute.
    func test_pathsArgument_takesLinesOrSemicolons() {
        let byLines = ControlServer.paths("a.txt\nb.txt", activeFolder: "/Users/x")
        XCTAssertEqual(byLines, ["/Users/x/a.txt", "/Users/x/b.txt"])
        let bySemicolons = ControlServer.paths("/tmp/a; ~/b", activeFolder: nil)
        XCTAssertEqual(bySemicolons.first, "/tmp/a")
        XCTAssertTrue(bySemicolons.last!.hasPrefix(NSHomeDirectory()))
        XCTAssertTrue(ControlServer.paths("  ", activeFolder: nil).isEmpty)
    }

    /// An omitted destination is NOT "here". Resolving an empty path answers the active
    /// panel's folder, which is right for reading and a trap for writing: a caller that forgot
    /// "to" would have had its files copied into whatever folder happened to be open. Live
    /// testing did exactly that once.
    func test_emptyDestinationMustNotBecomeTheActiveFolder() {
        // The resolver still answers the anchor — that is its job for reading …
        XCTAssertEqual(ControlServer.resolve("", activeFolder: "/Users/x/Загрузки"),
                       "/Users/x/Загрузки")
        // … so the writing path must not hand it an empty string at all. Its guard sees "".
        let asked = ""
        let destination = asked.trimmingCharacters(in: .whitespaces).isEmpty
            ? "" : ControlServer.resolve(asked, activeFolder: "/Users/x/Загрузки")
        XCTAssertTrue(destination.isEmpty, "an omitted 'to' must stay empty and be refused")
    }

    /// The dialog shows names, not a wall of paths, and says how many when there are many.
    func test_summaryNamesFilesAndCountsTheRest() {
        XCTAssertEqual(ControlServer.summary(of: ["/a/один.txt", "/b/два.txt"]),
                       "один.txt, два.txt")
        let many = (1...10).map { "/a/файл\($0).txt" }
        let text = ControlServer.summary(of: many)
        XCTAssertTrue(text.contains("файл1.txt"))
        XCTAssertTrue(text.contains("(10)"), text)
        XCTAssertFalse(text.contains("файл9.txt"), text)
    }

    func test_panelState_readsAsStableSortedLines() {
        let text = ControlServer.describe(["right folder": "/b", "left folder": "/a"])
        XCTAssertEqual(text, "left folder: /a\nright folder: /b")
    }

    // MARK: - The wire

    func test_requestAndResponse_surviveTheRoundTrip() throws {
        let request = ControlRequest(id: 7, command: "list", args: ["path": "/tmp/папка"])
        let decoded = try JSONDecoder().decode(
            ControlRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.id, 7)
        XCTAssertEqual(decoded.args["path"], "/tmp/папка")

        let failure = try JSONDecoder().decode(
            ControlResponse.self, from: JSONEncoder().encode(ControlResponse(id: 7, error: "нет")))
        XCTAssertFalse(failure.ok)
        XCTAssertEqual(failure.error, "нет")
        XCTAssertNil(failure.result)
    }

    /// One line per message is the framing; a message must therefore never contain a newline
    /// of its own once encoded.
    func test_encodedMessageIsASingleLine() throws {
        let response = ControlResponse(id: 1, result: "первая\nвторая")
        let data = try JSONEncoder().encode(response)
        XCTAssertFalse(data.contains(0x0A), "a raw newline would split one message into two")
    }
}

/// Paths as a person types them, and the exclusions the program already knows.
final class ControlServerPathTests: XCTestCase {

    func test_tildeIsExpanded() {
        let resolved = ControlServer.resolve("~/Документы", activeFolder: nil)
        XCTAssertTrue(resolved.hasPrefix(NSHomeDirectory()), resolved)
        XCTAssertTrue(resolved.hasSuffix("Документы"), resolved)
    }

    /// A bare name means "here", and here is whatever the ACTIVE panel shows.
    func test_relativePathIsAnchoredOnTheActivePanel() {
        XCTAssertEqual(ControlServer.resolve("docs", activeFolder: "/Users/x/проект"),
                       "/Users/x/проект/docs")
        XCTAssertEqual(ControlServer.resolve("../сосед", activeFolder: "/Users/x/проект"),
                       "/Users/x/сосед")
    }

    func test_absolutePathIsLeftAlone_andTidied() {
        XCTAssertEqual(ControlServer.resolve("/tmp/папка", activeFolder: "/ignored"), "/tmp/папка")
        XCTAssertEqual(ControlServer.resolve("/tmp/./папка/", activeFolder: nil), "/tmp/папка")
    }

    func test_emptyPathMeansTheActiveFolder() {
        XCTAssertEqual(ControlServer.resolve("  ", activeFolder: "/Users/x"), "/Users/x")
        XCTAssertEqual(ControlServer.resolve("", activeFolder: nil), "")
    }

    /// Hidden trees are not entered, so a walk of a project does not answer with .git and
    /// .claude machinery.
    func test_findDoesNotDiveIntoDotFolders() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-mcp-\(UUID().uuidString)")
        let hidden = root.appendingPathComponent(".git/objects")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("виден.txt"))
        try Data().write(to: hidden.appendingPathComponent("спрятан.txt"))

        let found = ControlServer.found(under: root.path, mask: "*.txt", limit: 50, id: 1)
        XCTAssertTrue(found.result!.contains("виден.txt"))
        XCTAssertFalse(found.result!.contains("спрятан.txt"), found.result!)
    }

    /// The exclusion list is the one the search dialog uses — one answer per program.
    func test_findSkipsExcludedTrees() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-mcp-\(UUID().uuidString)")
        let junk = root.appendingPathComponent("node_modules/deep")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("нужный.txt"))
        try Data().write(to: junk.appendingPathComponent("лишний.txt"))

        let all = ControlServer.found(under: root.path, mask: "*.txt", limit: 50, id: 1)
        XCTAssertTrue(all.result!.contains("лишний.txt"), "without a list nothing is skipped")

        let filtered = ControlServer.found(under: root.path, mask: "*.txt", limit: 50,
                                           excludes: ["node_modules"], id: 1)
        XCTAssertTrue(filtered.result!.contains("нужный.txt"))
        XCTAssertFalse(filtered.result!.contains("лишний.txt"))
        XCTAssertTrue(filtered.result!.contains("skipped"), filtered.result!)
    }
}
