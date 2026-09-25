import FCXLScrypt
import XCTest

@testable import TotumComXLApp

/// The age format lives or dies by exactness — these tests pin the scrypt arithmetic to the
/// RFC 7914 vectors (cross-checked against OpenSSL's independent implementation) and walk a
/// file through the whole circle: sealed, opened, refused, caught forged.
@MainActor
final class AgeCryptTests: XCTestCase {
    private var root = ""

    override func setUp() {
        super.setUp()
        root = NSTemporaryDirectory() + "age-tests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    private func path(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }

    private func scryptHex(_ password: String, _ salt: String, _ n: UInt64,
                           _ r: UInt32, _ p: UInt32) -> String {
        var out = [UInt8](repeating: 0, count: 64)
        let pw = Array(password.utf8), st = Array(salt.utf8)
        let rc = fcxl_scrypt(pw, pw.count, st, st.count, n, r, p, &out, out.count)
        XCTAssertEqual(rc, 0)
        return out.map { String(format: "%02x", $0) }.joined()
    }

    func testScryptMatchesTheReferenceVectors() {
        // RFC 7914 §12, confirmed byte for byte by OpenSSL's scrypt.
        XCTAssertEqual(scryptHex("", "", 16, 1, 1),
            "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442"
            + "fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906")
        XCTAssertEqual(scryptHex("password", "NaCl", 1024, 8, 16),
            "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b373162"
            + "2eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640")
        XCTAssertEqual(scryptHex("pleaseletmein", "SodiumChloride", 16384, 8, 1),
            "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2"
            + "d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887")
    }

    func testTheWholeCircle() throws {
        // Three shapes that matter: empty, exactly one chunk, chunks plus a ragged tail.
        for size in [0, 64 * 1024, 200_001] {
            let source = path("файл-\(size).bin")
            let sealed = path("файл-\(size).age")
            let opened = path("обратно-\(size).bin")
            var bytes = Data(count: size)
            bytes.withUnsafeMutableBytes {
                _ = SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress ?? $0.baseAddress!)
            }
            if size == 0 { bytes = Data() }
            try bytes.write(to: URL(fileURLWithPath: source))

            try AgeCrypt.encrypt(input: source, output: sealed, password: "тайна-999",
                                 workFactor: 12)
            try AgeCrypt.decrypt(input: sealed, output: opened, password: "тайна-999")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: opened)), bytes,
                           "круг для размера \(size)")

            // And the file LOOKS like age: version line, scrypt stanza, MAC line.
            let head = String(data: try Data(contentsOf: URL(fileURLWithPath: sealed)).prefix(200),
                              encoding: .isoLatin1) ?? ""
            XCTAssertTrue(head.hasPrefix("age-encryption.org/v1\n-> scrypt "))
            XCTAssertTrue(AgeCrypt.isAgeFile(sealed))
        }
    }

    func testTheWrongPasswordIsNamedAsSuch() throws {
        let source = path("секрет.txt")
        let sealed = path("секрет.txt.age")
        try "самое дорогое".write(toFile: source, atomically: true, encoding: .utf8)
        try AgeCrypt.encrypt(input: source, output: sealed, password: "правильный",
                             workFactor: 12)
        XCTAssertThrowsError(try AgeCrypt.decrypt(input: sealed, output: path("нет.txt"),
                                                  password: "неправильный")) { error in
            XCTAssertEqual(error as? AgeCrypt.AgeError, .wrongPassword)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("нет.txt")),
                       "провал не оставляет огрызка")
    }

    func testForgeryIsCaught() throws {
        let source = path("письмо.txt")
        let sealed = path("письмо.txt.age")
        try String(repeating: "строка\n", count: 1000)
            .write(toFile: source, atomically: true, encoding: .utf8)
        try AgeCrypt.encrypt(input: source, output: sealed, password: "пароль",
                             workFactor: 12)
        var bytes = try Data(contentsOf: URL(fileURLWithPath: sealed))

        // A flipped byte in the payload body must be caught by the chunk tag.
        var payloadForged = bytes
        payloadForged[bytes.count - 100] ^= 0xFF
        try payloadForged.write(to: URL(fileURLWithPath: path("подделка1.age")))
        XCTAssertThrowsError(try AgeCrypt.decrypt(input: path("подделка1.age"),
                                                  output: path("п1.txt"), password: "пароль")) {
            XCTAssertEqual($0 as? AgeCrypt.AgeError, .corrupted)
        }

        // A flipped byte in the MAC line must be caught by the header check.
        let macMark = Data("\n--- ".utf8)
        let macRange = bytes.range(of: macMark)!
        bytes[macRange.upperBound] = bytes[macRange.upperBound] == UInt8(ascii: "A")
            ? UInt8(ascii: "B") : UInt8(ascii: "A")
        try bytes.write(to: URL(fileURLWithPath: path("подделка2.age")))
        XCTAssertThrowsError(try AgeCrypt.decrypt(input: path("подделка2.age"),
                                                  output: path("п2.txt"), password: "пароль")) {
            XCTAssertEqual($0 as? AgeCrypt.AgeError, .corrupted)
        }
    }

    func testAKeyLockedFileIsRefusedHonestly() throws {
        let alien = path("чужой.age")
        try ("age-encryption.org/v1\n-> X25519 abcdef\nabcdef\n--- abcdef\n")
            .write(toFile: alien, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AgeCrypt.decrypt(input: alien, output: path("ч.txt"),
                                                  password: "любой")) {
            XCTAssertEqual($0 as? AgeCrypt.AgeError, .keyLocked)
        }
    }

    func testTheTwinNameNeverOverwrites() throws {
        let source = path("отчёт.txt")
        try "данные".write(toFile: source, atomically: true, encoding: .utf8)
        XCTAssertEqual(MainWindowController.freeAgePath(for: source, decrypt: false),
                       source + ".age")
        try Data().write(to: URL(fileURLWithPath: source + ".age"))
        XCTAssertEqual(MainWindowController.freeAgePath(for: source, decrypt: false),
                       path("отчёт.txt 2.age"), "занятое имя получает номер")
        XCTAssertEqual(MainWindowController.freeAgePath(for: source + ".age", decrypt: true),
                       path("отчёт 2.txt"), "расшифровка не затирает оригинал")
        try? FileManager.default.removeItem(atPath: source)
        XCTAssertEqual(MainWindowController.freeAgePath(for: source + ".age", decrypt: true),
                       source, "свободное имя берётся как есть")
    }

    func testAFolderRidesInsideAZipEnvelope() throws {
        // The folder road: zip by the bridge, seal, open back — the zip must come out
        // byte for byte, still a readable archive.
        let folder = path("Папка")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "раз".write(toFile: folder + "/один.txt", atomically: true, encoding: .utf8)
        try "два".write(toFile: folder + "/два.txt", atomically: true, encoding: .utf8)

        let zip = path("Папка.zip")
        try CoreBridgeService().createArchive(
            archivePath: zip, format: .zip, sources: [folder],
            includeSubfolders: true, preservePaths: true, compressionLevel: 6)
        try AgeCrypt.encrypt(input: zip, output: path("Папка.zip.age"), password: "пароль",
                             workFactor: 12)
        try AgeCrypt.decrypt(input: path("Папка.zip.age"), output: path("обратно.zip"),
                             password: "пароль")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: zip)),
                       try Data(contentsOf: URL(fileURLWithPath: path("обратно.zip"))),
                       "конверт вернул тот же самый zip")
    }

    func testAnAbsurdWorkFactorIsRefused() throws {
        let bomb = path("бомба.age")
        // A header naming 2^60 would ask for an exabyte of scrypt arena.
        let salt = Data((0..<16).map { UInt8($0) }).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        try ("age-encryption.org/v1\n-> scrypt \(salt) 60\n"
             + String(repeating: "A", count: 43) + "\n--- "
             + String(repeating: "A", count: 43) + "\n")
            .write(toFile: bomb, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AgeCrypt.decrypt(input: bomb, output: path("б.txt"),
                                                  password: "любой")) {
            XCTAssertEqual($0 as? AgeCrypt.AgeError, .tooExpensive)
        }
    }
}
