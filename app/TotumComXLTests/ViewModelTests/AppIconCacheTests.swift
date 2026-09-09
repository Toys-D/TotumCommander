import AppKit
import XCTest

@testable import TotumComXLApp

/// Application icons in the list. Asking the system for one costs about a hundred times what
/// an icon by file type costs, and every row of /Applications is a program — which is why that
/// folder felt heavy while ordinary folders flew.
@MainActor
final class AppIconCacheTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppIconCache.forget()
    }

    func test_theSameProgramIsAskedAboutOnce() throws {
        let path = "/System/Applications/Calculator.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))

        let first = AppIconCache.icon(path: path, size: 16)
        let second = AppIconCache.icon(path: path, size: 16)
        XCTAssertTrue(first === second, "the second look must come from memory, not LaunchServices")
    }

    /// Sizes are separate images: the list draws 16pt while a zoomed cursor row draws bigger,
    /// and one must not resize the other.
    func test_differentSizesAreDifferentImages() throws {
        let path = "/System/Applications/Calculator.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))

        let small = AppIconCache.icon(path: path, size: 16)
        let large = AppIconCache.icon(path: path, size: 32)
        XCTAssertFalse(small === large)
        XCTAssertEqual(small.size.width, 16)
        XCTAssertEqual(large.size.width, 32)
    }

    /// The image the system hands back is shared. Resizing it in place would change the icon
    /// everyone else is holding, so ours is a copy.
    func test_theSystemsOwnImageIsNotResizedInPlace() throws {
        let path = "/System/Applications/Calculator.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))

        let systemIcon = NSWorkspace.shared.icon(forFile: path)
        let systemSize = systemIcon.size
        _ = AppIconCache.icon(path: path, size: 16)
        XCTAssertEqual(NSWorkspace.shared.icon(forFile: path).size, systemSize,
                       "the shared image must come back the size it was")
    }

    /// A program replaced by an update must not keep its old icon: the bundle's modification
    /// time is part of what is remembered.
    func test_aChangedBundleGetsANewIcon() throws {
        let bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-icon-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let before = AppIconCache.icon(path: bundle.path, size: 16)
        // Move the bundle's clock on, as an update would.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: bundle.path)
        let after = AppIconCache.icon(path: bundle.path, size: 16)
        XCTAssertFalse(before === after, "a newer bundle must be asked about again")
    }
}
