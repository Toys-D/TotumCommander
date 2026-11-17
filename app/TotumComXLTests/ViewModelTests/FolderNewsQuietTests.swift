import XCTest
@testable import TotumComXLApp

/// Журнал новых файлов («+N») не должен стоить программе заметного процессора.
///
/// Замер на 1.20: каждое событие диска под папкой панели проверялось сразу, и в фоне тоже, —
/// ~80 мкс на событие. Пока рядом собирался проект, свёрнутая программа стояла первой в
/// «Мониторинге системы». Разбор пути теперь идёт байтами, а в фоне события только копятся.
final class FolderNewsQuietTests: XCTestCase {

    /// Временная папка лежит в /var — системном корне, где новое не отмечается; для проверок
    /// правило подменяется, как и в FolderNewsTests.
    override func setUp() {
        super.setUp()
        FileNewness.excludedOverride = { _ in false }
    }

    override func tearDown() {
        FileNewness.excludedOverride = nil
        super.tearDown()
    }

    private func freshTree() throws -> (top: URL, inner: URL) {
        let fm = FileManager.default
        let top = fm.temporaryDirectory.appendingPathComponent("fcxl-тихо-\(UUID().uuidString)")
        let inner = top.appendingPathComponent("Проект")
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("новое".utf8).write(to: inner.appendingPathComponent("отчёт.docx"))
        try Data("новое".utf8).write(to: inner.appendingPathComponent("смета.xlsx"))
        addTeardownBlock { try? fm.removeItem(at: top) }
        return (top, inner)
    }

    private func recent(_ arrivals: FolderNewsArrivals, under top: URL) -> [String] {
        arrivals.entries(under: top.path, since: Date().addingTimeInterval(-3600)).map(\.path).sorted()
    }

    // MARK: - Путь байтами

    func test_папкиСРасширениемНаПути_ближняяПервой() {
        let folders = FolderNewsPath.foldersWithExtension(above:)
        XCTAssertEqual(folders("/Users/кто/Проект.app/Contents/MacOS/файл"), ["/Users/кто/Проект.app"])
        XCTAssertEqual(folders("/a/b.x/c.y/d/file.txt"), ["/a/b.x/c.y", "/a/b.x"])
        XCTAssertEqual(folders("/Users/кто/Documents/отчёт.docx"), [], "расширение самого файла не в счёт")
        XCTAssertEqual(folders("/a/.скрытая/b/файл"), [], "точка в начале имени — не расширение")
        XCTAssertEqual(folders("/a/имя./файл"), [], "точка в конце — тоже")
        XCTAssertEqual(folders("/a/Документ.pages/"), [], "косая в конце: последняя часть — сам пакет")
        XCTAssertEqual(folders("/файл"), [])
        XCTAssertEqual(folders("файл"), [])
        XCTAssertEqual(folders(""), [])
    }

    func test_скрытаяЧастьПути() {
        XCTAssertTrue(FolderNewsPath.hasHiddenPart("/Users/кто/.git/config"))
        XCTAssertTrue(FolderNewsPath.hasHiddenPart("/Users/кто/проект/.DS_Store"))
        XCTAssertFalse(FolderNewsPath.hasHiddenPart("/Users/кто/a.b/c.d"))
        XCTAssertFalse(FolderNewsPath.hasHiddenPart(""))
    }

    /// Правило «где новое не отмечается» — то же, что было до разбора байтами.
    func test_гдеНовоеНеОтмечается_граничныеСлучаи() {
        let excluded = FileNewness.isExcludedByDefault
        XCTAssertFalse(excluded("/Users/кто/Documents/файл.txt"))
        XCTAssertTrue(excluded("/private/tmp/x"))
        XCTAssertTrue(excluded("/private"), "сам корень")
        XCTAssertFalse(excluded("/privateer/x"), "похожее начало имени — не корень")
        XCTAssertTrue(excluded(NSHomeDirectory() + "/Library/Preferences/x.plist"))
        XCTAssertFalse(excluded(NSHomeDirectory() + "/LibraryX/y"))
        XCTAssertTrue(excluded("/Users/кто/.git/config"), "скрытая папка на пути")
        XCTAssertTrue(excluded("/Users/кто/проект/.DS_Store"), "скрытый файл")
        XCTAssertFalse(excluded("/Users/кто/a.b/c.d"), "точка внутри имени — не скрытое")
        XCTAssertTrue(excluded("/Users/кто/проект/Caches/x"))
        XCTAssertTrue(excluded("/Users/кто/проект/cache"))
        XCTAssertFalse(excluded("/Users/кто/проект/MyCaches/x"))
        XCTAssertFalse(excluded("/Users/кто/проект/Cachesx/y"))
        XCTAssertFalse(excluded("/Users/кто/проект/CACHE/x"), "только четыре написания, как и было")
        XCTAssertFalse(excluded(""))
    }

    // MARK: - В фоне

    func test_программаВпереди_событиеРазбираетсяСразу() throws {
        let arrivals = FolderNewsArrivals()
        let (top, inner) = try freshTree()
        let report = inner.appendingPathComponent("отчёт.docx").path
        arrivals.arrive([report])
        XCTAssertEqual(recent(arrivals, under: top), [report])
    }

    func test_вФонеЖурналКопит_поВозвращенииРазбирает() throws {
        let arrivals = FolderNewsArrivals()
        let (top, inner) = try freshTree()
        let report = inner.appendingPathComponent("отчёт.docx").path
        let budget = inner.appendingPathComponent("смета.xlsx").path
        arrivals.hold()
        arrivals.arrive([report])
        arrivals.arrive([report, budget])
        arrivals.arrive([report])
        XCTAssertEqual(recent(arrivals, under: top), [], "в фоне на диск не смотрим")
        XCTAssertEqual(arrivals.heldCount, 2, "один путь — один раз, сколько бы его ни переписывали")

        arrivals.release(on: nil)
        XCTAssertEqual(recent(arrivals, under: top), [budget, report].sorted())
        XCTAssertEqual(arrivals.heldCount, 0)
        arrivals.arrive([report])
        XCTAssertEqual(arrivals.heldCount, 0, "вернулись — снова сразу")
    }

    /// Появился и исчез, пока программа была в фоне (временный файл сборки), — одна проверка
    /// по возвращении, и в списке его нет.
    func test_вФонеПоявилсяИИсчез_вСпискеНет() throws {
        let arrivals = FolderNewsArrivals()
        let (top, inner) = try freshTree()
        let temp = inner.appendingPathComponent("временный.o").path
        arrivals.hold()
        FileManager.default.createFile(atPath: temp, contents: nil)
        arrivals.arrive([temp])
        try FileManager.default.removeItem(atPath: temp)
        arrivals.arrive([temp])
        arrivals.release(on: nil)
        XCTAssertEqual(recent(arrivals, under: top), [])
    }

    /// Долгая сборка в фоне не копит пути без конца: набралось много — разбираются сразу.
    func test_вФонеПереполнение_разбираетсяНеДожидаясьВозвращения() throws {
        let arrivals = FolderNewsArrivals(heldCapacity: 1)
        let (top, inner) = try freshTree()
        let report = inner.appendingPathComponent("отчёт.docx").path
        let budget = inner.appendingPathComponent("смета.xlsx").path
        arrivals.hold()
        arrivals.arrive([report])
        XCTAssertEqual(recent(arrivals, under: top), [])
        arrivals.arrive([budget])
        XCTAssertEqual(recent(arrivals, under: top), [budget, report].sorted())
        XCTAssertEqual(arrivals.heldCount, 0)
    }

    // MARK: - Сведения о файле одним обращением к диску

    private func facts(_ path: String, file: StaticString = #filePath, line: UInt = #line) -> FolderNewsDisk.Facts? {
        guard case .facts(let facts) = FolderNewsDisk.facts(at: path) else {
            XCTFail("сведений нет: \(path)", file: file, line: line)
            return nil
        }
        return facts
    }

    /// Быстрый ответ — тот же, что давали lstat и свойства URL.
    func test_сведенияОФайле_теЖеЧтоПоСтарому() throws {
        let (_, inner) = try freshTree()
        let report = inner.appendingPathComponent("отчёт.docx").path
        let fast = try XCTUnwrap(facts(report))
        guard case .facts(let slow) = FolderNewsDisk.slowFacts(at: report) else { return XCTFail("по-старому не ответил") }
        XCTAssertEqual(fast.kind, .file)
        XCTAssertEqual(slow.kind, .file)
        XCTAssertFalse(fast.isHidden)
        let modified = try XCTUnwrap(fast.modified), added = try XCTUnwrap(fast.added)
        XCTAssertEqual(modified.timeIntervalSince1970, try XCTUnwrap(slow.modified).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(added.timeIntervalSince1970, try XCTUnwrap(slow.added).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertLessThan(abs(added.timeIntervalSinceNow), 60, "появился только что")
    }

    func test_сведения_папкаСсылкаСкрытыйИПропавший() throws {
        let fm = FileManager.default
        let (_, inner) = try freshTree()
        XCTAssertEqual(facts(inner.path)?.kind, .folder)

        let link = inner.appendingPathComponent("ссылка").path
        try fm.createSymbolicLink(atPath: link, withDestinationPath: inner.appendingPathComponent("отчёт.docx").path)
        XCTAssertEqual(facts(link)?.kind, .other, "ссылка — не файл: за ней не ходим")

        let hidden = inner.appendingPathComponent("спрятан.txt")
        try Data().write(to: hidden)
        var values = URLResourceValues()
        values.isHidden = true
        var url = hidden
        try url.setResourceValues(values)
        XCTAssertEqual(facts(hidden.path)?.isHidden, true)

        guard case .gone = FolderNewsDisk.facts(at: inner.appendingPathComponent("нет-такого").path) else {
            return XCTFail("пропавший файл должен быть «ушёл»")
        }
        guard case .gone = FolderNewsDisk.facts(at: inner.appendingPathComponent("отчёт.docx/внутри").path) else {
            return XCTFail("путь сквозь файл — тоже «ушёл»")
        }
    }
}
