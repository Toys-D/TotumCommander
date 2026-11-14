import Foundation
import XCTest

/// Свой маленький том для тестов: образ диска в собственной папке, подключённый без показа в
/// Finder. Нужен там, где поведение зависит от границы томов — копирование через copyfile,
/// Корзина внешнего диска, нехватка места. Настоящих дисков пользователя не касается.
final class TestDiskImage {

    /// Куда подключён том.
    let mountPoint: String
    private let folder: String
    private let image: String

    /// - Parameters:
    ///   - megabytes: размер образа.
    ///   - fileSystem: `HFS+`, `ExFAT`, `MS-DOS FAT32`, `APFS`.
    ///   - inVolumes: подключить в `/Volumes/<имя>` (как внешний диск), а не в свою папку.
    ///   - mountName: имя папки, в которую подключается том (когда не `inVolumes`).
    /// - Throws: `XCTSkip`, когда образ не создался или не подключился.
    init(megabytes: Int = 16, fileSystem: String = "HFS+", inVolumes: Bool = false,
         mountName: String = "том") throws {
        folder = NSTemporaryDirectory() + "fcxl-image-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        image = folder + "/том.dmg"
        // Не длиннее 11 знаков и без строчных: иначе метку не принимают exFAT и FAT, и образ
        // не создаётся вовсе.
        let name = "FCXLT\(Int.random(in: 100_000...999_999))"
        guard Self.run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "\(megabytes)m",
                                            "-fs", fileSystem, "-volname", name, image]).status == 0 else {
            try? FileManager.default.removeItem(atPath: folder)
            throw XCTSkip("образ диска не создался (\(fileSystem))")
        }
        var arguments = ["attach", "-nobrowse", "-owners", "on"]
        if inVolumes {
            mountPoint = "/Volumes/" + name
        } else {
            mountPoint = folder + "/" + mountName
            arguments += ["-mountpoint", mountPoint]
        }
        let attach = Self.run("/usr/bin/hdiutil", arguments + [image])
        guard attach.status == 0, Self.isMountPoint(mountPoint) else {
            try? FileManager.default.removeItem(atPath: folder)
            throw XCTSkip("образ диска не подключился: \(attach.output)")
        }
    }

    /// Отключить том и убрать образ. Повторный вызов безвреден.
    func detach() {
        if Self.isMountPoint(mountPoint) {
            _ = Self.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint])
        } else if let device = Self.attachedDevice(ofImage: image) {
            // Том отключили, а образ остался присоединён. Его устройство ищется по самому
            // образу: номера дисков система выдаёт заново, и по запомненному номеру можно
            // отсоединить чужой диск.
            _ = Self.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", device])
        }
        try? FileManager.default.removeItem(atPath: folder)
    }

    /// Устройство, под которым сейчас присоединён образ; nil — образ не присоединён.
    static func attachedDevice(ofImage image: String) -> String? {
        func real(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let info = run("/usr/bin/hdiutil", ["info", "-plist"])
        guard info.status == 0,
              let plist = try? PropertyListSerialization.propertyList(
                from: Data(info.output.utf8), format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        let wanted = real(image)
        for entry in images {
            guard let path = entry["image-path"] as? String, real(path) == wanted,
                  let entities = entry["system-entities"] as? [[String: Any]] else { continue }
            // Весь диск — самое короткое имя устройства (/dev/disk7, а не /dev/disk7s1).
            return entities.compactMap { $0["dev-entry"] as? String }.min { $0.count < $1.count }
        }
        return nil
    }

    private static func isMountPoint(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let mounted = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return URL(fileURLWithPath: mounted).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        // Читать до ожидания: иначе большой вывод запирает дочерний процесс.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
