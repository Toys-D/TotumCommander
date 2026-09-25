import XCTest
@testable import TotumComXLApp

/// Подпись S3-запросов проверяется официальными примерами AWS: там даны исходный запрос и
/// готовая подпись до последнего знака. Своя реализация или чужая — значения обязаны
/// совпасть, иначе сервер откажет без объяснения причины.
///
/// Источник: docs.aws.amazon.com, «Signature Calculations for the Authorization Header:
/// Transferring Payload in a Single Chunk» — примеры GET Object и PUT Object.
final class AWSSignatureV4Tests: XCTestCase {

    /// Ключи из примера в документации — публичные, специально выдуманные для неё.
    private let credentials = AWSSignatureV4.Credentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "us-east-1",
        service: "s3")

    /// 24 мая 2013 года, полночь по Гринвичу — дата из примеров.
    private var exampleDate: Date {
        var parts = DateComponents()
        parts.year = 2013; parts.month = 5; parts.day = 24
        parts.hour = 0; parts.minute = 0; parts.second = 0
        parts.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: parts)!
    }

    // MARK: - Пример 1: GET Object с диапазоном

    func testTheDocumentedGetObjectSignatureMatches() {
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!
        let headers = [
            "host": "examplebucket.s3.amazonaws.com",
            "range": "bytes=0-9",
            "x-amz-content-sha256": AWSSignatureV4.emptyPayloadHash,
            "x-amz-date": "20130524T000000Z",
        ]

        let canonical = AWSSignatureV4.canonicalRequest(
            method: "GET", url: url, headers: headers,
            payloadHash: AWSSignatureV4.emptyPayloadHash)
        let scope = AWSSignatureV4.credentialScope(date: exampleDate, credentials: credentials)
        let toSign = AWSSignatureV4.stringToSign(date: exampleDate, scope: scope,
                                                 canonicalRequest: canonical)
        let signature = AWSSignatureV4.sign(stringToSign: toSign, date: exampleDate,
                                            credentials: credentials)

        XCTAssertEqual(signature,
                       "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
                       "подпись из документации AWS")
        XCTAssertEqual(scope, "20130524/us-east-1/s3/aws4_request")
    }

    // MARK: - Пример 2: PUT Object

    func testTheDocumentedPutObjectSignatureMatches() {
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/test%24file.text")!
        let bodyHash = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
        let headers = [
            "date": "Fri, 24 May 2013 00:00:00 GMT",
            "host": "examplebucket.s3.amazonaws.com",
            "x-amz-content-sha256": bodyHash,
            "x-amz-date": "20130524T000000Z",
            "x-amz-storage-class": "REDUCED_REDUNDANCY",
        ]

        let canonical = AWSSignatureV4.canonicalRequest(
            method: "PUT", url: url, headers: headers, payloadHash: bodyHash)
        let scope = AWSSignatureV4.credentialScope(date: exampleDate, credentials: credentials)
        let toSign = AWSSignatureV4.stringToSign(date: exampleDate, scope: scope,
                                                 canonicalRequest: canonical)
        let signature = AWSSignatureV4.sign(stringToSign: toSign, date: exampleDate,
                                            credentials: credentials)

        XCTAssertEqual(signature,
                       "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd",
                       "подпись из документации AWS")
    }

    // MARK: - Пример 3: список объектов с параметрами

    /// Параметры запроса участвуют в подписи и обязаны идти по алфавиту.
    func testTheDocumentedListObjectsSignatureMatches() {
        let url = URL(string:
            "https://examplebucket.s3.amazonaws.com?max-keys=2&prefix=J")!
        let headers = [
            "host": "examplebucket.s3.amazonaws.com",
            "x-amz-content-sha256": AWSSignatureV4.emptyPayloadHash,
            "x-amz-date": "20130524T000000Z",
        ]

        let canonical = AWSSignatureV4.canonicalRequest(
            method: "GET", url: url, headers: headers,
            payloadHash: AWSSignatureV4.emptyPayloadHash)
        XCTAssertTrue(canonical.contains("max-keys=2&prefix=J"),
                      "параметры отсортированы и склеены амперсандом")

        let scope = AWSSignatureV4.credentialScope(date: exampleDate, credentials: credentials)
        let toSign = AWSSignatureV4.stringToSign(date: exampleDate, scope: scope,
                                                 canonicalRequest: canonical)
        let signature = AWSSignatureV4.sign(stringToSign: toSign, date: exampleDate,
                                            credentials: credentials)
        XCTAssertEqual(signature,
                       "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7",
                       "подпись из документации AWS")
    }

    // MARK: - Кодирование

    /// Кодировать надо по RFC 3986, а не как это делает URLComponents: там остаются
    /// нетронутыми знаки вроде `+` и `=`, и подпись расходится с серверной.
    func testEncodingFollowsTheStrictRules() {
        XCTAssertEqual(AWSSignatureV4.encode("простой", encodeSlash: true),
                       "%D0%BF%D1%80%D0%BE%D1%81%D1%82%D0%BE%D0%B9",
                       "кириллица уходит в проценты побайтно")
        XCTAssertEqual(AWSSignatureV4.encode("a+b=c", encodeSlash: true), "a%2Bb%3Dc")
        XCTAssertEqual(AWSSignatureV4.encode("a-b_c.d~e", encodeSlash: true), "a-b_c.d~e",
                       "эти знаки не кодируются никогда")
        XCTAssertEqual(AWSSignatureV4.encode("папка/файл", encodeSlash: false)
                        .contains("/"), true, "в пути слэш остаётся слэшем")
    }

    /// Путь режется на сегменты, и каждый кодируется отдельно — пробелы и кириллица в
    /// именах файлов иначе ломают подпись.
    func testThePathIsEncodedSegmentBySegment() {
        let url = URL(string: "https://bucket.example.com/папка%20один/файл.txt")!
        let uri = AWSSignatureV4.canonicalURI(url)
        XCTAssertTrue(uri.hasPrefix("/"), "путь начинается со слэша")
        XCTAssertEqual(uri.components(separatedBy: "/").count, 3, "два сегмента и корень")
        XCTAssertFalse(uri.contains(" "), "пробелов в подписи не бывает")
    }

    // MARK: - Заголовки

    func testTheAuthorizationHeaderIsAssembledInFullShape() {
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!
        let request = AWSSignatureV4.Request(
            method: "GET", url: url,
            headers: ["host": "examplebucket.s3.amazonaws.com"],
            payloadHash: AWSSignatureV4.emptyPayloadHash,
            date: exampleDate)

        let headers = AWSSignatureV4.signedHeaders(for: request, with: credentials)
        let authorization = try? XCTUnwrap(headers["Authorization"])

        XCTAssertEqual(headers["x-amz-date"], "20130524T000000Z")
        XCTAssertEqual(headers["x-amz-content-sha256"], AWSSignatureV4.emptyPayloadHash)
        XCTAssertTrue(authorization?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request") ?? false,
                      "область действия ключа записана целиком")
        XCTAssertTrue(authorization?.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date") ?? false,
                      "подписанные заголовки перечислены по алфавиту")
    }

    /// Тело файла не хешируется: гигабайтный файл пришлось бы прочитать дважды.
    func testUnsignedPayloadIsAllowed() {
        let url = URL(string: "https://bucket.example.com/large.bin")!
        let request = AWSSignatureV4.Request(
            method: "PUT", url: url, headers: ["host": "bucket.example.com"],
            payloadHash: AWSSignatureV4.unsignedPayload, date: exampleDate)

        let headers = AWSSignatureV4.signedHeaders(for: request, with: credentials)
        XCTAssertEqual(headers["x-amz-content-sha256"], "UNSIGNED-PAYLOAD")
        XCTAssertNotNil(headers["Authorization"])
    }

    func testEmptyBodyHashIsTheKnownConstant() {
        XCTAssertEqual(AWSSignatureV4.payloadHash(Data()), AWSSignatureV4.emptyPayloadHash)
        XCTAssertEqual(AWSSignatureV4.payloadHash(Data("hello".utf8)),
                       "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}
