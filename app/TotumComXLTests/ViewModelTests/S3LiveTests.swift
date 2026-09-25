import XCTest
@testable import TotumComXLApp

/// Проверка на настоящем сговоре: рядом поднимается S3-совместимый сервер, который сам
/// пересчитывает подпись по независимой реализации и отвергает запрос, если она не сошлась.
///
/// Заглушка, отвечающая заранее заготовленным XML, доказала бы только то, что мы умеем
/// читать свои же ответы. Здесь же проверяется весь сговор целиком: адресация, кодирование
/// ключей, подпись, разбор списка, отправка частями, докачка.
final class S3LiveTests: XCTestCase {

    private var server: Process?
    private var port: Int = 0
    private var fileSystem: S3RemoteFileSystem!

    override func setUpWithError() throws {
        let script = Self.serverScript
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script),
                          "нет пробного сервера")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script, "0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        server = process

        // Сервер печатает выбранный порт первой строкой.
        let handle = pipe.fileHandleForReading
        var line = Data()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !line.contains(0x0A) {
            line.append(handle.availableData)
        }
        guard let text = String(data: line, encoding: .utf8),
              let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw XCTSkip("сервер не сообщил порт")
        }
        port = number

        let connection = RemoteConnection(
            label: "проба", proto: .s3, host: "127.0.0.1", port: UInt16(port),
            username: "AKIAIOSFODNN7EXAMPLE", initialPath: "/",
            s3Bucket: "проба", s3Region: "us-east-1",
            s3UsePathStyle: true, s3UsesTLS: false)
        fileSystem = S3RemoteFileSystem(
            connection: connection,
            password: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    }

    override func tearDown() {
        fileSystem?.disconnect()
        server?.terminate()
        server = nil
        super.tearDown()
    }

    private static var serverScript: String {
        // Тесты запускаются из корня пакета.
        FileManager.default.currentDirectoryPath
            + "/app/TotumComXLTests/Fixtures/s3_test_server.py"
    }

    private func temporaryFile(named name: String, bytes: Int) throws -> String {
        let path = NSTemporaryDirectory() + "s3-\(UUID().uuidString)-\(name)"
        let data = Data((0..<bytes).map { UInt8($0 % 251) })
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    // MARK: - Подключение и подпись

    /// Если подпись расходится хоть на символ, сервер отвечает отказом — значит успешное
    /// подключение и есть доказательство, что две независимые реализации сошлись.
    func testConnectingProvesTheSignatureIsAccepted() async throws {
        try await fileSystem.connect()
        XCTAssertTrue(fileSystem.isConnected)
    }

    func testAWrongSecretIsRefused() async throws {
        let connection = RemoteConnection(
            proto: .s3, host: "127.0.0.1", port: UInt16(port),
            username: "AKIAIOSFODNN7EXAMPLE",
            s3Bucket: "проба", s3UsePathStyle: true, s3UsesTLS: false)
        let wrong = S3RemoteFileSystem(connection: connection, password: "не тот ключ")
        do {
            try await wrong.connect()
            XCTFail("с чужим ключом подключаться нельзя")
        } catch let error as RemoteFileSystemError {
            guard case .authenticationFailed = error else {
                return XCTFail("это отказ в доступе, а не \(error)")
            }
        }
    }

    // MARK: - Файлы

    func testAFileGoesThereAndComesBackByteForByte() async throws {
        try await fileSystem.connect()
        let source = try temporaryFile(named: "письмо.txt", bytes: 4096)
        let original = try Data(contentsOf: URL(fileURLWithPath: source))

        try await fileSystem.upload(localPath: source, to: "/папка/письмо.txt") { _, _ in false }

        let back = NSTemporaryDirectory() + "s3-back-\(UUID().uuidString)"
        try await fileSystem.download(remotePath: "/папка/письмо.txt", to: back) { _, _ in false }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: back)), original,
                       "файл вернулся тем же, до последнего байта")
    }

    /// Кириллица, пробелы и знаки процента в имени — обычное дело, и подпись обязана их
    /// пережить: ошибка в кодировании даёт отказ сервера, а не искажённое имя.
    func testAwkwardNamesSurviveTheSignature() async throws {
        try await fileSystem.connect()
        let names = ["Отчёт №1 (черновик).txt", "100% готово.txt", "a+b=c.txt"]
        for name in names {
            let source = try temporaryFile(named: "x.bin", bytes: 64)
            try await fileSystem.upload(localPath: source, to: "/имена/" + name) { _, _ in false }
        }
        let listed = try await fileSystem.listDirectory(at: "/имена").map(\.name).sorted()
        XCTAssertEqual(listed, names.sorted())
    }

    // MARK: - Папки

    func testFoldersAppearAndDisappear() async throws {
        try await fileSystem.connect()
        try await fileSystem.createDirectory(at: "/", name: "новая папка")
        let source = try temporaryFile(named: "внутри.bin", bytes: 128)
        try await fileSystem.upload(localPath: source,
                                    to: "/новая папка/внутри.bin") { _, _ in false }

        let root = try await fileSystem.listDirectory(at: "/")
        let folder = root.first { $0.name == "новая папка" }
        XCTAssertEqual(folder?.isDirectory, true, "свёртка по слэшу — это папка")

        let inside = try await fileSystem.listDirectory(at: "/новая папка")
        XCTAssertEqual(inside.map(\.name), ["внутри.bin"])

        // Папки в S3 нет, есть ключи с общим началом — удаление обязано снести их все.
        try await fileSystem.deleteItem(at: "/новая папка", isDirectory: true)
        let after = try await fileSystem.listDirectory(at: "/")
        XCTAssertNil(after.first { $0.name == "новая папка" }, "папка ушла целиком")
    }

    func testRenamingCopiesAndRemovesTheOriginal() async throws {
        try await fileSystem.connect()
        let source = try temporaryFile(named: "старое.txt", bytes: 256)
        try await fileSystem.upload(localPath: source, to: "/старое.txt") { _, _ in false }

        try await fileSystem.rename(at: "/старое.txt", to: "новое.txt")
        let names = try await fileSystem.listDirectory(at: "/").map(\.name)
        XCTAssertTrue(names.contains("новое.txt"))
        XCTAssertFalse(names.contains("старое.txt"), "исходник удалён после копии")
    }

    // MARK: - Большой файл

    /// Файл крупнее пяти мегабайт уходит частями. Сервер проверяет то же, что и настоящий
    /// S3: часть меньше пяти мегабайт он не примет — значит проверяется и расчёт размера.
    func testABigFileGoesInParts() async throws {
        try await fileSystem.connect()
        let size = 12 << 20      // 12 МБ — три части
        let source = try temporaryFile(named: "большой.bin", bytes: size)
        let original = try Data(contentsOf: URL(fileURLWithPath: source))

        var seen: [Int64] = []
        try await fileSystem.upload(localPath: source, to: "/большой.bin") { done, total in
            seen.append(done)
            XCTAssertEqual(total, Int64(size))
            return false
        }

        XCTAssertGreaterThan(seen.count, 2, "полоса двигалась по ходу отправки, а не разом")
        XCTAssertEqual(seen.last, Int64(size), "в конце — весь размер")

        let back = NSTemporaryDirectory() + "s3-big-\(UUID().uuidString)"
        try await fileSystem.download(remotePath: "/большой.bin", to: back) { _, _ in false }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: back)), original,
                       "склеенный из частей файл совпадает с исходным")
    }

    /// Отмена в середине отправки должна останавливать её, а не доводить до конца.
    func testCancellingStopsTheUpload() async throws {
        try await fileSystem.connect()
        let source = try temporaryFile(named: "отменяемый.bin", bytes: 12 << 20)
        do {
            try await fileSystem.upload(localPath: source, to: "/отменяемый.bin") { done, _ in
                done > 0        // отменяем после первой же части
            }
            XCTFail("отмена должна прерывать отправку")
        } catch let error as RemoteFileSystemError {
            guard case .transferCancelled = error else {
                return XCTFail("это отмена, а не \(error)")
            }
        }
        let names = try await fileSystem.listDirectory(at: "/").map(\.name)
        XCTAssertFalse(names.contains("отменяемый.bin"),
                       "недособранный файл на сервере не появляется")
    }

    // MARK: - Невидимое в ключе

    /// Ключ вставляют из буфера, и вместе с ним приезжает невидимое: табуляция из таблицы,
    /// перевод строки из письма. В подписи такой символ значим, сервер отвечает «не
    /// совпало» — и человек ищет ошибку где угодно, только не в невидимом пробеле.
    /// Настоящий случай: ключ, скопированный из таблицы, приехал с табуляцией впереди.
    func testAKeyPastedWithInvisibleCharactersStillWorks() async throws {
        let connection = RemoteConnection(
            proto: .s3, host: "127.0.0.1", port: UInt16(port),
            username: " AKIAIOSFODNN7EXAMPLE\n",
            s3Bucket: "проба", s3UsePathStyle: true, s3UsesTLS: false)
        let pasted = S3RemoteFileSystem(
            connection: connection,
            password: "\twJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \n")
        try await pasted.connect()
        XCTAssertTrue(pasted.isConnected, "невидимое отрезано, ключ рабочий")
    }

    /// А неверный ключ по-прежнему неверный — обрезка не должна чинить то, что сломано
    /// по-настоящему.
    func testTrimmingDoesNotExcuseAWrongKey() async throws {
        let connection = RemoteConnection(
            proto: .s3, host: "127.0.0.1", port: UInt16(port),
            username: "AKIAIOSFODNN7EXAMPLE",
            s3Bucket: "проба", s3UsePathStyle: true, s3UsesTLS: false)
        let wrong = S3RemoteFileSystem(connection: connection,
                                       password: "  wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKE  ")
        do {
            try await wrong.connect()
            XCTFail("ключ короче на символ — подключаться нельзя")
        } catch let error as RemoteFileSystemError {
            guard case .authenticationFailed(let text) = error else {
                return XCTFail("это отказ в доступе, а не \(error)")
            }
            XCTAssertTrue(text.contains("ключ"), "сказано, где искать причину: \(text)")
        }
    }

    // MARK: - Докачка

    /// Оборванное скачивание продолжается с места обрыва, а не начинается заново.
    func testDownloadContinuesFromWhereItStopped() async throws {
        try await fileSystem.connect()
        let size = 1 << 20
        let source = try temporaryFile(named: "докачка.bin", bytes: size)
        let original = try Data(contentsOf: URL(fileURLWithPath: source))
        try await fileSystem.upload(localPath: source, to: "/докачка.bin") { _, _ in false }

        // Половина файла уже «скачана».
        let half = size / 2
        let target = NSTemporaryDirectory() + "s3-part-\(UUID().uuidString)"
        try original.prefix(half).write(to: URL(fileURLWithPath: target))

        var firstReport: Int64 = -1
        try await fileSystem.download(remotePath: "/докачка.bin", to: target,
                                      resumeFrom: Int64(half)) { done, total in
            if firstReport < 0 { firstReport = done }
            XCTAssertEqual(total, Int64(size), "полоса считает весь файл, а не остаток")
            return false
        }
        XCTAssertGreaterThanOrEqual(firstReport, Int64(half),
                                    "отсчёт продолжается с середины, а не с нуля")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)), original,
                       "дописанный файл совпадает с исходным")
    }

    /// Оборванная отправка продолжается с уже принятых частей, а не начинается заново.
    ///
    /// Пробный сервер один раз роняет третью часть — первая попытка умирает, приняв две.
    /// Вторая обязана дослать только третью: незавершённая отправка лежит на сервере,
    /// и продолжение берётся оттуда, а не из памяти программы.
    func testAnInterruptedUploadContinuesFromTheAcceptedParts() async throws {
        try await fileSystem.connect()
        let size = 12 << 20      // три части: 5 + 5 + 2 МиБ
        let source = try temporaryFile(named: "обрыв.bin", bytes: size)
        let original = try Data(contentsOf: URL(fileURLWithPath: source))

        do {
            try await fileSystem.upload(localPath: source, to: "/обрыв.bin") { _, _ in false }
            XCTFail("первая попытка обязана оборваться")
        } catch {}

        let waiting = try await fileSystem.listDirectory(at: "/").map(\.name)
        XCTAssertFalse(waiting.contains("обрыв.bin"), "недособранного файла в хранилище нет")

        var firstReport: Int64 = -1
        try await fileSystem.upload(localPath: source, to: "/обрыв.bin") { done, _ in
            if firstReport < 0 { firstReport = done }
            return false
        }
        XCTAssertEqual(firstReport, Int64(10 << 20),
                       "отсчёт пошёл с двух принятых частей, а не с нуля")

        let back = NSTemporaryDirectory() + "s3-resume-\(UUID().uuidString)"
        try await fileSystem.download(remotePath: "/обрыв.bin", to: back) { _, _ in false }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: back)), original,
                       "досланный файл совпал с исходным до байта")
    }

    /// Файл правили между попытками — старые части чужие, и продолжать по ним нельзя:
    /// вышла бы мешанина из двух разных файлов под одним именем.
    func testChangedFileStartsTheUploadOver() async throws {
        try await fileSystem.connect()
        let size = 12 << 20
        let first = try temporaryFile(named: "обрыв.bin", bytes: size)
        do {
            try await fileSystem.upload(localPath: first, to: "/обрыв.bin") { _, _ in false }
            XCTFail("первая попытка обязана оборваться")
        } catch {}

        // Другое содержимое того же размера.
        let second = NSTemporaryDirectory() + "s3-other-\(UUID().uuidString)"
        let other = Data((0..<size).map { UInt8(($0 + 7) % 251) })
        try other.write(to: URL(fileURLWithPath: second))

        var firstReport: Int64 = -1
        try await fileSystem.upload(localPath: second, to: "/обрыв.bin") { done, _ in
            if firstReport < 0 { firstReport = done }
            return false
        }
        XCTAssertEqual(firstReport, 0, "отсчёт с нуля: чужие части отброшены")

        let back = NSTemporaryDirectory() + "s3-other-back-\(UUID().uuidString)"
        try await fileSystem.download(remotePath: "/обрыв.bin", to: back) { _, _ in false }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: back)), other,
                       "в хранилище второй файл целиком, без следов первого")
    }

    // MARK: - Удаление пачкой

    /// Папку сносит один запрос на тысячу имён, а не тысяча запросов.
    ///
    /// Сервер требует Content-MD5, как настоящий S3: без него — отказ. Значит успешное
    /// удаление доказывает и то, что запрос собран правильно.
    func testAWholeFolderGoesInOneRequest() async throws {
        try await fileSystem.connect()
        let source = try temporaryFile(named: "мелочь.bin", bytes: 32)
        for number in 1...25 {
            try await fileSystem.upload(localPath: source,
                                        to: "/пачка/файл \(number).bin") { _, _ in false }
        }
        let filled = try await fileSystem.listDirectory(at: "/пачка")
        XCTAssertEqual(filled.count, 25)

        let before = try await requestCount()
        try await fileSystem.deleteItem(at: "/пачка", isDirectory: true)
        let after = try await requestCount()

        let root = try await fileSystem.listDirectory(at: "/")
        XCTAssertNil(root.first { $0.name == "пачка" }, "папка ушла целиком")
        XCTAssertLessThanOrEqual(after - before, 3,
                                 "перечислить и снести одним ударом, а не по файлу за раз")
    }

    /// Угловые скобки и амперсанд в имени попадают в XML запроса — если их не
    /// экранировать, запрос разваливается и удаление молча промахивается.
    func testNamesWithXMLCharactersAreDeletedToo() async throws {
        try await fileSystem.connect()
        let source = try temporaryFile(named: "x.bin", bytes: 16)
        let names = ["Иванов & сын.txt", "<черновик>.txt", "цена \"5\".txt"]
        for name in names {
            try await fileSystem.upload(localPath: source, to: "/знаки/" + name) { _, _ in false }
        }
        try await fileSystem.deleteItem(at: "/знаки", isDirectory: true)
        let left = try await fileSystem.listDirectory(at: "/")
        XCTAssertNil(left.first { $0.name == "знаки" },
                     "имена со знаками XML удалились наравне с обычными")
    }

    /// Сколько запросов сервер обслужил с начала работы.
    private func requestCount() async throws -> Int {
        let url = URL(string: "http://127.0.0.1:\(port)/--счёт")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return Int(String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
    }
}
