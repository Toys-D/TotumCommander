import XCTest

@testable import TotumComXLApp

/// The Trash view is only as good as the "put back" records it reads, and those live in an
/// undocumented binary macOS rewrites whenever it likes. These build the record layout by hand and
/// hold the parser to it — including the malformed shapes, because a cache file that comes back
/// truncated must yield fewer records, never a crash.
final class TrashServiceTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-trash-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        try super.tearDownWithError()
    }

    // MARK: - Building a .DS_Store the way macOS does

    private func uint32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
              UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private func ustr(_ text: String) -> Data {
        let body = Data(text.unicodeScalars.flatMap { scalar -> [UInt8] in
            Array(String(scalar).utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        })
        return uint32(UInt32(body.count / 2)) + body
    }

    private func key(_ name: String) -> Data {
        let body = Data(Array(name.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        return uint32(UInt32(body.count / 2)) + body
    }

    /// One item's pair of records: `<key>ptbLustr<folder><key>ptbNustr<name>`.
    private func record(trashName: String, folder: String, originalName: String) -> Data {
        key(trashName) + Data("ptbLustr".utf8) + ustr(folder)
            + key(trashName) + Data("ptbNustr".utf8) + ustr(originalName)
    }

    private func writeStore(_ payload: Data) throws -> URL {
        let url = tmp.appendingPathComponent(".DS_Store")
        // Real files open with "Bud1" and allocator blocks; the parser scans rather than walks the
        // B-tree, so a plausible prefix is enough to prove it is not relying on a fixed offset.
        try (Data("Bud1".utf8) + Data(repeating: 0, count: 28) + payload).write(to: url)
        return url
    }

    // MARK: - Reading records

    func testOneRecordIsRead() throws {
        let url = try writeStore(record(trashName: "report.pdf",
                                        folder: "Users/dimas/Documents/",
                                        originalName: "report.pdf"))
        let index = PutBackIndex.parse(url)
        XCTAssertEqual(index["report.pdf"]?.folder, "Users/dimas/Documents/")
        XCTAssertEqual(index["report.pdf"]?.name, "report.pdf")
    }

    /// macOS suffixes a colliding name in the Trash, so the key and the original name differ —
    /// and the original name is the one to restore under.
    func testTheOriginalNameSurvivesACollisionSuffix() throws {
        let url = try writeStore(record(trashName: "2.png 01-04-07-125.png",
                                        folder: "Users/dimas/Documents/АВТО/",
                                        originalName: "2.png"))
        let index = PutBackIndex.parse(url)
        XCTAssertEqual(index["2.png 01-04-07-125.png"]?.name, "2.png")
        XCTAssertEqual(index["2.png 01-04-07-125.png"]?.folder, "Users/dimas/Documents/АВТО/")
    }

    func testCyrillicAndSpacesRoundTrip() throws {
        let url = try writeStore(record(trashName: "Мой отчёт.xlsx",
                                        folder: "Users/dimas/Рабочий стол/Отчёты 2026/",
                                        originalName: "Мой отчёт.xlsx"))
        let index = PutBackIndex.parse(url)
        XCTAssertEqual(index["Мой отчёт.xlsx"]?.folder, "Users/dimas/Рабочий стол/Отчёты 2026/")
    }

    func testEmojiInANameIsNotTruncated() throws {
        let url = try writeStore(record(trashName: "🎉 party.txt",
                                        folder: "Users/dimas/Desktop/",
                                        originalName: "🎉 party.txt"))
        XCTAssertEqual(PutBackIndex.parse(url)["🎉 party.txt"]?.name, "🎉 party.txt")
    }

    func testManyRecordsAreAllFound() throws {
        var payload = Data()
        for i in 1...50 {
            payload += record(trashName: "file\(i).txt",
                              folder: "Users/dimas/Documents/dir\(i)/",
                              originalName: "file\(i).txt")
        }
        let index = PutBackIndex.parse(try writeStore(payload))
        XCTAssertEqual(index.count, 50)
        XCTAssertEqual(index["file37.txt"]?.folder, "Users/dimas/Documents/dir37/")
    }

    // MARK: - Damaged input

    func testAMissingFileYieldsNoRecordsRatherThanCrashing() {
        XCTAssertTrue(PutBackIndex.parse(tmp.appendingPathComponent("nope.DS_Store")).isEmpty)
    }

    func testGarbageYieldsNoRecords() throws {
        let url = tmp.appendingPathComponent(".DS_Store")
        try Data((0..<4096).map { UInt8($0 % 251) }).write(to: url)
        // Random bytes may happen to contain "ptbL"; whatever survives must not crash the parser.
        _ = PutBackIndex.parse(url)
    }

    /// A record cut off mid-way — the exact shape a rewritten cache leaves behind.
    func testATruncatedRecordIsSkippedAndTheRestStillRead() throws {
        let good = record(trashName: "keep.txt", folder: "Users/dimas/", originalName: "keep.txt")
        let truncated = (key("cut.txt") + Data("ptbLustr".utf8) + uint32(99)).prefix(40)
        let index = PutBackIndex.parse(try writeStore(good + truncated))
        XCTAssertEqual(index["keep.txt"]?.name, "keep.txt")
        XCTAssertNil(index["cut.txt"])
    }

    /// A folder with no matching name record cannot say what to call the restored file.
    func testAHalfRecordIsIgnored() throws {
        let halfOnly = key("orphan.txt") + Data("ptbLustr".utf8) + ustr("Users/dimas/")
        XCTAssertNil(PutBackIndex.parse(try writeStore(halfOnly))["orphan.txt"])
    }

    // MARK: - Restore

    private func entry(at url: URL, folder: String?, name: String) -> TrashService.Entry {
        TrashService.Entry(url: url, displayName: name, originalFolder: folder,
                           deletedAt: Date(), isDirectory: false, size: 1)
    }

    func testRestorePutsTheFileBackUnderItsOriginalName() throws {
        let home = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let inTrash = tmp.appendingPathComponent("photo.jpg 01-02-03-004.jpg")
        try Data("bytes".utf8).write(to: inTrash)

        let restored = try TrashService.restore(
            [entry(at: inTrash, folder: home.path, name: "photo.jpg")])

        XCTAssertEqual(restored, [home.appendingPathComponent("photo.jpg").path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: inTrash.path))
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("photo.jpg"),
                                  encoding: .utf8), "bytes")
    }

    /// The original folder may itself have been deleted since.
    func testRestoreRecreatesAMissingParentFolder() throws {
        let gone = tmp.appendingPathComponent("long/gone/folder")
        let inTrash = tmp.appendingPathComponent("orphan.txt")
        try Data("x".utf8).write(to: inTrash)

        try TrashService.restore([entry(at: inTrash, folder: gone.path, name: "orphan.txt")])

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: gone.appendingPathComponent("orphan.txt").path))
    }

    /// Restoring must never overwrite whatever took the name in the meantime.
    func testRestoreRefusesWhenTheOldPlaceIsTaken() throws {
        let home = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let occupant = home.appendingPathComponent("note.txt")
        try Data("newer".utf8).write(to: occupant)
        let inTrash = tmp.appendingPathComponent("note.txt 11-11-11-111.txt")
        try Data("older".utf8).write(to: inTrash)

        XCTAssertThrowsError(try TrashService.restore(
            [entry(at: inTrash, folder: home.path, name: "note.txt")]))

        XCTAssertEqual(try String(contentsOf: occupant, encoding: .utf8), "newer")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inTrash.path),
                      "a refused restore must leave the item in the Trash")
    }

    func testRestoreRefusesWhenThereIsNoRecordOfWhereItCameFrom() throws {
        let inTrash = tmp.appendingPathComponent("mystery.txt")
        try Data("x".utf8).write(to: inTrash)

        XCTAssertThrowsError(try TrashService.restore(
            [entry(at: inTrash, folder: nil, name: "mystery.txt")]))

        XCTAssertTrue(FileManager.default.fileExists(atPath: inTrash.path))
    }

    // MARK: - Paths

    func testTrashRootIsRecognised() {
        XCTAssertTrue(TrashService.isTrashPath("/TRASH"))
        XCTAssertTrue(TrashService.isTrashPath("/TRASH/anything"))
        XCTAssertFalse(TrashService.isTrashPath("/TRASHCAN"))
        XCTAssertFalse(TrashService.isTrashPath("/Users/dimas"))
    }

    /// The home Trash is always in the list; volume ones join it only when they exist.
    func testTheHomeTrashIsAlwaysListed() {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash").path
        XCTAssertTrue(TrashService.trashFolders().contains { $0.path == home })
        // Корзина iCloud Drive — тоже корзина: Finder показывает её вместе с общей.
        let cloud = NSHomeDirectory() + "/Library/Mobile Documents/.Trash"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: cloud, isDirectory: &isDir), isDir.boolValue {
            XCTAssertTrue(TrashService.trashFolders().contains { $0.path == cloud },
                          "корзина iCloud Drive на месте")
        }
    }

    /// Reads whatever is really on this machine — asserts only that it does not blow up and that
    /// every entry it does produce is self-consistent, so an empty Trash passes too.
    func testReadingTheRealTrashIsSelfConsistent() {
        for entry in TrashService.entries().prefix(50) {
            XCTAssertFalse(entry.displayName.isEmpty)
            if let folder = entry.originalFolder {
                XCTAssertTrue(folder.hasPrefix("/"), folder)
                XCTAssertFalse(folder.hasSuffix("/"), "trailing slash should be trimmed: \(folder)")
                XCTAssertEqual(entry.restoreDestination,
                               (folder as NSString).appendingPathComponent(entry.displayName))
            }
        }
    }
}
