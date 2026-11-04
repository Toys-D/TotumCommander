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

    private func pack(_ sources: [String], into archive: String, format: ArchiveCreationFormat,
                      links: ArchiveLinkMode = .keep) throws {
        try bridge.createArchive(archivePath: archive, format: format, sources: sources,
                                 includeSubfolders: true, preservePaths: true,
                                 compressionLevel: 6, password: "", links: links,
                                 progress: { _, _, _, _, _, _ in })
    }

    private func isLink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    /// К папке из `makeSource` — ссылки наружу: на файл рядом, на папку рядом, по полному пути,
    /// битая наружу; и внутри — на исполняемый файл и петля вверх.
    private func makeLinkedSource() throws -> String {
        let fm = FileManager.default
        let outside = path("снаружи")
        try fm.createDirectory(atPath: outside + "/папка", withIntermediateDirectories: true)
        try "наружу".write(toFile: outside + "/data.txt", atomically: true, encoding: .utf8)
        try "в папке".write(toFile: outside + "/папка/deep.txt", atomically: true, encoding: .utf8)
        let source = try makeSource()
        try fm.createSymbolicLink(atPath: source + "/out-file", withDestinationPath: "../снаружи/data.txt")
        try fm.createSymbolicLink(atPath: source + "/out-dir", withDestinationPath: "../снаружи/папка")
        try fm.createSymbolicLink(atPath: source + "/abs-file", withDestinationPath: outside + "/data.txt")
        try fm.createSymbolicLink(atPath: source + "/broken-out", withDestinationPath: "../нет-такого")
        try fm.createSymbolicLink(atPath: source + "/tool-link", withDestinationPath: "tool")
        try fm.createSymbolicLink(atPath: source + "/sub/up", withDestinationPath: "..")
        return source
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

    /// «Наружные — файлами»: ссылка по полному пути или выше упакованного ложится тем, на что
    /// ведёт, — на другом Mac её цели нет. Ссылки внутри остаются ссылками, битая — тоже.
    func test_наружныеСсылкиЛожатсяТем_НаЧтоВедут() throws {
        let source = try makeLinkedSource()
        for (name, format) in [("наружные.zip", ArchiveCreationFormat.zip),
                               ("наружные.tar.gz", .tarGz)] {
            let archive = path(name)
            try pack([source], into: archive, format: format, links: .followOutside)
            let out = try unpack(archive) + "/проект"
            let fm = FileManager.default
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: out + "/link-to-file"), "plain.txt",
                           "\(name): внутри — ссылкой")
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: out + "/link-to-dir"), "sub")
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: out + "/sub/up"), "..")
            XCTAssertFalse(isLink(out + "/out-file"), "\(name): наружу — файлом")
            XCTAssertEqual(text(out + "/out-file"), "наружу")
            XCTAssertFalse(isLink(out + "/abs-file"), "\(name): по полному пути — файлом")
            XCTAssertEqual(text(out + "/abs-file"), "наружу")
            XCTAssertFalse(isLink(out + "/out-dir"), "\(name): папка снаружи — папкой")
            XCTAssertEqual(text(out + "/out-dir/deep.txt"), "в папке")
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: out + "/broken-out"), "../нет-такого",
                           "\(name): битую развернуть нечем — ссылкой")
        }
    }

    /// «Все — файлами»: каждая ссылка — тем, на что ведёт, с правами цели. Битая и петля вверх
    /// развернуться не могут и остаются ссылками — иначе упаковка не кончилась бы.
    func test_всеСсылкиЛожатсяТем_НаЧтоВедут() throws {
        let source = try makeLinkedSource()
        for (name, format) in [("все.zip", ArchiveCreationFormat.zip), ("все.tar.gz", .tarGz)] {
            let archive = path(name)
            try pack([source], into: archive, format: format, links: .followAll)
            let out = try unpack(archive) + "/проект"
            let fm = FileManager.default
            XCTAssertFalse(isLink(out + "/link-to-file"), "\(name)")
            XCTAssertEqual(text(out + "/link-to-file"), "текст")
            XCTAssertFalse(isLink(out + "/link-to-dir"), "\(name)")
            XCTAssertEqual(text(out + "/link-to-dir/inner.txt"), "внутри")
            XCTAssertEqual(text(out + "/out-file"), "наружу")
            XCTAssertEqual(text(out + "/out-dir/deep.txt"), "в папке")
            XCTAssertFalse(isLink(out + "/tool-link"))
            XCTAssertTrue(fm.isExecutableFile(atPath: out + "/tool-link"), "\(name): права — от цели")
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: out + "/broken"), "nowhere/gone")
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: out + "/sub/up"), "..",
                           "\(name): петля — ссылкой")
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: out + "/link-to-dir/up"), "..")
        }
    }

    /// Граница «своего» — всё выбранное: ссылка в соседнюю выбранную папку ведёт внутрь архива и
    /// остаётся ссылкой; без соседа та же ссылка ведёт наружу.
    func test_ссылкаВСоседнююВыбраннуюПапку() throws {
        let fm = FileManager.default
        let a = path("A"), b = path("B")
        try fm.createDirectory(atPath: a, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: b, withIntermediateDirectories: true)
        try "соседний".write(toFile: b + "/f.txt", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: a + "/l", withDestinationPath: "../B/f.txt")

        let both = path("оба.zip")
        try pack([a, b], into: both, format: .zip, links: .followOutside)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: try unpack(both) + "/A/l"), "../B/f.txt")

        let alone = path("один.zip")
        try pack([a], into: alone, format: .zip, links: .followOutside)
        let out = try unpack(alone) + "/A/l"
        XCTAssertFalse(isLink(out))
        XCTAssertEqual(text(out), "соседний")
    }

    /// Выбранная сама ссылка наружу — тем, на что ведёт: на файл — файлом, на папку — папкой.
    func test_выбраннаяСсылкаНаружу() throws {
        let source = try makeLinkedSource()
        let archive = path("выбранные.tar.gz")
        try pack([source + "/out-file", source + "/out-dir"], into: archive, format: .tarGz,
                 links: .followOutside)
        let out = try unpack(archive)
        XCTAssertFalse(isLink(out + "/out-file"))
        XCTAssertEqual(text(out + "/out-file"), "наружу")
        XCTAssertFalse(isLink(out + "/out-dir"))
        XCTAssertEqual(text(out + "/out-dir/deep.txt"), "в папке")
    }

    /// Ход упаковки знает и то, что придёт через ссылки: итог считает тот же обход, что пишет.
    func test_итогХодаСчитаетТо_ЧтоПридётЧерезСсылки() throws {
        let fm = FileManager.default
        let dir = path("итоги")
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: URL(fileURLWithPath: path("большой.bin")))
        try "x".write(toFile: dir + "/own.txt", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: dir + "/big", withDestinationPath: "../большой.bin")

        func total(_ links: ArchiveLinkMode) throws -> Int64 {
            var seen: Int64 = 0
            try bridge.createArchive(archivePath: path("итоги-\(links.rawValue).tar"), format: .tar,
                                     sources: [dir], includeSubfolders: true, preservePaths: true,
                                     compressionLevel: 0, password: "", links: links,
                                     progress: { _, _, bytesTotal, _, _, _ in seen = max(seen, bytesTotal) })
            return seen
        }
        XCTAssertEqual(try total(.keep), 1)
        XCTAssertEqual(try total(.followOutside), 100_001)
    }

    /// Правка tar (переименование записи) пересобирает его заново — ссылка верхнего уровня
    /// остаётся ссылкой, а битая не пропадает.
    func test_правкаАрхиваНеРазворачиваетСсылки() throws {
        let source = try makeSource()
        let archive = path("правка.tar.gz")
        try pack([source + "/plain.txt", source + "/link-to-dir", source + "/broken"],
                 into: archive, format: .tarGz)
        try bridge.renameEntryInArchive(archivePath: archive, oldEntryPath: "plain.txt",
                                        newEntryPath: "renamed.txt")
        let out = try unpack(archive)
        let fm = FileManager.default
        XCTAssertEqual(text(out + "/renamed.txt"), "текст")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: out + "/link-to-dir"), "sub")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: out + "/broken"), "nowhere/gone")
    }

    /// Отправляемый zip — без ссылок наружу при любом выборе: у получателя их цели нет.
    func test_отправкаНеОставляетСсылокНаружу() {
        XCTAssertEqual(ArchiveLinkMode.keep.forSending, .followOutside)
        XCTAssertEqual(ArchiveLinkMode.followOutside.forSending, .followOutside)
        XCTAssertEqual(ArchiveLinkMode.followAll.forSending, .followAll)
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
