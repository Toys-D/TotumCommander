import Foundation
import XCTest

@testable import TotumComXLApp

/// Архив с паролем спрашивает его на каждой дороге, которой из него достают файл, — и архивы
/// чужих программ тоже: системный zip (ZipCrypto) и 7-Zip (ZipCrypto и AES-256).
///
/// Окно пароля здесь заменено ответом (`ArchivePasswords.askOverride`): проверка видит, что
/// программа СПРОСИЛА, и отвечает за человека.
@MainActor
final class ArchivePasswordRoadsTests: XCTestCase {
    private var ops: FileOperationsService!
    private var bridge: CoreBridgeService!
    private var root: String!
    private var asked: [String] = []
    private var archives: [String] = []
    private let secret = "секретные данные"

    override func setUp() async throws {
        try await super.setUp()
        bridge = CoreBridgeService()
        ops = FileOperationsService(bridgeService: bridge)
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-password-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        asked = []
        archives = []
    }

    override func tearDown() async throws {
        ArchivePasswords.askOverride = nil
        for archive in archives {
            ArchivePasswords.forget(for: archive)
            ArchivePasswords.allowPreviewAsk(for: archive)
        }
        try? FileManager.default.removeItem(atPath: root)
        try await super.tearDown()
    }

    private func path(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }

    /// Архив с паролем «secret», сделанный чужой программой; nil — такой программы нет.
    private func foreignArchive(_ name: String, tool: String, _ arguments: [String]) throws -> String? {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let file = path("тайна.txt")
        try secret.write(toFile: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments + [name, "тайна.txt"]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        archives.append(path(name))
        return path(name)
    }

    /// Архив системного zip — он есть на каждом Маке.
    private func systemZip() throws -> String {
        try XCTUnwrap(try foreignArchive("системный.zip", tool: "/usr/bin/zip", ["-q", "-P", "secret"]))
    }

    private func answer(_ password: String?) {
        ArchivePasswords.askOverride = { [weak self] name in
            self?.asked.append(name)
            return password
        }
    }

    /// Запись архива так, как её видит панель: путь — ровно как в оглавлении архива
    /// (системный zip пишет «й» разложенным на «и» и значок).
    private func entry(in archive: String) throws -> FileItem {
        let listed = try XCTUnwrap(try bridge.listArchiveEntries(archivePath: archive).first)
        return FileItem(path: listed.path, name: (listed.path as NSString).lastPathComponent,
                        fileExtension: ".txt", size: UInt64(listed.uncompressedSize),
                        isDirectory: false, isHidden: false, isSymlink: false,
                        permissions: "", dateModified: Date())
    }

    // MARK: - Ядро

    /// Без пароля ядро отказывает так, что программа узнаёт «нужен пароль», — и для всего
    /// архива, и для одного файла; с паролем отдаёт содержимое.
    func test_архивыЧужихПрограмм_ОтказБезПароляУзнаётся() throws {
        let made = [
            try foreignArchive("zip.zip", tool: "/usr/bin/zip", ["-q", "-P", "secret"]),
            try foreignArchive("7z-zipcrypto.zip", tool: "/opt/homebrew/bin/7z", ["a", "-psecret", "-tzip"]),
            try foreignArchive("7z-aes.zip", tool: "/opt/homebrew/bin/7z", ["a", "-psecret", "-tzip", "-mem=AES256"]),
        ].compactMap { $0 }
        XCTAssertFalse(made.isEmpty)
        for archive in made {
            let name = (archive as NSString).lastPathComponent
            let item = try entry(in: archive)
            let out = path("наружу-" + name)
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

            XCTAssertThrowsError(try bridge.extractArchiveAll(
                archivePath: archive, destinationPath: out, overwriteExisting: true,
                progress: { _, _, _, _, _, _ in })) { error in
                XCTAssertTrue(ArchivePasswords.isPasswordFailure(error), "\(name): \(error)")
            }
            XCTAssertThrowsError(try bridge.extractArchiveEntry(
                archivePath: archive, entryPath: item.path, destinationPath: out)) { error in
                XCTAssertTrue(ArchivePasswords.isPasswordFailure(error), "\(name), один файл: \(error)")
            }
            try bridge.extractArchiveAll(archivePath: archive, destinationPath: out,
                                         overwriteExisting: false, password: "secret",
                                         progress: { _, _, _, _, _, _ in })
            XCTAssertEqual(try String(contentsOfFile: (out as NSString).appendingPathComponent(item.path),
                                      encoding: .utf8), secret, name)
        }
    }

    // MARK: - Дороги программы

    /// F5 из архива: программа спрашивает пароль и копирует.
    func test_копированиеИзАрхива_СпрашиваетПароль() throws {
        let archive = try systemZip()
        let item = try entry(in: archive)
        let out = path("копия")
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        answer("secret")

        try ops.copyItemsFromArchive([item], archivePath: archive, to: out)

        XCTAssertEqual(asked.count, 1, "спросили один раз")
        XCTAssertEqual(try String(contentsOfFile: (out as NSString).appendingPathComponent(item.name),
                                  encoding: .utf8), secret)
    }

    /// F4 на файле в архиве с паролем: вопрос, а не ошибка.
    func test_правкаИзАрхива_СпрашиваетПароль() throws {
        let archive = try systemZip()
        let item = try entry(in: archive)
        answer("secret")

        let target = ops.prepareEditorTarget(for: item, archivePath: archive, insideArchive: true)

        XCTAssertEqual(asked.count, 1)
        let opened = try XCTUnwrap(target, "файл достали для правки")
        XCTAssertEqual(try String(contentsOfFile: opened.path, encoding: .utf8), secret)
    }

    /// Просмотр идёт за курсором, поэтому спрашивает один раз и не посреди отрисовки, а узнав
    /// пароль, сообщает об этом — и следующий взгляд на файл его уже видит.
    func test_просмотр_СпрашиваетОдинРаз_ИПотомВидитФайл() async throws {
        let archive = try systemZip()
        let item = try entry(in: archive)
        answer("secret")
        let learned = XCTNSNotificationExpectation(
            name: ArchivePasswords.learnedForPreviewNotification, object: archive)

        XCTAssertNil(ops.extractArchiveEntryForPreview(archivePath: archive, entryPath: item.path),
                     "без пароля файла нет")
        XCTAssertTrue(asked.isEmpty, "не посреди извлечения — чуть позже")
        await fulfillment(of: [learned], timeout: 2)

        XCTAssertEqual(asked.count, 1)
        let shown = try XCTUnwrap(ops.extractArchiveEntryForPreview(archivePath: archive,
                                                                     entryPath: item.path))
        XCTAssertEqual(try String(contentsOfFile: shown, encoding: .utf8), secret)
    }

    /// Отказался назвать пароль — курсор, идущий по архиву, окна больше не поднимает. Открыл
    /// просмотр сам (F3) — можно спросить снова.
    func test_просмотр_ПослеОтказаНеПристаёт() async throws {
        let archive = try systemZip()
        let item = try entry(in: archive)
        answer(nil)

        _ = ops.extractArchiveEntryForPreview(archivePath: archive, entryPath: item.path)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(asked.count, 1)

        for _ in 0..<3 {
            _ = ops.extractArchiveEntryForPreview(archivePath: archive, entryPath: item.path)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(asked.count, 1, "после отказа просмотр молчит")

        ArchivePasswords.allowPreviewAsk(for: archive)
        _ = ops.extractArchiveEntryForPreview(archivePath: archive, entryPath: item.path)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(asked.count, 2, "F3 разрешает спросить снова")
    }
}
