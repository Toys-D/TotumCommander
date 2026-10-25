import Foundation
import XCTest

@testable import TotumComXLApp

/// Ссылки, права и битые ссылки в архивах.
///
/// Упаковка шла по ссылкам: ссылка на файл ложилась копией, на папку — пустой папкой, а битая
/// обрывала всю упаковку («Failed to inspect directory child» — папка с проектами, где во
/// фреймворках сборок сотни таких ссылок). Всем файлам ставилось 0644 — программа из архива не
/// запускалась. Распаковка zip выдавала ссылку файлом с путём внутри. Теперь ссылка — ссылкой
/// туда и обратно, права и дата — из архива, а запись сквозь свою же ссылку наружу запрещена.
final class ArchiveLinksTests: XCTestCase {
    private var root = ""
    private let bridge = CoreBridgeService()

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "ссылки-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    private func path(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }

    /// Папка как в жизни: исполняемый файл, ссылки на файл и на папку, битая ссылка.
    private func makeSource() throws -> String {
        let fm = FileManager.default
        let source = path("проект")
        try fm.createDirectory(atPath: source + "/sub", withIntermediateDirectories: true)
        try "#!/bin/sh\necho привет\n".write(toFile: source + "/tool", atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source + "/tool")
        try "текст".write(toFile: source + "/plain.txt", atomically: true, encoding: .utf8)
        try "внутри".write(toFile: source + "/sub/inner.txt", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: source + "/link-to-file", withDestinationPath: "plain.txt")
        try fm.createSymbolicLink(atPath: source + "/link-to-dir", withDestinationPath: "sub")
        try fm.createSymbolicLink(atPath: source + "/broken", withDestinationPath: "nowhere/gone")
        return source
    }

    private func pack(_ sources: [String], into archive: String, format: ArchiveCreationFormat) throws {
        try bridge.createArchive(archivePath: archive, format: format, sources: sources,
                                 includeSubfolders: true, preservePaths: true,
                                 compressionLevel: 6, password: "",
                                 progress: { _, _, _, _, _, _ in })
    }

    private func unpack(_ archive: String) throws -> String {
        let out = path("наружу-" + (archive as NSString).lastPathComponent)
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try bridge.extractArchiveAll(archivePath: archive, destinationPath: out,
                                     overwriteExisting: true, progress: { _, _, _, _, _, _ in })
        return out
    }

    func test_ссылкиПраваИБитаяСсылка_ТудаИОбратно() throws {
        let source = try makeSource()
        for (name, format) in [("проект.zip", ArchiveCreationFormat.zip),
                               ("проект.tar.gz", .tarGz)] {
            let archive = path(name)
            XCTAssertNoThrow(try pack([source], into: archive, format: format),
                             "\(name): битая ссылка не обрывает упаковку")
            let out = try unpack(archive) + "/проект"
            let fm = FileManager.default
            XCTAssertTrue(fm.isExecutableFile(atPath: out + "/tool"), "\(name): право на запуск осталось")
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: out + "/link-to-file"), "plain.txt",
                           "\(name): ссылка на файл — ссылкой")
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: out + "/link-to-dir"), "sub",
                           "\(name): ссылка на папку — ссылкой")
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: out + "/broken"), "nowhere/gone",
                           "\(name): битая ссылка — тоже ссылкой")
            XCTAssertEqual(try String(contentsOfFile: out + "/link-to-file", encoding: .utf8), "текст")
            XCTAssertEqual(try String(contentsOfFile: out + "/sub/inner.txt", encoding: .utf8), "внутри")
        }
    }

    /// Выбранная сама битая ссылка упаковывается ссылкой, а не ошибкой.
    func test_выбраннаяБитаяСсылкаУпаковываетсяСсылкой() throws {
        let source = try makeSource()
        let archive = path("одна.zip")
        try pack([source + "/broken"], into: archive, format: .zip)
        let out = try unpack(archive)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: out + "/broken"),
                       "nowhere/gone")
    }

    /// Архив-ловушка: запись «evil» — ссылка на папку снаружи, следом запись «evil/x.txt». Файл
    /// лёг бы вне папки распаковки; распаковка отказывает, и снаружи ничего нет.
    func test_архивНеПишетСквозьСвоюСсылкуНаружу() throws {
        let outside = path("снаружи")
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let archive = path("ловушка.zip")
        let script = """
        import sys, zipfile
        z = zipfile.ZipFile(sys.argv[1], "w")
        link = zipfile.ZipInfo("evil")
        link.create_system = 3
        link.external_attr = (0o120777 << 16)
        z.writestr(link, sys.argv[2])
        z.writestr("evil/x.txt", "попал")
        z.close()
        """
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-I", "-c", script, archive, outside]
        python.standardOutput = FileHandle.nullDevice
        python.standardError = FileHandle.nullDevice
        do { try python.run() } catch { throw XCTSkip("нет python3") }
        python.waitUntilExit()
        guard python.terminationStatus == 0 else { throw XCTSkip("python3 не собрал архив") }

        XCTAssertThrowsError(try unpack(archive), "распаковка отказывает")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside + "/x.txt"), "снаружи пусто")
    }
}
