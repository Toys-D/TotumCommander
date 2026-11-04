import XCTest
@testable import TotumComXLApp

/// Preview + classification behavior of MultiRenameViewModel against real files in a temp dir.
@MainActor
final class MultiRenameViewModelTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mrt-vm-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeFile(_ name: String) -> FileItem {
        let path = dir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        return FileItem(path: path, name: name, fileExtension: (name as NSString).pathExtension,
                        size: 1, isDirectory: false, isHidden: false, isSymlink: false,
                        permissions: "rw-r--r--", dateModified: Date())
    }

    private func makeVM(_ items: [FileItem]) -> MultiRenameViewModel {
        let queue = OperationQueueService(fileOps: FileOperationsService(bridgeService: CoreBridgeService()))
        return MultiRenameViewModel(items: items, rootPath: dir.path, session: nil, queue: queue)
    }

    func testLivePreview() {
        let vm = makeVM([makeFile("a.txt"), makeFile("b.txt")])
        vm.rule.nameMask = "x[N]"
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.map { $0.newName }, ["xa.txt", "xb.txt"])
        XCTAssertTrue(vm.canExecute)
    }

    func testManualOverride() {
        let a = makeFile("a.txt")
        let vm = makeVM([a, makeFile("b.txt")])
        vm.setManualName("custom.txt", for: a.path)
        XCTAssertEqual(vm.plans.first { $0.sourcePath == a.path }?.newName, "custom.txt")
    }

    func testOnDiskCollision() {
        let a = makeFile("a.txt")
        _ = makeFile("c.txt")   // exists on disk, not part of the batch
        let vm = makeVM([a])
        vm.rule.nameMask = "c"; vm.rule.extMask = "txt"
        vm.recomputeNow()
        XCTAssertEqual(vm.plans.first?.status, .collidesOnDisk)
        XCTAssertFalse(vm.canExecute)
    }

    func testDuplicateBlocks() {
        let vm = makeVM([makeFile("a.txt"), makeFile("b.txt")])
        vm.rule.nameMask = "same"; vm.rule.extMask = "txt"
        vm.recomputeNow()
        XCTAssertTrue(vm.hasBlockingIssues)
        XCTAssertFalse(vm.canExecute)
    }
}
