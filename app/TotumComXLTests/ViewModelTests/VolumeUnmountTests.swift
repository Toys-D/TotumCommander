import Foundation
import XCTest
@testable import TotumComXLApp

/// Отключение тома через диспетчер дисков, память «гостя» и имя, по которому идём к серверу.
final class VolumeUnmountTests: XCTestCase {

    /// Свой маленький образ диска: подключить, отключить нашей дорогой, убедиться, что тома
    /// нет, — и прибрать за собой.
    func test_образДискаОтключаетсяЧерезДиспетчер() throws {
        let folder = NSTemporaryDirectory() + "fcxl-unmount-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let image = folder + "/том.dmg"
        let name = "FCXLUnmount\(Int.random(in: 1000...9999))"
        guard run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "4m", "-fs", "APFS",
                                       "-volname", name, image]) == 0 else {
            throw XCTSkip("образ не создался")
        }
        let attach = output("/usr/bin/hdiutil", ["attach", "-nobrowse", image])
        let mountPoint = "/Volumes/" + name
        guard attach.contains(mountPoint) else { throw XCTSkip("образ не подключился: \(attach)") }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint]) }

        let started = Date()
        let outcome = VolumeUnmount.unmount(path: mountPoint)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        XCTAssertEqual(outcome, .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mountPoint), "тома больше нет")
        XCTAssertLessThan(ms, 5000, "отключение без посредника — не секунды")

        // Том, которого уже нет, — отключён: это не ошибка.
        XCTAssertEqual(VolumeUnmount.unmount(path: mountPoint), .done)
    }

    func test_памятьГостя() {
        let defaults = UserDefaults(suiteName: "fcxl.guest.tests")!
        defaults.removePersistentDomain(forName: "fcxl.guest.tests")
        XCTAssertFalse(NetworkGuestMemory.isGuest("Server_SO", defaults: defaults))
        NetworkGuestMemory.remember("Server_SO", defaults: defaults)
        XCTAssertTrue(NetworkGuestMemory.isGuest("server_so", defaults: defaults), "без учёта регистра")
        NetworkGuestMemory.remember("192.168.0.5", defaults: defaults)
        NetworkGuestMemory.forget("SERVER_SO", defaults: defaults)
        XCTAssertFalse(NetworkGuestMemory.isGuest("server_so", defaults: defaults))
        XCTAssertTrue(NetworkGuestMemory.isGuest("192.168.0.5", defaults: defaults))
    }

    func test_имяИзОтветаNetBIOS() {
        XCTAssertEqual(NetworkBrowserService.parseNetBIOSLookup(
            "Got response from 192.168.0.169\nIP address of server_so: 192.168.0.169\n"), "192.168.0.169")
        XCTAssertNil(NetworkBrowserService.parseNetBIOSLookup("smbutil: unable to resolve nobody\n"))
        XCTAssertTrue(NetworkBrowserService.looksLikeIPv4("192.168.0.169"))
        XCTAssertFalse(NetworkBrowserService.looksLikeIPv4("server_so"))
        XCTAssertFalse(NetworkBrowserService.looksLikeIPv4("macbook.local"))
        XCTAssertFalse(NetworkBrowserService.looksLikeIPv4("1.2.3"))
    }

    private func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func output(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
