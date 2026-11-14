import Foundation

/// Какими байтами записан текст: кодировка и метка порядка байтов в начале файла.
///
/// Редактор хранит это вместе с открытым документом и тем же записывает его обратно: файл
/// UTF-16 остаётся UTF-16, метка остаётся на месте, и программа, которая этот файл читает,
/// правки не замечает.
struct TextFileEncoding: Equatable {
    let encoding: String.Encoding
    /// Метка в начале файла, байт в байт. Пусто — метки не было.
    let bom: [UInt8]

    init(_ encoding: String.Encoding, bom: [UInt8] = []) {
        self.encoding = encoding
        self.bom = bom
    }

    static let utf8 = TextFileEncoding(.utf8)

    /// Название для строки состояния редактора и просмотра.
    var name: String {
        switch encoding {
        case .utf8: return bom.isEmpty ? "UTF-8" : "UTF-8 (BOM)"
        case .utf16LittleEndian: return "UTF-16LE"
        case .utf16BigEndian: return "UTF-16BE"
        case .utf32LittleEndian: return "UTF-32LE"
        case .utf32BigEndian: return "UTF-32BE"
        case .windowsCP1251: return "Windows-1251"
        case .isoLatin1: return "ISO-8859-1"
        default: return encoding.description
        }
    }

    /// Текст байтами этой кодировки, с меткой, если она была. nil — в тексте есть знак,
    /// которого в кодировке нет: в Windows-1251 не записать «→».
    func data(from text: String) -> Data? {
        guard let body = text.data(using: encoding) else { return nil }
        return Data(bom) + body
    }
}

/// Один на программу способ прочитать текстовый файл — для редактора и для просмотра.
///
/// Декодеров было два, и они расходились: просмотр смотрел на метку в начале файла, редактор —
/// нет, и файл UTF-16 открывался в нём как Windows-1251, а после сохранения переставал
/// читаться вовсе.
enum TextFileCodec {

    struct Decoded: Equatable {
        let text: String
        let encoding: TextFileEncoding
    }

    /// В тексте есть знак, которого нет в кодировке файла.
    struct UnencodableText: LocalizedError {
        let encodingName: String
        var errorDescription: String? { L("editor.error.encode", encodingName) }
    }

    /// Метки порядка байтов. Четырёхбайтные раньше двухбайтных: FF FE 00 00 начинается и как
    /// метка UTF-16.
    private static let marks: [(bytes: [UInt8], encoding: String.Encoding)] = [
        ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian), ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
        ([0xEF, 0xBB, 0xBF], .utf8), ([0xFE, 0xFF], .utf16BigEndian), ([0xFF, 0xFE], .utf16LittleEndian),
    ]

    /// Без метки: UTF-8, затем однобайтные. Последняя читает любой набор байтов.
    private static let unmarked: [String.Encoding] = [.utf8, .windowsCP1251, .isoLatin1]

    // MARK: - Редактор

    /// Для редактора: текст и то, чем записать его обратно. nil — прочитать файл так, чтобы
    /// сохранение вернуло те же байты, нельзя; открывать его можно только для чтения.
    static func decodeForEditing(_ data: Data) -> Decoded? {
        let candidates = marks.filter { data.starts(with: $0.bytes) }
        if candidates.isEmpty {
            for encoding in unmarked {
                if let text = String(data: data, encoding: encoding),
                   let same = exact(text, from: data, as: encoding) {
                    return Decoded(text: same, encoding: TextFileEncoding(encoding))
                }
            }
            return nil
        }
        // Метка есть — файл записан так, как она говорит. Первая метка, которой файл читается,
        // решает кодировку; не читается без потерь — только чтение, другую кодировку не подбираем:
        // подобранная покажет кашу и даст её сохранить.
        for mark in candidates {
            let payload = data.dropFirst(mark.bytes.count)
            guard let text = String(data: payload, encoding: mark.encoding) else { continue }
            return exact(text, from: payload, as: mark.encoding).map {
                Decoded(text: $0, encoding: TextFileEncoding(mark.encoding, bom: mark.bytes))
            }
        }
        return nil
    }

    /// Тот же текст, если запись его этой кодировкой даёт ровно эти байты; иначе nil.
    /// Foundation читает и то, что обратно не запишет: оборванный знак в конце UTF-16 молча
    /// отбрасывает.
    private static func exact(_ text: String, from bytes: Data, as encoding: String.Encoding) -> String? {
        if text.data(using: encoding) == bytes { return text }
        // Метку UTF-8 в начале Foundation снимает сама. Если за меткой файла шла вторая,
        // возвращаем её знаком — иначе запись её потеряет.
        let marked = "\u{FEFF}" + text
        return marked.data(using: encoding) == bytes ? marked : nil
    }

    // MARK: - Просмотр

    /// Для показа: текст получается всегда, чего не разобрать — знаком «�».
    ///
    /// С редактором расходится в одном, и намеренно: файл без метки с битым UTF-8. Редактору
    /// нужен текст, который сохранится теми же байтами, и он берёт Windows-1251, где занят
    /// почти каждый байт. Просмотру нужен текст, который можно прочесть, и, пока целых знаков
    /// больше, чем битых, он остаётся при UTF-8.
    static func decodeForDisplay(_ data: Data) -> Decoded {
        let candidates = marks.filter { data.starts(with: $0.bytes) }
        if let first = candidates.first {
            for mark in candidates {
                if let text = String(data: data.dropFirst(mark.bytes.count), encoding: mark.encoding) {
                    return Decoded(text: text, encoding: TextFileEncoding(mark.encoding, bom: mark.bytes))
                }
            }
            // С меткой, но с изъяном: читаем, как велит метка, битые места — знаком «�».
            return Decoded(text: lenientText(data.dropFirst(first.bytes.count), as: first.encoding),
                           encoding: TextFileEncoding(first.encoding, bom: first.bytes))
        }
        if let text = String(data: data, encoding: .utf8) { return Decoded(text: text, encoding: .utf8) }
        let patched = String(decoding: data, as: UTF8.self)
        if isMostlyIntact(patched) { return Decoded(text: patched, encoding: .utf8) }
        for encoding in unmarked.dropFirst() {
            if let text = String(data: data, encoding: encoding) {
                return Decoded(text: text, encoding: TextFileEncoding(encoding))
            }
        }
        return Decoded(text: patched, encoding: .utf8)
    }

    /// Целых знаков вне ASCII больше, чем битых: это UTF-8 с изъяном, а не другая кодировка.
    /// Русский текст в Windows-1251, прочитанный как UTF-8, битый почти весь.
    private static func isMostlyIntact(_ text: String) -> Bool {
        var whole = 0
        var lost = 0
        for scalar in text.unicodeScalars where scalar.value >= 0x80 {
            if scalar.value == 0xFFFD { lost += 1 } else { whole += 1 }
        }
        return whole > lost
    }

    private static func lenientText(_ bytes: Data, as encoding: String.Encoding) -> String {
        switch encoding {
        case .utf16LittleEndian, .utf16BigEndian:
            let units = units(in: bytes, of: UInt16.self, bigEndian: encoding == .utf16BigEndian)
            return String(decoding: units, as: UTF16.self)
        case .utf32LittleEndian, .utf32BigEndian:
            let units = units(in: bytes, of: UInt32.self, bigEndian: encoding == .utf32BigEndian)
            return String(decoding: units, as: UTF32.self)
        default:
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Байты как кодовые единицы нужной ширины; неполный хвост отбрасывается.
    private static func units<Unit: FixedWidthInteger>(in bytes: Data, of _: Unit.Type,
                                                       bigEndian: Bool) -> [Unit] {
        let width = MemoryLayout<Unit>.size
        return bytes.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count - raw.count % width, by: width).map { start in
                var unit: Unit = 0
                for offset in 0..<width {
                    let byte = Unit(raw[start + offset])
                    let shift = 8 * (bigEndian ? width - 1 - offset : offset)
                    unit |= byte << shift
                }
                return unit
            }
        }
    }

    // MARK: - Текст или нет

    /// Начинается ли файл с метки порядка байтов. Метка — это текст, что бы ни шло следом.
    static func hasByteOrderMark(_ data: Data) -> Bool {
        marks.contains { data.starts(with: $0.bytes) }
    }

    /// Двоичное ли это, судя по началу файла. Правило то же, что у сравнения файлов
    /// (FileDiffService.looksBinary), с одной поправкой: файл с меткой — текст. В латинице
    /// UTF-16 каждый второй байт — ноль, и без поправки такой файл показывался двоичным.
    static func looksBinary(sample: Data) -> Bool {
        !hasByteOrderMark(sample) && FileDiffService.looksBinary(sample: Data(sample.prefix(8192)))
    }

    // MARK: - Запись

    /// Записать текст документа его кодировкой — тем же, чем файл был записан до правки.
    static func write(_ text: String, to path: String, as encoding: TextFileEncoding) throws {
        guard let data = encoding.data(from: text) else {
            throw UnencodableText(encodingName: encoding.name)
        }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
