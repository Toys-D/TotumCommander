import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import TotumComXLApp

final class PackDialogControllerTests: XCTestCase {
    func test_archiveNameSelectionRange_whenNameHasCurrentExtension_shouldSelectBaseNameOnly() {
        let range = PackDialogController.archiveNameSelectionRange(
            for: "backup.zip",
            format: .zip
        )

        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, 6)
    }

    func test_archiveNameSelectionRange_whenNameHasCompoundExtension_shouldSelectBaseNameOnly() {
        let range = PackDialogController.archiveNameSelectionRange(
            for: "backup.tar.gz",
            format: .tarGz
        )

        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, 6)
    }

    func test_archiveNameSelectionRange_whenNameHasNoExtension_shouldSelectWholeName() {
        let range = PackDialogController.archiveNameSelectionRange(
            for: "backup",
            format: .zip
        )

        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, 6)
    }

    /// The pack window in both themes, the links row included — into FCXL_LOOK_DIR, to be
    /// looked at by eye. Drawn taller than the real window (which scrolls) so every row shows.
    @MainActor
    func test_снимокОкнаУпаковкиВОбеихТемах() throws {
        guard let dir = ProcessInfo.processInfo.environment["FCXL_LOOK_DIR"] else { return }
        let size = NSSize(width: PackDialogController.size.width, height: 1160)
        for (name, format, appearance) in [("упаковка-светлая", ArchiveFormat.zip, NSAppearance.Name.aqua),
                                           ("упаковка-тёмная", .zip, .darkAqua),
                                           ("упаковка-dmg", .dmg, .aqua)] {
            let view = PackDialogView(session: FCXLDialogSession<ArchivePackDialogResult>(),
                                      defaultArchivePath: "/tmp/проект" + format.fileExtension,
                                      defaultFormat: format, selectedItemsCount: 3)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
        }
    }
}
