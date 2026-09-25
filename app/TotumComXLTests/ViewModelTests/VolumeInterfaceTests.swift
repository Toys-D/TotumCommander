import XCTest
@testable import TotumComXLApp

/// Образ диска — быстрый том: лежит на диске компьютера, а не за шиной. Раньше обход IOKit
/// его не узнавал и записывал в «медленные»: панель не ставила наблюдателя, и файлы,
/// скопированные в хранилище, не появлялись, пока папку не перечитаешь руками.
final class VolumeInterfaceTests: XCTestCase {

    func test_образДискаСчитаетсяБыстрымТомом() throws {
        let folder = NSTemporaryDirectory() + "img-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let image = folder + "/проба.dmg"
        let name = "FCXLPROBE\(Int.random(in: 1000...9999))"
        try run(["create", "-quiet", "-size", "8m", "-fs", "HFS+", "-volname", name, image])
        try run(["attach", "-quiet", "-nobrowse", "-mountpoint", folder + "/mnt", image])
        defer { try? run(["detach", "-quiet", "-force", folder + "/mnt"]) }

        VolumeInterfaceDetector.clearCache()
        let info = VolumeInterfaceDetector.detect(forPath: folder + "/mnt")
        XCTAssertEqual(info.busType, .diskImage, "\(info.displayName)")
        XCTAssertTrue(info.isFast)

        let internalDisk = VolumeInterfaceDetector.detect(forPath: "/")
        XCTAssertTrue(internalDisk.isFast, "внутренний диск как был")
    }

    private func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "hdiutil", code: Int(p.terminationStatus))
        }
    }
}
