import XCTest
@testable import TotumComXLApp

/// Как программа пишет размеры.
///
/// Настоящий случай: в полосе загрузки из облака стояло «Обработано: Zero KB из 3,7 MB».
/// `ByteCountFormatter` пишет ноль словами, и системного перевода этих слов на русский
/// нет. В панели это когда-то обошли отдельной строкой, а в остальных местах — нет.
final class ByteTextTests: XCTestCase {

    func test_нольПишетсяЦифрой_аНеСловом() {
        let ноль = ByteText.file(0)
        XCTAssertFalse(ноль.lowercased().contains("zero"), "никаких «Zero KB»: \(ноль)")
        XCTAssertTrue(ноль.contains("0"), "ноль показан цифрой: \(ноль)")
    }

    func test_отрицательныйРазмерТожеНоль() {
        // Такого быть не должно, но приходит: счётчики иногда уходят в минус.
        XCTAssertEqual(ByteText.file(-5), ByteText.file(0))
    }

    func test_обычныеРазмерыЧитаемы() {
        // Единицы измерения переводит система, и на разных языках они разные — проверяем
        // число, а не подпись к нему.
        let крупный = ByteText.file(3_749_667)
        XCTAssertTrue(крупный.contains("3,7") || крупный.contains("3.7"), крупный)
        XCTAssertFalse(ByteText.file(1024).isEmpty)
        XCTAssertFalse(ByteText.memory(1_048_576).isEmpty)
    }

    /// Больше нигде размер напрямую не форматируется — иначе «Zero KB» вернётся тем же
    /// путём, каким пришёл: в одном месте обошли, в двадцати восьми забыли.
    func test_прямыхВызововФорматировщикаНеОсталось() throws {
        let корень = FileManager.default.currentDirectoryPath + "/app/TotumComXL"
        let обходчик = try XCTUnwrap(FileManager.default.enumerator(atPath: корень))
        var виновные: [String] = []
        for случай in obходчикFiles(обходчик) where случай.hasSuffix(".swift") {
            let путь = корень + "/" + случай
            guard !путь.hasSuffix("Helpers/ByteText.swift"),
                  let текст = try? String(contentsOfFile: путь, encoding: .utf8) else { continue }
            if текст.contains("ByteCountFormatter.string(fromByteCount:") { виновные.append(случай) }
        }
        XCTAssertTrue(виновные.isEmpty, "форматируют размер мимо ByteText: \(виновные)")
    }

    private func obходчикFiles(_ обходчик: FileManager.DirectoryEnumerator) -> [String] {
        обходчик.compactMap { $0 as? String }
    }
}
