import AppKit
import XCTest

@testable import TotumComXLApp

/// Свой том на весь класс. Держится вне главного актора: заводят и снимают его общие
/// `setUp`/`tearDown` класса, а они к актору не привязаны.
private enum UndoVolume {
    static var image: TestDiskImage?
}

/// Признак, который ставят с одного потока и читают с другого.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private func existsOnDisk(_ path: String) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: path)) != nil
}

/// Обычные файлы под папкой, скрытые тоже: всё, что копирование уже успело положить.
private func filesBelow(_ folder: String) -> [String] {
    guard let walker = FileManager.default.enumerator(atPath: folder) else { return [] }
    var found: [String] = []
    for case let relative as String in walker {
        var info = stat()
        if lstat(folder + "/" + relative, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
            found.append(relative)
        }
    }
    return found.sorted()
}

private func bytesBelow(_ folder: String) -> Int64 {
    filesBelow(folder).reduce(0) { sum, relative in
        var info = stat()
        return lstat(folder + "/" + relative, &info) == 0 ? sum + Int64(info.st_size) : sum
    }
}

/// ⌘Z и ⇧⌘Z над большим переносом: работа идёт в стороне от главного потока, её можно
/// остановить, остановленная не оставляет половины на месте и доделывается повтором, а пока
/// она тянется — показано окно хода.
@MainActor
final class UndoInterruptTests: XCTestCase {

    private var ops: FileOperationsService!
    private var tmp: String!
    private var volumeFolders: [String] = []

    override class func setUp() {
        super.setUp()
        UndoVolume.image = try? TestDiskImage(megabytes: 16)
    }

    override class func tearDown() {
        UndoVolume.image?.detach()
        UndoVolume.image = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        UndoJournal.shared.reset()
        ops = FileOperationsService(bridgeService: CoreBridgeService())
        tmp = (FileManager.default.temporaryDirectory.path as NSString)
            .appendingPathComponent("fcxl-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path("b"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UndoJournal.shared.reset()
        for folder in volumeFolders { try? FileManager.default.removeItem(atPath: folder) }
        volumeFolders = []
        if let tmp { try? FileManager.default.removeItem(atPath: tmp) }
        ops = nil
        tmp = nil
        try super.tearDownWithError()
    }

    // MARK: - Отмена, остановленная на полпути

    func test_остановленнаяОтменаОставляетЗаписьИДоделываетсяПовтором() async throws {
        // Три файла уже лежат в «b»; запись говорит, что они пришли из «a».
        let names = ["один.txt", "два.txt", "три.txt"]
        var pairs: [(from: String, to: String)] = []
        for name in names {
            pairs.append((from: path("a", name), to: try write("b", name)))
        }
        UndoJournal.shared.record(.moved(pairs: pairs))

        let firstBack = path("a", "один.txt")
        let asked = Flag(), askedOnMain = Flag()
        let stop: @Sendable () -> Bool = {
            asked.set()
            if Thread.isMainThread { askedOnMain.set() }
            return existsOnDisk(firstBack)
        }
        do {
            try await undoLast(stop)
            XCTFail("остановленная отмена должна сказать, что её остановили")
        } catch {
            assertStopped(error)
        }

        XCTAssertTrue(asked.isSet, "об остановке надо спрашивать")
        XCTAssertFalse(askedOnMain.isSet, "работа отмены идёт в стороне от главного потока")
        XCTAssertTrue(exists(path("a", "один.txt")), "первый вернулся до остановки")
        XCTAssertTrue(exists(path("b", "два.txt")), "до второго дело не дошло")
        XCTAssertTrue(exists(path("b", "три.txt")))
        XCTAssertTrue(UndoJournal.shared.canUndo, "остановленную отмену можно повторить")
        XCTAssertFalse(UndoJournal.shared.canRedo)

        try await undoLast()

        for name in names {
            XCTAssertTrue(exists(path("a", name)), name)
            XCTAssertFalse(exists(path("b", name)), name)
        }
        XCTAssertFalse(UndoJournal.shared.canUndo)
        XCTAssertTrue(UndoJournal.shared.canRedo)
    }

    func test_остановленнаяОтменаМеждуТомамиНеОставляетПоловиныИДоделываетсяПовтором() async throws {
        let away = try volumeFolder()
        let moved = away + "/Набор"
        let files = try makeSet(at: moved)
        let home = path("a")
        let back = path("a", "Набор")
        UndoJournal.shared.record(.moved(pairs: [(from: back, to: moved)]))

        // Остановить, как только на прежнем месте появился первый файл — посреди папки.
        let stop: @Sendable () -> Bool = { !filesBelow(home).isEmpty }
        do {
            try await undoLast(stop)
            XCTFail("остановленная отмена должна сказать, что её остановили")
        } catch {
            assertStopped(error)
        }

        XCTAssertEqual(names(in: home), [], "от остановленной отмены на месте ничего не остаётся")
        XCTAssertEqual(filesBelow(moved), files, "перенесённое цело там, где лежало")
        XCTAssertTrue(UndoJournal.shared.canUndo, "остановленную отмену можно повторить")

        try await undoLast()

        XCTAssertEqual(filesBelow(back), files, "повторная отмена вернула папку целиком")
        XCTAssertFalse(exists(moved))
        XCTAssertEqual(names(in: home), ["Набор"])
        XCTAssertFalse(UndoJournal.shared.canUndo)
        XCTAssertTrue(UndoJournal.shared.canRedo)
    }

    func test_отменаПереносаМеждуТомамиВозвращаетПапкуЦеликом() async throws {
        let away = try volumeFolder()
        let moved = away + "/Набор"
        let files = try makeSet(at: moved)
        let size = bytesBelow(moved)
        let back = path("a", "Набор")
        UndoJournal.shared.record(.moved(pairs: [(from: back, to: moved)]))

        try await undoLast()

        XCTAssertEqual(filesBelow(back), files)
        XCTAssertEqual(bytesBelow(back), size)
        XCTAssertEqual(names(in: away), [], "на другом томе от папки ничего не осталось")
        XCTAssertTrue(UndoJournal.shared.canRedo)
    }

    // MARK: - Повтор, остановленный на полпути

    func test_остановленныйПовторОставляетЗаписьИДоделывается() async throws {
        let names = ["один.txt", "два.txt", "три.txt"]
        var pairs: [(from: String, to: String)] = []
        for name in names {
            pairs.append((from: try write("a", name), to: path("b", name)))
        }
        UndoJournal.shared.record(.moved(pairs: pairs))
        try await UndoJournal.shared.undo { _ in }      // запись — в «повторить», файлы в «a»

        let firstThere = path("b", "один.txt")
        let stop: @Sendable () -> Bool = { existsOnDisk(firstThere) }
        do {
            try await redoLast(stop)
            XCTFail("остановленный повтор должен сказать, что его остановили")
        } catch {
            assertStopped(error)
        }

        XCTAssertTrue(exists(path("b", "один.txt")), "первый ушёл до остановки")
        XCTAssertTrue(exists(path("a", "два.txt")), "до второго дело не дошло")
        XCTAssertTrue(exists(path("a", "три.txt")))
        XCTAssertTrue(UndoJournal.shared.canRedo, "остановленный повтор можно повторить")

        try await redoLast()

        for name in names {
            XCTAssertTrue(exists(path("b", name)), name)
            XCTAssertFalse(exists(path("a", name)), name)
        }
        XCTAssertFalse(UndoJournal.shared.canRedo)
        XCTAssertTrue(UndoJournal.shared.canUndo)
    }

    func test_остановленныйПовторКопииМеждуТомамиНеОставляетПоловины() async throws {
        let source = path("a", "Набор")
        let files = try makeSet(at: source)
        let away = try volumeFolder()
        let copy = away + "/Набор"
        let record = UndoJournal.Record.copied(sources: [source], destinationDir: away, created: [copy])

        let stop: @Sendable () -> Bool = { !filesBelow(away).isEmpty }
        do {
            _ = try await ops.performRedo(of: record, shouldCancel: stop)
            XCTFail("остановленный повтор должен сказать, что его остановили")
        } catch {
            assertStopped(error)
        }

        XCTAssertEqual(names(in: away), [], "от остановленной копии на месте ничего не остаётся")
        XCTAssertEqual(filesBelow(source), files, "источник цел")

        _ = try await ops.performRedo(of: record)

        XCTAssertEqual(filesBelow(copy), files, "повтор без остановки кладёт копию целиком")
        XCTAssertEqual(bytesBelow(copy), bytesBelow(source))
        XCTAssertEqual(filesBelow(source), files)
    }

    // MARK: - Окно хода

    func test_затянувшаясяОтменаПоказываетОкноХодаИЗакрываетЕго() async throws {
        let file = try write("b", "долго.txt")
        UndoJournal.shared.record(.moved(pairs: [(from: path("a", "долго.txt"), to: file)]))
        let title = L("undo.progress.back")
        let seen = Flag()
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if Self.progressWindowIsUp(title) { seen.set() }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        defer { watcher.cancel() }
        // Работа «тянется», пока окно не показалось: об остановке спрашивают в стороне от
        // главного потока, и ответ задерживается до окна (или до крайнего срока).
        let hold: @Sendable () -> Bool = {
            let deadline = Date().addingTimeInterval(5)
            while !seen.isSet, Date() < deadline { usleep(20_000) }
            return false
        }

        try await undoLast(hold)

        XCTAssertTrue(seen.isSet, "когда отмена тянется, показывается окно хода")
        XCTAssertFalse(Self.progressWindowIsUp(title), "по завершении окно закрыто")
        XCTAssertTrue(exists(path("a", "долго.txt")))
        XCTAssertFalse(UndoJournal.shared.canUndo)
    }

    func test_быстраяОтменаОкнаНеПоказываетИНеОставляет() async throws {
        let file = try write("b", "быстро.txt")
        UndoJournal.shared.record(.moved(pairs: [(from: path("a", "быстро.txt"), to: file)]))
        let title = L("undo.progress.back")

        try await undoLast()

        XCTAssertTrue(exists(path("a", "быстро.txt")))
        XCTAssertFalse(Self.progressWindowIsUp(title))
        // Окно назначено на полсекунды вперёд: после конца работы оно всплыть не должно.
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertFalse(Self.progressWindowIsUp(title), "окно не всплывает, когда работа уже кончилась")
    }

    // MARK: - Перенос и копия «целиком или никак»

    func test_переносЦеликомНаЗанятоеИмяОтказываетИНичегоНеТрогает() throws {
        let source = try write("a", "письмо.txt", text: "новое")
        let taken = try write("b", "письмо.txt", text: "прежнее")

        XCTAssertThrowsError(try DarwinFileOperations.moveWhole(from: source, to: taken)) { error in
            let failure = error as NSError
            XCTAssertEqual(failure.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(failure.code, Int(EEXIST))
        }

        XCTAssertEqual(read(source), "новое", "источник на месте")
        XCTAssertEqual(read(taken), "прежнее", "занявший имя не затёрт")
    }

    func test_копияЦеликомНаЗанятоеИмяОтказываетИНичегоНеТрогает() throws {
        let source = try write("a", "письмо.txt", text: "новое")
        let taken = try write("b", "письмо.txt", text: "прежнее")

        XCTAssertThrowsError(try DarwinFileOperations.copyWhole(from: source, to: taken)) { error in
            let failure = error as NSError
            XCTAssertEqual(failure.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(failure.code, Int(EEXIST))
        }

        XCTAssertEqual(read(source), "новое")
        XCTAssertEqual(read(taken), "прежнее", "занявший имя не затёрт")
        XCTAssertEqual(names(in: path("b")), ["письмо.txt"], "заготовок рядом не осталось")
    }

    func test_переносЦеликомНаТомЖеТомеЭтоПереименование() throws {
        let source = try write("a", "письмо.txt", text: "новое")
        let target = path("b", "письмо.txt")

        XCTAssertTrue(try DarwinFileOperations.moveWhole(from: source, to: target))

        XCTAssertFalse(exists(source))
        XCTAssertEqual(read(target), "новое")
    }

    func test_остановленныйПереносЦеликомМеждуТомамиНеОставляетПоловины() throws {
        let source = path("a", "Набор")
        let files = try makeSet(at: source)
        let away = try volumeFolder()
        var calls = 0

        XCTAssertThrowsError(try DarwinFileOperations.moveWhole(
            from: source, to: away + "/Набор",
            shouldCancel: { calls += 1; return calls > 3 })) { error in
            let failure = error as NSError
            XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
            XCTAssertEqual(failure.code, CocoaError.userCancelled.rawValue)
        }

        XCTAssertEqual(names(in: away), [], "ни начатой папки, ни заготовки")
        XCTAssertEqual(filesBelow(source), files, "источник цел")
    }

    func test_остановленнаяКопияЦеликомМеждуТомамиНеОставляетПоловины() throws {
        let source = path("a", "Набор")
        let files = try makeSet(at: source)
        let away = try volumeFolder()
        var calls = 0

        XCTAssertThrowsError(try DarwinFileOperations.copyWhole(
            from: source, to: away + "/Набор",
            shouldCancel: { calls += 1; return calls > 3 })) { error in
            let failure = error as NSError
            XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
            XCTAssertEqual(failure.code, CocoaError.userCancelled.rawValue)
        }

        XCTAssertEqual(names(in: away), [], "ни начатой папки, ни заготовки")
        XCTAssertEqual(filesBelow(source), files, "источник цел")
    }

    func test_переносЦеликомМеждуТомамиПереноситВсё() throws {
        let source = path("a", "Набор")
        let files = try makeSet(at: source)
        let size = bytesBelow(source)
        let away = try volumeFolder()

        XCTAssertFalse(try DarwinFileOperations.moveWhole(from: source, to: away + "/Набор"),
                       "между томами это копия, а не переименование")

        XCTAssertEqual(names(in: away), ["Набор"], "заготовка получила своё имя")
        XCTAssertEqual(filesBelow(away + "/Набор"), files)
        XCTAssertEqual(bytesBelow(away + "/Набор"), size)
        XCTAssertFalse(exists(source), "источник убран")
    }

    // MARK: - Подсобное

    private func path(_ parts: String...) -> String {
        parts.reduce(tmp) { ($0 as NSString).appendingPathComponent($1) }
    }

    private func write(_ relative: String..., text: String = "содержимое") throws -> String {
        let p = relative.reduce(tmp!) { ($0 as NSString).appendingPathComponent($1) }
        try text.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    private func read(_ p: String) -> String? {
        try? String(contentsOfFile: p, encoding: .utf8)
    }

    private func exists(_ p: String) -> Bool { existsOnDisk(p) }

    /// Всё, что лежит в папке, скрытое тоже.
    private func names(in folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }

    /// Папка с несколькими файлами и вложенной папкой — то, что копируется не одним махом.
    /// - Returns: её файлы, как их называет `filesBelow`.
    private func makeSet(at folder: String) throws -> [String] {
        try FileManager.default.createDirectory(atPath: folder + "/вложенная",
                                                withIntermediateDirectories: true)
        var made: [String] = []
        for index in 1...6 {
            let name = "часть-\(index).bin"
            try Data(repeating: UInt8(index), count: 48 * 1024)
                .write(to: URL(fileURLWithPath: folder + "/" + name))
            made.append(name)
        }
        for index in 1...2 {
            let name = "вложенная/глубже-\(index).bin"
            try Data(repeating: UInt8(0x40 + index), count: 24 * 1024)
                .write(to: URL(fileURLWithPath: folder + "/" + name))
            made.append(name)
        }
        return made.sorted()
    }

    /// Своя папка на томе теста; убирается после теста.
    private func volumeFolder() throws -> String {
        guard let image = UndoVolume.image else { throw XCTSkip("образ диска не подключился") }
        let folder = image.mountPoint + "/t-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        volumeFolders.append(folder)
        return folder
    }

    private func undoLast(_ stop: (@Sendable () -> Bool)? = nil) async throws {
        try await UndoJournal.shared.undo { try await self.ops.performUndo(of: $0, shouldCancel: stop) }
    }

    private func redoLast(_ stop: (@Sendable () -> Bool)? = nil) async throws {
        var replacement: UndoJournal.Record?
        try await UndoJournal.shared.redo {
            replacement = try await self.ops.performRedo(of: $0, shouldCancel: stop)
        }
        if let replacement { UndoJournal.shared.replaceNewestUndo(with: replacement) }
    }

    private func assertStopped(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        let failure = error as NSError
        XCTAssertEqual(failure.domain, NSCocoaErrorDomain, file: file, line: line)
        XCTAssertEqual(failure.code, CocoaError.userCancelled.rawValue, file: file, line: line)
    }

    private static func progressWindowIsUp(_ title: String) -> Bool {
        NSApplication.shared.windows.contains { $0.title == title && $0.isVisible }
    }
}
