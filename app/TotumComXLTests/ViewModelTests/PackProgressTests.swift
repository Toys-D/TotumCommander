import XCTest

@testable import TotumComXLApp

/// The pack progress bar and its detail line.
///
/// The regression that started this: packing ONE 1.92 GB file showed 100% from the first moment,
/// because the bar took max(bytes, files) and libarchive counts the entry it is still writing as
/// done — 1 of 1. The bytes text underneath was honest the whole time; the bar was the lie.
final class PackProgressTests: XCTestCase {

    // MARK: - The bar

    /// The screenshot case: one file, half written. The bar must say half, not done.
    func testOneBigFileHalfWrittenIsHalfNotDone() {
        let fraction = FileOperationsService.archiveBarFraction(
            bytesDone: 976_000_000, bytesTotal: 1_920_000_000, filesDone: 1, filesTotal: 1)
        XCTAssertEqual(fraction, 976_000_000.0 / 1_920_000_000.0, accuracy: 0.001)
        XCTAssertLessThan(fraction, 0.6, "the bar claimed 100% while half the bytes remained")
    }

    func testAllBytesWrittenIsDone() {
        XCTAssertEqual(FileOperationsService.archiveBarFraction(
            bytesDone: 500, bytesTotal: 500, filesDone: 3, filesTotal: 7), 1.0)
    }

    /// The core normalizes an unknown byte total to 1 — only then may files drive the bar.
    func testUnknownBytesFallBackToFiles() {
        XCTAssertEqual(FileOperationsService.archiveBarFraction(
            bytesDone: 0, bytesTotal: 1, filesDone: 3, filesTotal: 4), 0.75)
    }

    func testEmptyFilesArchiveUsesFileCount() {
        // Ten empty files: no bytes anywhere, progress is the count.
        XCTAssertEqual(FileOperationsService.archiveBarFraction(
            bytesDone: 0, bytesTotal: 1, filesDone: 5, filesTotal: 10), 0.5)
    }

    func testGarbageInputCannotEscapeZeroToOne() {
        XCTAssertEqual(FileOperationsService.archiveBarFraction(
            bytesDone: 9_999, bytesTotal: 100, filesDone: 0, filesTotal: 0), 1.0)
        XCTAssertEqual(FileOperationsService.archiveBarFraction(
            bytesDone: -5, bytesTotal: 100, filesDone: 0, filesTotal: 0), 0.0)
    }

    // MARK: - The detail line

    private let mb: Int64 = 1024 * 1024

    func testSettingsAloneBeforeAnythingIsWritten() {
        let text = FileOperationsService.packProgressDetail(
            format: .tarGz, compressionLevel: 6,
            compressedBytes: 0, uncompressedDone: 0, uncompressedTotal: 0)
        XCTAssertEqual(text, L("progress.pack.settings", "GZIP", 6))
    }

    /// TAR is a container, not a compressor — a level shown there would be a lie.
    func testTarShowsNoCompressionLevel() {
        let text = FileOperationsService.packProgressDetail(
            format: .tar, compressionLevel: 6,
            compressedBytes: 0, uncompressedDone: 0, uncompressedTotal: 0)
        XCTAssertEqual(text, "TAR")
        XCTAssertFalse(text.contains("6"))
    }

    /// Below the threshold the ratio is container-header noise; promising a size from it would
    /// have the estimate swinging wildly in the user's face.
    func testNoEstimateOnTooLittleInput() {
        let text = FileOperationsService.packProgressDetail(
            format: .zip, compressionLevel: 5,
            compressedBytes: 2 * mb, uncompressedDone: 4 * mb, uncompressedTotal: 100 * mb)
        XCTAssertEqual(text, L("progress.pack.settings", "ZIP", 5))
    }

    func testEstimateAppearsAndScalesTheRatioToTheTotal() {
        // 100 MB in, 52 MB out, 200 MB to go in total → 52% and ≈104 MB.
        let text = FileOperationsService.packProgressDetail(
            format: .tarGz, compressionLevel: 6,
            compressedBytes: 52 * mb, uncompressedDone: 100 * mb, uncompressedTotal: 200 * mb)
        let expected = L("progress.pack.settings", "GZIP", 6) + " · "
            + L("progress.pack.estimate", 52,
                ByteCountFormatter.string(fromByteCount: 104 * mb, countStyle: .file))
        XCTAssertEqual(text, expected)
    }

    /// Incompressible data plus container overhead: over 100% is the honest answer, not an error.
    func testIncompressibleDataMayExceedTheOriginal() {
        let text = FileOperationsService.packProgressDetail(
            format: .zip, compressionLevel: 9,
            compressedBytes: 103 * mb, uncompressedDone: 100 * mb, uncompressedTotal: 100 * mb)
        XCTAssertTrue(text.contains("103"), text)
    }
}
