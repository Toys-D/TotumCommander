import XCTest
import FCXLBridgeObjC
@testable import TotumComXLApp

/// Split and join, exercised against the real bridge — the whole point of the feature is that the
/// bytes survive the round trip, and only an actual split/join can show that.
final class FileSplitJoinTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("split-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Arbitrary binary content, so the test covers what a real archive or image looks like rather
    /// than a friendly run of text.
    private func makeFile(named name: String, bytes count: Int) throws -> URL {
        var data = Data(count: count)
        for i in 0..<count { data[i] = UInt8((i &* 31 &+ 7) % 251) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func test_splitThenJoin_restoresTheExactBytes() throws {
        // A size that does NOT divide evenly, so the last part is a remainder.
        let source = try makeFile(named: "payload.zip", bytes: 250_000)
        let original = try Data(contentsOf: source)
        let bridge = FCXLToolsBridge()

        let parts = try bridge.splitFile(atPath: source.path, chunkSize: 100_000,
                                         outputDir: directory.path) as? [String]
        let partPaths = try XCTUnwrap(parts)
        XCTAssertEqual(partPaths.count, 3, "250 KB in 100 KB pieces is three parts")

        // The naming other tools expect: name.ext.001, .002, .003
        XCTAssertEqual((partPaths[0] as NSString).lastPathComponent, "payload.zip.001")
        XCTAssertEqual((partPaths[2] as NSString).lastPathComponent, "payload.zip.003")

        let rebuilt = directory.appendingPathComponent("rebuilt.zip")
        try bridge.joinFiles(partPaths, outputPath: rebuilt.path)
        XCTAssertEqual(try Data(contentsOf: rebuilt), original,
                       "the rejoined file must be byte-identical to the original")
    }

    /// An archive is just bytes to the splitter, but the extension is what a user actually splits,
    /// and a `.zip` must not be mistaken for something the tool refuses.
    func test_archiveExtension_isSplittable() throws {
        let source = try makeFile(named: "archive.zip", bytes: 30_000)
        let bridge = FCXLToolsBridge()
        let parts = try bridge.splitFile(atPath: source.path, chunkSize: 10_000,
                                         outputDir: directory.path) as? [String]
        XCTAssertEqual(parts?.count, 3)
    }

    // MARK: - Finding the set from one part

    func test_parts_areFoundFromAnyMember_andOrderedNumerically() throws {
        // Ten parts, so a plain string sort would put .010 before .002.
        for i in 1...10 {
            _ = try makeFile(named: String(format: "movie.mkv.%03d", i), bytes: 16)
        }
        let fifth = directory.appendingPathComponent("movie.mkv.005").path
        let found = try XCTUnwrap(FileJoiner.parts(forPartAt: fifth))

        XCTAssertEqual(found.count, 10)
        XCTAssertEqual((found[1] as NSString).lastPathComponent, "movie.mkv.002",
                       "ordering must be numeric, not lexical")
        XCTAssertEqual((found[9] as NSString).lastPathComponent, "movie.mkv.010")
        XCTAssertEqual(FileJoiner.joinedName(forPartAt: fifth), "movie.mkv")
    }

    func test_ordinaryFile_isNotTreatedAsAPart() throws {
        let plain = try makeFile(named: "notes.txt", bytes: 16)
        XCTAssertNil(FileJoiner.parts(forPartAt: plain.path))
        XCTAssertFalse(FileJoiner.isPart(plain.path))
    }

    /// A lone `.001` is not a set — joining it would just copy the file under a new name.
    func test_singlePart_isNotASet() throws {
        let lonely = try makeFile(named: "solo.bin.001", bytes: 16)
        XCTAssertTrue(FileJoiner.isPart(lonely.path))
        XCTAssertNil(FileJoiner.parts(forPartAt: lonely.path))
    }

    func test_isPart_recognisesNumericSuffixesOnly() throws {
        XCTAssertTrue(FileJoiner.isPart("/tmp/archive.zip.001"))
        XCTAssertTrue(FileJoiner.isPart("/tmp/archive.zip.12"))
        XCTAssertFalse(FileJoiner.isPart("/tmp/archive.zip"))
        XCTAssertFalse(FileJoiner.isPart("/tmp/archive.tar.gz"))
    }
}

/// The core's split/join gained a byte-progress callback with cancellation, and started checking
/// its writes. Exercised through the real bridge on real files — the same path the app takes.
@MainActor
final class SplitJoinProgressTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("splitprog-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeSource(bytes: Int) -> String {
        let path = dir.appendingPathComponent("source.bin").path
        var data = Data(capacity: bytes)
        var seed: UInt8 = 7
        for _ in 0..<bytes { seed = seed &* 31 &+ 17; data.append(seed) }
        FileManager.default.createFile(atPath: path, contents: data)
        return path
    }

    func test_splitReportsProgressAndJoinRebuildsByteIdentical() throws {
        let source = makeSource(bytes: 300_000)
        let bridge = FCXLToolsBridge()

        var reports: [UInt64] = []
        let parts = try bridge.splitFile(atPath: source, chunkSize: 100_000, outputDir: dir.path,
                                         progress: { done, _ in reports.append(done); return false })
        XCTAssertEqual(parts.count, 3)
        XCTAssertFalse(reports.isEmpty, "the split never reported progress")
        XCTAssertEqual(reports, reports.sorted(), "byte counts went backwards")
        XCTAssertEqual(reports.last, 300_000, "the final report must cover the whole file")

        let output = dir.appendingPathComponent("rebuilt.bin").path
        try bridge.joinFiles(parts, outputPath: output, progress: { _, _ in false })
        XCTAssertEqual(FileManager.default.contents(atPath: output),
                       FileManager.default.contents(atPath: source),
                       "the rebuilt file must be byte-identical to the source")
    }

    /// Cancelling must stop the work AND remove the partial parts — a truncated part set looks
    /// complete to the eye and only fails at join time.
    func test_cancelledSplitLeavesNoPartsBehind() {
        let source = makeSource(bytes: 300_000)
        let bridge = FCXLToolsBridge()

        let parts = try? bridge.splitFile(atPath: source, chunkSize: 100_000, outputDir: dir.path,
                                          progress: { _, _ in true })   // cancel at once
        XCTAssertNil(parts, "a cancelled split must report an error, not a part list")

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasPrefix("source.bin.") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "cancilled split left partial parts: \(leftovers)")
    }
}
