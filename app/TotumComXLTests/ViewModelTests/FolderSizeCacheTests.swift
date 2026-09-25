import XCTest

@testable import TotumComXLApp

/// The folder-size cache and the adaptive walker's arithmetic. The cache is trusted-then-verified
/// by design, so what these pin down is the machinery: remembering survives a relaunch, forgetting
/// takes subtrees with it, and the slider maths never produces zero workers or a wrong order.
final class FolderSizeCacheTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcxl-sizecache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        try super.tearDownWithError()
    }

    private func cacheFile() -> URL { tmp.appendingPathComponent("sizes.json") }

    // MARK: - Remembering

    func testARememberedSizeComesBack() {
        let cache = FolderSizeCache(fileURL: cacheFile())
        cache.store(size: 123_456, for: "/Users/dimas/Documents/АВТО")
        XCTAssertEqual(cache.size(for: "/Users/dimas/Documents/АВТО"), 123_456)
        XCTAssertNil(cache.size(for: "/Users/dimas/Documents/другая"))
    }

    /// The whole point of persistence: a NEW instance reading the same file knows the answer.
    func testTheCacheSurvivesARelaunch() {
        let first = FolderSizeCache(fileURL: cacheFile())
        first.store(size: 42_000_000, for: "/some/deep/папка")
        first.flush()

        let second = FolderSizeCache(fileURL: cacheFile())
        XCTAssertEqual(second.size(for: "/some/deep/папка"), 42_000_000)
    }

    func testStoringAgainOverwrites() {
        let cache = FolderSizeCache(fileURL: cacheFile())
        cache.store(size: 100, for: "/f")
        cache.store(size: 200, for: "/f")
        XCTAssertEqual(cache.size(for: "/f"), 200)
    }

    /// A deleted folder must not haunt the panel — and everything UNDER it goes too.
    func testForgettingTakesTheSubtree() {
        let cache = FolderSizeCache(fileURL: cacheFile())
        cache.store(size: 1, for: "/gone")
        cache.store(size: 2, for: "/gone/child")
        cache.store(size: 3, for: "/gone-but-different")

        cache.forget(path: "/gone")

        XCTAssertNil(cache.size(for: "/gone"))
        XCTAssertNil(cache.size(for: "/gone/child"))
        XCTAssertEqual(cache.size(for: "/gone-but-different"), 3,
                       "a PREFIX match is not a subtree: /gone-but-different is unrelated")
    }

    /// Many threads hammering one cache: the lock either holds or this crashes.
    func testConcurrentStoresDoNotCorrupt() {
        let cache = FolderSizeCache(fileURL: cacheFile())
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            cache.store(size: UInt64(i), for: "/dir\(i % 20)")
            _ = cache.size(for: "/dir\(i % 20)")
        }
        for i in 0..<20 {
            XCTAssertNotNil(cache.size(for: "/dir\(i)"))
        }
    }

    // MARK: - The slider's arithmetic

    func testHundredPercentIsEveryCore() {
        XCTAssertEqual(FolderSizeCache.workerCount(loadPercent: 100, coreCount: 10), 10)
    }

    func testAQuarterOfTenCoresIsTwoOrThreeQuietWorkers() {
        XCTAssertEqual(FolderSizeCache.workerCount(loadPercent: 25, coreCount: 10), 3)
    }

    /// The floor: even 10% on a two-core machine must leave ONE worker, or the feature is
    /// silently a no-op.
    func testTinyMachinesStillGetOneWorker() {
        XCTAssertEqual(FolderSizeCache.workerCount(loadPercent: 10, coreCount: 2), 1)
        XCTAssertEqual(FolderSizeCache.workerCount(loadPercent: 10, coreCount: 1), 1)
    }

    func testGarbagePercentsAreClamped() {
        XCTAssertEqual(FolderSizeCache.workerCount(loadPercent: 0, coreCount: 8), 1)
        XCTAssertEqual(FolderSizeCache.workerCount(loadPercent: 500, coreCount: 8), 8)
    }

    func testLowLoadRunsInTheBackground() {
        XCTAssertEqual(FolderSizeCache.workerPriority(loadPercent: 10), .background)
        XCTAssertEqual(FolderSizeCache.workerPriority(loadPercent: 25), .background)
        XCTAssertEqual(FolderSizeCache.workerPriority(loadPercent: 50), .utility)
        XCTAssertEqual(FolderSizeCache.workerPriority(loadPercent: 100), .userInitiated)
    }

    // MARK: - Walk order

    /// The user is looking at the cursor; that row's answer must come first.
    func testWalkStartsAtTheCursor() {
        XCTAssertEqual(FolderSizeCache.walkOrder(count: 5, cursorIndex: 2).first, 2)
    }

    func testWalkSpreadsOutwardBelowFirst() {
        // Cursor at 2 of 0..4: reading direction wins ties — below, then above.
        XCTAssertEqual(FolderSizeCache.walkOrder(count: 5, cursorIndex: 2), [2, 3, 1, 4, 0])
    }

    func testEveryFolderAppearsExactlyOnce() {
        let order = FolderSizeCache.walkOrder(count: 100, cursorIndex: 37)
        XCTAssertEqual(Set(order).count, 100)
        XCTAssertEqual(order.count, 100)
    }

    func testCursorOutOfRangeIsClampedNotCrashed() {
        XCTAssertEqual(FolderSizeCache.walkOrder(count: 3, cursorIndex: 99), [2, 1, 0])
        XCTAssertEqual(FolderSizeCache.walkOrder(count: 3, cursorIndex: -5), [0, 1, 2])
        XCTAssertEqual(FolderSizeCache.walkOrder(count: 0, cursorIndex: 0), [])
    }
}
