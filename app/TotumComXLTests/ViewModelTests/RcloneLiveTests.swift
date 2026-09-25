import XCTest
@testable import TotumComXLApp

/// Мост к rclone целиком: запуск чужого процесса, пароль через окружение, ожидание отклика,
/// разговор по JSON, ход дела и отмена.
///
/// Вместо настоящего rclone здесь его учебный двойник (`rclone_stub.py`): он требует тот же
/// пароль и отвечает на те же вызовы. Так проверяется НАША половина разговора — та, где
/// ошибки наши. Что настоящий rclone отвечает именно так, доказывает уже он сам, живьём.
final class RcloneLiveTests: XCTestCase {

    private var daemon: RcloneDaemon!
    private var fileSystem: RcloneRemoteFileSystem!
    private var storage = ""

    private static var stubPath: String {
        FileManager.default.currentDirectoryPath
            + "/app/TotumComXLTests/Fixtures/rclone_stub.py"
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.stubPath),
                          "нет учебного rclone")

        storage = NSTemporaryDirectory() + "rclone-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: storage,
                                                withIntermediateDirectories: true)
        // Учебный rclone читает это при запуске: хранилище на один тест, чужого в нём нет.
        setenv("TOTUM_RCLONE_STUB_ROOT", storage, 1)
        UserDefaults.standard.set(Self.stubPath, forKey: RcloneDaemon.customPathKey)

        // Свой сервер на каждый тест, а не общий: иначе второй тест разговаривал бы с
        // процессом, поднятым для первого, и смотрел бы в его папку.
        daemon = RcloneDaemon()
        fileSystem = RcloneRemoteFileSystem(connection: Self.connection(to: "мойдиск"),
                                            daemon: daemon)
    }

    override func tearDown() {
        let stopping = daemon
        Task { await stopping?.stop() }
        UserDefaults.standard.removeObject(forKey: RcloneDaemon.customPathKey)
        try? FileManager.default.removeItem(atPath: storage)
        super.tearDown()
    }

    private static func connection(to remote: String) -> RemoteConnection {
        RemoteConnection(label: "проба", proto: .rclone, rcloneRemote: remote)
    }

    private func makeFile(_ name: String, bytes: Int) throws -> String {
        let path = storage + "/" + name
        let data = Data((0..<bytes).map { UInt8($0 % 251) })
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func localFile(_ name: String, bytes: Int) throws -> String {
        let path = NSTemporaryDirectory() + "местный-\(UUID().uuidString)-\(name)"
        let data = Data((0..<bytes).map { UInt8(($0 + 3) % 251) })
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    // MARK: - Запуск и пароль

    /// Учебный rclone отвергает запрос без пароля, который сам же получил в окружении.
    /// Значит удавшееся подключение доказывает: процесс поднят, пароль передан и принят.
    func testConnectingStartsTheHelperAndIsLetIn() async throws {
        try await fileSystem.connect()
        XCTAssertTrue(fileSystem.isConnected)
    }

    /// Имени хранилища, которого у rclone нет, соответствует внятный отказ, а не пустая
    /// панель: человек должен узнать, что искать надо в `rclone config`.
    func testAnUnknownRemoteIsRefusedWithAClearWord() async throws {
        let stranger = RcloneRemoteFileSystem(connection: Self.connection(to: "нетакого"),
                                              daemon: daemon)
        do {
            try await stranger.connect()
            XCTFail("к несуществующему хранилищу подключаться нельзя")
        } catch let error as RemoteFileSystemError {
            guard case .connectionFailed(let text) = error else {
                return XCTFail("это отказ подключения, а не \(error)")
            }
            XCTAssertTrue(text.contains("rclone config"), "сказано, где искать: \(text)")
        }
    }

    func testAMissingRemoteNameIsRefusedBeforeAnythingStarts() async throws {
        let empty = RcloneRemoteFileSystem(connection: Self.connection(to: ""),
                                           daemon: daemon)
        do {
            try await empty.connect()
            XCTFail("без имени хранилища подключаться некуда")
        } catch let error as RemoteFileSystemError {
            guard case .connectionFailed = error else {
                return XCTFail("это отказ подключения, а не \(error)")
            }
        }
    }

    func testTheListOfRemotesComesFromRcloneItself() async throws {
        let remotes = try await RcloneRemoteFileSystem.availableRemotes(daemon: daemon)
        XCTAssertEqual(remotes, ["мойдиск"])
    }

    // MARK: - Список

    func testTheListingShowsFilesAndFoldersApart() async throws {
        try await fileSystem.connect()
        _ = try makeFile("письмо.txt", bytes: 120)
        try FileManager.default.createDirectory(atPath: storage + "/документы",
                                                withIntermediateDirectories: true)

        let items = try await fileSystem.listDirectory(at: "/")
        XCTAssertEqual(items.map(\.name).sorted(), ["документы", "письмо.txt"])

        let folder = try XCTUnwrap(items.first { $0.name == "документы" })
        XCTAssertTrue(folder.isDirectory)
        let file = try XCTUnwrap(items.first { $0.name == "письмо.txt" })
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(file.size, 120, "размер взят у хранилища, а не выдуман")
        XCTAssertEqual(file.path, "/письмо.txt", "путь собран от запрошенной папки")
    }

    /// Путь строится от запрошенной папки, а не из поля `Path` в ответе — иначе на
    /// вложенной папке вышло бы «/папка/папка/файл».
    func testPathsInsideAFolderAreNotDoubled() async throws {
        try await fileSystem.connect()
        try FileManager.default.createDirectory(atPath: storage + "/папка",
                                                withIntermediateDirectories: true)
        _ = try makeFile("папка/внутри.txt", bytes: 10)

        let items = try await fileSystem.listDirectory(at: "/папка")
        XCTAssertEqual(items.map(\.path), ["/папка/внутри.txt"])
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

    func testAFolderIsMadeAndRemovedWithEverythingInside() async throws {
        try await fileSystem.connect()
        try await fileSystem.createDirectory(at: "/", name: "новая")
        _ = try makeFile("новая/внутри.bin", bytes: 64)

        let inside = try await fileSystem.listDirectory(at: "/новая").map(\.name)
        XCTAssertEqual(inside, ["внутри.bin"])

        try await fileSystem.deleteItem(at: "/новая", isDirectory: true)
        let root = try await fileSystem.listDirectory(at: "/")
        XCTAssertNil(root.first { $0.name == "новая" }, "папка ушла вместе с содержимым")
    }

    func testAFileIsRenamedInPlace() async throws {
        try await fileSystem.connect()
        _ = try makeFile("старое.txt", bytes: 32)

        try await fileSystem.rename(at: "/старое.txt", to: "новое.txt")
        let names = try await fileSystem.listDirectory(at: "/").map(\.name)
        XCTAssertEqual(names, ["новое.txt"])
    }

    /// У папок отдельного «переименовать» нет — переезжает содержимое, а пустой исходник
    /// обязан исчезнуть, иначе после каждого переименования оставался бы пустой двойник.
    func testARenamedFolderLeavesNoEmptyTwin() async throws {
        try await fileSystem.connect()
        try FileManager.default.createDirectory(atPath: storage + "/старая",
                                                withIntermediateDirectories: true)
        _ = try makeFile("старая/файл.bin", bytes: 48)

        try await fileSystem.rename(at: "/старая", to: "новая")
        let names = try await fileSystem.listDirectory(at: "/").map(\.name)
        XCTAssertEqual(names, ["новая"], "пустой исходной папки не осталось")
        let moved = try await fileSystem.listDirectory(at: "/новая").map(\.name)
        XCTAssertEqual(moved, ["файл.bin"], "содержимое переехало")
    }

    func testAFileIsDeleted() async throws {
        try await fileSystem.connect()
        _ = try makeFile("лишний.bin", bytes: 16)
        try await fileSystem.deleteItem(at: "/лишний.bin", isDirectory: false)
        let left = try await fileSystem.listDirectory(at: "/")
        XCTAssertTrue(left.isEmpty)
    }

    // MARK: - Перенос

    func testAFileGoesThereAndComesBackByteForByte() async throws {
        try await fileSystem.connect()
        let source = try localFile("документ.bin", bytes: 300_000)
        let original = try Data(contentsOf: URL(fileURLWithPath: source))

        var seen: [Int64] = []
        try await fileSystem.upload(localPath: source, to: "/папка/документ.bin") { done, total in
            seen.append(done)
            XCTAssertEqual(total, Int64(original.count))
            return false
        }
        XCTAssertEqual(seen.last, Int64(original.count), "в конце — весь размер")

        let back = NSTemporaryDirectory() + "назад-\(UUID().uuidString)"
        try await fileSystem.download(remotePath: "/папка/документ.bin", to: back) { _, _ in false }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: back)), original,
                       "файл вернулся тем же, до последнего байта")
    }

    /// Полоса обязана двигаться по ходу дела. Обычный вызов rclone отвечает только по
    /// окончании — на гигабайте это минуты молчания, поэтому перенос идёт заданием.
    func testTheBarMovesWhileTheFileIsStillGoing() async throws {
        try await fileSystem.connect()
        let source = try localFile("толстый.bin", bytes: 900_000)

        var seen: [Int64] = []
        try await fileSystem.upload(localPath: source, to: "/толстый.bin") { done, _ in
            seen.append(done)
            return false
        }
        let moving = Set(seen).count
        XCTAssertGreaterThan(moving, 2, "цифры менялись по ходу, а не разом в конце: \(seen)")
    }

    func testCancellingStopsTheTransfer() async throws {
        try await fileSystem.connect()
        let source = try localFile("отменяемый.bin", bytes: 2_000_000)
        do {
            try await fileSystem.upload(localPath: source, to: "/отменяемый.bin") { done, _ in
                done > 0
            }
            XCTFail("отмена должна прерывать перенос")
        } catch let error as RemoteFileSystemError {
            guard case .transferCancelled = error else {
                return XCTFail("это отмена, а не \(error)")
            }
        }
        let names = try await fileSystem.listDirectory(at: "/").map(\.name)
        XCTAssertFalse(names.contains("отменяемый.bin"),
                       "недокопированный файл в хранилище не остаётся")
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

    // MARK: - Чужой процесс

    /// Помощник обязан уходить вместе с программой. Он чужой процесс: сам он не уйдёт, а
    /// в памяти у него ключи от всех хранилищ человека.
    func testTheHelperDiesWhenTheProgramLeaves() async throws {
        try await fileSystem.connect()
        let helper = try XCTUnwrap(RcloneDaemon.helperProcessID, "помощник поднялся")
        XCTAssertTrue(Self.alive(helper))

        RcloneDaemon.terminateHelper()
        try await Self.waitUntil { !Self.alive(helper) }
        XCTAssertFalse(Self.alive(helper), "и ушёл")
    }

    /// Последнее подключение закрылось — помощник тоже уходит: держать чужой процесс
    /// дольше, чем он нужен, незачем.
    func testTheHelperLeavesWithTheLastConnection() async throws {
        try await fileSystem.connect()
        let helper = try XCTUnwrap(RcloneDaemon.helperProcessID)

        fileSystem.disconnect()
        try await Self.waitUntil { !Self.alive(helper) }
        XCTAssertFalse(Self.alive(helper))
    }

    /// Жив ли процесс — спрашивается у системы. Наши собственные записи о нём здесь не
    /// в счёт: обнулённое поле доказывало бы только то, что мы его обнулили.
    private static func alive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !condition() {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Отменённый перенос

    /// Отменённый показ не должен продолжать колотиться в сервер.
    ///
    /// Так и было: `Task.sleep` при отмене выбрасывает мгновенно, `try?` это глотал — и
    /// цикл ожидания начинал крутиться без пауз, по два запроса на оборот. В просмотрщике
    /// каждое движение курсора отменяет предыдущий показ, и через несколько нажатий
    /// помощник задыхался под этими холостыми запросами: файл из облака открывался
    /// «очень долго», хотя тот же файл копировался мгновенно.
    func testACancelledTransferStopsKnockingAtTheServer() async throws {
        try await fileSystem.connect()
        // Файл кладём заранее и берём покрупнее: учебный помощник копирует его кусками
        // с задержкой, поэтому перенос заведомо ещё идёт, когда его отменяют.
        let source = try localFile("долгий.bin", bytes: 8_000_000)
        try await fileSystem.upload(localPath: source, to: "/долгий.bin") { _, _ in false }

        let work = Task {
            try await fileSystem.download(remotePath: "/долгий.bin", to:
                NSTemporaryDirectory() + "куда-\(UUID().uuidString)") { _, _ in false }
        }
        try await Task.sleep(nanoseconds: 400_000_000)

        let before = try await requestsServed()
        work.cancel()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let after = try await requestsServed()

        XCTAssertLessThan(after - before, 20,
                          "после отмены сервер тревожат единицы раз, а не сотни: \(after - before)")
    }

    /// Сколько запросов обслужил учебный помощник.
    private func requestsServed() async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(await portOfDaemon())/--счёт")!)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (answer["served"] as? NSNumber)?.intValue ?? -1
    }

    private func portOfDaemon() async -> Int {
        await daemon.addressForTests?.port ?? 0
    }

    /// Помощник не должен гибнуть от ЗАПОЗДАЛОГО чужого «отпускаю».
    ///
    /// Настоящий случай, из-за которого подключение падало с «rclone запустился, но не
    /// отвечает». Окно выбора хранилищ берёт помощника и отпускает его следом, отложенно.
    /// Человек в это время нажимает «Подключиться» — поднимается НОВЫЙ помощник, и вот
    /// тут приходит то самое запоздалое «отпускаю» от старого. Оно гасило нового.
    func testALateLetGoDoesNotKillTheNextHelper() async throws {
        // Первый берёт помощника и отпускает — помощник гаснет, место закрыто.
        let first = try await daemon.acquire()
        await daemon.release(first.ticket)

        // Второй поднимает нового…
        let second = try await daemon.acquire()
        // …и тут приходит запоздалое «отпускаю» от первого.
        await daemon.release(first.ticket)

        let answer = try await daemon.call("rc/noop", ["жив": true])
        XCTAssertEqual(answer["жив"] as? Bool, true,
                       "новый помощник жив: чужое место его не касается")
        await daemon.release(second.ticket)
    }

    /// А своё «отпускаю» помощника гасит — держать чужой процесс дольше нужного незачем.
    func testTheLastOwnLetGoStopsTheHelper() async throws {
        let place = try await daemon.acquire()
        let helper = try XCTUnwrap(RcloneDaemon.helperProcessID)
        await daemon.release(place.ticket)
        try await Self.waitUntil { !Self.alive(helper) }
        XCTAssertFalse(Self.alive(helper))
    }

    /// Двое держат — уход одного помощника не роняет.
    func testTheHelperStaysWhileSomebodyStillHoldsIt() async throws {
        let one = try await daemon.acquire()
        let two = try await daemon.acquire()
        await daemon.release(one.ticket)

        let answer = try await daemon.call("rc/noop", ["жив": true])
        XCTAssertEqual(answer["жив"] as? Bool, true, "второй держатель ещё здесь")
        await daemon.release(two.ticket)
    }

    // MARK: - Родные документы Google

    /// Правки в документе Google (Docs/Sheets/Slides) должны доезжать обратно.
    ///
    /// Такой документ — не файл: перезаписать его байтами Диск не даёт и отвечает
    /// «can't update google document type without --drive-import-formats». Человек видел
    /// это как «Не удалось отправить» на правках, которые сам же сохранил. Клиент обязан
    /// повторить отправку с ключом ввоза — двойник, как настоящий Диск, без ключа
    /// отказывает и принимает с ним.
    func testEditsInAGoogleDocComeBackThroughImport() async throws {
        try await fileSystem.connect()
        let source = try localFile("правки.docx", bytes: 5_000)
        let original = try Data(contentsOf: URL(fileURLWithPath: source))

        try await fileSystem.upload(localPath: source, to: "/гуглодок-отчёт.docx") { _, _ in
            false
        }

        let back = NSTemporaryDirectory() + "гуглодок-\(UUID().uuidString)"
        try await fileSystem.download(remotePath: "/гуглодок-отчёт.docx", to: back) { _, _ in
            false
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: back)), original,
                       "правки доехали, хотя без ключа ввоза Диск отказал")
    }

    /// Проба записи, которой подключение проверяет сервер: пустой файл со служебным
    /// именем должен уехать и удалиться. Раньше проба брала источником /dev/null —
    /// устройство, не файл, — rclone отказывался, и Google Drive объявлялся «только для
    /// чтения», хотя загрузка работала.
    func testAnEmptyProbeFileGoesThroughLikeTheHealthCheckDoes() async throws {
        try await fileSystem.connect()
        let probe = NSTemporaryDirectory() + ".fcxl_write_test_проба"
        FileManager.default.createFile(atPath: probe, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: probe) }

        try await fileSystem.upload(localPath: probe,
                                    to: "/.fcxl_write_test_проба") { _, _ in false }
        try await fileSystem.deleteItem(at: "/.fcxl_write_test_проба", isDirectory: false)
        let left = try await fileSystem.listDirectory(at: "/")
        XCTAssertNil(left.first { $0.name.hasPrefix(".fcxl_write_test") },
                     "проба уехала и убрана — сервер записываем")
    }
}
