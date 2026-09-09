import XCTest
@testable import TotumComXLApp

/// Выход из архива: «..» в корне архива возвращает в папку, где он лежит.
///
/// Настоящий случай: человек вошёл в zip и не смог выйти. Защита «местное чтение не
/// затирает панель в облаке или архиве» отбрасывала и НАМЕРЕННЫЙ выход: признак
/// «внутри архива» снимался только после этой защиты, то есть никогда.
@MainActor
final class ArchiveExitTests: XCTestCase {

    private var folder = ""
    private var archive = ""

    override func setUpWithError() throws {
        folder = NSTemporaryDirectory() + "архив-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for name in ["урок 1.txt", "урок 2.txt"] {
            FileManager.default.createFile(atPath: folder + "/" + name, contents: Data("текст".utf8))
        }
        archive = folder + "/уроки.zip"
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = URL(fileURLWithPath: folder)
        zip.arguments = ["-q", "-j", archive, folder + "/урок 1.txt", folder + "/урок 2.txt"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0, "zip собрался")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: folder)
        super.tearDown()
    }

    private func panel() -> PanelViewModel {
        let id = UUID().uuidString
        return PanelViewModel(service: CoreBridgeService(),
                              initialPath: NSHomeDirectory(),
                              pathDefaultsKey: "panel.path.архив.\(id)",
                              viewModeDefaultsKey: "panel.mode.архив.\(id)",
                              showHiddenFiles: false)
    }

    private func подождать(_ условие: @escaping () -> Bool) async throws {
        let срок = Date().addingTimeInterval(3)
        while Date() < срок, !условие() {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func test_изКорняАрхиваМожноВыйтиНаверх() async throws {
        let vm = panel()
        vm.loadDirectory(at: folder)
        try await подождать { vm.currentPath == self.folder && vm.items.contains { $0.path == self.archive } }
        let zip = try XCTUnwrap(vm.items.first { $0.path == archive })
        XCTAssertTrue(vm.open(zip), "архив открылся")
        try await подождать { vm.insideArchive && vm.items.contains { $0.name == "урок 1.txt" } }
        XCTAssertTrue(vm.insideArchive, "панель внутри архива")

        vm.goUp()
        try await подождать { !vm.insideArchive && vm.currentPath == self.folder }
        XCTAssertFalse(vm.insideArchive, "«..» в корне архива выводит из него")
        XCTAssertEqual(vm.currentPath, folder)
        XCTAssertEqual(vm.cursorItem?.path, archive, "курсор остался на архиве")
    }
}
