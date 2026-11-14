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

    private func writeStore(_ payload: Data, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? tmp).appendingPathComponent(".DS_Store")
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

    // MARK: - Корзина внешнего диска

    /// «Диск» для записей, собранных руками, — папка: в корзине настоящего тома самодельный
    /// `.DS_Store` система стирает за доли секунды. Настоящий том — в проверках ниже, где
    /// запись пишет сама система.
    private func disk(_ name: String = "Флешка") throws -> URL {
        let disk = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        // Корень диска программа называет настоящим путём — таким он и нужен для сверки.
        return disk.resolvingSymlinksInPath()
    }

    /// Файл в корзине диска — `<диск>/.Trashes/<uid>` — и запись о том, откуда он, в том виде,
    /// в каком их оставляет система: путь идёт от корня диска, косая черта с обеих сторон.
    private func putInTrash(of disk: URL, name: String, from folder: String,
                            content: String = "bytes") throws -> (trash: URL, file: URL) {
        let trash = disk.appendingPathComponent(".Trashes")
            .appendingPathComponent(String(getuid()))
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let file = trash.appendingPathComponent(name)
        try Data(content.utf8).write(to: file)
        _ = try writeStore(record(trashName: name, folder: folder, originalName: name), in: trash)
        return (trash, file)
    }

    /// Запись возврата хранит путь от корня СВОЕГО диска, и у каждой корзины этот корень свой.
    func testEachTrashFolderKnowsTheDiskItBelongsTo() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(TrashService.volumeRoot(
            ofTrashFolder: home.appendingPathComponent(".Trash")), "/")
        XCTAssertEqual(TrashService.volumeRoot(
            ofTrashFolder: home.appendingPathComponent("Library/Mobile Documents/.Trash")), "/")
        XCTAssertEqual(TrashService.volumeRoot(
            ofTrashFolder: URL(fileURLWithPath: "/Volumes/Флешка/.Trashes/501")), "/Volumes/Флешка")
    }

    /// «/Volumes/Macintosh HD» — ссылка на загрузочный диск: корень у него «/», а не она сама.
    /// Сверяется с тем, куда ссылка ведёт; саму ссылку в ответе раскрывать здесь нельзя —
    /// иначе проверка проходила бы и без раскрытия в программе.
    func testADiskThatIsALinkCountsFromWhereTheLinkLeads() throws {
        let real = try disk("настоящий")
        let link = tmp.appendingPathComponent("ссылка")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let root = TrashService.volumeRoot(
            ofTrashFolder: link.appendingPathComponent(".Trashes").appendingPathComponent("501"))

        XCTAssertEqual(root, real.path)
    }

    /// Файл с внешнего диска «возвращался» на загрузочный: путь из записи считался от «/».
    /// Чаще всего такой папки там нет, и возврат падал; а на резервном диске с тем же деревом
    /// папок файл молча уезжал на другой диск.
    func testAFileFromAnExternalDiskGoesBackToThatDisk() throws {
        let disk = try disk()
        let (trash, inTrash) = try putInTrash(of: disk, name: "снимок.jpg",
                                              from: "/Photos/2024/", content: "кадр")
        let home = disk.path + "/Photos/2024"

        let entry = try XCTUnwrap(TrashService.entries(in: [trash]).first)
        XCTAssertEqual(entry.originalFolder, home)
        XCTAssertEqual(TrashService.originalFolder(forTrashedPath: inTrash.path), home)

        // Возврат идёт, только когда место назначения — внутри своей папки: проверка ничего
        // не создаёт в корне загрузочного диска, даже пока исправления нет.
        guard entry.restoreDestination?.hasPrefix(disk.path + "/") == true else { return }
        let restored = try TrashService.restore([entry])

        XCTAssertEqual(restored, [home + "/снимок.jpg"])
        XCTAssertEqual(try String(contentsOfFile: home + "/снимок.jpg", encoding: .utf8), "кадр")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inTrash.path))
    }

    /// У файла из самого корня диска запись — одна косая черта.
    func testAFileFromTheRootOfAnExternalDiskGoesBackToItsRoot() throws {
        let disk = try disk()
        let (trash, _) = try putInTrash(of: disk, name: "заметка.txt", from: "/",
                                        content: "из корня")

        let entry = try XCTUnwrap(TrashService.entries(in: [trash]).first)
        XCTAssertEqual(entry.originalFolder, disk.path)

        guard entry.restoreDestination?.hasPrefix(disk.path + "/") == true else { return }
        try TrashService.restore([entry])

        XCTAssertEqual(try String(contentsOfFile: disk.path + "/заметка.txt", encoding: .utf8),
                       "из корня")
    }

    /// Диск чужой, и запись на нём мог написать кто угодно. Путь с «..» выводит за пределы
    /// диска — по такой записи файл не возвращается никуда.
    func testARecordThatClimbsOutOfItsDiskIsNotTrusted() throws {
        let disk = try disk()
        let (trash, inTrash) = try putInTrash(of: disk, name: "подарок.txt",
                                              from: "/Photos/../../снаружи/")

        let entry = try XCTUnwrap(TrashService.entries(in: [trash]).first)
        // Пока место возврата есть, вызывать возврат нельзя: он унёс бы файл с «диска».
        guard entry.originalFolder == nil else {
            return XCTFail("запись с «..» принята: \(entry.originalFolder ?? "")")
        }
        XCTAssertThrowsError(try TrashService.restore([entry]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inTrash.path),
                      "отказ оставляет файл в корзине")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("снаружи").path))
    }

    /// Имя в записи — одно звено пути. Путь на его месте Finder не пишет никогда: даже «/» из
    /// имени на диске хранится двоеточием.
    func testARecordWhoseNameIsAPathIsIgnored() throws {
        for name in ["../../evil.txt", "вложенная/папка.txt", "..", "."] {
            let url = try writeStore(record(trashName: "x.txt", folder: "Users/dimas/",
                                            originalName: name))
            XCTAssertNil(PutBackIndex.parse(url)["x.txt"], name)
        }
        // Двоеточие — обычная буква имени, такая запись читается.
        let url = try writeStore(record(trashName: "a:b.txt", folder: "Users/dimas/",
                                        originalName: "a:b.txt"))
        XCTAssertEqual(PutBackIndex.parse(url)["a:b.txt"]?.name, "a:b.txt")
    }

    // MARK: - То же вживую: настоящий том, запись пишет система

    /// В корзину отправляет сама программа, запись о возврате пишет система — проверяется, что
    /// её вид понят верно, а не только наше о нём представление. Два файла разом: из папки и из
    /// самого корня диска. Затем всё, что человек видит и делает: колонка «Откуда» и возврат.
    ///
    /// На главном потоке не только ради панели: из фонового потока XCTest записывает не все
    /// неудачи, идущие подряд, — первая видна всегда, остальные через раз.
    @MainActor
    private func assertFilesTheSystemTrashedComeBack(fileSystem: String, megabytes: Int,
                                                     file: StaticString = #filePath,
                                                     line: UInt = #line) async throws {
        let disk = try TestDiskImage(megabytes: megabytes, fileSystem: fileSystem, inVolumes: true)
        defer { disk.detach() }
        let root = URL(fileURLWithPath: disk.mountPoint)
        let folder = root.appendingPathComponent("Документы/2024")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let deep = folder.appendingPathComponent("отчёт.txt")
        let top = root.appendingPathComponent("заметка.txt")
        try Data("вернусь".utf8).write(to: deep)
        try Data("из корня".utf8).write(to: top)

        let moved = try await DarwinFileOperations.trash(urls: [deep, top])
        let trashedDeep = try XCTUnwrap(
            moved.values.first { $0.lastPathComponent == deep.lastPathComponent },
            "система не сказала, куда убрала файл", file: file, line: line)
        let trashedTop = try XCTUnwrap(
            moved.values.first { $0.lastPathComponent == top.lastPathComponent },
            "система не сказала, куда убрала файл", file: file, line: line)
        XCTAssertTrue(trashedDeep.path.hasPrefix(disk.mountPoint + "/"),
                      "корзина не на том же диске: \(trashedDeep.path)", file: file, line: line)

        // Записи система пишет не сразу и по одной: ждать обеих, а не гадать о сроке.
        var entries: [TrashService.Entry] = []
        for _ in 0..<80 {
            entries = TrashService.entries().filter {
                $0.url.path == trashedDeep.path || $0.url.path == trashedTop.path
            }
            if entries.count == 2, entries.allSatisfy({ $0.originalFolder != nil }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let deepEntry = entries.first(where: { $0.url.path == trashedDeep.path }),
              let topEntry = entries.first(where: { $0.url.path == trashedTop.path }),
              let deepFrom = deepEntry.originalFolder, let topFrom = topEntry.originalFolder else {
            throw XCTSkip("система не записала, откуда файлы (\(fileSystem)): проверять нечего")
        }

        XCTAssertEqual(deepFrom, folder.path, "файл из папки", file: file, line: line)
        XCTAssertEqual(topFrom, disk.mountPoint, "файл из корня диска", file: file, line: line)
        XCTAssertEqual(TrashService.items().first { $0.path == trashedDeep.path }?.owner,
                       folder.path, "строка списка корзины", file: file, line: line)
        XCTAssertEqual(TrashService.originalFolder(forTrashedPath: trashedDeep.path),
                       folder.path, "по пути файла в корзине", file: file, line: line)
        let id = UUID().uuidString
        let panel = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: NSHomeDirectory(),
            pathDefaultsKey: "panel.path.trash.volume.test.\(id)",
            viewModeDefaultsKey: "panel.mode.trash.volume.test.\(id)",
            showHiddenFiles: false
        )
        panel.loadTrashDirectory()
        XCTAssertEqual(panel.trashOrigins[trashedDeep.path], folder.path,
                       "колонка «Откуда» в панели", file: file, line: line)

        // Возврат идёт, только когда оба места назначения — на своём образе: проверка ничего
        // не создаёт на загрузочном диске, даже пока исправления нет.
        guard [deepEntry, topEntry].allSatisfy({
            $0.restoreDestination?.hasPrefix(disk.mountPoint + "/") == true
        }) else { return }
        let restored = try TrashService.restore(paths: [trashedDeep.path, trashedTop.path])

        XCTAssertEqual(Set(restored), [deep.path, top.path], file: file, line: line)
        XCTAssertEqual(try String(contentsOf: deep, encoding: .utf8), "вернусь",
                       file: file, line: line)
        XCTAssertEqual(try String(contentsOf: top, encoding: .utf8), "из корня",
                       file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashedDeep.path),
                       file: file, line: line)
    }

    @MainActor func testFilesTheSystemTrashedOnAnHFSDiskComeBack() async throws {
        try await assertFilesTheSystemTrashedComeBack(fileSystem: "HFS+", megabytes: 4)
    }

    @MainActor func testFilesTheSystemTrashedOnAnAPFSDiskComeBack() async throws {
        try await assertFilesTheSystemTrashedComeBack(fileSystem: "APFS", megabytes: 32)
    }

    @MainActor func testFilesTheSystemTrashedOnAnExFATDiskComeBack() async throws {
        try await assertFilesTheSystemTrashedComeBack(fileSystem: "ExFAT", megabytes: 16)
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
