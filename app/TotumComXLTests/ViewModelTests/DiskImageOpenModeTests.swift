import Foundation
import XCTest

@testable import TotumComXLApp

/// Which road a .dmg takes: the system's (Finder shows the image's own installer window) or
/// ours (mount quietly, step into the volume). The setting decides; Shift+Enter and the
/// context menu always offer the other one.
final class DiskImageOpenModeTests: XCTestCase {

    func test_savedChoice_wins() {
        XCTAssertEqual(DiskImageOpenMode.chosen(savedRawValue: "panel"), .panel)
        XCTAssertEqual(DiskImageOpenMode.chosen(savedRawValue: "finder"), .finder)
    }

    /// Nothing saved, or nonsense saved — Finder's way, because a disk image is nearly always
    /// an installer and its window is the instruction sheet.
    func test_nothingOrGarbageSaved_fallsBackToFinder() {
        XCTAssertEqual(DiskImageOpenMode.chosen(savedRawValue: nil), .finder)
        XCTAssertEqual(DiskImageOpenMode.chosen(savedRawValue: "какая-то чушь"), .finder)
        XCTAssertEqual(DiskImageOpenMode.fallback, .finder)
    }

    func test_opposite_isAlwaysTheOtherRoad() {
        XCTAssertEqual(DiskImageOpenMode.finder.opposite, .panel)
        XCTAssertEqual(DiskImageOpenMode.panel.opposite, .finder)
        for mode in DiskImageOpenMode.allCases {
            XCTAssertEqual(mode.opposite.opposite, mode)
        }
    }

    // MARK: - What the setting governs

    func test_isDiskImage_extensionOnly_anyCase() {
        XCTAssertTrue(DiskImageOpenMode.isDiskImage("/Users/x/Downloads/Airmail 26.0.34.dmg"))
        XCTAssertTrue(DiskImageOpenMode.isDiskImage("/x/ОБРАЗ.DMG"))
        // The file need not exist — an image too broken to mount takes the same road.
        XCTAssertTrue(DiskImageOpenMode.isDiskImage("/нет/такого.dmg"))
    }

    /// Под именем .iso нередко лежит обыкновенный DMG — так раздают программы. Его узнают по
    /// подписи «koly» в хвосте; настоящий ISO9660 остаётся архивом.
    func test_dmgПодИменемISO_УзнаётсяПоХвосту() throws {
        let folder = NSTemporaryDirectory() + "udif-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }

        var udif = Data(repeating: 0xAB, count: 4096)
        udif.append(Data("koly".utf8))
        udif.append(Data(repeating: 0, count: 508))
        FileManager.default.createFile(atPath: folder + "/образ.iso", contents: udif)
        XCTAssertTrue(DiskImageOpenMode.isDiskImage(folder + "/образ.iso"), "DMG под именем .iso — образ")

        FileManager.default.createFile(atPath: folder + "/чужой.iso", contents: Data(repeating: 0xCD, count: 4096))
        XCTAssertFalse(DiskImageOpenMode.isDiskImage(folder + "/чужой.iso"), "без подписи — не образ")
        XCTAssertFalse(DiskImageOpenMode.isDiskImage(folder + "/нет.iso"), "нет файла — не образ")

        XCTAssertTrue(DiskImageOpenMode.isDiskImage("/x/диск.cdr"))
        XCTAssertTrue(DiskImageOpenMode.isDiskImage("/x/диск.toast"))
    }

    func test_isDiskImage_leavesEverythingElseAlone() {
        for path in ["/x/archive.zip", "/x/disk.iso", "/x/dmg", "/x/.dmg.txt", "/x/folder.dmg/inner.txt"] {
            XCTAssertFalse(DiskImageOpenMode.isDiskImage(path), path)
        }
    }

    func test_titleKeysAndRawValues_areDistinct() {
        XCTAssertEqual(Set(DiskImageOpenMode.allCases.map(\.rawValue)).count,
                       DiskImageOpenMode.allCases.count)
        XCTAssertEqual(Set(DiskImageOpenMode.allCases.map(\.titleKey)).count,
                       DiskImageOpenMode.allCases.count)
    }
}
