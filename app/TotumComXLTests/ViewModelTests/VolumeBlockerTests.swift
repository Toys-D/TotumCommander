import XCTest

@testable import TotumComXLApp

/// "Disk in use — (could not determine the processes)" was what every eject said, for every disk:
/// lsof was being launched from /usr/bin, where macOS does not keep it, so the launch threw and
/// the list came back empty every time.
@MainActor
final class VolumeBlockerTests: XCTestCase {

    private let volume = "/Volumes/SERVER_SO"

    /// The bug itself, in one assertion: the tool has to be where the system keeps it.
    func testLsofIsWhereWeLookForIt() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"),
                      "macOS keeps lsof in /usr/sbin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/usr/bin/lsof"),
                       "and not in /usr/bin, which is where it used to be run from")
    }

    /// A real eject asks the real system; if this ever returns nothing at all it means the
    /// launch failed again, exactly as before.
    func testAskingTheSystemActuallyRuns() {
        // The root volume always has something open on it — the whole OS lives there.
        let blockers = PanelVolumeBar.blockingProcessNames(volumeRoot: "/")
        XCTAssertFalse(blockers.isEmpty, "lsof did not run — this is the original bug returning")
    }

    // MARK: - Reading lsof's answer

    private func lsof(_ pairs: [(String, String)]) -> String {
        pairs.map { "c\($0.0)\nn\($0.1)" }.joined(separator: "\n")
    }

    func testABlockerIsNamedWithTheFileItHolds() {
        let out = lsof([("QuickTimePlayer", "\(volume)/кино/отпуск.mov")])
        XCTAssertEqual(PanelVolumeBar.parseBlockers(lsofOutput: out, volumeRoot: volume),
                       ["QuickTimePlayer — кино/отпуск.mov"])
    }

    /// We are the likeliest blocker of all, and hiding ourselves is what left the user with
    /// "could not determine" even when lsof did run.
    func testWeNameOurselvesToo() {
        let out = lsof([("TotumComXL", "\(volume)/видео.mp4")])
        XCTAssertEqual(PanelVolumeBar.parseBlockers(lsofOutput: out, volumeRoot: volume),
                       ["Totum Commander — видео.mp4"])
    }

    /// Standing in the volume root is not holding a file — there is nothing to name.
    func testSittingInTheVolumeRootNamesNoFile() {
        let out = lsof([("zsh", volume)])
        XCTAssertEqual(PanelVolumeBar.parseBlockers(lsofOutput: out, volumeRoot: volume), ["zsh"])
    }

    /// One line per process: a player with forty open files must not fill the dialog.
    func testAProcessIsListedOnce() {
        let out = lsof([("VLC", "\(volume)/a.mkv"), ("VLC", "\(volume)/b.mkv"),
                        ("VLC", "\(volume)/c.mkv")])
        XCTAssertEqual(PanelVolumeBar.parseBlockers(lsofOutput: out, volumeRoot: volume),
                       ["VLC — a.mkv"])
    }

    func testFilesOnOtherVolumesAreIgnored() {
        let out = lsof([("Safari", "/Users/dimas/загрузка.zip"),
                        ("Finder", "/Volumes/SERVER_SO_OLD/x.txt"),
                        ("Preview", "\(volume)/скан.pdf")])
        XCTAssertEqual(PanelVolumeBar.parseBlockers(lsofOutput: out, volumeRoot: volume),
                       ["Preview — скан.pdf"],
                       "a prefix match must not swallow a differently-named neighbour volume")
    }

    func testNothingHoldingItIsAnEmptyList() {
        XCTAssertTrue(PanelVolumeBar.parseBlockers(lsofOutput: "", volumeRoot: volume).isEmpty)
    }

    func testTheListIsCapped() {
        let out = lsof((1...30).map { ("app\($0)", "\(volume)/f\($0)") })
        XCTAssertEqual(PanelVolumeBar.parseBlockers(lsofOutput: out, volumeRoot: volume).count, 12)
    }
}
