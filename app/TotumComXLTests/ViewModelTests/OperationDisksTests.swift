import Foundation
import XCTest

@testable import TotumComXLApp

/// Очередь по дискам: на одном внешнем или сетевом диске — по одной операции, на разных —
/// вместе, на внутреннем — вместе, как раньше. Тома здесь выдуманные: настоящие диски не нужны.
@MainActor
final class OperationDisksTests: XCTestCase {
    private typealias Mount = OperationDisks.Mount
    private let mounts = [
        Mount(point: "/", device: "/dev/disk3s3s1"),
        Mount(point: "/System/Volumes/Data", device: "/dev/disk3s1"),
        Mount(point: "/Volumes/USB", device: "/dev/disk9s1"),
        Mount(point: "/Volumes/USB 2", device: "/dev/disk10s2"),
        Mount(point: "/Volumes/Share", device: "//guest@nas/share"),
    ]

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.set(4, forKey: "fcxl.maxConcurrentTransfers")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "fcxl.maxConcurrentTransfers")
        try await super.tearDown()
    }

    private func item(_ path: String) -> FileItem {
        FileItem(path: path, name: (path as NSString).lastPathComponent, fileExtension: "", size: 0,
                 isDirectory: false, isHidden: false, isSymlink: false,
                 permissions: "rw-r--r--", dateModified: Date(timeIntervalSince1970: 0))
    }

    private func packParams(_ archive: String) -> ArchiveOperationParams {
        var params = ArchiveOperationParams()
        params.archivePath = archive
        return params
    }

    func test_разделыОдногоДиска_одинДиск() {
        XCTAssertEqual(OperationDisks.wholeDisk("/dev/disk3s1s1"), "disk3")
        XCTAssertEqual(OperationDisks.wholeDisk("/dev/disk32s2"), "disk32")
        XCTAssertEqual(OperationDisks.wholeDisk("//guest@nas/share"), "//guest@nas/share")
    }

    func test_дискПути_толькоВнешнийИСетевой() {
        XCTAssertNil(OperationDisks.exclusiveDisk(for: "/Users/dimas/a.txt", mounts: mounts))
        XCTAssertEqual(OperationDisks.exclusiveDisk(for: "/Volumes/USB/Дима/x.zip", mounts: mounts), "disk9")
        XCTAssertEqual(OperationDisks.exclusiveDisk(for: "/Volumes/USB", mounts: mounts), "disk9")
        XCTAssertEqual(OperationDisks.exclusiveDisk(for: "/Volumes/USB 2/x", mounts: mounts), "disk10",
                       "похожее имя тома — другой диск")
        XCTAssertEqual(OperationDisks.exclusiveDisk(for: "/Volumes/Share/f", mounts: mounts), "//guest@nas/share")
        XCTAssertNil(OperationDisks.exclusiveDisk(for: "папка/внутри/архива", mounts: mounts))
    }

    func test_дискиОперации_иИсточникИНазначение() {
        let toShare = QueuedOperation(id: UUID(), kind: .copy, items: [item("/Volumes/USB/a"), item("/Users/x/b")],
                                      destinationPath: "/Volumes/Share/dir", createdAt: Date())
        XCTAssertEqual(OperationDisks.exclusiveDisks(of: toShare, mounts: mounts), ["disk9", "//guest@nas/share"])
        let toInternal = QueuedOperation(id: UUID(), kind: .copy, items: [item("/Volumes/USB/a")],
                                         destinationPath: "/Users/x/dir", createdAt: Date())
        XCTAssertEqual(OperationDisks.exclusiveDisks(of: toInternal, mounts: mounts), ["disk9"])

        var pack = QueuedOperation(id: UUID(), kind: .pack, items: [item("/Users/x/src")],
                                   destinationPath: nil, createdAt: Date())
        pack.archiveParams = packParams("/Volumes/USB 2/src.zip")
        XCTAssertEqual(OperationDisks.exclusiveDisks(of: pack, mounts: mounts), ["disk10"])
    }

    func test_наОдномВнешнемПоОдной_наРазныхВместе_внутреннийНеЖдёт() {
        let queue = OperationQueueService(fileOps: FileOperationsService(bridgeService: CoreBridgeService()))
        queue.mountTable = { [mounts] in mounts }
        func status(_ id: UUID) -> OperationStatus? { queue.operations.first { $0.id == id }?.status }

        // Долгая упаковка на USB, отданная в очередь посреди работы.
        let running = queue.adoptRunningOperation(
            kind: .pack, items: [item("/Users/x/src")], destination: "/Volumes/USB",
            archiveParams: packParams("/Volumes/USB/big.zip"), currentProgress: 0.1, currentFile: "",
            bytesDone: 0, bytesTotal: 0, filesDone: 0, filesTotal: 1).0

        // Источники несуществующие: начавшаяся операция сразу кончится ошибкой, ничего не записав.
        let sameDisk = queue.enqueueArchive(kind: .pack, items: [item("/нет/такого/a")], destination: "/Volumes/USB",
                                            archiveParams: packParams("/Volumes/USB/a.zip"))
        let otherDisk = queue.enqueueArchive(kind: .pack, items: [item("/нет/такого/b")], destination: "/Volumes/USB 2",
                                             archiveParams: packParams("/Volumes/USB 2/b.zip"))
        let onInternal = queue.enqueueArchive(kind: .pack, items: [item("/нет/такого/c")], destination: NSTemporaryDirectory(),
                                            archiveParams: packParams(NSTemporaryDirectory() + "нет-такого-c.zip"))

        XCTAssertEqual(status(sameDisk), .queued, "на том же внешнем диске — ждёт")
        XCTAssertNotEqual(status(otherDisk), .queued, "на другом диске — сразу")
        XCTAssertNotEqual(status(onInternal), .queued, "на внутреннем — не ждёт")

        queue.markOperationCompleted(running)
        XCTAssertNotEqual(status(sameDisk), .queued, "диск освободился — пошла")
    }
}
