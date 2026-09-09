import XCTest
@testable import TotumComXLApp

/// То же самое, но с НАСТОЯЩИМ rclone — тем, который едет внутри программы.
///
/// Учебный двойник проверяет нашу половину разговора; эта проверка — вторую: что rclone
/// действительно отвечает так, как мы прочли в его описании. Ошибка здесь — это ошибка
/// нашего понимания чужой программы, и найти её больше негде.
///
/// Хранилище — псевдоним (`alias`) на временную папку: настоящий бэкенд rclone, работающий
/// ровно как облачный, но без облака. Настройка своя, во временном файле: трогать
/// настоящую настройку человека тесты не должны.
final class RcloneRealTests: XCTestCase {

    private var daemon: RcloneDaemon!
    private var fileSystem: RcloneRemoteFileSystem!
    private var storage = ""
    private var configPath = ""

    /// Тот самый rclone, который кладётся внутрь программы.
    private static var realPath: String {
        FileManager.default.currentDirectoryPath + "/third_party/rclone/rclone"
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.realPath),
                          "нет rclone — достаньте его: ./scripts/fetch-rclone.sh")

        storage = NSTemporaryDirectory() + "rclone-real-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: storage,
                                                withIntermediateDirectories: true)
        configPath = storage + ".conf"
        // Два хранилища на разные надобности. «Мойдиск» — псевдоним на папку: по нему
        // проверяются список, имена и удаление. «Память» — встроенное в rclone хранилище
        // в памяти; оно нужно там, где важно, чтобы байты ШЛИ.
        //
        // На APFS копия из папки в папку делается клонированием: файл появляется целиком и
        // мгновенно, ни один байт не проходит через счётчик. Для человека это прекрасно, а
        // для проверки полосы и отмены бесполезно — проверять было бы нечего.
        try ("[мойдиск]\ntype = alias\nremote = \(storage)\n\n"
             + "[память]\ntype = memory\n")
            .write(toFile: configPath, atomically: true, encoding: .utf8)
        setenv("RCLONE_CONFIG", configPath, 1)
        UserDefaults.standard.set(Self.realPath, forKey: RcloneDaemon.customPathKey)

        daemon = RcloneDaemon()
        fileSystem = RcloneRemoteFileSystem(
            connection: RemoteConnection(proto: .rclone, rcloneRemote: "мойдиск"),
            daemon: daemon)
    }

    override func tearDown() {
        let stopping = daemon
        Task { await stopping?.stop() }
        UserDefaults.standard.removeObject(forKey: RcloneDaemon.customPathKey)
        unsetenv("RCLONE_CONFIG")
        try? FileManager.default.removeItem(atPath: storage)
        try? FileManager.default.removeItem(atPath: configPath)
        super.tearDown()
    }

    private func makeFile(_ name: String, bytes: Int) throws {
        let data = Data((0..<bytes).map { UInt8($0 % 251) })
        try data.write(to: URL(fileURLWithPath: storage + "/" + name))
    }

    private func localFile(_ name: String, bytes: Int) throws -> String {
        let path = NSTemporaryDirectory() + "местный-\(UUID().uuidString)-\(name)"
        try Data((0..<bytes).map { UInt8(($0 + 3) % 251) })
            .write(to: URL(fileURLWithPath: path))
        return path
    }

    // MARK: - Запуск

    func testTheBundledHelperStartsAndAnswers() async throws {
        try await fileSystem.connect()
        XCTAssertTrue(fileSystem.isConnected)
    }

    func testRealRcloneListsItsRemotes() async throws {
        let remotes = try await RcloneRemoteFileSystem.availableRemotes(daemon: daemon)
        XCTAssertEqual(remotes, ["мойдиск", "память"])
    }

    /// Хранилище, куда байты действительно идут — со скоростью, которую мы задаём.
    private func slowStorage() async throws -> RcloneRemoteFileSystem {
        let memory = RcloneRemoteFileSystem(
            connection: RemoteConnection(proto: .rclone, rcloneRemote: "память"),
            daemon: daemon)
        try await memory.connect()
        try await daemon.call("core/bwlimit", ["rate": "2M"])
        return memory
    }

    func testAnUnknownRemoteIsRefused() async throws {
        let stranger = RcloneRemoteFileSystem(
            connection: RemoteConnection(proto: .rclone, rcloneRemote: "нетакого"),
            daemon: daemon)
        do {
            try await stranger.connect()
            XCTFail("к несуществующему хранилищу подключаться нельзя")
        } catch let error as RemoteFileSystemError {
            guard case .connectionFailed = error else {
                return XCTFail("это отказ подключения, а не \(error)")
            }
        }
    }

    // MARK: - Список

    /// Главная проверка разбора: имена, размеры, папки и время — из настоящей выдачи.
    func testTheRealListingIsReadCorrectly() async throws {
        try await fileSystem.connect()
        try makeFile("письмо.txt", bytes: 120)
        try FileManager.default.createDirectory(atPath: storage + "/документы",
                                                withIntermediateDirectories: true)

        let items = try await fileSystem.listDirectory(at: "/")
        XCTAssertEqual(items.map(\.name).sorted(), ["документы", "письмо.txt"])

        let folder = try XCTUnwrap(items.first { $0.name == "документы" })
        XCTAssertTrue(folder.isDirectory)
        XCTAssertEqual(folder.size, 0, "у папки размера нет, а rclone отдаёт −1")

        let file = try XCTUnwrap(items.first { $0.name == "письмо.txt" })
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(file.size, 120)
        XCTAssertEqual(file.path, "/письмо.txt")
        XCTAssertGreaterThan(file.dateModified.timeIntervalSince1970, 1_600_000_000,
                             "время разобрано, а не подставлено сегодняшним")
    }

    /// Поле `Path` у настоящего rclone относительно запрошенной папки — и именно поэтому
    /// путь мы собираем сами: перепутать здесь значит получить «/папка/папка/файл».
    func testNestedPathsAreNotDoubled() async throws {
        try await fileSystem.connect()
        try FileManager.default.createDirectory(atPath: storage + "/папка/глубже",
                                                withIntermediateDirectories: true)
        try makeFile("папка/глубже/внутри.txt", bytes: 10)

        let items = try await fileSystem.listDirectory(at: "/папка/глубже")
        XCTAssertEqual(items.map(\.path), ["/папка/глубже/внутри.txt"])
    }

    func testListingAMissingFolderSaysPathNotFound() async throws {
        try await fileSystem.connect()
        do {
            _ = try await fileSystem.listDirectory(at: "/нет такой")
            XCTFail("несуществующая папка не может показать список")
        } catch let error as RemoteFileSystemError {
            guard case .pathNotFound = error else {
                return XCTFail("это «пути нет», а не \(error)")
            }
        }
    }

    // MARK: - Папки и имена

    func testAFolderIsMadeAndPurgedWithEverythingInside() async throws {
        try await fileSystem.connect()
        try await fileSystem.createDirectory(at: "/", name: "новая")
        try makeFile("новая/внутри.bin", bytes: 64)

        let inside = try await fileSystem.listDirectory(at: "/новая").map(\.name)
        XCTAssertEqual(inside, ["внутри.bin"])

        try await fileSystem.deleteItem(at: "/новая", isDirectory: true)
        let root = try await fileSystem.listDirectory(at: "/")
        XCTAssertNil(root.first { $0.name == "новая" })
    }

    func testAFileIsRenamed() async throws {
        try await fileSystem.connect()
        try makeFile("старое.txt", bytes: 32)
        try await fileSystem.rename(at: "/старое.txt", to: "новое.txt")
        let names = try await fileSystem.listDirectory(at: "/").map(\.name)
        XCTAssertEqual(names, ["новое.txt"])
    }

    /// Переименование папки у rclone — переезд содержимого. Пустой исходник обязан исчезнуть.
    func testARenamedFolderLeavesNoEmptyTwin() async throws {
        try await fileSystem.connect()
        try FileManager.default.createDirectory(atPath: storage + "/старая",
                                                withIntermediateDirectories: true)
        try makeFile("старая/файл.bin", bytes: 48)

        try await fileSystem.rename(at: "/старая", to: "новая")
        let names = try await fileSystem.listDirectory(at: "/").map(\.name)
        XCTAssertEqual(names, ["новая"], "пустой исходной папки не осталось")
        let moved = try await fileSystem.listDirectory(at: "/новая").map(\.name)
        XCTAssertEqual(moved, ["файл.bin"])
    }

    func testAFileIsDeleted() async throws {
        try await fileSystem.connect()
        try makeFile("лишний.bin", bytes: 16)
        try await fileSystem.deleteItem(at: "/лишний.bin", isDirectory: false)
        let left = try await fileSystem.listDirectory(at: "/")
        XCTAssertTrue(left.isEmpty)
    }

    // MARK: - Перенос

    func testAFileGoesThereAndComesBackByteForByte() async throws {
        try await fileSystem.connect()
        let source = try localFile("документ.bin", bytes: 400_000)
        let original = try Data(contentsOf: URL(fileURLWithPath: source))

        try await fileSystem.upload(localPath: source, to: "/папка/документ.bin") { _, _ in false }

        let back = NSTemporaryDirectory() + "назад-\(UUID().uuidString)"
        try await fileSystem.download(remotePath: "/папка/документ.bin", to: back) { _, _ in false }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: back)), original)
    }

    /// Полоса берётся из `core/stats` по имени группы. Если настоящий rclone считает
    /// группы иначе, чем мы поняли, здесь будут нули — и это надо знать.
    ///
    /// Скорость ограничена нарочно: без этого перенос кончается раньше первого опроса и
    /// проверка доказывала бы только то, что диск быстрый. С ограничением видно ровно то,
    /// что увидит человек на настоящем облаке.
    func testProgressComesFromRealStats() async throws {
        let storage = try await slowStorage()
        let size: Int64 = 6 << 20
        let source = try localFile("толстый.bin", bytes: Int(size))

        var seen: [Int64] = []
        try await storage.upload(localPath: source, to: "/толстый.bin") { done, total in
            seen.append(done)
            XCTAssertEqual(total, size)
            return false
        }
        XCTAssertEqual(seen.last, size, "в конце — весь размер")
        XCTAssertTrue(seen.contains { $0 > 0 && $0 < size },
                      "полоса шла по ходу дела, а не прыгнула с нуля в конец: \(seen)")
    }

    /// Отмена обязана убирать огрызок. Настоящий rclone пишет прямо в назначение и после
    /// остановки оставляет там половину файла под настоящим именем — за ним убираем мы.
    func testCancellingStopsTheRealTransfer() async throws {
        let storage = try await slowStorage()
        let source = try localFile("отменяемый.bin", bytes: 12 << 20)
        do {
            try await storage.upload(localPath: source, to: "/отменяемый.bin") { done, _ in
                done > 0
            }
            XCTFail("отмена должна прерывать перенос")
        } catch let error as RemoteFileSystemError {
            guard case .transferCancelled = error else {
                return XCTFail("это отмена, а не \(error)")
            }
        }
        let names = try await storage.listDirectory(at: "/").map(\.name)
        XCTAssertFalse(names.contains("отменяемый.bin"),
                       "недокопированный файл в хранилище не остаётся")
    }

    /// Отменённое скачивание не должно оставлять огрызок на диске у человека: файл с
    /// настоящим именем и половиной содержимого выглядит законченным, и однажды на него
    /// положатся.
    func testCancellingADownloadLeavesNoHalfFileOnDisk() async throws {
        let storage = try await slowStorage()
        let size = 12 << 20
        let source = try localFile("большой.bin", bytes: size)
        try await storage.upload(localPath: source, to: "/большой.bin") { _, _ in false }

        let target = NSTemporaryDirectory() + "огрызок-\(UUID().uuidString).bin"
        do {
            try await storage.download(remotePath: "/большой.bin", to: target) { done, _ in
                done > 0
            }
            XCTFail("отмена должна прерывать скачивание")
        } catch let error as RemoteFileSystemError {
            guard case .transferCancelled = error else {
                return XCTFail("это отмена, а не \(error)")
            }
        }

        let left = (try? Data(contentsOf: URL(fileURLWithPath: target)))?.count
        XCTAssertNil(left, "недокачанного файла на диске не осталось (было \(left ?? -1) байт)")
    }

    func testDownloadingAMissingFileSaysPathNotFound() async throws {
        try await fileSystem.connect()
        let target = NSTemporaryDirectory() + "пусто-\(UUID().uuidString)"
        do {
            try await fileSystem.download(remotePath: "/нет.bin", to: target) { _, _ in false }
            XCTFail("скачивать нечего")
        } catch let error as RemoteFileSystemError {
            guard case .pathNotFound = error else {
                return XCTFail("это «пути нет», а не \(error)")
            }
        }
    }

    // MARK: - Заведение облака

    /// Хранилище заводится одним нашим вызовом, без Терминала и без вопросов человеку.
    ///
    /// Разговор с rclone тут не один запрос, а несколько: он спрашивает про общий ключ,
    /// про обновление пропуска, про общий диск организации. Проверяется главное — что
    /// разговор доходит до конца и в настройке оказывается ровно то, что нужно.
    func testACloudIsCreatedWithoutAnyTerminal() async throws {
        let token = "{\"access_token\":\"пропуск\",\"token_type\":\"Bearer\","
            + "\"refresh_token\":\"ещё\",\"expiry\":\"2030-01-01T00:00:00Z\"}"
        let drive = try XCTUnwrap(RcloneCloudService.popular.first { $0.type == "drive" })

        try await RcloneCloudSetup.createRemote(named: "Мой диск", service: drive,
                                                token: token, daemon: daemon)

        let remotes = try await RcloneRemoteFileSystem.availableRemotes(daemon: daemon)
        XCTAssertTrue(remotes.contains("Мой диск"), "облако появилось в списке: \(remotes)")

        let written = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(written.contains("[Мой диск]"))
        XCTAssertTrue(written.contains("type = drive"))
        XCTAssertTrue(written.contains("scope = drive"), "просим доступ ко всему диску")
        XCTAssertTrue(written.contains("пропуск"), "пропуск записан")
        // Отвечать «как по умолчанию» на всё нельзя: на вопросы про ключ службы так в
        // настройку попадало «client_id = true» — мусор, с которым вход не работает.
        XCTAssertFalse(written.contains("client_id = true"), "в настройке нет мусора:\n\(written)")
        XCTAssertFalse(written.contains("client_secret = true"))
    }

    /// И убирается тоже нами: заводить из окна, а удалять из Терминала было бы издевательством.
    func testACloudIsRemovedAgain() async throws {
        let drive = try XCTUnwrap(RcloneCloudService.popular.first { $0.type == "dropbox" })
        try await RcloneCloudSetup.createRemote(named: "Временное", service: drive,
                                                token: "{\"access_token\":\"ф\"}",
                                                daemon: daemon)
        try await RcloneCloudSetup.deleteRemote(named: "Временное", daemon: daemon)

        let remotes = try await RcloneRemoteFileSystem.availableRemotes(daemon: daemon)
        XCTAssertFalse(remotes.contains("Временное"))
    }

    /// Поход за пропуском: rclone поднимает свою страничку и даёт ссылку, которую мы
    /// открываем человеку в браузере. Дальше него не идём — там живой Google.
    func testAuthorizeOffersALinkAndObeysCancel() async throws {
        let waiting = expectation(description: "ссылка пришла")
        let drive = try XCTUnwrap(RcloneCloudService.popular.first { $0.type == "drive" })

        var got: URL?
        let work = Task {
            try await RcloneCloudSetup.authorize(service: drive) { url in
                if got == nil { got = url; waiting.fulfill() }
            }
        }
        await fulfillment(of: [waiting], timeout: 20)
        XCTAssertEqual(got?.host, "127.0.0.1", "ссылка ведёт на страничку самого rclone")
        XCTAssertTrue(got?.path.contains("auth") == true, "и именно на разрешение доступа: \(got as Any)")

        // Отмена обязана снимать чужой процесс: иначе он так и сидел бы на своём порту,
        // и второй заход упёрся бы в занятый порт.
        work.cancel()
        do {
            _ = try await work.value
            XCTFail("после отмены пропуска быть не может")
        } catch {}
        try await Self.waitUntilNoAuthorizeIsRunning()
    }

    /// Отмена в первое же мгновение — до того, как rclone успел подняться.
    ///
    /// Так и бывает: человек нажал «Разрешить доступ», сразу передумал и закрыл окно.
    /// Спросить «процесс ещё бежит?» и уйти здесь мало — он побежит через миг и останется
    /// сидеть на своём порту, а следующая попытка упрётся в занятый порт.
    func testCancellingBeforeTheHelperEvenStartsStillKillsIt() async throws {
        let drive = try XCTUnwrap(RcloneCloudService.popular.first { $0.type == "drive" })
        let work = Task {
            try await RcloneCloudSetup.authorize(service: drive) { _ in }
        }
        work.cancel()
        _ = try? await work.value
        try await Self.waitUntilNoAuthorizeIsRunning()
    }

    private static func waitUntilNoAuthorizeIsRunning() async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, authorizeIsRunning() {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertFalse(authorizeIsRunning(), "ждущий пропуска rclone не остался висеть")
    }

    /// Спрашивается у системы, а не у наших записей.
    private static func authorizeIsRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "rclone authorize"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
