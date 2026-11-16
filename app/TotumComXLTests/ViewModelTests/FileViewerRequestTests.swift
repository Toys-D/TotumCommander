import AppKit
import XCTest

@testable import TotumComXLApp

/// Totum Commander вместо Finder: когда программа просит «показать в Finder», а в настройке
/// `NSFileViewer` стоит наш идентификатор, система шлёт нам «открыть документ» (odoc) с самим
/// путём — папки или файла. Папка открывается в активной панели, файл показывается в своей
/// папке с курсором на нём и ничем не запускается.
@MainActor
final class FileViewerRequestTests: XCTestCase {

    private func makeFolder() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-fileviewer-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/внутри", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dir + "/Программа.app/Contents", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/файл.txt"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/внутри/вложенный.txt"))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    func test_папка_открываетсяСама() throws {
        let dir = try makeFolder()
        XCTAssertEqual(FileViewerRequest.target(for: URL(fileURLWithPath: dir + "/внутри")),
                       .init(folder: dir + "/внутри", cursor: nil))
    }

    func test_файл_егоПапкаИКурсорНаНём() throws {
        let dir = try makeFolder()
        XCTAssertEqual(FileViewerRequest.target(for: URL(fileURLWithPath: dir + "/файл.txt")),
                       .init(folder: dir, cursor: dir + "/файл.txt"))
    }

    /// Программа — папка-пакет: «показать в Finder» выделяет её, а не входит внутрь.
    func test_программа_показываетсяКакФайл() throws {
        let dir = try makeFolder()
        XCTAssertEqual(FileViewerRequest.target(for: URL(fileURLWithPath: dir + "/Программа.app")),
                       .init(folder: dir, cursor: dir + "/Программа.app"))
    }

    func test_несуществующееИНеФайловое_ничего() throws {
        let dir = try makeFolder()
        XCTAssertNil(FileViewerRequest.target(for: URL(fileURLWithPath: dir + "/нет-такого")))
        XCTAssertNil(FileViewerRequest.target(for: URL(string: "https://example.com/x")!))
    }

    /// Из нескольких путей берётся первый существующий.
    func test_изНесколькихПервыйЖивой() throws {
        let dir = try makeFolder()
        let urls = [URL(fileURLWithPath: dir + "/нет-такого"), URL(fileURLWithPath: dir + "/файл.txt")]
        XCTAssertEqual(FileViewerRequest.target(for: urls), .init(folder: dir, cursor: dir + "/файл.txt"))
    }

    /// Панель: файл из другой папки — панель уходит туда и ставит курсор на него.
    func test_панельПереходитИСтавитКурсор() async throws {
        let dir = try makeFolder()
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: dir,
                                pathDefaultsKey: "panel.path.fileviewer.\(id)",
                                viewModeDefaultsKey: "panel.mode.fileviewer.\(id)",
                                showHiddenFiles: false)
        addTeardownBlock { [weak vm] in MainActor.assumeIsolated { vm?.stopWatching() } }
        vm.loadDirectory(at: dir)
        await settle { vm.items.contains { $0.name == "файл.txt" } }

        let target = try XCTUnwrap(FileViewerRequest.target(
            for: URL(fileURLWithPath: dir + "/внутри/вложенный.txt")))
        FileViewerRequest.show(target, in: vm)
        await settle { vm.cursorItem?.name == "вложенный.txt" }
        XCTAssertEqual(vm.currentPath, dir + "/внутри")
        XCTAssertEqual(vm.cursorItem?.name, "вложенный.txt")
    }

    /// Info.plist объявляет папки — ролью «просмотр» и рангом «запасной», чтобы не перехватывать
    /// у Finder открытие обычных папок двойным щелчком и вовсе не трогать файлы.
    func test_InfoPlistОбъявляетПапки() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("scripts/document-types.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil)
                                  as? [String: Any])
        let types = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertEqual(types.count, 1)
        XCTAssertEqual(types[0]["LSItemContentTypes"] as? [String], ["public.folder"])
        XCTAssertEqual(types[0]["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertEqual(types[0]["LSHandlerRank"] as? String, "Alternate")
        let script = try String(contentsOf: root.appendingPathComponent("scripts/launch.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("Merge scripts/document-types.plist"),
                      "launch.sh вливает объявление в Info.plist")
    }

    private func settle(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}
