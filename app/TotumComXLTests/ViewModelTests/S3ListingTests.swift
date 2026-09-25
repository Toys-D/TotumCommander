import XCTest
@testable import TotumComXLApp

/// Разбор ответа S3 на запрос списка. Ответы взяты в том виде, в каком их присылает сервер:
/// у S3 нет каталогов, и «папки» приходят отдельным списком свёрток (CommonPrefixes).
final class S3ListingTests: XCTestCase {

    private func data(_ xml: String) -> Data { Data(xml.utf8) }

    /// Ответ на запрос содержимого корня с разделителем «/»: два файла и две «папки».
    private let rootListing = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>мои-файлы</Name>
      <Prefix></Prefix>
      <Delimiter>/</Delimiter>
      <IsTruncated>false</IsTruncated>
      <Contents>
        <Key>отчёт.pdf</Key>
        <LastModified>2026-08-20T11:22:33.000Z</LastModified>
        <Size>1048576</Size>
        <StorageClass>STANDARD</StorageClass>
      </Contents>
      <Contents>
        <Key>заметки.txt</Key>
        <LastModified>2026-08-21T09:00:00.000Z</LastModified>
        <Size>512</Size>
      </Contents>
      <CommonPrefixes><Prefix>фото/</Prefix></CommonPrefixes>
      <CommonPrefixes><Prefix>резервные копии/</Prefix></CommonPrefixes>
    </ListBucketResult>
    """

    func testFilesAndFoldersComeOutOfOneAnswer() {
        let page = S3ListingParser.parse(data(rootListing), prefix: "")
        let names = page.items.map(\.name).sorted()
        XCTAssertEqual(names, ["заметки.txt", "отчёт.pdf", "резервные копии", "фото"])

        let folders = page.items.filter(\.isDirectory).map(\.name).sorted()
        XCTAssertEqual(folders, ["резервные копии", "фото"],
                       "свёртки CommonPrefixes — это папки")

        let report = page.items.first { $0.name == "отчёт.pdf" }
        XCTAssertEqual(report?.size, 1_048_576)
        XCTAssertFalse(report?.isDirectory ?? true)
        XCTAssertEqual(report?.path, "/отчёт.pdf", "путь панели — ключ с ведущим слэшем")
        XCTAssertNil(page.nextToken, "список кончился")
    }

    /// Внутри папки у ключей есть префикс — в списке должны остаться короткие имена,
    /// иначе в панели видно «фото/снимок.jpg» вместо «снимок.jpg».
    func testInsideAFolderNamesAreShort() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Prefix>фото/</Prefix>
          <Contents>
            <Key>фото/снимок.jpg</Key>
            <LastModified>2026-08-01T10:00:00.000Z</LastModified>
            <Size>2048</Size>
          </Contents>
          <CommonPrefixes><Prefix>фото/2026/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let page = S3ListingParser.parse(data(xml), prefix: "фото/")
        XCTAssertEqual(page.items.map(\.name).sorted(), ["2026", "снимок.jpg"])
        XCTAssertEqual(page.items.first { $0.name == "снимок.jpg" }?.path, "/фото/снимок.jpg",
                       "полный путь остаётся полным")
    }

    /// Сам объект-папка («ключ, оканчивающийся слэшем») вторым пунктом не показывается:
    /// он уже есть как папка из свёрток, а иначе выглядел бы файлом нулевого размера.
    func testTheFolderMarkerObjectIsNotShownTwice() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Prefix>фото/</Prefix>
          <Contents>
            <Key>фото/</Key>
            <LastModified>2026-08-01T10:00:00.000Z</LastModified>
            <Size>0</Size>
          </Contents>
          <Contents>
            <Key>фото/снимок.jpg</Key>
            <LastModified>2026-08-01T10:00:00.000Z</LastModified>
            <Size>2048</Size>
          </Contents>
        </ListBucketResult>
        """
        let page = S3ListingParser.parse(data(xml), prefix: "фото/")
        XCTAssertEqual(page.items.map(\.name), ["снимок.jpg"],
                       "пустышка-папка в списке не нужна")
    }

    /// Запрошенный префикс приходит в ответе эхом — папкой самого себя он быть не должен.
    func testTheEchoedPrefixIsNotMistakenForAFolder() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Prefix>фото/</Prefix>
          <Delimiter>/</Delimiter>
          <CommonPrefixes><Prefix>фото/лето/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let page = S3ListingParser.parse(data(xml), prefix: "фото/")
        XCTAssertEqual(page.items.map(\.name), ["лето"])
    }

    /// Больше тысячи объектов сервер отдаёт частями — без продолжения половина папки
    /// просто не покажется.
    func testAContinuationTokenIsPickedUp() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>1ueGcxLPRx1Tr</NextContinuationToken>
          <Contents><Key>a.bin</Key><Size>1</Size>
            <LastModified>2026-08-01T10:00:00.000Z</LastModified></Contents>
        </ListBucketResult>
        """
        let page = S3ListingParser.parse(data(xml), prefix: "")
        XCTAssertEqual(page.nextToken, "1ueGcxLPRx1Tr")
    }

    /// Для удаления папки нужны ВСЕ ключи под префиксом, включая сам объект-папку.
    func testEveryKeyIsCollectedForDeletion() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Contents><Key>папка/</Key><Size>0</Size>
            <LastModified>2026-08-01T10:00:00.000Z</LastModified></Contents>
          <Contents><Key>папка/файл.txt</Key><Size>10</Size>
            <LastModified>2026-08-01T10:00:00.000Z</LastModified></Contents>
        </ListBucketResult>
        """
        let page = S3ListingParser.parseKeys(data(xml))
        XCTAssertEqual(page.keys, ["папка/", "папка/файл.txt"])
    }

    func testDatesAreReadWithAndWithoutFractions() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Contents><Key>a</Key><Size>1</Size>
            <LastModified>2026-08-20T11:22:33.123Z</LastModified></Contents>
          <Contents><Key>b</Key><Size>1</Size>
            <LastModified>2026-08-20T11:22:33Z</LastModified></Contents>
        </ListBucketResult>
        """
        let page = S3ListingParser.parse(data(xml), prefix: "")
        let dates = page.items.map(\.dateModified)
        XCTAssertEqual(dates.count, 2)
        XCTAssertEqual(dates[0].timeIntervalSince1970, dates[1].timeIntervalSince1970,
                       accuracy: 1, "обе записи времени читаются одинаково")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                            from: dates[0])
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 8)
        XCTAssertEqual(parts.day, 20)
        XCTAssertEqual(parts.hour, 11, "время читается как UTC, а не как местное")
        XCTAssertEqual(parts.minute, 22)
        XCTAssertEqual(parts.second, 33)
    }

    // MARK: - Ошибки

    /// Причину отказа сервер пишет в теле ответа — её и надо показать человеку, а не
    /// «ошибка 403».
    func testTheServersOwnReasonIsShown() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Error>
          <Code>AccessDenied</Code>
          <Message>У этого ключа нет прав на бакет</Message>
        </Error>
        """
        let error = S3RemoteFileSystem.error(status: 403, body: data(xml))
        guard case .authenticationFailed(let text) = error else {
            return XCTFail("отказ по ключу — это отказ в доступе, а не «что-то пошло не так»")
        }
        XCTAssertEqual(text, "У этого ключа нет прав на бакет")
    }

    /// А вот про несошедшуюся подпись сервер говорит по-своему и бесполезно: «signature we
    /// calculated does not match». Настоящая причина почти всегда одна — в ключ при вставке
    /// затесался невидимый символ. Об этом и надо сказать.
    func testASignatureMismatchTellsWhereToLook() {
        let xml = """
        <Error><Code>SignatureDoesNotMatch</Code>
        <Message>The request signature we calculated does not match</Message></Error>
        """
        guard case .authenticationFailed(let text) =
                S3RemoteFileSystem.error(status: 403, body: data(xml)) else {
            return XCTFail("это отказ в доступе")
        }
        XCTAssertTrue(text.contains("вставке"), "сказано про вставку ключа: \(text)")
        XCTAssertTrue(text.contains("регион"), "и про область — вторая частая причина")
    }

    func testAMissingObjectIsReportedAsMissing() {
        let xml = "<Error><Code>NoSuchKey</Code><Message>Ключа нет</Message></Error>"
        guard case .pathNotFound(let text) = S3RemoteFileSystem.error(status: 404,
                                                                      body: data(xml)) else {
            return XCTFail("404 — это «не найдено»")
        }
        XCTAssertEqual(text, "Ключа нет")
    }

    func testAnEmptyBodyStillGivesAReadableError() {
        guard case .operationFailed(let text) = S3RemoteFileSystem.error(status: 500,
                                                                         body: Data()) else {
            return XCTFail("прочие коды — обычная неудача операции")
        }
        XCTAssertEqual(text, "HTTP 500")
    }
}

/// Отправка большими файлами: размер части, кодирование ключей, ошибки внутри «успешных»
/// ответов — всё то, на чём чужие клиенты спотыкаются о нестандартные хранилища.
final class S3UploadRulesTests: XCTestCase {

    /// Частей не может быть больше десяти тысяч. Постоянный кусок в пять мегабайт упирается
    /// в этот потолок уже на пятидесяти гигабайтах — дальше файл просто нельзя отправить.
    func testThePartSizeGrowsWithTheFile() {
        let small = S3RemoteFileSystem.partSize(forFileOf: 100 << 20)      // 100 МБ
        XCTAssertEqual(small, 5 << 20, "мелкому файлу хватает наименьшей части")

        let huge = S3RemoteFileSystem.partSize(forFileOf: 500 << 30)       // 500 ГБ
        let parts = (500 << 30) / huge
        XCTAssertLessThanOrEqual(parts, 10_000, "в потолок по числу частей не упираемся")
        XCTAssertEqual(huge % (5 << 20), 0, "размер части кратен наименьшему")
    }

    func testEveryFileSizeStaysWithinTheLimits() {
        for gigabytes in [1, 10, 100, 1_000, 5_000] {
            let size = Int64(gigabytes) << 30
            let part = S3RemoteFileSystem.partSize(forFileOf: size)
            XCTAssertGreaterThanOrEqual(part, 5 << 20, "\(gigabytes) ГБ: часть не меньше пяти мегабайт")
            XCTAssertLessThanOrEqual((size + part - 1) / part, 10_000,
                                     "\(gigabytes) ГБ: частей не больше десяти тысяч")
        }
    }

    /// Копирование и завершение отправки — те две операции, где S3 отвечает «200 ОК» и
    /// кладёт отказ в тело. Поверив коду ответа, мы бы удалили исходный файл после
    /// несостоявшейся копии.
    func testAnErrorHiddenInASuccessfulAnswerIsCaught() {
        let body = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Error><Code>InternalError</Code><Message>Не сложилось</Message></Error>
        """.utf8)
        XCTAssertThrowsError(try S3RemoteFileSystem.checkBodyForError(body)) { error in
            guard case RemoteFileSystemError.operationFailed(let text) = error else {
                return XCTFail("это неудача операции")
            }
            XCTAssertEqual(text, "Не сложилось")
        }
        XCTAssertNoThrow(try S3RemoteFileSystem.checkBodyForError(
            Data("<CopyObjectResult><ETag>\"abc\"</ETag></CopyObjectResult>".utf8)))
    }

    /// Разъехавшиеся часы — обиднейшая из ошибок: ключи верные, а сервер отказывает.
    /// Человек должен прочитать про часы, а не искать причину в пароле.
    func testSkewedClocksAreNamedPlainly() {
        let body = Data("""
        <Error><Code>RequestTimeTooSkewed</Code>
        <Message>The difference between the request time and the current time is too large</Message>
        </Error>
        """.utf8)
        guard case RemoteFileSystemError.operationFailed(let text) =
                S3RemoteFileSystem.error(status: 403, body: body) else {
            return XCTFail("часы — это не отказ по ключу")
        }
        XCTAssertTrue(text.contains("Часы"), "сказано про часы: \(text)")
        XCTAssertTrue(text.contains("15 минут"), "и про допуск")
    }

    /// Ключи в ответе приходят закодированными — показывать их человеку в таком виде нельзя.
    func testEncodedKeysAreDecodedForDisplay() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Prefix></Prefix>
          <Contents><Key>%D0%9E%D1%82%D1%87%D1%91%D1%82%20%E2%84%961.pdf</Key>
            <Size>10</Size>
            <LastModified>2026-08-01T10:00:00.000Z</LastModified></Contents>
        </ListBucketResult>
        """
        let page = S3ListingParser.parse(Data(xml.utf8), prefix: "")
        XCTAssertEqual(page.items.map(\.name), ["Отчёт №1.pdf"])
    }
}
