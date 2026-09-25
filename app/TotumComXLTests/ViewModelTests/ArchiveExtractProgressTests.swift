import Foundation
import XCTest

@testable import TotumComXLApp

/// Dragging files out of an archive used to happen in silence: the work ran on a background
/// queue with nothing on screen to say the program was busy, or to let the person stop it.
/// These tests are about the half that makes a progress window possible — the reporting.
@MainActor
final class ArchiveExtractProgressTests: XCTestCase {
    private var ops: FileOperationsService!
    private var root: String!

    override func setUp() async throws {
        try await super.setUp()
        ops = FileOperationsService(bridgeService: CoreBridgeService())
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: root)
        try await super.tearDown()
    }

    /// A zip with one big entry and two small ones — enough to tell a bar that moves by bytes
    /// from one that moves by file count.
    private func makeArchive() throws -> String {
        let source = (root as NSString).appendingPathComponent("вложить")
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        let write = { (name: String, bytes: Int) in
            let data = Data(repeating: 0x41, count: bytes)
            try data.write(to: URL(fileURLWithPath: (source as NSString).appendingPathComponent(name)))
        }
        // Latin names on purpose: /usr/bin/zip stores a non-ASCII name in a legacy encoding
        // without the UTF-8 flag, so the archive it builds is not the archive our packer builds.
        try write("big.bin", 400_000)
        try write("small.txt", 100)
        try write("small2.txt", 100)

        let archive = (root as NSString).appendingPathComponent("проба.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // Named outright rather than "-r .": a recursive zip stores every path with a "./"
        // in front of it, and the entry names then do not match what a panel shows.
        process.arguments = ["-q", archive, "big.bin", "small.txt", "small2.txt"]
        process.currentDirectoryURL = URL(fileURLWithPath: source)
        try process.run()
        process.waitUntilExit()
        return archive
    }

    func testExtractionReportsEveryFileAndMovesByBytes() throws {
        let archive = try makeArchive()
        let destination = (root as NSString).appendingPathComponent("вынуть")
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)

        var names: [String] = []
        var fractions: [Double] = []
        var lastFilesTotal = 0
        try ops.extractEntries(["big.bin", "small.txt"], fromArchive: archive,
                               to: destination,
                               onProgress: { name, fraction, _, total, _, filesTotal in
                                   names.append(name)
                                   fractions.append(fraction)
                                   lastFilesTotal = filesTotal
                                   XCTAssertGreaterThan(total, 0, "общий размер известен")
                               })

        XCTAssertEqual(Set(names), ["big.bin", "small.txt"], "названы оба файла")
        XCTAssertEqual(lastFilesTotal, 2)
        XCTAssertEqual(fractions.first, 0, "начинается с нуля")
        XCTAssertEqual(fractions.last ?? 0, 1, accuracy: 0.001, "и доходит до конца")
        // By bytes, not by file count: after the big file the bar is far past half, which a
        // count-based bar (one of two files) would put exactly at a half.
        XCTAssertGreaterThan(fractions.dropFirst().first ?? 0, 0.9,
                             "полоса идёт по байтам, а не по числу файлов")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (destination as NSString).appendingPathComponent("big.bin")))
    }

    /// The Cancel button has to actually stop the walk, and say it stopped rather than
    /// pretending the extraction finished.
    func testCancellingStopsTheWalk() throws {
        let archive = try makeArchive()
        let destination = (root as NSString).appendingPathComponent("отменить")
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)

        var extracted = 0
        XCTAssertThrowsError(
            try ops.extractEntries(["big.bin", "small.txt", "small2.txt"],
                                   fromArchive: archive, to: destination,
                                   onProgress: { _, _, _, _, filesDone, _ in extracted = filesDone },
                                   shouldCancel: { extracted >= 1 }))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (destination as NSString).appendingPathComponent("small2.txt")),
            "после отмены остальное не извлекается")
    }

    /// Without a progress handler the reporting costs nothing — the archive index is not even
    /// read. Every other road into this call is unchanged.
    func testWithoutAHandlerNothingExtraHappens() throws {
        let archive = try makeArchive()
        let destination = (root as NSString).appendingPathComponent("тихо")
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        try ops.extractEntries(["small.txt"], fromArchive: archive, to: destination)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (destination as NSString).appendingPathComponent("small.txt")))
    }
}

/// The queue side of the same road: an extraction can now BE a queued operation, which is what
/// makes the progress window's "to the queue" button possible at all.
final class ArchiveExtractQueueTests: XCTestCase {

    private func operation(entries: [String]) -> QueuedOperation {
        var op = QueuedOperation(id: UUID(), kind: .archiveExtract, items: [],
                                 destinationPath: "/куда", createdAt: Date(),
                                 filesTotal: entries.count)
        var params = ArchiveOperationParams()
        params.archivePath = "/дом/архив.zip"
        params.entryPaths = entries
        op.archiveParams = params
        return op
    }

    /// The queue names an operation by what it holds. An extraction holds entry PATHS, not
    /// files on disk, so a title built from `items` would have come out empty.
    func testTheQueueNamesAnExtractionByItsEntries() {
        XCTAssertTrue(operation(entries: ["видео/урок 1.mp4"]).displayTitle.contains("урок 1.mp4"))
        XCTAssertTrue(operation(entries: ["а.txt", "б.txt", "в.txt"]).displayTitle.contains("3"))
    }

    func testAnExtractionIsALocalOperation() {
        XCTAssertFalse(OperationKind.archiveExtract.isRemote,
                       "распаковка идёт с диска — она встаёт в общую последовательную очередь")
    }
}

/// The progress window's own contract. The extraction road leans on it: it asks for the queue
/// button after the window is up, and the button has to appear.
@MainActor
final class ProgressQueueButtonTests: XCTestCase {

    func testTheQueueButtonIsOffUntilAskedFor() {
        let progress = DialogService.shared.showProgress(title: "проба", message: "",
                                                         cancelHandler: nil)
        defer { progress.close() }
        XCTAssertFalse(progress.isQueueButtonVisible,
                       "по умолчанию — только «Отмена»: не всякую работу можно отдать в очередь")
        progress.showSendToQueueButton()
        XCTAssertTrue(progress.isQueueButtonVisible)
    }

    /// Handing the running work over means swapping who receives the reports — the walk itself
    /// must not notice, and cancelling must still reach it through the new receiver.
    func testTheReporterCanBeSwappedMidFlight() {
        let progress = DialogService.shared.showProgress(title: "проба", message: "",
                                                         cancelHandler: nil)
        defer { progress.close() }
        let swappable = SwappableProgressReporter(progress)
        XCTAssertFalse(swappable.isCancelled)

        final class Stub: OperationProgressReporter {
            var isCancelled = true
            var isPaused = false
            var isSentToQueue = false
            func update(currentFile: String, progress: Double, bytesDone: Int64,
                        bytesTotal: Int64, filesDone: Int, filesTotal: Int) {}
            func close() {}
        }
        swappable.swap(to: Stub())
        XCTAssertTrue(swappable.isCancelled, "отмена доходит через нового получателя")
    }
}

/// The picture under the cursor when several files are dragged at once. A drag of twelve files
/// that looks exactly like a drag of one is a lie the person only finds out about after dropping.
@MainActor
final class DragStackImageTests: XCTestCase {

    private func icons(_ count: Int) -> [NSImage] {
        (0..<count).map { DragStackImage.icon(forPath: "/нет/файл\($0).txt", isReal: false) }
    }

    /// The icon has to come from the file's TYPE when there is no file — an entry inside an
    /// archive has a name but nothing on disk to ask about.
    func testAnIconIsFoundForAFileThatDoesNotExist() {
        let picture = DragStackImage.icon(forPath: "/нет/такого/снимок.jpg", isReal: false)
        XCTAssertGreaterThan(picture.size.width, 0)
        let folder = DragStackImage.icon(forPath: "/нет/такой/папки", isReal: false,
                                         isDirectory: true)
        XCTAssertGreaterThan(folder.size.width, 0)
    }

    func testThePileGrowsWithTheFilesButOnlySoFar() {
        let two = DragStackImage.make(icons: icons(2), count: 2, accent: .systemPurple)
        let three = DragStackImage.make(icons: icons(3), count: 3, accent: .systemPurple)
        let many = DragStackImage.make(icons: icons(3), count: 150, accent: .systemPurple)
        XCTAssertGreaterThan(three.size.width, two.size.width, "третья карточка видна")
        XCTAssertEqual(many.size.width, three.size.width, accuracy: 0.01,
                       "сто пятьдесят файлов рисуются той же стопкой — счёт говорит значок")
        XCTAssertEqual(DragStackImage.shownCards, 3)
    }

    /// One file keeps the plain single icon: a badge saying "1" would be noise.
    func testASingleFileIsNotAPile() {
        let one = DragStackImage.make(icons: icons(1), count: 1, accent: .systemPurple)
        let two = DragStackImage.make(icons: icons(2), count: 2, accent: .systemPurple)
        XCTAssertLessThan(one.size.width, two.size.width)
    }
}
