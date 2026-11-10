import XCTest

@testable import TotumComXLApp

/// Путь, вставленный в строку пути: Finder и оболочка отдают его в кавычках —
/// '/Users/…/Правки', — и переход никуда не вёл.
final class TypedPathTests: XCTestCase {

    func test_кавычкиПоКраямУбираются() {
        let path = "/Users/dimas/Documents/tryClodCode/Vishni/Правки"
        for wrapped in ["'\(path)'", "\"\(path)\"", "  '\(path)'\n", "‘\(path)’", "“\(path)”", "«\(path)»",
                        "'\"\(path)\"'", "'\(path)", "\(path)'", "`\(path)`"] {
            XCTAssertEqual(TypedPath.cleaned(wrapped), path, wrapped)
        }
    }

    func test_кавычкиВнутриПутиОстаются() {
        XCTAssertEqual(TypedPath.cleaned("'/tmp/Отчёт \"2026\" итог'"), "/tmp/Отчёт \"2026\" итог")
        XCTAssertEqual(TypedPath.cleaned("/tmp/it's here"), "/tmp/it's here")
    }

    func test_пустоеОстаётсяПустым() {
        XCTAssertEqual(TypedPath.cleaned("''"), "")
        XCTAssertEqual(TypedPath.cleaned("   "), "")
    }

    /// Имя может само кончаться кавычкой — тогда путь как набран, если он есть на диске.
    func test_существующийПутьСКавычкойНеРежется() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypedPathTests-\(UUID().uuidString)")
        let quoted = root.appendingPathComponent("Отчёт \"2026\"")
        try FileManager.default.createDirectory(at: quoted, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(TypedPath.resolve(quoted.path), quoted.path, "имя с кавычкой в конце")
        XCTAssertEqual(TypedPath.resolve("'\(root.path)'"), root.path, "вставленный в кавычках")
        XCTAssertEqual(TypedPath.resolve("  \(root.path)\n"), root.path)
    }
}
