import XCTest
@testable import TotumComXLApp

/// Файлы, о которых молчит имя (HEAD, config, index из .git), просмотр показывает по
/// содержимому: текст — текстом, двоичное без известного типа — HEX.
final class ViewerContentSniffTests: XCTestCase {

    func test_безРасширенияИНеизвестноеСмотрятсяПоСодержимому() {
        for name in ["HEAD", "config", "index", "COMMIT_EDITMSG", "Makefile", ".gitignore", "notes.qqq"] {
            XCTAssertTrue(needsContentSniff(fileName: name), name)
        }
    }

    func test_известноеПоИмениНеТрогается() {
        for name in ["a.txt", "README.md", "photo.png", "pack.zip", "tool.exe", "book.pdf"] {
            XCTAssertFalse(needsContentSniff(fileName: name), name)
        }
    }

    func test_текстТекстом() {
        XCTAssertEqual(contentMode(forSample: Data("ref: refs/heads/main\n".utf8), fileName: "HEAD"), .text)
        XCTAssertEqual(contentMode(forSample: Data("[core]\n\tbare = false\n".utf8), fileName: "config"), .text)
        XCTAssertEqual(contentMode(forSample: Data(), fileName: "empty"), .text, "пустой — текст, «файл пуст»")
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("привет".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(contentMode(forSample: utf16, fileName: "note"), .text, "нули UTF-16 — не двоичное")
    }

    func test_двоичноеБезТипаВHEXСТипомКарточкой() {
        var index = Data("DIRC".utf8)
        index.append(Data(repeating: 0, count: 60))
        index.append(Data("app/main.swift".utf8))
        XCTAssertEqual(contentMode(forSample: index, fileName: "index"), .hex, "index из .git — HEX")
        XCTAssertEqual(contentMode(forSample: index, fileName: "blob.qqq"), .hex, "тип неизвестен и системе")
        XCTAssertEqual(contentMode(forSample: index, fileName: "data.plist"), .info,
                       "двоичное известного системе типа — карточка, как раньше")
    }

    func test_правитьУТекстаБезРасширения() {
        XCTAssertTrue(viewerOffersEdit(fileName: "HEAD", fileExtension: "", isDirectory: false,
                                       insideRemote: false, looksLikeText: true))
        XCTAssertFalse(viewerOffersEdit(fileName: "index", fileExtension: "", isDirectory: false,
                                        insideRemote: false, looksLikeText: false),
                       "двоичное без расширения — не править")
    }

    func test_файлСДискаЧитаетсяПоНачалу() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-sniff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let head = dir.appendingPathComponent("HEAD")
        try "ref: refs/heads/TotumCommander\n".write(to: head, atomically: true, encoding: .utf8)
        let mode = await sniffContentMode(path: head.path)
        XCTAssertEqual(mode, .text)
        let missing = await sniffContentMode(path: dir.appendingPathComponent("нет").path)
        XCTAssertEqual(missing, .info, "не прочиталось — карточка сведений")
    }
}
