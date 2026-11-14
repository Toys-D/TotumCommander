import Foundation
import XCTest

@testable import TotumComXLApp

/// Окно хода отдало операцию в очередь кнопкой «В очередь»: работа идёт дальше там же, где шла,
/// а кончившись, должна закрыть СВОЮ строку очереди. Раньше закрывалась «первая идущая того же
/// вида» — и если рядом шла чужая такая же, завершённой отмечали её: её обратный вызов
/// срабатывал раньше времени, ошибка приписывалась ей, а своя строка так и висела «идёт».
///
/// Каждый тест сначала ставит в очередь чужую идущую операцию того же вида — она в списке
/// первая, — а затем ведёт настоящую операцию через окно хода и кнопку.
@MainActor
final class SentToQueueCompletionTests: XCTestCase {

    private static let slotsKey = "fcxl.maxConcurrentTransfers"

    private var ops: FileOperationsService!
    private var queue: OperationQueueService!
    private var tmp: String!
    /// Сколько раз очередь сообщила о конце чужой операции и своей.
    private var foreignCompletions = 0
    private var ownCompletions = 0
    private var skipDeleteBefore: Any?

    override func setUpWithError() throws {
        UndoJournal.shared.reset()
        ops = FileOperationsService(bridgeService: CoreBridgeService())
        queue = OperationQueueService(fileOps: ops)
        tmp = (FileManager.default.temporaryDirectory.path as NSString)
            .appendingPathComponent("fcxl-queue-test-\(UUID().uuidString)")
        try makeFolder("a")
        try makeFolder("b")
        foreignCompletions = 0
        ownCompletions = 0
        skipDeleteBefore = UserDefaults.standard.object(forKey: DialogService.skipDeleteDialogKey)
        XCTAssertFalse(ProgressController.canSendToQueue,
                       "от прежних тестов осталось окно хода с кнопкой «В очередь»")
    }

    override func tearDownWithError() throws {
        UndoJournal.shared.reset()
        if let skipDeleteBefore {
            UserDefaults.standard.set(skipDeleteBefore, forKey: DialogService.skipDeleteDialogKey)
        } else {
            UserDefaults.standard.removeObject(forKey: DialogService.skipDeleteDialogKey)
        }
        UserDefaults.standard.removeObject(forKey: Self.slotsKey)
        try? FileManager.default.removeItem(atPath: tmp)
        ops = nil
        queue = nil
        tmp = nil
    }

    // MARK: - Файлы и архивы

    private func path(_ parts: String...) -> String {
        parts.reduce(tmp) { ($0 as NSString).appendingPathComponent($1) }
    }

    @discardableResult
    private func write(_ relative: String..., text: String = "содержимое") throws -> String {
        let p = relative.reduce(tmp!) { ($0 as NSString).appendingPathComponent($1) }
        try text.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    /// Файл, который есть, но читать его нельзя: операция дойдёт до него и на нём встанет.
    private func writeUnreadable(_ relative: String...) throws -> String {
        let p = relative.reduce(tmp!) { ($0 as NSString).appendingPathComponent($1) }
        try "тайна".write(toFile: p, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: p)
        return p
    }

    @discardableResult
    private func makeFolder(_ relative: String...) throws -> String {
        let p = relative.reduce(tmp!) { ($0 as NSString).appendingPathComponent($1) }
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    private func read(_ p: String) -> String? { try? String(contentsOfFile: p, encoding: .utf8) }

    private func item(at p: String) -> FileItem {
        let attrs = try? FileManager.default.attributesOfItem(atPath: p)
        let isDir = (attrs?[.type] as? FileAttributeType) == .typeDirectory
        let name = (p as NSString).lastPathComponent
        return FileItem(path: p, name: name, fileExtension: (name as NSString).pathExtension,
                        size: (attrs?[.size] as? UInt64) ?? 0, isDirectory: isDir,
                        isHidden: false, isSymlink: false, permissions: "-rw-r--r--",
                        dateModified: Date())
    }

    /// Объект по пути, которого может и не быть на диске: запись архива (путь внутри архива)
    /// либо пропавший источник.
    private func entry(_ path: String) -> FileItem {
        let name = (path as NSString).lastPathComponent
        return FileItem(path: path, name: name, fileExtension: (name as NSString).pathExtension,
                        size: 0, isDirectory: false, isHidden: false, isSymlink: false,
                        permissions: "-rw-r--r--", dateModified: Date())
    }

    /// Архив zip с названными файлами внутри; в каждом — его имя.
    private func makeZip(_ archive: String, containing names: [String]) throws {
        let folder = try makeFolder("zip-\(UUID().uuidString.prefix(6))")
        let files = try names.map { name -> String in
            let file = (folder as NSString).appendingPathComponent(name)
            try name.write(toFile: file, atomically: true, encoding: .utf8)
            return file
        }
        let made = TestDiskImage.run("/usr/bin/zip", ["-q", "-j", archive] + files)
        XCTAssertEqual(made.status, 0, made.output)
    }

    /// Файл с именем архива, но архивом не являющийся: работа над ним кончается ошибкой.
    private func makeBrokenZip(_ archive: String) throws {
        try Data(repeating: 0x5A, count: 4096).write(to: URL(fileURLWithPath: archive))
    }

    private func entryNames(of archive: String) -> [String] {
        ((try? CoreBridgeService().listArchiveEntries(archivePath: archive)) ?? [])
            .map(\.path).sorted()
    }

    // MARK: - Очередь и кнопка «В очередь»

    /// Чужая операция того же вида: уже идёт в очереди и кончаться не собирается.
    private func foreignRunning(_ kind: OperationKind, items: [FileItem] = [],
                                archive: String? = nil) -> UUID {
        queue.adoptRunningOperation(
            kind: kind, items: items, destination: path("чужое"),
            archiveParams: archive.map { ArchiveOperationParams(archivePath: $0) },
            currentProgress: 0.1, currentFile: "", bytesDone: 0, bytesTotal: 0,
            filesDone: 0, filesTotal: 1,
            onCompletion: { self.foreignCompletions += 1 }).0
    }

    private func status(_ id: UUID) -> OperationStatus? {
        queue.operations.first { $0.id == id }?.status
    }

    /// Строки очереди словами — в сообщения проверок: по ним видно, какая закрылась и чем.
    private var rows: String {
        queue.operations
            .map { "\($0.kind.rawValue)=\($0.status.rawValue)" + ($0.error.map { " «\($0)»" } ?? "") }
            .joined(separator: ", ")
    }

    /// Нажать «В очередь», как только окно хода показало кнопку.
    ///
    /// Продолжение теста всё время стоит в главной очереди, а блок, которым работа сообщает о
    /// своём конце, попадает туда позже — поэтому нажатие приходит раньше него, даже если сама
    /// работа уже кончилась. Не успеть нельзя; опоздай тест — кнопки бы уже не было и проверка
    /// ниже упала бы.
    private func pressSendToQueue(file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !ProgressController.canSendToQueue, Date() < deadline { await Task.yield() }
        guard ProgressController.canSendToQueue else {
            XCTFail("окно хода с кнопкой «В очередь» не появилось [\(rows)]", file: file, line: line)
            return false
        }
        ProgressController.sendFirstToQueue()
        return true
    }

    /// Строка, которую завела кнопка: вторая после чужой.
    private func ownRow(besides foreign: UUID,
                        file: StaticString = #filePath, line: UInt = #line) throws -> UUID {
        XCTAssertEqual(queue.operations.count, 2, "кнопка заводит одну строку [\(rows)]",
                       file: file, line: line)
        return try XCTUnwrap(queue.operations.first { $0.id != foreign }?.id, file: file, line: line)
    }

    private func waitUntil(_ timeout: TimeInterval = 20, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Работа кончилась и сказала об этом очереди: какая-то из двух строк закрылась.
    private func waitForVerdict() async {
        await waitUntil { !self.queue.operations.allSatisfy(\.isActive) }
    }

    /// Итог — в своей строке, и о нём сообщили один раз; чужая идёт, как шла.
    private func expectOwnClosed(_ expected: OperationStatus, own: UUID, foreign: UUID,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(status(foreign), .running,
                       "чужая операция ещё идёт — её строку трогать нельзя [\(rows)]",
                       file: file, line: line)
        XCTAssertEqual(foreignCompletions, 0, "о конце чужой операции сообщили раньше времени",
                       file: file, line: line)
        XCTAssertEqual(status(own), expected, "итог операции — в её строке [\(rows)]",
                       file: file, line: line)
        XCTAssertEqual(ownCompletions, 1, "о конце своей операции сообщают один раз",
                       file: file, line: line)
        if expected == .failed {
            let text = queue.operations.first { $0.id == own }?.error ?? ""
            XCTAssertFalse(text.isEmpty, "у сбоя есть слова — в своей строке [\(rows)]",
                           file: file, line: line)
        }
    }

    /// Провести операцию через окно хода и кнопку «В очередь» рядом с чужой идущей.
    private func runThroughQueueButton(foreign: UUID, expecting expected: OperationStatus,
                                       file: StaticString = #filePath, line: UInt = #line,
                                       _ start: @escaping @MainActor () async throws -> Void) async throws {
        let work = Task { @MainActor in try await start() }
        guard await pressSendToQueue(file: file, line: line) else { return }
        let own = try ownRow(besides: foreign, file: file, line: line)
        await waitForVerdict()
        expectOwnClosed(expected, own: own, foreign: foreign, file: file, line: line)
        // Вызвавшему отданная операция ничего не бросает: её итог теперь в строке очереди.
        _ = await work.result
        queue.cancel(foreign)
    }

    // MARK: - Копирование

    func test_копирование_завершаетСвоюСтроку() async throws {
        let foreign = foreignRunning(.copy)
        let source = try write("a", "файл.txt")

        try await runThroughQueueButton(foreign: foreign, expecting: .completed) {
            try await self.ops.copyItems([self.item(at: source)], to: self.path("b"),
                                         queueService: self.queue,
                                         onCompletion: { self.ownCompletions += 1 })
        }

        XCTAssertEqual(read(path("b", "файл.txt")), "содержимое")
    }

    /// Сбой должен случиться в самой передаче, а не до неё: предварительная проверка смотрит
    /// только на сами выбранные объекты, и закрытый файл среди них остановил бы операцию
    /// сообщением ещё до окна хода. Поэтому закрытый файл лежит внутри копируемой папки.
    func test_копирование_сбойПоказываетСвояСтрока() async throws {
        let foreign = foreignRunning(.copy)
        let source = try makeFolder("a", "папка")
        try write("a", "папка", "открыт.txt")
        _ = try writeUnreadable("a", "папка", "закрыт.txt")

        try await runThroughQueueButton(foreign: foreign, expecting: .failed) {
            try await self.ops.copyItems([self.item(at: source)], to: self.path("b"),
                                         queueService: self.queue,
                                         onCompletion: { self.ownCompletions += 1 })
        }
    }

    /// Отданное копирование отменили в очереди. Работа сворачивается и сообщает о конце — и это
    /// сообщение не должно закрыть чужое копирование вместо своего, уже закрытого.
    func test_копирование_отменённоеВОчередиНеЗакрываетЧужое() async throws {
        UserDefaults.standard.set(2, forKey: Self.slotsKey)
        let foreign = foreignRunning(.copy)
        let source = try write("a", "файл.txt")

        let work = Task { @MainActor in
            try await self.ops.copyItems([self.item(at: source)], to: self.path("b"),
                                         queueService: self.queue,
                                         onCompletion: { self.ownCompletions += 1 })
        }
        guard await pressSendToQueue() else { return }
        let own = try ownRow(besides: foreign)
        queue.cancel(own)

        // Мест два, и оба заняты: чужая идёт, своя сворачивается. Третья ждёт, пока своя не
        // остановится, — по ней и видно, что работа сообщила о конце. Источника у третьей нет:
        // начавшись, она сразу кончится ошибкой, ничего не записав.
        let third = queue.enqueueArchive(kind: .pack, items: [entry(path("нет", "такого"))],
                                         destination: path("b"),
                                         archiveParams: ArchiveOperationParams(archivePath: path("b", "третья.zip")))
        XCTAssertEqual(status(third), .queued, "оба места заняты [\(rows)]")
        await waitUntil { self.status(third) != .queued }
        XCTAssertNotEqual(status(third), .queued, "своя остановилась — место освободилось [\(rows)]")

        XCTAssertEqual(status(foreign), .running, "чужое копирование идёт, как шло [\(rows)]")
        XCTAssertEqual(foreignCompletions, 0, "о конце чужой операции сообщили раньше времени")
        XCTAssertEqual(status(own), .cancelled, "отменённая так и остаётся отменённой [\(rows)]")
        XCTAssertEqual(ownCompletions, 1, "об отмене сообщили один раз — при самой отмене")

        _ = await work.result
        await waitUntil { self.queue.operations.first { $0.id == third }?.isFinished == true }
        queue.cancel(foreign)
    }

    // MARK: - Внутри архива: добавить, удалить, переименовать

    func test_добавлениеВАрхив_завершаетСвоюСтроку() async throws {
        let foreign = foreignRunning(.pack)
        let archive = path("a", "архив.zip")
        try makeZip(archive, containing: ["было.txt"])
        let source = try write("a", "новый.txt")

        try await runThroughQueueButton(foreign: foreign, expecting: .completed) {
            try await self.ops.addItemsToArchive([self.item(at: source)], archivePath: archive,
                                                 destinationRelativePath: "",
                                                 queueService: self.queue,
                                                 onCompletion: { self.ownCompletions += 1 })
        }

        XCTAssertEqual(entryNames(of: archive), ["было.txt", "новый.txt"])
    }

    func test_добавлениеВАрхив_сбойПоказываетСвояСтрока() async throws {
        let foreign = foreignRunning(.pack)
        let archive = path("a", "архив.zip")
        try makeZip(archive, containing: ["было.txt"])
        let missing = entry(path("a", "пропал.txt"))

        try await runThroughQueueButton(foreign: foreign, expecting: .failed) {
            try await self.ops.addItemsToArchive([missing], archivePath: archive,
                                                 destinationRelativePath: "",
                                                 queueService: self.queue,
                                                 onCompletion: { self.ownCompletions += 1 })
        }
    }

    func test_удалениеИзАрхива_завершаетСвоюСтроку() async throws {
        UserDefaults.standard.set(true, forKey: DialogService.skipDeleteDialogKey)
        let foreign = foreignRunning(.archiveDelete)
        let archive = path("a", "архив.zip")
        try makeZip(archive, containing: ["лишнее.txt", "нужное.txt"])

        try await runThroughQueueButton(foreign: foreign, expecting: .completed) {
            try await self.ops.deleteEntriesFromArchive([self.entry("лишнее.txt")], archivePath: archive,
                                                        queueService: self.queue,
                                                        onCompletion: { self.ownCompletions += 1 })
        }

        XCTAssertEqual(entryNames(of: archive), ["нужное.txt"])
    }

    func test_удалениеИзАрхива_сбойПоказываетСвояСтрока() async throws {
        UserDefaults.standard.set(true, forKey: DialogService.skipDeleteDialogKey)
        let foreign = foreignRunning(.archiveDelete)
        let archive = path("a", "битый.zip")
        try makeBrokenZip(archive)

        try await runThroughQueueButton(foreign: foreign, expecting: .failed) {
            try await self.ops.deleteEntriesFromArchive([self.entry("лишнее.txt")], archivePath: archive,
                                                        queueService: self.queue,
                                                        onCompletion: { self.ownCompletions += 1 })
        }
    }

    func test_переименованиеВАрхиве_завершаетСвоюСтроку() async throws {
        let foreign = foreignRunning(.archiveRename)
        let archive = path("a", "архив.zip")
        try makeZip(archive, containing: ["старое.txt"])

        try await runThroughQueueButton(foreign: foreign, expecting: .completed) {
            try await self.ops.renameEntryInArchive(self.entry("старое.txt"), archivePath: archive,
                                                    to: "новое.txt", queueService: self.queue,
                                                    onCompletion: { self.ownCompletions += 1 })
        }

        XCTAssertEqual(entryNames(of: archive), ["новое.txt"])
    }

    func test_переименованиеВАрхиве_сбойПоказываетСвояСтрока() async throws {
        let foreign = foreignRunning(.archiveRename)
        let archive = path("a", "архив.zip")
        try makeZip(archive, containing: ["есть.txt"])

        // Записи с таким именем в архиве нет: переименовывать нечего.
        try await runThroughQueueButton(foreign: foreign, expecting: .failed) {
            try await self.ops.renameEntryInArchive(self.entry("нет.txt"), archivePath: archive,
                                                    to: "новое.txt", queueService: self.queue,
                                                    onCompletion: { self.ownCompletions += 1 })
        }
    }

    // MARK: - Упаковка и распаковка: тот же архив в двух строках

    func test_упаковка_завершаетСвоюСтроку() async throws {
        let archive = path("b", "архив.zip")
        // В очереди уже есть операция над архивом с тем же именем.
        let foreign = foreignRunning(.pack, archive: archive)
        let source = try write("a", "файл.txt")

        try await runThroughQueueButton(foreign: foreign, expecting: .completed) {
            try await self.ops.packItems([self.item(at: source)], to: archive, format: .zip,
                                         queueService: self.queue,
                                         onCompletion: { self.ownCompletions += 1 })
        }

        XCTAssertEqual(entryNames(of: archive), ["файл.txt"])
    }

    func test_упаковка_сбойПоказываетСвояСтрока() async throws {
        let archive = path("b", "архив.zip")
        let foreign = foreignRunning(.pack, archive: archive)
        let source = try writeUnreadable("a", "закрыт.txt")

        try await runThroughQueueButton(foreign: foreign, expecting: .failed) {
            try await self.ops.packItems([self.item(at: source)], to: archive, format: .zip,
                                         queueService: self.queue,
                                         onCompletion: { self.ownCompletions += 1 })
        }
    }

    /// Отданную упаковку отменили в очереди. Строка её закрыта сразу, а место она держит, пока
    /// работа сворачивается, — и, свернувшись, обязана его освободить: иначе ждущие операции
    /// не начнутся до перезапуска программы.
    func test_упаковка_отменённаяВОчередиОсвобождаетМесто() async throws {
        UserDefaults.standard.set(1, forKey: Self.slotsKey)
        let source = try write("a", "файл.txt")
        let archive = path("b", "архив.zip")

        let work = Task { @MainActor in
            try await self.ops.packItems([self.item(at: source)], to: archive, format: .zip,
                                         queueService: self.queue,
                                         onCompletion: { self.ownCompletions += 1 })
        }
        guard await pressSendToQueue() else { return }
        let own = try XCTUnwrap(queue.operations.first?.id)
        queue.cancel(own)

        // Место одно, и его держит сворачивающаяся упаковка. Источника у ждущей нет: начавшись,
        // она сразу кончится ошибкой, ничего не записав.
        let waiting = queue.enqueueArchive(kind: .pack, items: [entry(path("нет", "такого"))],
                                           destination: path("b"),
                                           archiveParams: ArchiveOperationParams(archivePath: path("b", "ждущая.zip")))
        XCTAssertEqual(status(waiting), .queued, "место занято [\(rows)]")
        await waitUntil(5) { self.status(waiting) != .queued }
        XCTAssertNotEqual(status(waiting), .queued,
                          "упаковка остановилась — место освободилось [\(rows)]")
        XCTAssertEqual(status(own), .cancelled, "отменённая так и остаётся отменённой [\(rows)]")
        XCTAssertEqual(ownCompletions, 1, "об отмене сообщили один раз — при самой отмене")

        _ = await work.result
        await waitUntil(5) { self.queue.operations.first { $0.id == waiting }?.isFinished == true }
    }

    // MARK: - «Удалить после упаковки» у отданной в очередь упаковки

    /// Что убрала подставная Корзина и что она при этом видела. Настоящей Корзины тесты не
    /// касаются: уборку источников упаковки сервис ведёт через подменяемую функцию.
    private final class SourceRemovals {
        var paths: [[String]] = []
        var completionsSeen: [Int] = []
    }

    /// «Удалить после упаковки» при кнопке «В очередь»: обещанное галочкой делает очередь —
    /// после удачной упаковки и до того, как панели узнают о конце работы.
    func test_упаковка_отданнаяВОчередьУбираетИсточники() async throws {
        let archive = path("b", "архив.zip")
        let foreign = foreignRunning(.pack, archive: archive)
        let source = try write("a", "файл.txt")
        let removals = SourceRemovals()
        ops.trashPackedSources = { items in
            removals.paths.append(items.map(\.path))
            removals.completionsSeen.append(self.ownCompletions)
        }

        try await runThroughQueueButton(foreign: foreign, expecting: .completed) {
            try await self.ops.packItems([self.item(at: source)], to: archive, format: .zip,
                                         deleteAfterPack: true, queueService: self.queue,
                                         onCompletion: { self.ownCompletions += 1 })
        }

        XCTAssertEqual(removals.paths, [[source]], "источники не убраны — галочка осталась обещанием")
        XCTAssertEqual(removals.completionsSeen, [0], "панели обновляются после уборки, а не до неё")
        XCTAssertEqual(entryNames(of: archive), ["файл.txt"])
    }

    /// Архив создан, а убрать источники не вышло: строка говорит об этом сама — молчаливого
    /// «готово» при оставшихся на месте файлах быть не должно.
    func test_упаковка_отданнаяВОчередь_сбойУборкиВиденВСтроке() async throws {
        let archive = path("b", "архив.zip")
        let foreign = foreignRunning(.pack, archive: archive)
        let source = try write("a", "файл.txt")
        ops.trashPackedSources = { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                          userInfo: [NSLocalizedDescriptionKey: "нет доступа к папке"])
        }

        try await runThroughQueueButton(foreign: foreign, expecting: .failed) {
            try await self.ops.packItems([self.item(at: source)], to: archive, format: .zip,
                                         deleteAfterPack: true, queueService: self.queue,
                                         onCompletion: { self.ownCompletions += 1 })
        }

        let own = queue.operations.first { $0.id != foreign }
        XCTAssertTrue(own?.error?.contains("нет доступа к папке") == true,
                      "строка не говорит, почему источники остались: \(own?.error ?? "слов нет")")
        XCTAssertEqual(entryNames(of: archive), ["файл.txt"], "архив создан")
        XCTAssertEqual(read(source), "содержимое", "источник на месте")
    }

    /// Отданную упаковку с галочкой отменили в очереди: работа свёрнута — источники остаются.
    func test_упаковка_отменённаяВОчередиИсточникиНеТрогает() async throws {
        let source = try write("a", "файл.txt")
        let archive = path("b", "архив.zip")
        let removals = SourceRemovals()
        ops.trashPackedSources = { items in removals.paths.append(items.map(\.path)) }

        let work = Task { @MainActor in
            try await self.ops.packItems([self.item(at: source)], to: archive, format: .zip,
                                         deleteAfterPack: true, queueService: self.queue,
                                         onCompletion: { self.ownCompletions += 1 })
        }
        guard await pressSendToQueue() else { return }
        let own = try XCTUnwrap(queue.operations.first?.id)
        queue.cancel(own)

        _ = await work.result
        await waitUntil(1) { !removals.paths.isEmpty }
        XCTAssertEqual(status(own), .cancelled, "отменённая так и остаётся отменённой [\(rows)]")
        XCTAssertTrue(removals.paths.isEmpty, "упаковку отменили — источники трогать нельзя")
        XCTAssertEqual(read(source), "содержимое", "источник на месте")
    }

    /// Распаковка начинается без ожиданий: окно с кнопкой есть сразу после вызова, и нажать
    /// надо тут же — раньше, чем главный поток отдаст управление блоку завершения.
    private func unpackThroughQueueButton(_ archive: String, foreign: UUID,
                                          expecting expected: OperationStatus,
                                          file: StaticString = #filePath, line: UInt = #line) async throws {
        ops.unpackArchive(at: archive, to: path("b"), createSubfolder: false, overwriteExisting: true,
                          queueService: queue) { _ in self.ownCompletions += 1 }
        guard ProgressController.canSendToQueue else {
            return XCTFail("окно хода с кнопкой «В очередь» не появилось [\(rows)]", file: file, line: line)
        }
        ProgressController.sendFirstToQueue()
        let own = try ownRow(besides: foreign, file: file, line: line)
        await waitForVerdict()
        expectOwnClosed(expected, own: own, foreign: foreign, file: file, line: line)
        queue.cancel(foreign)
    }

    func test_распаковка_завершаетСвоюСтроку() async throws {
        let archive = path("a", "архив.zip")
        try makeZip(archive, containing: ["запись.txt"])
        // Тот же архив уже распаковывают в другую папку.
        let foreign = foreignRunning(.unpack, items: [entry(archive)])

        try await unpackThroughQueueButton(archive, foreign: foreign, expecting: .completed)

        XCTAssertEqual(read(path("b", "запись.txt")), "запись.txt")
    }

    func test_распаковка_сбойПоказываетСвояСтрока() async throws {
        let archive = path("a", "битый.zip")
        try makeBrokenZip(archive)
        let foreign = foreignRunning(.unpack, items: [entry(archive)])

        try await unpackThroughQueueButton(archive, foreign: foreign, expecting: .failed)
    }
}
