import XCTest
@testable import TotumComXLApp

/// Файл с расширением архива, который архивом не является, — об этом говорят вслух.
///
/// Настоящий случай: «Parallels….iso» не отвечал ни на Enter, ни на двойной щелчок.
/// Внутри лежал оборванный xz-поток, ядро честно отказывало — но отказ уходил в
/// errorMessage, который рисуется только в ПУСТОМ списке. Список был полон, и человек
/// видел молчание. Настоящий ISO при этом обязан открываться как папка.
@MainActor
final class ArchiveOpenFailureTests: XCTestCase {

    private var folder = ""

    override func setUpWithError() throws {
        folder = NSTemporaryDirectory() + "iso-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder + "/src", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder + "/src/файл.txt", contents: Data("привет".utf8))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: folder)
        super.tearDown()
    }

    private func panel() -> PanelViewModel {
        let id = UUID().uuidString
        return PanelViewModel(service: CoreBridgeService(),
                              initialPath: NSHomeDirectory(),
                              pathDefaultsKey: "panel.path.iso.\(id)",
                              viewModeDefaultsKey: "panel.mode.iso.\(id)",
                              showHiddenFiles: false)
    }

    private func подождать(_ условие: @escaping () -> Bool) async throws {
        let срок = Date().addingTimeInterval(4)
        while Date() < срок, !условие() {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func test_чужойФайлПодВидомISO_ЖалуетсяВслух() async throws {
        // Не архив вовсе: xz-заголовок и мусор, как у оборванной закачки.
        let fake = folder + "/образ.iso"
        var bytes = Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
        bytes.append(Data((0..<4096).map { _ in UInt8.random(in: 0...255) }))
        FileManager.default.createFile(atPath: fake, contents: bytes)

        let vm = panel()
        var complaints: [(String, String)] = []
        vm.complainAboutArchive = { name, why in complaints.append((name, why)) }
        vm.loadDirectory(at: folder)
        try await подождать { vm.items.contains { $0.path == fake } }
        let item = try XCTUnwrap(vm.items.first { $0.path == fake })
        XCTAssertTrue(vm.open(item), "панель взялась открыть — это архив по расширению")
        try await подождать { !complaints.isEmpty }
        XCTAssertEqual(complaints.first?.0, "образ.iso", "жалоба названа по файлу")
        XCTAssertEqual(complaints.first?.1, L("error.archiveCorruptedMessage"),
                       "причина — по-русски, а не английская строка ядра")
        XCTAssertFalse(vm.insideArchive, "в несуществующий архив не вошли")
        XCTAssertEqual(vm.currentPath, folder, "панель осталась в папке")
    }

    /// DMG под именем .iso идёт дорогой образов, а не архивов: панель отдаёт его системе
    /// (по умолчанию — DiskImageMounter) и не жалуется на «повреждённый архив».
    func test_dmgПодИменемISO_ИдётДорогойОбразов() async throws {
        let fake = folder + "/образ.iso"
        var udif = Data(repeating: 0xAB, count: 4096)
        udif.append(Data("koly".utf8))
        udif.append(Data(repeating: 0, count: 508))
        FileManager.default.createFile(atPath: fake, contents: udif)

        let vm = panel()
        var complaints: [String] = []
        vm.complainAboutArchive = { name, _ in complaints.append(name) }
        vm.loadDirectory(at: folder)
        try await подождать { vm.items.contains { $0.path == fake } }
        let item = try XCTUnwrap(vm.items.first { $0.path == fake })

        XCTAssertFalse(vm.open(item, diskImageRoad: .finder), "образ отдан системе, а не открыт как архив")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(vm.insideArchive)
        XCTAssertTrue(complaints.isEmpty, "жалобы на архив нет")
    }

    func test_настоящийISOОткрываетсяКакПапка() async throws {
        let iso = folder + "/образ.iso"
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        make.arguments = ["makehybrid", "-quiet", "-o", iso, folder + "/src", "-iso", "-joliet"]
        try make.run()
        make.waitUntilExit()
        XCTAssertEqual(make.terminationStatus, 0, "ISO собрался")

        let vm = panel()
        var complaints: [String] = []
        vm.complainAboutArchive = { name, _ in complaints.append(name) }
        vm.loadDirectory(at: folder)
        try await подождать { vm.items.contains { $0.path == iso } }
        let item = try XCTUnwrap(vm.items.first { $0.path == iso })
        XCTAssertTrue(vm.open(item))
        try await подождать { vm.insideArchive && vm.items.contains { $0.name.lowercased().hasPrefix("файл") } }
        XCTAssertTrue(vm.insideArchive, "настоящий ISO открылся")
        XCTAssertTrue(vm.items.contains { $0.name.lowercased().hasPrefix("файл") }, "внутри виден файл: \(vm.items.map(\.name))")
        XCTAssertTrue(complaints.isEmpty, "жалоб нет")
    }
}
