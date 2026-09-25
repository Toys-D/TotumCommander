import XCTest
@testable import TotumComXLApp

/// Местная копия удалённого файла — то, без чего просмотрщик и системная программа видят
/// на месте файла пустоту: они умеют читать диск, а не облако.
///
/// Проверяется на настоящем rclone: хранилище — псевдоним на временную папку.
@MainActor
final class RemoteFileCacheTests: XCTestCase {

    private var daemon: RcloneDaemon!
    private var session: RemoteSession!
    private var storage = ""
    private var configPath = ""

    private static var realPath: String {
        FileManager.default.currentDirectoryPath + "/third_party/rclone/rclone"
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.realPath),
                          "нет rclone — достаньте его: ./scripts/fetch-rclone.sh")
        storage = NSTemporaryDirectory() + "кэш-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: storage,
                                                withIntermediateDirectories: true)
        configPath = storage + ".conf"
        try "[мойдиск]\ntype = alias\nremote = \(storage)\n"
            .write(toFile: configPath, atomically: true, encoding: .utf8)
        setenv("RCLONE_CONFIG", configPath, 1)
        UserDefaults.standard.set(Self.realPath, forKey: RcloneDaemon.customPathKey)

        daemon = RcloneDaemon()
        let connection = RemoteConnection(label: "Google Drive", proto: .rclone,
                                          rcloneRemote: "мойдиск", cloudService: "drive")
        session = RemoteSession(connection: connection,
                                fileSystem: RcloneRemoteFileSystem(connection: connection,
                                                                   daemon: daemon))
    }

    override func tearDown() {
        RemoteFileCache.shared.forget(connectionID: session.connection.id)
        let stopping = daemon
        Task { await stopping?.stop() }
        UserDefaults.standard.removeObject(forKey: RcloneDaemon.customPathKey)
        unsetenv("RCLONE_CONFIG")
        try? FileManager.default.removeItem(atPath: storage)
        try? FileManager.default.removeItem(atPath: configPath)
        super.tearDown()
    }

    private func put(_ relativePath: String, bytes: Int) throws -> Data {
        let full = storage + "/" + relativePath
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let data = Data((0..<bytes).map { UInt8(($0 * 7) % 251) })
        try data.write(to: URL(fileURLWithPath: full))
        return data
    }

    private func item(at path: String) async throws -> FileItem {
        let folder = (path as NSString).deletingLastPathComponent
        let items = try await session.fileSystem.listDirectory(at: folder.isEmpty ? "/" : folder)
        return try XCTUnwrap(items.first { $0.name == (path as NSString).lastPathComponent })
    }

    // MARK: - Копия

    func testARemoteFileGetsALocalCopyByteForByte() async throws {
        try await session.fileSystem.connect()
        let original = try put("снимок.png", bytes: 40_000)

        let target = try await item(at: "/снимок.png")
        let local = try await RemoteFileCache.shared.localCopy(of: target, session: session)

        XCTAssertTrue(FileManager.default.fileExists(atPath: local), "копия на диске: \(local)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: local)), original)
        XCTAssertEqual((local as NSString).lastPathComponent, "снимок.png",
                       "имя сохранено — просмотрщик судит о файле по нему")
    }

    /// Листая папку туда-сюда, человек не должен качать одну и ту же картинку по десять раз.
    func testAnAlreadyFetchedCopyIsReused() async throws {
        try await session.fileSystem.connect()
        _ = try put("картинка.png", bytes: 20_000)
        let target = try await item(at: "/картинка.png")
        let first = try await RemoteFileCache.shared.localCopy(of: target, session: session)

        // Файл убран из хранилища: если копию попробуют скачать заново, ничего не выйдет.
        try FileManager.default.removeItem(atPath: storage + "/картинка.png")
        let second = try await RemoteFileCache.shared.localCopy(of: target, session: session)
        XCTAssertEqual(first, second, "вернулась та же копия, без похода в хранилище")
    }

    /// Два «снимок.png» из разных папок — разные файлы, и копии у них разные. Иначе
    /// просмотрщик показывал бы один вместо другого.
    func testSameNameInDifferentFoldersDoesNotCollide() async throws {
        try await session.fileSystem.connect()
        let one = try put("первая/снимок.png", bytes: 1_000)
        let two = try put("вторая/снимок.png", bytes: 2_000)

        let localOne = try await RemoteFileCache.shared.localCopy(
            of: try await item(at: "/первая/снимок.png"), session: session)
        let localTwo = try await RemoteFileCache.shared.localCopy(
            of: try await item(at: "/вторая/снимок.png"), session: session)

        XCTAssertNotEqual(localOne, localTwo)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: localOne)), one)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: localTwo)), two)
    }

    /// Файл в облаке изменился — копия устарела и должна поехать заново, иначе человек
    /// смотрел бы на вчерашнее содержимое сегодняшнего файла.
    func testAChangedFileIsFetchedAgain() async throws {
        try await session.fileSystem.connect()
        _ = try put("отчёт.txt", bytes: 500)
        let before = try await item(at: "/отчёт.txt")
        _ = try await RemoteFileCache.shared.localCopy(of: before, session: session)

        let changed = try put("отчёт.txt", bytes: 900)
        let after = try await item(at: "/отчёт.txt")
        let local = try await RemoteFileCache.shared.localCopy(of: after, session: session)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: local)), changed,
                       "копия обновилась вместе с файлом")
    }

    func testForgettingAConnectionRemovesItsCopies() async throws {
        try await session.fileSystem.connect()
        _ = try put("временный.bin", bytes: 100)
        let target = try await item(at: "/временный.bin")
        let local = try await RemoteFileCache.shared.localCopy(of: target, session: session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local))

        RemoteFileCache.shared.forget(connectionID: session.connection.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local),
                       "копии ушли вместе с подключением")
    }

    /// Документ Google (Docs, Sheets, Slides) — файл без размера: Диск собирает его на
    /// лету при выгрузке и заранее не знает, сколько получится. Копия такого документа
    /// обязана переиспользоваться, иначе каждый взгляд запускает выгрузку заново — а она
    /// у Диска стоит двадцати секунд, и просмотр выглядит зависшим.
    func testADocumentWithoutAKnownSizeIsStillReused() async throws {
        try await session.fileSystem.connect()
        _ = try put("таблица.xlsx", bytes: 5_000)
        let real = try await item(at: "/таблица.xlsx")

        let local = try await RemoteFileCache.shared.localCopy(of: real, session: session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local))

        // Ровно то, что приходит от Google Drive: имя и время есть, размера нет.
        let asGoogleReportsIt = FileItem(
            path: real.path, name: real.name, fileExtension: real.fileExtension,
            size: 0, isDirectory: false, isHidden: false, isSymlink: false,
            permissions: "-rw-r--r--", dateModified: real.dateModified)

        XCTAssertEqual(
            RemoteFileCache.shared.readyCopy(of: asGoogleReportsIt,
                                             connectionID: session.connection.id),
            local,
            "копия узнана по времени правки, хотя размер неизвестен")
    }

    /// Но копия чужого времени за свою не выдаётся: правленый в облаке файл едет заново.
    func testACopyOfAnOlderVersionIsNotReused() async throws {
        try await session.fileSystem.connect()
        _ = try put("правленый.txt", bytes: 300)
        let first = try await item(at: "/правленый.txt")
        _ = try await RemoteFileCache.shared.localCopy(of: first, session: session)

        let newer = FileItem(
            path: first.path, name: first.name, fileExtension: first.fileExtension,
            size: 0, isDirectory: false, isHidden: false, isSymlink: false,
            permissions: "-rw-r--r--",
            dateModified: first.dateModified.addingTimeInterval(60))
        XCTAssertNil(RemoteFileCache.shared.readyCopy(of: newer,
                                                      connectionID: session.connection.id),
                     "время правки другое — копия устарела")
    }

    // MARK: - Когда копии уходят

    /// Ушла последняя панель — ушли и копии: человек отключился от облака, и чужих файлов
    /// у него на диске оставаться не должно.
    func testCopiesGoWithTheLastPanelThatLeaves() async throws {
        try await session.fileSystem.connect()
        _ = try put("снимок.png", bytes: 1_000)
        let target = try await item(at: "/снимок.png")

        RemoteFileCache.shared.hold(connectionID: session.connection.id)
        let local = try await RemoteFileCache.shared.localCopy(of: target, session: session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local))

        RemoteFileCache.shared.release(connectionID: session.connection.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local), "копии ушли")
    }

    /// Одно хранилище часто открыто в обеих панелях. Уход из одной не должен уносить
    /// копии из-под другой — иначе соседняя панель показывала бы пустоту.
    func testCopiesSurviveWhileTheOtherPanelIsStillThere() async throws {
        try await session.fileSystem.connect()
        _ = try put("общий.png", bytes: 1_000)
        let target = try await item(at: "/общий.png")

        RemoteFileCache.shared.hold(connectionID: session.connection.id)
        RemoteFileCache.shared.hold(connectionID: session.connection.id)
        let local = try await RemoteFileCache.shared.localCopy(of: target, session: session)

        RemoteFileCache.shared.release(connectionID: session.connection.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local),
                      "вторая панель ещё смотрит — копия на месте")

        RemoteFileCache.shared.release(connectionID: session.connection.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local))
    }

    // MARK: - Правки едут обратно

    /// Весь круг на настоящем rclone: файл из хранилища открыт копией, копию правят —
    /// присмотр отправляет правки назад, и в хранилище лежит новое содержимое.
    func testEditedCopyGoesBackToTheStorage() async throws {
        try await session.fileSystem.connect()
        _ = try put("отчёт.docx", bytes: 500)
        let target = try await item(at: "/отчёт.docx")
        let copy = try await RemoteFileCache.shared.localCopy(of: target, session: session)

        let watcher = RemoteEditWatcher()
        watcher.makeProgress = { _, _ in nil }
        watcher.complain = { _, _ in }
        watcher.askToSend = { _, _ in true }
        watcher.watch(localPath: copy, item: target, session: session)

        // Человек «поправил в Word и сохранил».
        let edited = Data("правленый отчёт".utf8)
        try edited.write(to: URL(fileURLWithPath: copy))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: copy)

        await watcher.checkNow()   // замечено
        await watcher.checkNow()   // устоялось — спрошено и отправлено

        let inStorage = try Data(contentsOf: URL(fileURLWithPath: storage + "/отчёт.docx"))
        XCTAssertEqual(inStorage, edited, "в хранилище — правленое содержимое")
        XCTAssertTrue(watcher.dirtyNames(for: session.connection.id).isEmpty)
    }
}
