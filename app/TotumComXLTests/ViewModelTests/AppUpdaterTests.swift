import AppKit
import XCTest
@testable import TotumComXLApp

/// Обновление в один щелчок: разбор выпуска, сверка суммы, кто может обновляться на месте
/// и сама подмена — на временных папках, настоящие «Программы» и Корзина не трогаются.
final class AppUpdaterTests: XCTestCase {

    private var root = URL(fileURLWithPath: "")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-update-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private let answer = Data("""
    {"tag_name": "v1.3.1", "html_url": "https://github.com/Toys-D/TotumCommander/releases/tag/v1.3.1",
     "assets": [
       {"name": "SHA256SUMS.txt", "browser_download_url": "https://github.com/Toys-D/TotumCommander/releases/download/v1.3.1/SHA256SUMS.txt"},
       {"name": "Totum-Commander-1.3.1.dmg", "browser_download_url": "https://github.com/Toys-D/TotumCommander/releases/download/v1.3.1/Totum-Commander-1.3.1.dmg"}
     ]}
    """.utf8)

    // MARK: - Ответ GitHub

    func test_образИСуммыИзОтвета() throws {
        let assets = try XCTUnwrap(UpdatePlan.assets(from: answer))
        XCTAssertEqual(assets.dmgName, "Totum-Commander-1.3.1.dmg")
        XCTAssertEqual(assets.dmg.lastPathComponent, "Totum-Commander-1.3.1.dmg")
        XCTAssertEqual(assets.sums.lastPathComponent, "SHA256SUMS.txt")
    }

    /// Без файла сумм установки не будет: образ без проверки не ставится.
    func test_безФайлаСуммНетУстановки() {
        let noSums = Data("""
        {"tag_name": "v1.3.1", "assets": [{"name": "Totum-Commander-1.3.1.dmg",
          "browser_download_url": "https://example.com/a.dmg"}]}
        """.utf8)
        XCTAssertNil(UpdatePlan.assets(from: noSums))
        XCTAssertNil(UpdatePlan.assets(from: Data("мусор".utf8)))
    }

    func test_суммаИзФайлаСумм() {
        let sums = """
        ad3279a1caf8b46292a30eb94fc16ebefb4dc543bf9dbbbfbc6eed6d54387d74  Totum-Commander-1.3.1.dmg
        00000000000000000000000000000000000000000000000000000000000000ff *Other.dmg
        """
        XCTAssertEqual(UpdatePlan.expectedHash(in: sums, for: "Totum-Commander-1.3.1.dmg"),
                       "ad3279a1caf8b46292a30eb94fc16ebefb4dc543bf9dbbbfbc6eed6d54387d74")
        XCTAssertEqual(UpdatePlan.expectedHash(in: sums, for: "Other.dmg"),
                       "00000000000000000000000000000000000000000000000000000000000000ff",
                       "звёздочка двоичного режима не мешает")
        XCTAssertNil(UpdatePlan.expectedHash(in: sums, for: "Nope.dmg"))
    }

    func test_sha256Файла() throws {
        let file = root.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try UpdatePlan.sha256(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Кому можно на месте

    private func fakeBundle(named name: String, in dir: URL, payload: String) throws -> URL {
        let bundle = dir.appendingPathComponent(name)
        let macos = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try Data(payload.utf8).write(to: macos.appendingPathComponent("TotumComXL"))
        return bundle
    }

    func test_препятствия() throws {
        let ok = try fakeBundle(named: "Totum Commander.app", in: root, payload: "old")
        XCTAssertNil(UpdatePlan.obstacle(bundleURL: ok), "свой бандл в своей папке — можно")
        XCTAssertEqual(UpdatePlan.obstacle(bundleURL: root.appendingPathComponent("TotumComXL")),
                       .notABundle, "голый исполняемый файл — нельзя")
        let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Totum Commander.app")
        XCTAssertEqual(UpdatePlan.obstacle(bundleURL: translocated), .translocated)

        // Чужая папка: без права записи в родителя подмена невозможна.
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        let inside = try fakeBundle(named: "Totum Commander.app", in: locked, payload: "old")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertEqual(UpdatePlan.obstacle(bundleURL: inside), .notWritable)
    }

    func test_временныеИменаРядомСБандлом() {
        let bundle = URL(fileURLWithPath: "/Applications/Totum Commander.app")
        let staging = UpdatePlan.stagingURLs(for: bundle, tag: "1.3.1")
        XCTAssertEqual(staging.incoming.deletingLastPathComponent().path, "/Applications")
        XCTAssertEqual(staging.retired.deletingLastPathComponent().path, "/Applications")
        XCTAssertTrue(staging.incoming.lastPathComponent.hasPrefix("."), "скрытые, пока идёт подмена")
        XCTAssertTrue(staging.incoming.lastPathComponent.contains("1.3.1"))
        XCTAssertNotEqual(staging.incoming, staging.retired)
    }

    // MARK: - Подмена

    /// Новая копия встаёт на место старой, старая уходит, следов рядом не остаётся.
    func test_подменаБандла() throws {
        let apps = root.appendingPathComponent("Программы", isDirectory: true)
        let old = try fakeBundle(named: "Totum Commander.app", in: apps, payload: "old")
        let fresh = try fakeBundle(named: "Totum Commander.app", in: root.appendingPathComponent("image"), payload: "new")
        try UpdateSteps.install(from: fresh, over: old, tag: "1.3.1", retire: .delete)
        let payload = try String(contentsOf: old.appendingPathComponent("Contents/MacOS/TotumComXL"), encoding: .utf8)
        XCTAssertEqual(payload, "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: apps.path)
        XCTAssertEqual(leftovers, ["Totum Commander.app"], "ни входящей, ни отставленной копии")
    }

    /// Копия без исполняемого файла на место не встаёт — старая остаётся как была.
    func test_битаяКопияНеСтавится() throws {
        let apps = root.appendingPathComponent("Программы", isDirectory: true)
        let old = try fakeBundle(named: "Totum Commander.app", in: apps, payload: "old")
        let broken = root.appendingPathComponent("image/Totum Commander.app", isDirectory: true)
        try FileManager.default.createDirectory(at: broken.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try UpdateSteps.install(from: broken, over: old, tag: "x", retire: .delete))
        let payload = try String(contentsOf: old.appendingPathComponent("Contents/MacOS/TotumComXL"), encoding: .utf8)
        XCTAssertEqual(payload, "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["Totum Commander.app"])
    }

    /// Настоящий образ выпуска: FCXL_UPDATE_DMG=путь к .dmg. Подключает, копирует поверх
    /// поддельной старой копии во временной папке, отключает. По умолчанию пропускается.
    func test_настоящийОбраз() throws {
        guard let path = ProcessInfo.processInfo.environment["FCXL_UPDATE_DMG"] else {
            throw XCTSkip("FCXL_UPDATE_DMG не задан")
        }
        let apps = root.appendingPathComponent("Программы", isDirectory: true)
        let old = try fakeBundle(named: "Totum Commander.app", in: apps, payload: "old")
        let mount = try UpdateSteps.mount(dmg: URL(fileURLWithPath: path), at: root.appendingPathComponent("mnt"))
        defer { UpdateSteps.detach(mount) }
        let app = try XCTUnwrap(UpdateSteps.appInside(mount))
        try UpdateSteps.install(from: app, over: old, tag: "проверка", retire: .delete)
        let plist = old.appendingPathComponent("Contents/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist))
        print("INSTALLED version=\(info["CFBundleShortVersionString"] ?? "?") build=\(info["CFBundleVersion"] ?? "?")")
        XCTAssertNotNil(info["CFBundleShortVersionString"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: old.appendingPathComponent("Contents/MacOS/TotumComXL").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["Totum Commander.app"])
    }
}
