import XCTest
@testable import TotumComXLApp

/// Копирование и перемещение через границу томов (дорога copyfile): то, что не скопировалось,
/// не теряется молча; перемещение не стирает ни источник, ни готовую копию; папка «только
/// чтение» копируется; нехватка места — ошибка, а не вечный цикл.
final class CrossVolumeTransferTests: XCTestCase {

    private static var volume: TestDiskImage?
    private var source: String!
    private var target: String!

    override class func setUp() {
        super.setUp()
        volume = try? TestDiskImage(megabytes: 16)
    }

    override class func tearDown() {
        volume?.detach()
        volume = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        guard let volume = Self.volume else { throw XCTSkip("образ диска не подключился") }
        source = NSTemporaryDirectory() + "fcxl-xvol-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        target = volume.mountPoint + "/t-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for root in [source, target].compactMap({ $0 }) {
            Self.unlock(root)
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    // MARK: - Нечитаемое

    func test_нечитаемыйФайлВПапкеЭтоОшибкаАОстальноеСкопировано() throws {
        let folder = try makeTree(["a.txt": "альфа", "secret.txt": "тайна", "b.txt": "бета"])
        chmod(folder + "/secret.txt", 0)
        let destination = target + "/Папка"

        XCTAssertThrowsError(try DarwinFileOperations.copy(
            from: folder, to: destination, progress: nil, shouldCancel: { false })) { error in
            let failure = error as NSError
            XCTAssertNotEqual(failure.code, NSUserCancelledError, "это не отмена пользователем")
            XCTAssertEqual(failure.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(failure.code, Int(EACCES))
            XCTAssertEqual((failure.userInfo[NSFilePathErrorKey] as? String).map { ($0 as NSString).lastPathComponent },
                           "secret.txt", "ошибка называет файл")
        }
        XCTAssertEqual(read(destination + "/a.txt"), "альфа")
        XCTAssertEqual(read(destination + "/b.txt"), "бета")
        XCTAssertFalse(exists(destination + "/secret.txt"), "пустышки вместо файла нет")
    }

    func test_безНаблюдателейНечитаемыйФайлТожеОшибка() throws {
        let folder = try makeTree(["a.txt": "альфа", "secret.txt": "тайна"])
        chmod(folder + "/secret.txt", 0)
        XCTAssertThrowsError(try DarwinFileOperations.copy(
            from: folder, to: target + "/Папка", progress: nil, shouldCancel: nil))
    }

    func test_перемещениеСНечитаемымФайломОставляетИсточникЦелым() throws {
        let folder = try makeTree(["a.txt": "альфа", "secret.txt": "тайна", "b.txt": "бета"])
        chmod(folder + "/secret.txt", 0)

        XCTAssertThrowsError(try DarwinFileOperations.move(
            from: folder, to: target + "/Папка", progress: nil, shouldCancel: { false }))

        chmod(folder + "/secret.txt", 0o644)
        XCTAssertEqual(read(folder + "/secret.txt"), "тайна", "то, что не скопировалось, осталось на месте")
        XCTAssertEqual(read(folder + "/a.txt"), "альфа")
        XCTAssertEqual(read(folder + "/b.txt"), "бета")
    }

    func test_одинНечитаемыйФайлНеПеремещаетсяВНикуда() throws {
        let file = source + "/secret.txt"
        try Data("тайна".utf8).write(to: URL(fileURLWithPath: file))
        chmod(file, 0)

        XCTAssertThrowsError(try DarwinFileOperations.move(
            from: file, to: target + "/secret.txt", progress: nil, shouldCancel: { false }))

        chmod(file, 0o644)
        XCTAssertEqual(read(file), "тайна")
    }

    // MARK: - Источник не удаляется

    func test_сбойУдаленияИсточникаНеСтираетГотовуюКопию() throws {
        let folder = try makeTree(["a.txt": "альфа", "locked.txt": "замок", "b.txt": "бета", "c.txt": "гамма"])
        XCTAssertEqual(chflags(folder + "/locked.txt", UInt32(UF_IMMUTABLE)), 0)
        let destination = target + "/Папка"

        XCTAssertThrowsError(try DarwinFileOperations.move(
            from: folder, to: destination, progress: nil, shouldCancel: { false })) { error in
            XCTAssertNotEqual((error as NSError).code, NSUserCancelledError)
        }

        for (name, text) in ["a.txt": "альфа", "locked.txt": "замок", "b.txt": "бета", "c.txt": "гамма"] {
            XCTAssertEqual(read(destination + "/" + name), text, "копия \(name) цела")
        }
        XCTAssertTrue(exists(folder + "/locked.txt"), "неудаляемый файл источника на месте")
    }

    // MARK: - Только чтение

    func test_папкаСПодпапкойТолькоЧтениеКопируетсяЦеликом() throws {
        let folder = try makeTree(["ro/x.txt": "икс", "ro/глубже/y.txt": "игрек", "z.txt": "зет"])
        chmod(folder + "/ro/глубже", 0o555)
        chmod(folder + "/ro", 0o555)
        let destination = target + "/Папка"

        XCTAssertNoThrow(try DarwinFileOperations.copy(
            from: folder, to: destination, progress: nil, shouldCancel: { false }))

        XCTAssertEqual(read(destination + "/ro/x.txt"), "икс")
        XCTAssertEqual(read(destination + "/ro/глубже/y.txt"), "игрек")
        XCTAssertEqual(read(destination + "/z.txt"), "зет")
        XCTAssertEqual(mode(destination + "/ro"), 0o555, "права папки перенесены")
    }

    func test_существующееНазначениеНеЗатирается() throws {
        let file = source + "/новый.txt"
        try Data("новое".utf8).write(to: URL(fileURLWithPath: file))
        let destination = target + "/старый.txt"
        try Data("старое".utf8).write(to: URL(fileURLWithPath: destination))

        XCTAssertThrowsError(try DarwinFileOperations.copy(
            from: file, to: destination, progress: nil, shouldCancel: { false }))
        XCTAssertEqual(read(destination), "старое")
    }

    func test_ссылкиПризнакиИПустыеПапкиПереносятся() throws {
        let folder = try makeTree(["a.txt": "альфа"])
        try FileManager.default.createDirectory(atPath: folder + "/пусто", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder + "/ссылка", withDestinationPath: "a.txt")
        XCTAssertEqual(setxattr(folder + "/a.txt", "com.fcxl.test", "метка", 10, 0, 0), 0)
        let destination = target + "/Папка"

        XCTAssertNoThrow(try DarwinFileOperations.copy(
            from: folder, to: destination, progress: nil, shouldCancel: { false }))

        XCTAssertTrue(DarwinFileOperations.rawStat(destination + "/пусто").isDir)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination + "/ссылка"), "a.txt")
        XCTAssertGreaterThan(getxattr(destination + "/a.txt", "com.fcxl.test", nil, 0, 0, 0), 0)
    }

    /// Диски без прав и без своих признаков (флешки) не должны давать ложных «не скопировано»:
    /// данные на месте — значит, копия удалась.
    func test_наФлешкахИAPFSДеревоКопируетсяБезЛожныхОшибок() throws {
        let folder = try makeTree(["a.txt": "альфа", "вложено/b.txt": "бета", "ro/c.txt": "гамма"])
        try FileManager.default.createDirectory(atPath: folder + "/пусто", withIntermediateDirectories: true)
        XCTAssertEqual(setxattr(folder + "/a.txt", "com.fcxl.test", "метка", 10, 0, 0), 0)
        chmod(folder + "/ro", 0o555)

        var checked = 0
        for fileSystem in ["ExFAT", "MS-DOS FAT32", "APFS"] {
            guard let disk = try? TestDiskImage(megabytes: 40, fileSystem: fileSystem) else { continue }
            defer { disk.detach() }
            let destination = disk.mountPoint + "/Папка"
            XCTAssertNoThrow(try DarwinFileOperations.copy(
                from: folder, to: destination, progress: nil, shouldCancel: { false }), fileSystem)
            XCTAssertEqual(read(destination + "/a.txt"), "альфа", fileSystem)
            XCTAssertEqual(read(destination + "/вложено/b.txt"), "бета", fileSystem)
            XCTAssertEqual(read(destination + "/ro/c.txt"), "гамма", fileSystem)
            XCTAssertTrue(DarwinFileOperations.rawStat(destination + "/пусто").isDir, fileSystem)
            Self.unlock(destination)
            checked += 1
        }
        if checked == 0 { throw XCTSkip("ни один образ не подключился") }
    }

    // MARK: - Нет места

    func test_нехваткаМестаЭтоОшибкаАНеВечныйЦикл() throws {
        let small = try TestDiskImage(megabytes: 2)
        defer { small.detach() }
        let file = source + "/большой.bin"
        try Data(repeating: 0x5A, count: 6 * 1024 * 1024).write(to: URL(fileURLWithPath: file))
        let destination = small.mountPoint + "/большой.bin"

        // Страховка от зависания: через 15 секунд наблюдатель просит остановиться сам.
        let deadline = Date().addingTimeInterval(15)
        var raised: NSError?
        do {
            try DarwinFileOperations.copy(from: file, to: destination, progress: nil,
                                          shouldCancel: { Date() > deadline })
        } catch {
            raised = error as NSError
        }

        XCTAssertLessThan(Date(), deadline, "копирование остановилось само, а не по страховке")
        XCTAssertEqual(raised?.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(raised?.code, Int(ENOSPC))
        XCTAssertFalse(exists(destination), "обрубка файла на томе не осталось")
    }

    // MARK: - Подспорье

    private func makeTree(_ files: [String: String]) throws -> String {
        let folder = source + "/Папка"
        for (relative, text) in files {
            let path = folder + "/" + relative
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
        return folder
    }

    private func read(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    private func exists(_ path: String) -> Bool {
        DarwinFileOperations.rawStat(path).exists
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    /// Снять запреты со всего дерева, иначе временную папку не убрать.
    private static func unlock(_ root: String) {
        var pending = [root]
        while let path = pending.popLast() {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if info.st_flags != 0 { _ = lchflags(path, 0) }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                if (info.st_mode & S_IFMT) == S_IFREG { chmod(path, 0o644) }
                continue
            }
            chmod(path, 0o755)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                pending.append(path + "/" + name)
            }
        }
    }
}
