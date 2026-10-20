import Compression
import XCTest
@testable import TotumComXLApp

/// Пакет установки (.pkg) — архив, в который входят пунктом «Открыть пакет» (Enter запускает
/// установщик): оглавление, вложенный пакет, Payload и Scripts. Payload бывает cpio в gzip (так пишет pkgbuild) и в pbzx (так пишут Apple и
/// Tailscale) — в оба можно войти. Писать в пакет нельзя: он потерял бы подпись.
@MainActor
final class InstallerPackageTests: XCTestCase {

    private var folder = ""

    override func setUpWithError() throws {
        folder = NSTemporaryDirectory() + "пакет-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: folder)
        super.tearDown()
    }

    // MARK: - Сборка пакетов

    @discardableResult
    private func run(_ tool: String, _ arguments: [String], in directory: String? = nil) throws -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("нет \(tool)") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Что пакет установит: приложение с одним файлом внутри.
    private func makeRoot() throws -> String {
        let root = folder + "/root"
        let contents = root + "/Applications/Тест.app/Contents"
        try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
        try "привет".write(toFile: contents + "/readme.txt", atomically: true, encoding: .utf8)
        return root
    }

    /// Пакет так, как его делает разработчик: pkgbuild и productbuild.
    private func makeDistributionPackage() throws -> String {
        let root = try makeRoot()
        let scripts = folder + "/scripts"
        try FileManager.default.createDirectory(atPath: scripts, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(toFile: scripts + "/postinstall", atomically: true, encoding: .utf8)
        let component = folder + "/comp.pkg"
        let product = folder + "/Установка.pkg"
        guard try run("/usr/bin/pkgbuild", ["--quiet", "--root", root, "--scripts", scripts,
                                            "--identifier", "com.fcxl.test", "--version", "1.0",
                                            "--install-location", "/", component]) == 0,
              try run("/usr/bin/productbuild", ["--quiet", "--package", component, product]) == 0
        else { throw XCTSkip("pkgbuild не собрал пакет") }
        try FileManager.default.removeItem(atPath: component)
        return product
    }

    /// cpio того же содержимого — то, что лежит внутри Payload.
    private func makeCPIO() throws -> Data {
        let root = try makeRoot()
        let cpio = folder + "/payload.cpio"
        guard try run("/usr/bin/bsdtar", ["--format", "odc", "-cf", cpio, "-C", root, "."]) == 0 else {
            throw XCTSkip("bsdtar не собрал cpio")
        }
        defer { try? FileManager.default.removeItem(atPath: cpio) }
        return try Data(contentsOf: URL(fileURLWithPath: cpio))
    }

    /// pbzx: первые куски сжаты xz, последний — как есть, без сжатия.
    private func pbzx(_ payload: Data, chunk: Int) -> Data {
        func be64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        var out = Data("pbzx".utf8) + be64(1 << 24)
        var offset = 0
        while offset < payload.count {
            let piece = payload[offset ..< min(offset + chunk, payload.count)]
            offset += piece.count
            let isLast = offset >= payload.count
            var body = Data(piece)
            if !isLast {
                var encoded = [UInt8](repeating: 0, count: piece.count + 4096)
                let size = piece.withUnsafeBytes { raw in
                    compression_encode_buffer(&encoded, encoded.count,
                                              raw.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                                              nil, COMPRESSION_LZMA)
                }
                body = Data(encoded.prefix(size))
            }
            out += be64(isLast ? 0 : 1 << 24) + be64(UInt64(body.count)) + body
        }
        return out
    }

    /// Пакет, собранный xar вручную, с Payload в pbzx.
    private func makePBZXPackage() throws -> String {
        let staging = folder + "/xar"
        try FileManager.default.createDirectory(atPath: staging + "/comp.pkg", withIntermediateDirectories: true)
        try pbzx(try makeCPIO(), chunk: 512).write(to: URL(fileURLWithPath: staging + "/comp.pkg/Payload"))
        try "<installer-gui-script/>".write(toFile: staging + "/Distribution", atomically: true, encoding: .utf8)
        let package = folder + "/Apple.pkg"
        guard try run("/usr/bin/xar", ["-cf", package, "comp.pkg", "Distribution"], in: staging) == 0 else {
            throw XCTSkip("xar не собрал пакет")
        }
        try FileManager.default.removeItem(atPath: staging)
        return package
    }

    // MARK: - Панель

    private func panel() -> PanelViewModel {
        let id = UUID().uuidString
        return PanelViewModel(service: CoreBridgeService(),
                              initialPath: NSHomeDirectory(),
                              pathDefaultsKey: "panel.path.пакет.\(id)",
                              viewModeDefaultsKey: "panel.mode.пакет.\(id)",
                              showHiddenFiles: true)
    }

    private func wait(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !condition() {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Войти в строку с этим именем и дождаться строки `expected`.
    private func enter(_ name: String, in vm: PanelViewModel, expecting expected: String,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let item = try XCTUnwrap(vm.items.first { $0.name == name }, "нет «\(name)»", file: file, line: line)
        XCTAssertTrue(vm.open(item), "«\(name)» открылся", file: file, line: line)
        try await wait { vm.items.contains { $0.name == expected } }
        XCTAssertTrue(vm.items.contains { $0.name == expected },
                      "внутри «\(name)» есть «\(expected)»: \(vm.items.map(\.name))", file: file, line: line)
    }

    /// Войти в пакет так, как это делает пункт «Открыть пакет».
    private func openPackage(_ package: String, in vm: PanelViewModel) async throws {
        vm.loadDirectory(at: folder)
        try await wait { vm.items.contains { $0.path == package } }
        let item = try XCTUnwrap(vm.items.first { $0.path == package })
        XCTAssertTrue(vm.canEnterPackage(item))
        vm.enterPackage(item)
        try await wait { vm.items.contains { $0.name == "comp.pkg" } }
    }

    /// Вход до самого файла: пакет → вложенный пакет → Payload → приложение → файл.
    private func walkToTheFile(of package: String) async throws -> PanelViewModel {
        let vm = panel()
        try await openPackage(package, in: vm)
        XCTAssertTrue(vm.insideArchive)
        XCTAssertTrue(vm.items.contains { $0.name == "Distribution" })
        try await enter("comp.pkg", in: vm, expecting: "Payload")
        try await enter("Payload", in: vm, expecting: "Applications")
        XCTAssertFalse(vm.items.contains { $0.name == "." }, "корень cpio — не строка: \(vm.items.map { "\($0.name)|\($0.path)" })")
        try await enter("Applications", in: vm, expecting: "Тест.app")
        try await enter("Тест.app", in: vm, expecting: "Contents")
        try await enter("Contents", in: vm, expecting: "readme.txt")
        return vm
    }

    func test_вПакетВходятКакВАрхив_ИВPayload() async throws {
        let package = try makeDistributionPackage()
        _ = try await walkToTheFile(of: package)
    }

    /// Enter пакет не открывает: он уходит системе — установщику, как в Finder.
    func test_EnterОтдаётПакетУстановщику() async throws {
        let package = try makeDistributionPackage()
        let vm = panel()
        vm.loadDirectory(at: folder)
        try await wait { vm.items.contains { $0.path == package } }
        let item = try XCTUnwrap(vm.items.first { $0.path == package })
        XCTAssertFalse(vm.open(item), "Enter — системе, а не внутрь")
        XCTAssertFalse(vm.insideArchive)
    }

    func test_вPayloadВУпаковкеPbzxТожеВходят() async throws {
        let package = try makePBZXPackage()
        _ = try await walkToTheFile(of: package)
    }

    /// Scripts — тоже архив: в нём сценарии установки.
    func test_вScriptsВходят() async throws {
        let package = try makeDistributionPackage()
        let vm = panel()
        try await openPackage(package, in: vm)
        try await enter("comp.pkg", in: vm, expecting: "Scripts")
        try await enter("Scripts", in: vm, expecting: "postinstall")
    }

    // MARK: - pbzx

    func test_pbzxРазворачиваетсяБайтВБайт() throws {
        let cpio = try makeCPIO()
        let packed = folder + "/Payload"
        try pbzx(cpio, chunk: 700).write(to: URL(fileURLWithPath: packed))
        XCTAssertTrue(PackagePayload.isPBZX(atPath: packed))

        let out = folder + "/Payload.cpio"
        try PackagePayload.unpack(atPath: packed, to: out)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out)), cpio)
        let entries = try CoreBridgeService().listArchiveEntries(archivePath: out).map(\.path)
        XCTAssertTrue(entries.contains { $0.hasSuffix("Contents/readme.txt") }, "\(entries)")
    }

    /// Оборванный pbzx — ошибка, и недоразвёрнутого файла не остаётся.
    func test_оборванныйPbzx_Ошибка() throws {
        let whole = pbzx(try makeCPIO(), chunk: 700)
        let packed = folder + "/Payload"
        try whole.prefix(whole.count - 100).write(to: URL(fileURLWithPath: packed))
        let out = folder + "/Payload.cpio"
        XCTAssertThrowsError(try PackagePayload.unpack(atPath: packed, to: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out))
    }

    // MARK: - Только чтение

    func test_вПакетНельзяДописать() throws {
        let package = try makeDistributionPackage()
        let before = try Data(contentsOf: URL(fileURLWithPath: package))
        let extra = folder + "/лишний.txt"
        try "x".write(toFile: extra, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CoreBridgeService().addFilesToArchive(
            archivePath: package, filePaths: [extra], basePath: folder))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: package)), before, "пакет не тронут")
    }

    func test_пакетомСчитаетсяФайлНоНеПапка() {
        func item(_ path: String, directory: Bool) -> FileItem {
            FileItem(path: path, name: (path as NSString).lastPathComponent, fileExtension: ".pkg",
                     size: 0, isDirectory: directory, isHidden: false, isSymlink: false,
                     permissions: "", dateModified: Date())
        }
        XCTAssertTrue(InstallerPackage.isFlatPackage(item("/tmp/Установка.pkg", directory: false)))
        XCTAssertTrue(InstallerPackage.isFlatPackage(item("/tmp/СТАРЫЙ.PKG", directory: false)))
        XCTAssertFalse(InstallerPackage.isFlatPackage(item("/tmp/Бандл.pkg", directory: true)),
                       "пакет-папка открывается как папка")
        XCTAssertTrue(InstallerPackage.isPackageArchiveEntry(name: "Payload"))
        XCTAssertFalse(InstallerPackage.isPackageArchiveEntry(name: "Bom"))
    }
}
