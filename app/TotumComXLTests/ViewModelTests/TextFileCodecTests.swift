import XCTest
@testable import TotumComXLApp

/// Текстовый файл читается одним декодером — и редактором, и просмотром. Метка порядка байтов
/// в начале файла решает раньше догадок, а сохранение пишет файл той же кодировкой и с той же
/// меткой: файл UTF-16 после правки остаётся файлом UTF-16.
@MainActor
final class TextFileCodecTests: XCTestCase {

    private let utf8Mark: [UInt8] = [0xEF, 0xBB, 0xBF]
    private let utf16LE: [UInt8] = [0xFF, 0xFE]
    private let utf16BE: [UInt8] = [0xFE, 0xFF]
    private let utf32LE: [UInt8] = [0xFF, 0xFE, 0x00, 0x00]
    private let utf32BE: [UInt8] = [0x00, 0x00, 0xFE, 0xFF]

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-codec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Содержимое файла: метка и текст в названной кодировке.
    private func bytes(_ mark: [UInt8] = [], _ text: String, _ encoding: String.Encoding) -> Data {
        Data(mark) + text.data(using: encoding)!
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: - Редактор: метка решает

    func test_редакторЧитаетUTF16ПоМетке() {
        let text = "\"greeting\" = \"Привет, мир\";\n"
        let cases: [([UInt8], String.Encoding, String)] = [
            (utf16LE, .utf16LittleEndian, "UTF-16LE"), (utf16BE, .utf16BigEndian, "UTF-16BE"),
        ]
        for (mark, encoding, name) in cases {
            let decoded = MonacoEditorController.decodeText(bytes(mark, text, encoding))
            XCTAssertEqual(decoded.text, text, name)
            XCTAssertTrue(decoded.decodable, name)
            XCTAssertEqual(decoded.encoding, TextFileEncoding(encoding, bom: mark), name)
            XCTAssertEqual(decoded.encoding.name, name)
        }
    }

    func test_редакторЧитаетUTF32ПоМетке() {
        let text = "Привет, мир \u{1F600}\n"
        let cases: [([UInt8], String.Encoding, String)] = [
            (utf32LE, .utf32LittleEndian, "UTF-32LE"), (utf32BE, .utf32BigEndian, "UTF-32BE"),
        ]
        for (mark, encoding, name) in cases {
            let decoded = MonacoEditorController.decodeText(bytes(mark, text, encoding))
            XCTAssertEqual(decoded.text, text, name)
            XCTAssertTrue(decoded.decodable, name)
            XCTAssertEqual(decoded.encoding, TextFileEncoding(encoding, bom: mark), name)
            XCTAssertEqual(decoded.encoding.name, name)
        }
    }

    func test_меткаUTF8НеПопадаетВТекстИПомнится() {
        let decoded = MonacoEditorController.decodeText(bytes(utf8Mark, "привет\n", .utf8))
        XCTAssertEqual(decoded.text, "привет\n", "метка — не знак текста")
        XCTAssertTrue(decoded.decodable)
        XCTAssertEqual(decoded.encoding, TextFileEncoding(.utf8, bom: utf8Mark),
                       "метку надо помнить: без неё сохранение её потеряет")
        XCTAssertEqual(decoded.encoding.name, "UTF-8 (BOM)")
    }

    func test_безМеткиКакРаньше() {
        let utf8 = MonacoEditorController.decodeText(bytes([], "Привет, мир\n", .utf8))
        XCTAssertEqual(utf8.text, "Привет, мир\n")
        XCTAssertEqual(utf8.encoding, .utf8)
        XCTAssertEqual(utf8.encoding.name, "UTF-8")
        XCTAssertTrue(utf8.decodable)

        let cp1251 = MonacoEditorController.decodeText(bytes([], "Привет, мир", .windowsCP1251))
        XCTAssertEqual(cp1251.text, "Привет, мир")
        XCTAssertEqual(cp1251.encoding.name, "Windows-1251")
        XCTAssertTrue(cp1251.decodable)

        // 0x98 в Windows-1251 не занят — остаётся кодировка, в которой занят каждый байт.
        let latin = MonacoEditorController.decodeText(Data([0x63, 0x61, 0x66, 0xE9, 0x98]))
        XCTAssertEqual(latin.text, "caf\u{E9}\u{98}")
        XCTAssertEqual(latin.encoding.name, "ISO-8859-1")
        XCTAssertTrue(latin.decodable)

        let empty = MonacoEditorController.decodeText(Data())
        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(empty.encoding, .utf8)
        XCTAssertTrue(empty.decodable)
    }

    // MARK: - Сохранение: той же кодировкой, с той же меткой

    func test_неправленыйФайлСохраняетсяБайтВБайт() throws {
        let mixed = "строка один\r\nline two\n\u{1F600}\n"
        let samples: [(String, Data)] = [
            ("UTF-8", bytes([], mixed, .utf8)),
            ("UTF-8 с меткой", bytes(utf8Mark, mixed, .utf8)),
            ("UTF-8 с двумя метками", bytes(utf8Mark + utf8Mark, "привет\n", .utf8)),
            ("UTF-16LE", bytes(utf16LE, mixed, .utf16LittleEndian)),
            ("UTF-16BE", bytes(utf16BE, mixed, .utf16BigEndian)),
            ("UTF-32LE", bytes(utf32LE, mixed, .utf32LittleEndian)),
            ("UTF-32BE", bytes(utf32BE, mixed, .utf32BigEndian)),
            ("Windows-1251", bytes([], "Привет,\r\nмир\r\n", .windowsCP1251)),
            ("ISO-8859-1", Data([0x63, 0x61, 0x66, 0xE9, 0x98, 0x0A])),
            ("одна метка UTF-16", Data(utf16LE)),
            ("одна метка UTF-8", Data(utf8Mark)),
            ("пустой", Data()),
        ]
        for (name, original) in samples {
            let decoded = MonacoEditorController.decodeText(original)
            XCTAssertTrue(decoded.decodable, name)
            let file = dir.appendingPathComponent("roundtrip.txt")
            try TextFileCodec.write(decoded.text, to: file.path, as: decoded.encoding)
            XCTAssertEqual(hex(try Data(contentsOf: file)), hex(original), name)
        }
    }

    /// Случай из ревью: Localizable.strings в UTF-16. Раньше он открывался как Windows-1251, и
    /// одна вставленная буква сдвигала все байты за ней — файл превращался в иероглифы.
    func test_правкаФайлаUTF16ОставляетЕгоUTF16() throws {
        let file = dir.appendingPathComponent("Localizable.strings")
        try bytes(utf16LE, "\"key\" = \"значение\";\n", .utf16LittleEndian).write(to: file)

        let decoded = MonacoEditorController.decodeText(try Data(contentsOf: file))
        let edited = decoded.text.replacingOccurrences(of: "k", with: "ok")
        try TextFileCodec.write(edited, to: file.path, as: decoded.encoding)

        let saved = try Data(contentsOf: file)
        XCTAssertEqual([UInt8](saved.prefix(2)), utf16LE, "метка на месте")
        XCTAssertEqual(String(data: saved.dropFirst(2), encoding: .utf16LittleEndian),
                       "\"okey\" = \"значение\";\n")
    }

    func test_знакВнеКодировкиНеЗаписывается() throws {
        let file = dir.appendingPathComponent("note.txt")
        let original = bytes([], "Привет, мир", .windowsCP1251)
        try original.write(to: file)

        XCTAssertThrowsError(
            try TextFileCodec.write("Привет → мир", to: file.path, as: TextFileEncoding(.windowsCP1251))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Windows-1251"),
                          "в сообщении — кодировка файла: \(error.localizedDescription)")
        }
        XCTAssertEqual(hex(try Data(contentsOf: file)), hex(original), "файл не тронут")
    }

    // MARK: - Редактор: чего не вернуть байт в байт — только читать

    func test_повреждённыйUTF16ТолькоДляЧтения() {
        // Нечётное число байтов: последний знак оборван.
        let odd = MonacoEditorController.decodeText(bytes(utf16LE, "привет", .utf16LittleEndian) + Data([0x41]))
        XCTAssertFalse(odd.decodable, "сохранение потеряло бы оборванный хвост")
        XCTAssertTrue(odd.text.hasPrefix("привет"), odd.text)
        XCTAssertEqual(odd.encoding.name, "UTF-16LE")

        // Половина пары без второй: п, D800, р.
        let lone = MonacoEditorController.decodeText(Data(utf16LE + [0x3F, 0x04, 0x00, 0xD8, 0x40, 0x04]))
        XCTAssertFalse(lone.decodable)
        XCTAssertEqual(lone.text, "п\u{FFFD}р", "показан читаемо, а не как Windows-1251")
        XCTAssertEqual(lone.encoding.name, "UTF-16LE")
    }

    /// FF FE 00 00 — и метка UTF-32, и метка UTF-16 перед знаком с кодом ноль. Что именно,
    /// решает то, чем файл читается без потерь.
    func test_меткаUTF32АТекстUTF16() {
        let decoded = MonacoEditorController.decodeText(bytes(utf16LE, "\u{0}привет", .utf16LittleEndian))
        XCTAssertTrue(decoded.decodable)
        XCTAssertEqual(decoded.text, "\u{0}привет")
        XCTAssertEqual(decoded.encoding, TextFileEncoding(.utf16LittleEndian, bom: utf16LE))
    }

    // MARK: - Просмотр

    func test_UTF16СМеткойНеДвоичное() {
        let text = "\"key\" = \"value\";\n"
        let data = bytes(utf16LE, text, .utf16LittleEndian)
        XCTAssertFalse(TextFileCodec.looksBinary(sample: data),
                       "в латинице UTF-16 каждый второй байт — ноль; с меткой это текст")
        let shown = TextFileCodec.decodeForDisplay(data)
        XCTAssertEqual(shown.text, text)
        XCTAssertEqual(shown.encoding.name, "UTF-16LE")
    }

    func test_двоичноеБезМеткиДвоичное() {
        var index = Data("DIRC".utf8)
        index.append(Data(repeating: 0, count: 60))
        XCTAssertTrue(TextFileCodec.looksBinary(sample: index))
        XCTAssertFalse(TextFileCodec.looksBinary(sample: Data("ref: refs/heads/main\n".utf8)))
        XCTAssertFalse(TextFileCodec.looksBinary(sample: Data()), "пустой — текст")
    }

    func test_просмотрЧитаетWindows1251() {
        let shown = TextFileCodec.decodeForDisplay(bytes([], "Привет, мир", .windowsCP1251))
        XCTAssertEqual(shown.text, "Привет, мир")
        XCTAssertEqual(shown.encoding.name, "Windows-1251")
    }

    /// Один битый байт не делает файл UTF-8 файлом Windows-1251: остальное читается как было.
    func test_почтиUTF8ОстаётсяUTF8() {
        let data = bytes([], "Привет, мир", .utf8) + Data([0xFF]) + bytes([], " и дальше", .utf8)
        let shown = TextFileCodec.decodeForDisplay(data)
        XCTAssertEqual(shown.text, "Привет, мир\u{FFFD} и дальше")
        XCTAssertEqual(shown.encoding.name, "UTF-8")
    }

    func test_просмотрПоказываетПовреждённыйUTF16() {
        let shown = TextFileCodec.decodeForDisplay(Data(utf16BE + [0x04, 0x3F, 0xD8, 0x00, 0x04, 0x40]))
        XCTAssertEqual(shown.text, "п\u{FFFD}р")
        XCTAssertEqual(shown.encoding.name, "UTF-16BE")

        // То же в UTF-32: половина пары кодом знака стоять не может.
        let wide = TextFileCodec.decodeForDisplay(
            Data(utf32LE + [0x3F, 0x04, 0x00, 0x00, 0x00, 0xD8, 0x00, 0x00, 0x40, 0x04, 0x00, 0x00]))
        XCTAssertEqual(wide.text, "п\u{FFFD}р")
        XCTAssertEqual(wide.encoding.name, "UTF-32LE")
    }

    func test_просмотрИРедакторЧитаютОдинаково() {
        let text = "Привет, мир\nline two\n"
        let samples: [(String, Data)] = [
            ("UTF-8", bytes([], text, .utf8)),
            ("UTF-8 с меткой", bytes(utf8Mark, text, .utf8)),
            ("UTF-16LE", bytes(utf16LE, text, .utf16LittleEndian)),
            ("UTF-16BE", bytes(utf16BE, text, .utf16BigEndian)),
            ("UTF-32LE", bytes(utf32LE, text, .utf32LittleEndian)),
            ("UTF-32BE", bytes(utf32BE, text, .utf32BigEndian)),
            ("Windows-1251", bytes([], text, .windowsCP1251)),
            ("ISO-8859-1", Data([0x63, 0x61, 0x66, 0xE9, 0x98, 0x0A])),
        ]
        for (name, data) in samples {
            let edited = MonacoEditorController.decodeText(data)
            XCTAssertEqual(TextFileCodec.decodeForDisplay(data),
                           TextFileCodec.Decoded(text: edited.text, encoding: edited.encoding), name)
        }
    }

    func test_меткаЗначитТекст() {
        for mark in [utf8Mark, utf16LE, utf16BE, utf32LE, utf32BE] {
            XCTAssertTrue(TextFileCodec.hasByteOrderMark(Data(mark + [0x41, 0x00])), "\(mark)")
            // Нули за меткой — не повод показывать файл как двоичный.
            let sample = Data(mark) + Data(repeating: 0, count: 64)
            XCTAssertEqual(contentMode(forSample: sample, fileName: "note"), .text, "\(mark)")
        }
        XCTAssertFalse(TextFileCodec.hasByteOrderMark(Data("привет".utf8)))
        XCTAssertFalse(TextFileCodec.hasByteOrderMark(Data()))
        XCTAssertFalse(TextFileCodec.hasByteOrderMark(Data([0xFF])), "половина метки — не метка")
    }
}
