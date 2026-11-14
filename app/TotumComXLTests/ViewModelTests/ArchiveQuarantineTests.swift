import Darwin
import Foundation
import XCTest

@testable import TotumComXLApp

/// Скачанный архив несёт признак карантина, и всё, что из него вынуто, должно нести тот же
/// признак: по нему система спрашивает человека, прежде чем запустить программу из сети.
/// Признак ставится только на свой архив во временной папке; ничего здесь не запускается.
@MainActor
final class ArchiveQuarantineTests: XCTestCase {
    private let attribute = "com.apple.quarantine"
    private let mark = "0083;65f1a2b3;Safari;F6A7B8C9-0000-4000-8000-000000000001"
    private var bridge: CoreBridgeService!
    private var root: String!

    override func setUp() async throws {
        try await super.setUp()
        bridge = CoreBridgeService()
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-quarantine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: root)
        try await super.tearDown()
    }

    // MARK: - Подготовка

    private func path(_ name: String) -> String {
        (root as NSString).appendingPathComponent(name)
    }

    private func folder(_ name: String) throws -> String {
        let folder = path(name)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Архив с папкой «посылка»: скрипт в корне, письмо в глубине и памятка только для чтения.
    private func makeArchive(_ format: ArchiveCreationFormat = .zip, ext: String = ".zip",
                             quarantined: Bool = true) throws -> String {
        let id = UUID().uuidString
        let source = path("исходное-\(id)/посылка")
        let deep = (source as NSString).appendingPathComponent("вложено/глубже")
        try FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)
        try "#!/bin/sh\necho привет\n".write(
            toFile: (source as NSString).appendingPathComponent("запуск.sh"),
            atomically: true, encoding: .utf8)
        try "новое письмо".write(
            toFile: (deep as NSString).appendingPathComponent("письмо.txt"),
            atomically: true, encoding: .utf8)
        let note = (source as NSString).appendingPathComponent("памятка.txt")
        try "памятка".write(toFile: note, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(note, 0o444), 0)

        let archive = path("скачанное-\(id)\(ext)")
        try bridge.createArchive(archivePath: archive, format: format, sources: [source],
                                 includeSubfolders: true, preservePaths: true,
                                 compressionLevel: 6)
        if quarantined { try setQuarantine(archive) }
        return archive
    }

    private func setQuarantine(_ path: String) throws {
        let bytes = Array(mark.utf8)
        guard setxattr(path, attribute, bytes, bytes.count, 0, 0) == 0 else {
            throw XCTSkip("том временной папки не хранит расширенные атрибуты")
        }
    }

    /// Признак самой вещи, а не того, на что она ссылается.
    private func quarantine(at path: String) -> String? {
        let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, attribute, &bytes, size, 0, XATTR_NOFOLLOW)
        guard read > 0 else { return nil }
        return String(decoding: bytes.prefix(read), as: UTF8.self)
    }

    /// Всё, что лежит в папке, на любой глубине.
    private func everything(under folder: String) -> [String] {
        (FileManager.default.enumerator(atPath: folder)?.allObjects as? [String] ?? [])
            .map { (folder as NSString).appendingPathComponent($0) }
    }

    private func entry(of archive: String, endingWith suffix: String) throws -> String {
        try XCTUnwrap(bridge.listArchiveEntries(archivePath: archive)
            .first { !$0.isDirectory && $0.path.hasSuffix(suffix) }).path
    }

    private func unpack(_ archive: String, to destination: String, overwrite: Bool = true) throws {
        try bridge.extractArchiveAll(archivePath: archive, destinationPath: destination,
                                     overwriteExisting: overwrite,
                                     progress: { _, _, _, _, _, _ in })
    }

    // MARK: - Распаковка целиком

    func test_распаковкаЦеликом_помечаетФайлыИПапки() throws {
        let formats: [(ArchiveCreationFormat, String)] = [(.zip, ".zip"), (.tarGz, ".tar.gz"),
                                                          (.sevenZip, ".7z")]
        for (format, ext) in formats {
            let archive = try makeArchive(format, ext: ext)
            let destination = try folder("наружу-\(format.rawValue)")

            try unpack(archive, to: destination)

            let extracted = everything(under: destination)
            XCTAssertGreaterThanOrEqual(extracted.count, 6,
                                        "\(format.rawValue): вышли три файла и три папки")
            for item in extracted {
                XCTAssertEqual(quarantine(at: item), mark,
                               "\(format.rawValue): без признака осталось \(item)")
            }
            XCTAssertNil(quarantine(at: destination),
                         "\(format.rawValue): сама папка человека не из архива")
        }
    }

    func test_архивБезПризнака_ничегоНеПомечает() throws {
        let archive = try makeArchive(quarantined: false)
        let destination = try folder("наружу")

        try unpack(archive, to: destination)

        let extracted = everything(under: destination)
        XCTAssertGreaterThanOrEqual(extracted.count, 6)
        for item in extracted {
            XCTAssertNil(quarantine(at: item), "признак взялся ниоткуда: \(item)")
        }
    }

    func test_чужиеФайлыПриёмника_неПомечаются() throws {
        let archive = try makeArchive()
        let destination = try folder("наружу")
        let own = (destination as NSString).appendingPathComponent("своё.txt")
        try "своё".write(toFile: own, atomically: true, encoding: .utf8)
        let ownInside = try folder("наружу/посылка") + "/старое.txt"
        try "старое".write(toFile: ownInside, atomically: true, encoding: .utf8)

        try unpack(archive, to: destination)

        XCTAssertNil(quarantine(at: own), "файл человека рядом с распакованным")
        XCTAssertNil(quarantine(at: ownInside), "файл человека в папке, куда легло распакованное")
        XCTAssertEqual(quarantine(at: (destination as NSString)
            .appendingPathComponent("посылка/запуск.sh")), mark)
    }

    func test_безПерезаписи_уцелевшийФайлНеПомечается() throws {
        let archive = try makeArchive()
        let destination = try folder("наружу")
        let kept = try folder("наружу/посылка/вложено/глубже") + "/письмо.txt"
        try "старое письмо".write(toFile: kept, atomically: true, encoding: .utf8)

        try unpack(archive, to: destination, overwrite: false)

        XCTAssertEqual(try String(contentsOfFile: kept, encoding: .utf8), "старое письмо")
        XCTAssertNil(quarantine(at: kept), "файл не из архива: распаковка его пропустила")
        XCTAssertEqual(quarantine(at: (destination as NSString)
            .appendingPathComponent("посылка/запуск.sh")), mark, "а вышедшее из архива помечено")
    }

    func test_сПерезаписью_заменённыйФайлПомечается() throws {
        let archive = try makeArchive()
        let destination = try folder("наружу")
        let replaced = try folder("наружу/посылка/вложено/глубже") + "/письмо.txt"
        try "старое письмо".write(toFile: replaced, atomically: true, encoding: .utf8)

        try unpack(archive, to: destination, overwrite: true)

        XCTAssertEqual(try String(contentsOfFile: replaced, encoding: .utf8), "новое письмо")
        XCTAssertEqual(quarantine(at: replaced), mark)
    }

    func test_файлТолькоДляЧтения_помеченИОстаётсяТолькоДляЧтения() throws {
        let archive = try makeArchive()
        let destination = try folder("наружу")

        try unpack(archive, to: destination)

        let note = (destination as NSString).appendingPathComponent("посылка/памятка.txt")
        var info = stat()
        XCTAssertEqual(lstat(note, &info), 0)
        XCTAssertEqual(info.st_mode & 0o222, 0, "права из архива: писать нельзя никому")
        XCTAssertEqual(quarantine(at: note), mark)
    }

    /// Папка приёмника с именем из архива оказалась ссылкой наружу: ядро туда не пишет, и
    /// признак на чужое по ту сторону ссылки не ложится.
    func test_сквозьСсылкуНаружу_чужоеНеПомечается() throws {
        let archive = try makeArchive()
        let destination = try folder("наружу")
        let outside = try folder("в-стороне")
        let foreign = try folder("в-стороне/вложено/глубже") + "/письмо.txt"
        try "чужое письмо".write(toFile: foreign, atomically: true, encoding: .utf8)
        let foreignScript = (outside as NSString).appendingPathComponent("запуск.sh")
        try "чужой скрипт".write(toFile: foreignScript, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: (destination as NSString).appendingPathComponent("посылка"),
            withDestinationPath: outside)

        try? unpack(archive, to: destination)

        XCTAssertEqual(try String(contentsOfFile: foreign, encoding: .utf8), "чужое письмо")
        XCTAssertNil(quarantine(at: foreign))
        XCTAssertNil(quarantine(at: foreignScript))
        XCTAssertNil(quarantine(at: outside))
    }

    // MARK: - Отдельные записи

    func test_однаЗапись_помеченаВместеСПапкамиНаПути() throws {
        let archive = try makeArchive()
        let destination = try folder("временное")
        let letter = try entry(of: archive, endingWith: "письмо.txt")

        try bridge.extractArchiveEntry(archivePath: archive, entryPath: letter,
                                       destinationPath: destination)

        let extracted = everything(under: destination)
        XCTAssertTrue(extracted.contains { $0.hasSuffix("письмо.txt") }, "запись вышла")
        for item in extracted {
            XCTAssertEqual(quarantine(at: item), mark, "без признака осталось \(item)")
        }
    }

    func test_записьПапка_помеченаЦеликом() throws {
        let archive = try makeArchive()
        let destination = try folder("временное")
        let letter = try entry(of: archive, endingWith: "письмо.txt")
        // «посылка/вложено» — папка с папкой внутри.
        let branch = ((letter as NSString).deletingLastPathComponent as NSString)
            .deletingLastPathComponent

        try bridge.extractArchiveEntry(archivePath: archive, entryPath: branch,
                                       destinationPath: destination)

        let extracted = everything(under: destination)
        XCTAssertTrue(extracted.contains { $0.hasSuffix("письмо.txt") }, "вышло и вложенное")
        for item in extracted {
            XCTAssertEqual(quarantine(at: item), mark, "без признака осталось \(item)")
        }
    }

    /// Так записи архива вынимает перетаскивание и копирование: через временную папку рядом.
    func test_извлечениеВПапку_несётПризнак() throws {
        let archive = try makeArchive()
        let destination = try folder("наружу")
        let script = try entry(of: archive, endingWith: "запуск.sh")
        let top = (script as NSString).deletingLastPathComponent
        let ops = FileOperationsService(bridgeService: bridge)

        try ops.extractEntries([top], fromArchive: archive, to: destination,
                               onProgress: { _, _, _, _, _, _ in })

        let extracted = everything(under: destination)
        XCTAssertGreaterThanOrEqual(extracted.count, 6, "вышла вся папка")
        for item in extracted {
            XCTAssertEqual(quarantine(at: item), mark, "без признака осталось \(item)")
        }
    }

    func test_архивБезПризнака_записьНеПомечается() throws {
        let archive = try makeArchive(quarantined: false)
        let destination = try folder("временное")
        let letter = try entry(of: archive, endingWith: "письмо.txt")

        try bridge.extractArchiveEntry(archivePath: archive, entryPath: letter,
                                       destinationPath: destination)

        for item in everything(under: destination) {
            XCTAssertNil(quarantine(at: item), "признак взялся ниоткуда: \(item)")
        }
    }

    // MARK: - Порядок: список записей, потом распаковка

    /// Список записей не прочитан — в том числе из-за «Отмены», нажатой в это время, —
    /// и распаковка не начинается: без списка вынутое осталось бы без признака.
    func test_списокНеПрочитан_распаковкаНеНачинается() throws {
        let archive = try makeArchive()
        let destination = try folder("наружу")
        var extracted = false

        XCTAssertThrowsError(try ArchiveQuarantine.extracting(
            archive, into: destination, overwriteExisting: true,
            entries: { throw CocoaError(.userCancelled) },
            extract: { extracted = true }))

        XCTAssertFalse(extracted, "распаковка пошла без списка записей")
    }

    /// Архив не из сети: записи лишний раз не перечисляются — у сжатого tar это целый проход.
    func test_архивБезПризнака_записиНеПеречисляются() throws {
        let archive = try makeArchive(quarantined: false)
        let destination = try folder("наружу")
        var listed = false
        var extracted = false

        try ArchiveQuarantine.extracting(
            archive, into: destination, overwriteExisting: true,
            entries: { listed = true; return [] },
            extract: { extracted = true })

        XCTAssertFalse(listed, "записи перечислены зря")
        XCTAssertTrue(extracted)
    }

    /// Список, уже прочитанный вызывающим, берётся как есть: архив второй раз не читается.
    func test_готовыйСписок_берётсяКакЕсть() throws {
        let archive = try makeArchive()
        let destination = try folder("наружу")
        let script = try XCTUnwrap(bridge.listArchiveEntries(archivePath: archive)
            .first { $0.path.hasSuffix("запуск.sh") })

        try bridge.extractArchiveAll(archivePath: archive, destinationPath: destination,
                                     overwriteExisting: true, entries: [script],
                                     progress: { _, _, _, _, _, _ in })

        let extracted = everything(under: destination)
        let scriptPath = try XCTUnwrap(extracted.first { $0.hasSuffix("запуск.sh") })
        let notePath = try XCTUnwrap(extracted.first { $0.hasSuffix("памятка.txt") })
        XCTAssertEqual(quarantine(at: scriptPath), mark)
        XCTAssertNil(quarantine(at: notePath), "архив перечитан: помечено и то, чего в списке нет")
    }
}
