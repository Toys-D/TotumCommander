import Foundation
import XCTest

@testable import TotumComXLApp

/// Операция, отданная окном хода в очередь посреди работы: извлечение из архива так и висело
/// в очереди на 100 % с идущим таймером, хотя файл давно лежал на месте, — о конце работы
/// очереди никто не говорил, а следующие операции её ждали.
@MainActor
final class AdoptedQueueOperationTests: XCTestCase {

    private func adoptExtract(_ queue: OperationQueueService,
                              onCompletion: (() -> Void)? = nil) -> UUID {
        queue.adoptRunningOperation(kind: .archiveExtract, items: [], destination: NSTemporaryDirectory(),
                                    archiveParams: ArchiveOperationParams(), currentProgress: 0.5,
                                    currentFile: "", bytesDone: 0, bytesTotal: 0,
                                    filesDone: 0, filesTotal: 1, onCompletion: onCompletion).0
    }

    private func makeQueue() -> OperationQueueService {
        OperationQueueService(fileOps: FileOperationsService(bridgeService: CoreBridgeService()))
    }

    func test_отданнаяВОчередьЗакрываетсяТамЖе() {
        let queue = makeQueue()
        var refreshed = false
        let adopted = AdoptedQueueOperation()
        adopted.id = adoptExtract(queue) { refreshed = true }

        XCTAssertTrue(adopted.finish(in: queue))
        let op = queue.operations.first { $0.id == adopted.id }
        XCTAssertEqual(op?.status, .completed)
        XCTAssertEqual(op?.progress, 1.0)
        XCTAssertTrue(refreshed, "панели обновляет завершение очереди")
    }

    func test_сбойПоказываетСтрокаОчереди() {
        let queue = makeQueue()
        let adopted = AdoptedQueueOperation()
        adopted.id = adoptExtract(queue)
        let failure = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "сломалось"])

        XCTAssertTrue(adopted.finish(in: queue, error: failure))
        let op = queue.operations.first { $0.id == adopted.id }
        XCTAssertEqual(op?.status, .failed)
        XCTAssertEqual(op?.error, "сломалось")
    }

    func test_неОтданнаяОчередьНеТрогает() {
        let queue = makeQueue()
        XCTAssertFalse(AdoptedQueueOperation().finish(in: queue), "окно само закрывается и само сообщает")
        XCTAssertTrue(queue.operations.isEmpty)
    }

    func test_отменённуюВОчередиНеПереписывает() {
        let queue = makeQueue()
        let adopted = AdoptedQueueOperation()
        adopted.id = adoptExtract(queue)
        queue.cancel(adopted.id!)

        XCTAssertTrue(adopted.finish(in: queue))
        XCTAssertEqual(queue.operations.first { $0.id == adopted.id }?.status, .cancelled)
    }

    /// Отданную в очередь операцию отменили в самой очереди: строка закрыта сразу, а место и
    /// диск она держит, пока работа сворачивается. Работа остановилась — место надо отдать,
    /// иначе ждущие операции не пойдут, пока человек не очистит список.
    func test_отменённаяВОчередиОсвобождаетМесто() {
        let queue = makeQueue()
        queue.mountTable = {
            [OperationDisks.Mount(point: "/", device: "/dev/disk3s3s1"),
             OperationDisks.Mount(point: "/Volumes/USB", device: "/dev/disk9s1")]
        }
        func status(_ id: UUID) -> OperationStatus? { queue.operations.first { $0.id == id }?.status }
        func item(_ path: String) -> FileItem {
            FileItem(path: path, name: (path as NSString).lastPathComponent, fileExtension: "", size: 0,
                     isDirectory: false, isHidden: false, isSymlink: false, permissions: "rw-r--r--",
                     dateModified: Date(timeIntervalSince1970: 0))
        }

        // Долгая упаковка на USB, отданная в очередь посреди работы.
        let adopted = AdoptedQueueOperation()
        adopted.id = queue.adoptRunningOperation(
            kind: .pack, items: [item("/Users/x/src")], destination: "/Volumes/USB",
            archiveParams: ArchiveOperationParams(archivePath: "/Volumes/USB/big.zip"),
            currentProgress: 0.1, currentFile: "", bytesDone: 0, bytesTotal: 0,
            filesDone: 0, filesTotal: 1).0
        // Источник несуществующий: начавшись, операция сразу кончится ошибкой, ничего не записав.
        let waiting = queue.enqueueArchive(kind: .pack, items: [item("/нет/такого/a")],
                                           destination: "/Volumes/USB",
                                           archiveParams: ArchiveOperationParams(archivePath: "/Volumes/USB/a.zip"))
        XCTAssertEqual(status(waiting), .queued, "диск занят — ждёт")

        queue.cancel(adopted.id!)
        XCTAssertEqual(status(waiting), .queued, "отменённая ещё сворачивается и диск держит")

        XCTAssertTrue(adopted.finish(in: queue, error: CocoaError(.userCancelled)))
        XCTAssertNotEqual(status(waiting), .queued, "работа остановилась — следующая пошла")
        XCTAssertEqual(status(adopted.id!), .cancelled, "итог отменённой не переписан")
    }

    // MARK: - «Удалить после упаковки» у упаковки в очереди

    /// Подставная Корзина: что её просили убрать и что она при этом видела. Настоящей Корзины
    /// тесты не касаются — уборку источников упаковки сервис ведёт через подменяемую функцию.
    private final class SourceRemovals {
        var paths: [[String]] = []
        var archiveWasThere: [Bool] = []
        var started = false
        var release: CheckedContinuation<Void, Never>?
    }

    private func makeQueueAndOps() -> (OperationQueueService, FileOperationsService) {
        let ops = FileOperationsService(bridgeService: CoreBridgeService())
        return (OperationQueueService(fileOps: ops), ops)
    }

    private func packItem(_ path: String) -> FileItem {
        FileItem(path: path, name: (path as NSString).lastPathComponent, fileExtension: "", size: 0,
                 isDirectory: false, isHidden: false, isSymlink: false, permissions: "rw-r--r--",
                 dateModified: Date(timeIntervalSince1970: 0))
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Галочки «Удалить после упаковки» не было — отданная в очередь упаковка источники не трогает.
    func test_принятаяУпаковкаБезГалочкиИсточникиНеТрогает() async {
        let (queue, ops) = makeQueueAndOps()
        let removals = SourceRemovals()
        ops.trashPackedSources = { items in removals.paths.append(items.map(\.path)) }
        let adopted = AdoptedQueueOperation()
        adopted.id = queue.adoptRunningOperation(
            kind: .pack, items: [packItem("/Users/x/src")], destination: NSTemporaryDirectory(),
            archiveParams: ArchiveOperationParams(archivePath: NSTemporaryDirectory() + "big.zip"),
            currentProgress: 0.9, currentFile: "", bytesDone: 0, bytesTotal: 0,
            filesDone: 0, filesTotal: 1).0

        XCTAssertTrue(adopted.finish(in: queue))
        await waitUntil(0.2) { !removals.paths.isEmpty }

        XCTAssertEqual(queue.operations.first { $0.id == adopted.id }?.status, .completed)
        XCTAssertTrue(removals.paths.isEmpty, "галочки не было — источники остаются")
    }

    /// Архив записан, идёт уборка источников — и тут строку отменяют. Строка закрыта сразу, а
    /// место и диск она держит, пока уборка не кончится: Корзина ещё работает с этим диском.
    /// Панелям о конце говорят тогда же — иначе они перечитают папку раньше, чем файлы уйдут.
    func test_отменаВоВремяУборкиИсточников_местоДоКонцаУборки() async {
        let (queue, ops) = makeQueueAndOps()
        let volume = "/Volumes/FCXL-NO-SUCH-DISK"
        queue.mountTable = {
            [OperationDisks.Mount(point: "/", device: "/dev/disk3s3s1"),
             OperationDisks.Mount(point: volume, device: "/dev/disk99s1")]
        }
        func status(_ id: UUID) -> OperationStatus? { queue.operations.first { $0.id == id }?.status }
        let removals = SourceRemovals()
        ops.trashPackedSources = { _ in
            removals.started = true
            await withCheckedContinuation { removals.release = $0 }
        }
        var completions = 0

        let adopted = AdoptedQueueOperation()
        let id = queue.adoptRunningOperation(
            kind: .pack, items: [packItem("/Users/x/src")], destination: volume,
            archiveParams: ArchiveOperationParams(archivePath: volume + "/big.zip",
                                                  deleteSourcesAfterPack: true),
            currentProgress: 0.9, currentFile: "", bytesDone: 0, bytesTotal: 0,
            filesDone: 0, filesTotal: 1, onCompletion: { completions += 1 }).0
        adopted.id = id
        // Источник несуществующий: начавшись, операция сразу кончится ошибкой, ничего не записав.
        let waiting = queue.enqueueArchive(kind: .pack, items: [packItem("/нет/такого/a")],
                                           destination: volume,
                                           archiveParams: ArchiveOperationParams(archivePath: volume + "/a.zip"))
        XCTAssertEqual(status(waiting), .queued, "диск занят — ждёт")

        XCTAssertTrue(adopted.finish(in: queue))
        await waitUntil(3) { removals.started }
        guard removals.started else { return XCTFail("уборка источников не началась") }
        XCTAssertEqual(status(id), .running, "пока источники убираются, строка ещё в работе")
        XCTAssertEqual(completions, 0, "панелям о конце работы ещё не сказано")
        XCTAssertEqual(status(waiting), .queued, "диск занят уборкой — ждущая стоит")

        queue.cancel(id)
        XCTAssertEqual(status(id), .cancelled)
        XCTAssertEqual(completions, 0, "уборка ещё идёт — панелям скажут, когда она кончится")
        XCTAssertEqual(status(waiting), .queued, "уборка ещё идёт — диск занят")

        removals.release?.resume()
        await waitUntil(3) { status(waiting) != .queued }
        XCTAssertNotEqual(status(waiting), .queued, "уборка кончилась — место отдано")
        XCTAssertEqual(status(id), .cancelled, "итог отменённой не переписан")
        XCTAssertEqual(completions, 1, "о конце работы сказано один раз — после уборки")
    }

    /// Упаковку с галочкой ведёт сама очередь: источники она убирает так же — после архива.
    func test_упаковкаВОчередиУбираетИсточникиПослеАрхива() async throws {
        let (queue, ops) = makeQueueAndOps()
        let dir = NSTemporaryDirectory() + "fcxl-queue-pack-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let source = dir + "/файл.txt"
        try "содержимое".write(toFile: source, atomically: true, encoding: .utf8)
        let archive = dir + "/архив.zip"
        let removals = SourceRemovals()
        ops.trashPackedSources = { items in
            removals.paths.append(items.map(\.path))
            removals.archiveWasThere.append(FileManager.default.fileExists(atPath: archive))
        }

        let id = queue.enqueueArchive(kind: .pack, items: [packItem(source)], destination: dir,
                                      archiveParams: ArchiveOperationParams(archivePath: archive,
                                                                            deleteSourcesAfterPack: true))
        await waitUntil(20) { queue.operations.first { $0.id == id }?.isFinished == true }

        XCTAssertEqual(queue.operations.first { $0.id == id }?.status, .completed)
        XCTAssertEqual(removals.paths, [[source]], "источники не убраны")
        XCTAssertEqual(removals.archiveWasThere, [true], "сначала архив, потом уборка")
    }
}
