import XCTest
@testable import TotumComXLApp

/// «Свободно» в строке состояния панели: где спрашивать место.
///
/// Внутри архива путь панели — «…/архив.zip::/папка», такого пути нет ни на одном диске:
/// statfs по нему не отвечал, и строка показывала «Свободно: 0 КБ». То же на полке, в Корзине
/// и в «Сети» — у них путь вымышленный (/STACK, /TRASH, /NETWORK).
@MainActor
final class StatusBarFreeSpaceTests: XCTestCase {

    private var folder = ""
    /// Из чего собираются архивы — отдельно от папки панели, чтобы «внутри» было видно только
    /// в архиве.
    private var source: String { folder + "-исходники" }

    override func setUpWithError() throws {
        folder = NSTemporaryDirectory() + "свободно-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: source + "/внутри", withIntermediateDirectories: true)
        try "текст".write(toFile: source + "/внутри/файл.txt", atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: folder)
        try? FileManager.default.removeItem(atPath: source)
        super.tearDown()
    }

    /// Архив из исходников — в папку панели (или в исходники, чтобы вложить его в другой).
    private func zip(_ name: String, _ entries: [String], intoSource: Bool = false) throws -> String {
        let output = (intoSource ? source : folder) + "/" + name
        let tool = "/usr/bin/zip"
        guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("нет \(tool)") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-qr", output] + entries
        process.currentDirectoryURL = URL(fileURLWithPath: source)
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zip не собрал \(name)")
        return output
    }

    private func panel() -> PanelViewModel {
        let id = UUID().uuidString
        return PanelViewModel(service: CoreBridgeService(), initialPath: folder,
                              pathDefaultsKey: "panel.path.свободно.\(id)",
                              viewModeDefaultsKey: "panel.mode.свободно.\(id)",
                              showHiddenFiles: true)
    }

    private func wait(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !condition() {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func enter(_ name: String, in vm: PanelViewModel, expecting expected: String) async throws {
        try await wait { vm.items.contains { $0.name == name } }
        let item = try XCTUnwrap(vm.items.first { $0.name == name }, "нет «\(name)»: \(vm.items.map(\.name))")
        XCTAssertTrue(vm.open(item), "«\(name)» открылся")
        try await wait { vm.items.contains { $0.name == expected } }
        XCTAssertTrue(vm.items.contains { $0.name == expected }, "внутри «\(name)» нет «\(expected)»")
    }

    /// Внутри архива — место тома, на котором лежит сам архив: его показывает и полоса дисков.
    func test_вАрхивеСвободноМестоТомаАрхива() async throws {
        let archive = try zip("архив.zip", ["внутри"])
        let vm = panel()
        vm.loadDirectory(at: folder)
        XCTAssertEqual(vm.freeSpacePath, folder, "в обычной папке — сама папка")

        try await enter("архив.zip", in: vm, expecting: "внутри")
        XCTAssertTrue(vm.insideArchive)
        XCTAssertTrue(vm.currentPath.contains("::"), "путь панели — не путь на диске: \(vm.currentPath)")
        XCTAssertEqual(vm.freeSpacePath, archive)

        try await enter("внутри", in: vm, expecting: "файл.txt")
        XCTAssertEqual(vm.freeSpacePath, archive, "и в папке внутри архива")
    }

    /// Во вложенный архив входят через распаковку во временную папку — место всё равно
    /// внешнего архива, того, что лежит у человека на диске.
    func test_воВложенномАрхивеМестоВнешнего() async throws {
        _ = try zip("вложенный.zip", ["внутри"], intoSource: true)
        let outer = try zip("внешний.zip", ["вложенный.zip"])
        let vm = panel()
        vm.loadDirectory(at: folder)
        try await enter("внешний.zip", in: vm, expecting: "вложенный.zip")
        try await enter("вложенный.zip", in: vm, expecting: "внутри")
        XCTAssertTrue(vm.isNestedArchive)
        XCTAssertEqual(vm.freeSpacePath, outer)
    }

    /// Места без файловой системы — строка «Свободно» не показывается, как в облаке.
    func test_вВымышленныхМестахМестоНеПоказывается() {
        for place in [TrashService.trashRoot, DropStackStore.stackRoot, NetworkBrowserService.networkRoot,
                      NetworkBrowserService.networkRoot + "/сервер"] {
            XCTAssertNil(PanelViewModel.freeSpacePath(currentPath: place, remote: false, archive: nil), place)
        }
        XCTAssertNil(PanelViewModel.freeSpacePath(currentPath: "/папка", remote: true, archive: nil), "облако")
        XCTAssertEqual(PanelViewModel.freeSpacePath(currentPath: "/Users", remote: false, archive: nil), "/Users")
    }
}
