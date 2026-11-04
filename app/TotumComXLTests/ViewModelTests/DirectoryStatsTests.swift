import XCTest
@testable import TotumComXLApp

/// The folder walk behind the properties window. It was rewritten for speed, so the thing worth
/// pinning down is that it still counts the same things — and that it stops when asked.
final class DirectoryStatsTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dirstats-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @discardableResult
    private func write(_ relativePath: String, bytes: Int) -> URL {
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: bytes))
        return url
    }

    func test_sumsEveryFileAtEveryDepth() {
        write("a.bin", bytes: 100)
        write("sub/b.bin", bytes: 250)
        write("sub/deeper/c.bin", bytes: 1000)

        let stats = FileOperationsService.directoryStats(path: root.path)
        XCTAssertEqual(stats.totalBytes, 1350)
        XCTAssertEqual(stats.filesCount, 3)
        XCTAssertEqual(stats.directoriesCount, 2, "sub and sub/deeper — the root itself is not inside itself")
    }

    func test_emptyFolderIsZeroNotAnError() {
        let stats = FileOperationsService.directoryStats(path: root.path)
        XCTAssertEqual(stats.totalBytes, 0)
        XCTAssertEqual(stats.filesCount, 0)
        XCTAssertEqual(stats.directoriesCount, 0)
    }

    /// A link is not the thing it points at. Following one would count the target twice — and a
    /// link that points at its own ancestor would never finish at all.
    func test_symlinksAreNeitherFollowedNorCounted() {
        write("real/big.bin", bytes: 500)
        try? FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                                                    withDestinationURL: root.appendingPathComponent("real"))
        // A loop back to the root: fatal for a walk that follows links.
        try? FileManager.default.createSymbolicLink(at: root.appendingPathComponent("real/loop"),
                                                    withDestinationURL: root)

        let stats = FileOperationsService.directoryStats(path: root.path)
        XCTAssertEqual(stats.totalBytes, 500, "the linked folder was counted a second time")
        XCTAssertEqual(stats.filesCount, 1)
        XCTAssertEqual(stats.directoriesCount, 1, "only the real folder counts")
    }

    /// Closing the window must stop the syscalls, not just discard the answer.
    func test_cancellationStopsTheWalkEarly() {
        for i in 0..<4000 { write("bulk/f\(i).bin", bytes: 1) }

        let full = FileOperationsService.directoryStats(path: root.path)
        XCTAssertEqual(full.filesCount, 4000)

        var seen = 0
        let stopped = FileOperationsService.directoryStats(
            path: root.path,
            isCancelled: { seen > 0 },
            progress: { _ in seen += 1 })
        XCTAssertLessThan(stopped.filesCount, full.filesCount,
                          "the walk ran to completion after it had been cancelled")
    }

    /// The running totals are what make the window count up instead of sitting blank.
    func test_progressReportsGrowingTotals() {
        for i in 0..<3000 { write("bulk/f\(i).bin", bytes: 10) }

        var reports: [Int] = []
        let final = FileOperationsService.directoryStats(path: root.path,
                                                         progress: { reports.append($0.filesCount) })
        XCTAssertFalse(reports.isEmpty, "the walk never reported anything while it worked")
        XCTAssertEqual(reports, reports.sorted(), "running totals went backwards")
        XCTAssertLessThanOrEqual(reports.last ?? 0, final.filesCount)
        XCTAssertEqual(final.filesCount, 3000)
    }

    /// The count is of real files, so an empty file counts and its zero bytes add nothing.
    func test_zeroLengthFilesCountAsFiles() {
        write("empty.bin", bytes: 0)
        let stats = FileOperationsService.directoryStats(path: root.path)
        XCTAssertEqual(stats.filesCount, 1)
        XCTAssertEqual(stats.totalBytes, 0)
    }
}
