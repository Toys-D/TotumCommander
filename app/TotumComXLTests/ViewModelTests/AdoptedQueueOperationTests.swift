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
}
