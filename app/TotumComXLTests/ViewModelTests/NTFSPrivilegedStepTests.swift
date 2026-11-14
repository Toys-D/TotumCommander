import Foundation
import XCTest
import FCXLBridgeObjC

@testable import TotumComXLApp

/// Запись на NTFS начинается с одного шага от имени администратора: отключить системный
/// драйвер «только чтение» и отдать устройство программе. В этот шаг попадает точка
/// подключения тома — то есть имя тома, а его задаёт тот, кто форматировал диск.
///
/// Сам шаг здесь выполняется БЕЗ прав администратора, на своём образе диска: его устройство и
/// так принадлежит пользователю, поэтому и отключение тома, и передача устройства проходят.
/// Дорога с правами (sudo, окно пароля) в тестах не вызывается никогда.
final class NTFSPrivilegedStepTests: XCTestCase {

    private var folder: String!
    private var marker: String!

    /// Имя, которое в записи команды одной строкой закрывало кавычку и дописывало своё.
    private let hostileName = "том\"; touch \"$FCXL_MARKER\"; echo \""

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = NSTemporaryDirectory() + "fcxl-ntfs-step-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        marker = folder + "/исполнилось"
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(atPath: folder) }
        folder = nil
        marker = nil
        try super.tearDownWithError()
    }

    /// Запустить командную строку как есть; чужая команда, если она исполнится, оставит файл.
    private func run(_ commandLine: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: commandLine[0])
        process.arguments = Array(commandLine.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["FCXL_MARKER"] = marker
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Том образа так, как его видит программа: устройство и точка подключения.
    private func volume(of disk: TestDiskImage) throws -> (device: String, mountPoint: String) {
        let info = try XCTUnwrap(FCXLNTFSBridge.detectNTFSVolume(atPath: disk.mountPoint))
        return (try XCTUnwrap(info["devicePath"] as? String),
                try XCTUnwrap(info["mountPoint"] as? String))
    }

    private func isMounted(_ device: String) -> Bool {
        var list: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&list, MNT_NOWAIT)
        guard count > 0, let list else { return false }
        return (0..<Int(count)).contains { index in
            withUnsafePointer(to: &list[index].f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            } == device
        }
    }

    // MARK: - Имя тома — данные, а не команда

    /// Дорога с сохранённым паролем: та же командная строка, что получает sudo.
    func test_подготовкаТома_ИмяТомаНеИсполняетсяКакКоманда() throws {
        let disk = try TestDiskImage(megabytes: 8, mountName: hostileName)
        defer { disk.detach() }
        let volume = try volume(of: disk)
        XCTAssertTrue(volume.mountPoint.hasSuffix(hostileName), "том подключён не под тем именем")

        let step = try XCTUnwrap(FCXLNTFSBridge.shellArguments(toPrepareDevice: volume.device,
                                                               mountPoint: volume.mountPoint,
                                                               owner: getuid()))
        let result = run(step)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker),
                       "имя тома исполнилось как команда")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(isMounted(volume.device), "том остался подключён")
    }

    /// Дорога окна пароля: тот же сценарий AppleScript, только без запроса прав.
    func test_подготовкаТомаЧерезОкноПароля_ИмяТомаНеИсполняетсяКакКоманда() throws {
        let disk = try TestDiskImage(megabytes: 8, mountName: hostileName)
        defer { disk.detach() }
        let volume = try volume(of: disk)

        let step = try XCTUnwrap(FCXLNTFSBridge.appleScriptArguments(
            toPrepareDevice: volume.device, mountPoint: volume.mountPoint, owner: getuid(),
            privileged: false))
        let result = run(step)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker),
                       "имя тома исполнилось как команда")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(isMounted(volume.device), "том остался подключён")
    }

    // MARK: - Кому достаётся устройство

    /// Права на узел устройства; nil — узла нет.
    private func node(_ path: String) -> (owner: uid_t, mode: mode_t)? {
        var info = stat()
        return stat(path, &info) == 0 ? (info.st_uid, info.st_mode) : nil
    }

    /// Узел устройства живёт до отсоединения диска и свои права при повторном подключении
    /// тома не возвращает. Открытый «всем на запись», он оставался бы таким и после работы.
    func test_подготовкаТома_УстройствоОтдаётсяПользователюАНеВсем() throws {
        let disk = try TestDiskImage(megabytes: 8)
        defer { disk.detach() }
        let volume = try volume(of: disk)

        let step = try XCTUnwrap(FCXLNTFSBridge.shellArguments(toPrepareDevice: volume.device,
                                                               mountPoint: volume.mountPoint,
                                                               owner: getuid()))
        let result = run(step)

        XCTAssertEqual(result.status, 0, result.output)
        let node = try XCTUnwrap(node(volume.device))
        XCTAssertEqual(node.owner, getuid(), "устройство не у пользователя")
        XCTAssertEqual(node.mode & (S_IWGRP | S_IROTH | S_IWOTH), 0,
                       "устройство открыто посторонним: \(String(node.mode & 0o777, radix: 8))")
    }

    func test_подготовкаТомаЧерезОкноПароля_УстройствоОтдаётсяПользователюАНеВсем() throws {
        let disk = try TestDiskImage(megabytes: 8)
        defer { disk.detach() }
        let volume = try volume(of: disk)

        let step = try XCTUnwrap(FCXLNTFSBridge.appleScriptArguments(
            toPrepareDevice: volume.device, mountPoint: volume.mountPoint, owner: getuid(),
            privileged: false))
        let result = run(step)

        XCTAssertEqual(result.status, 0, result.output)
        let node = try XCTUnwrap(node(volume.device))
        XCTAssertEqual(node.owner, getuid(), "устройство не у пользователя")
        XCTAssertEqual(node.mode & (S_IWGRP | S_IROTH | S_IWOTH), 0,
                       "устройство открыто посторонним: \(String(node.mode & 0o777, radix: 8))")
    }

    // MARK: - Что вообще можно отдать на этот шаг

    func test_подготовкаТома_ТолькоДисковоеУстройствоИПолныйПуть() {
        let volume = "/Volumes/Диск \"с кавычками\" $(x)"
        for device in ["/dev/disk4s1", "/dev/disk12s3s1", "/dev/disk5"] {
            XCTAssertNotNil(FCXLNTFSBridge.shellArguments(toPrepareDevice: device, mountPoint: volume,
                                                          owner: 501),
                            device)
            XCTAssertNotNil(FCXLNTFSBridge.appleScriptArguments(
                toPrepareDevice: device, mountPoint: volume, owner: 501, privileged: true), device)
        }
        let notDisks = ["", "/etc/passwd", "/dev/null", "disk4s1", "/dev/disk", "/dev/disk4s",
                        "/dev/disk4s1; rm", "/dev/disk4s1\n", "/dev/../etc/passwd",
                        "/dev/disk4/../../etc/passwd", "/dev/rdisk4s1", "/dev/disk٤",
                        "//server/share", "-disk4s1"]
        for device in notDisks {
            XCTAssertNil(FCXLNTFSBridge.shellArguments(toPrepareDevice: device, mountPoint: volume,
                                                          owner: 501),
                         "принято как диск: «\(device)»")
            XCTAssertNil(FCXLNTFSBridge.appleScriptArguments(
                toPrepareDevice: device, mountPoint: volume, owner: 501, privileged: true),
                         "принято как диск: «\(device)»")
        }
        for mountPoint in ["", "Volumes/Диск", "-force", "/Volumes/Ди\u{0}ск"] {
            XCTAssertNil(FCXLNTFSBridge.shellArguments(toPrepareDevice: "/dev/disk4s1",
                                                       mountPoint: mountPoint, owner: 501),
                         "принято как точка подключения: «\(mountPoint)»")
            XCTAssertNil(FCXLNTFSBridge.appleScriptArguments(
                toPrepareDevice: "/dev/disk4s1", mountPoint: mountPoint, owner: 501,
                privileged: true),
                         "принято как точка подключения: «\(mountPoint)»")
        }
    }

    // MARK: - Запись команды (закрепляющие проверки)

    /// С правами выполняется ровно то, что тесты выполняют без прав: разница в одной приписке.
    func test_окноПароля_ТаЖеКомандаЧтоПроверенаБезПрав() throws {
        let device = "/dev/disk4s1"
        let volume = "/Volumes/Диск"
        let plain = try XCTUnwrap(FCXLNTFSBridge.appleScriptArguments(
            toPrepareDevice: device, mountPoint: volume, owner: 501, privileged: false))
        let privileged = try XCTUnwrap(FCXLNTFSBridge.appleScriptArguments(
            toPrepareDevice: device, mountPoint: volume, owner: 501, privileged: true))

        XCTAssertEqual(plain.count, privileged.count)
        let different = zip(plain, privileged).filter { $0 != $1 }
        XCTAssertEqual(different.count, 1)
        XCTAssertEqual(different.first?.1,
                       (different.first?.0 ?? "") + " with administrator privileges")
    }

    /// Имя тома, устройство и владелец — отдельные слова командной строки, в текст команды
    /// не входят; файла со сценарием для администратора больше нет.
    func test_подготовкаТома_ДанныеИдутОтдельнымиСловами() throws {
        let device = "/dev/disk4s1"
        let volume = "/Volumes/Диск"
        let owner = "54321"
        let shell = try XCTUnwrap(FCXLNTFSBridge.shellArguments(toPrepareDevice: device,
                                                                mountPoint: volume, owner: 54321))
        let dialog = try XCTUnwrap(FCXLNTFSBridge.appleScriptArguments(
            toPrepareDevice: device, mountPoint: volume, owner: 54321, privileged: true))

        for commandLine in [shell, dialog] {
            XCTAssertEqual(commandLine.filter { $0 == volume }.count, 1)
            XCTAssertEqual(commandLine.filter { $0 == device }.count, 1)
            XCTAssertEqual(commandLine.filter { $0 == owner }.count, 1)
            for word in commandLine where word != volume && word != device && word != owner {
                XCTAssertFalse(word.contains(volume), word)
                XCTAssertFalse(word.contains(device), word)
                XCTAssertFalse(word.contains(owner), word)
                XCTAssertFalse(word.contains(NSTemporaryDirectory()), word)
                XCTAssertFalse(word.contains("fcxl_ntfs.sh"), word)
            }
        }
        XCTAssertEqual(shell.first, "/bin/sh")
        XCTAssertEqual(dialog.first, "/usr/bin/osascript")
    }
}
