import XCTest
@testable import TotumComXLApp

/// Что берёт операция: выделенное, иначе файл под курсором — и настройка, добавляющая
/// файл под курсором к выделенным.
@MainActor
final class OperationTargetsSettingTests: XCTestCase {

    private var folder = ""
    private var saved: Any?

    override func setUpWithError() throws {
        saved = UserDefaults.standard.object(forKey: PanelViewModel.includeCursorInOperationsKey)
        UserDefaults.standard.removeObject(forKey: PanelViewModel.includeCursorInOperationsKey)
        folder = NSTemporaryDirectory() + "targets-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt"] {
            FileManager.default.createFile(atPath: folder + "/" + name, contents: Data(name.utf8))
        }
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: PanelViewModel.includeCursorInOperationsKey) }
        else { UserDefaults.standard.removeObject(forKey: PanelViewModel.includeCursorInOperationsKey) }
        try? FileManager.default.removeItem(atPath: folder)
        super.tearDown()
    }

    private func panel() async throws -> PanelViewModel {
        let id = UUID().uuidString
        let vm = PanelViewModel(service: CoreBridgeService(), initialPath: folder,
                                pathDefaultsKey: "panel.path.targets.\(id)",
                                viewModeDefaultsKey: "panel.mode.targets.\(id)",
                                showHiddenFiles: false)
        vm.loadDirectory(at: folder)
        let срок = Date().addingTimeInterval(3)
        while Date() < срок, !vm.items.contains(where: { $0.name == "c.txt" }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return vm
    }

    private func путь(_ name: String) -> String { folder + "/" + name }
    private func курсор(_ vm: PanelViewModel, на name: String) throws {
        vm.setCursor(index: try XCTUnwrap(vm.items.firstIndex { $0.name == name }))
    }

    func test_выключено_ТолькоВыделенное() async throws {
        let vm = try await panel()
        vm.selectedPaths = [путь("b.txt")]
        try курсор(vm, на: "c.txt")
        XCTAssertEqual(vm.operationTargets.map(\.name), ["b.txt"], "файл под курсором не в счёт")
    }

    func test_включено_ФайлПодКурсоромДобавляется() async throws {
        UserDefaults.standard.set(true, forKey: PanelViewModel.includeCursorInOperationsKey)
        let vm = try await panel()
        vm.selectedPaths = [путь("b.txt")]
        try курсор(vm, на: "c.txt")
        XCTAssertEqual(vm.operationTargets.map(\.name), ["b.txt", "c.txt"])
        try курсор(vm, на: "b.txt")
        XCTAssertEqual(vm.operationTargets.map(\.name), ["b.txt"], "уже выделенный не удваивается")
        try курсор(vm, на: "..")
        XCTAssertEqual(vm.operationTargets.map(\.name), ["b.txt"], "«..» не участвует никогда")
    }

    func test_безВыделения_ФайлПодКурсоромВЛюбомСлучае() async throws {
        let vm = try await panel()
        try курсор(vm, на: "c.txt")
        XCTAssertEqual(vm.operationTargets.map(\.name), ["c.txt"])
        UserDefaults.standard.set(true, forKey: PanelViewModel.includeCursorInOperationsKey)
        XCTAssertEqual(vm.operationTargets.map(\.name), ["c.txt"])
    }
}
