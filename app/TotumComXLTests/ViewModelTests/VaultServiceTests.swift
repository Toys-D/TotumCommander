import Foundation
import XCTest

@testable import TotumComXLApp

/// The vault, end to end against the real hdiutil: created, unlocked, written into, locked,
/// and refused to the wrong password. Slow for a unit test (~seconds), and worth every one of
/// them — a vault that quietly fails to encrypt is worse than none.
final class VaultServiceTests: XCTestCase {

    private var root: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Whatever a failed test left mounted must not survive it.
        if let vault = vaultPath, VaultService.isUnlocked(vault) {
            try? VaultService.lock(vault)
        }
        try? FileManager.default.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    private var vaultPath: String? {
        didSet {}
    }

    func testTheWholeLifeOfAVault() throws {
        let vault = (root as NSString).appendingPathComponent("Сейф.sparsebundle")
        vaultPath = vault
        try VaultService.create(at: vault, sizeMB: 20, password: "тайна-123")

        // A sparsebundle is a FOLDER of bands, and it starts small: the declared size is a
        // ceiling, not a cost.
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "sparsebundle — это пакет, не файл")
        XCTAssertFalse(VaultService.isUnlocked(vault), "создано запертым... точнее, отцепленным")
        XCTAssertFalse(VaultService.isMountedFast(vault), "быстрый ответ согласен: заперто")

        // Unlock, write, see it there.
        let mountPoint = try VaultService.unlock(vault, password: "тайна-123")
        XCTAssertTrue(VaultService.isUnlocked(vault))
        XCTAssertTrue(VaultService.isMountedFast(vault), "быстрый ответ согласен: открыто")
        XCTAssertEqual(VaultService.mountPoint(ofVault: vault), mountPoint)
        let secret = (mountPoint as NSString).appendingPathComponent("записка.txt")
        try "самое дорогое".write(toFile: secret, atomically: true, encoding: .utf8)

        // Lock: the volume goes, the bundle stays, the content is unreachable.
        try VaultService.lock(vault)
        XCTAssertFalse(VaultService.isUnlocked(vault))
        XCTAssertFalse(VaultService.isMountedFast(vault), "быстрый ответ согласен: снова заперто")
        XCTAssertFalse(FileManager.default.fileExists(atPath: secret))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault))

        // And it comes back with the right password, contents intact.
        let again = try VaultService.unlock(vault, password: "тайна-123")
        XCTAssertEqual(try String(contentsOfFile:
            (again as NSString).appendingPathComponent("записка.txt"), encoding: .utf8),
            "самое дорогое")
        try VaultService.lock(vault)
    }

    /// The wrong password is REFUSED, and named as such — that is the entire promise.
    func testTheWrongPasswordIsRefused() throws {
        let vault = (root as NSString).appendingPathComponent("Чужой.sparsebundle")
        vaultPath = vault
        try VaultService.create(at: vault, sizeMB: 20, password: "правильный")
        XCTAssertThrowsError(try VaultService.unlock(vault, password: "неправильный")) { error in
            guard case VaultService.VaultError.wrongPassword = error else {
                return XCTFail("не распознано как неверный пароль: \(error)")
            }
        }
        XCTAssertFalse(VaultService.isUnlocked(vault))
    }

    func testLockingALockedVaultSaysSo() throws {
        let vault = (root as NSString).appendingPathComponent("Спит.sparsebundle")
        vaultPath = vault
        try VaultService.create(at: vault, sizeMB: 20, password: "п")
        XCTAssertThrowsError(try VaultService.lock(vault)) { error in
            guard case VaultService.VaultError.notMounted = error else {
                return XCTFail("не тот отказ: \(error)")
            }
        }
    }

    /// The attach answer is a plist; the reader has to find the mount point in it.
    /// Locking from the main thread stalled the window for ~14 s: diskarbitrationd was waiting
    /// for THIS app's answer while the app waited for hdiutil. The awaited lock must leave the
    /// main thread free — a main-actor job queued before it runs during the lock, not after.
    @MainActor
    func test_запираниеНеДержитГлавныйПоток() async throws {
        let vault = (root as NSString).appendingPathComponent("свободный.sparsebundle")
        vaultPath = vault
        try VaultService.create(at: vault, sizeMB: 20, password: "п")
        _ = try VaultService.unlock(vault, password: "п")

        let queuedBeforeLock = Task { @MainActor in Date() }
        try await VaultService.lockOffMain(vault)
        let lockDone = Date()
        let ranAt = await queuedBeforeLock.value
        XCTAssertLessThan(ranAt, lockDone, "главный поток простоял всё время hdiutil detach")
        XCTAssertFalse(VaultService.isUnlocked(vault))
    }

    func testTheAttachAnswerIsRead() {
        let sample = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>system-entities</key><array>
        <dict><key>content-hint</key><string>GUID_partition_scheme</string></dict>
        <dict><key>mount-point</key><string>/Volumes/Сейф</string></dict>
        </array></dict></plist>
        """
        XCTAssertEqual(VaultService.mountPoint(inAttachPlist: sample), "/Volumes/Сейф")
        XCTAssertNil(VaultService.mountPoint(inAttachPlist: "не plist"))
    }

    /// The password round-trip in the keychain — the storing half. (The reading half shows a
    /// Touch ID sheet and cannot run headless; what CAN be checked is that the item is really
    /// there to read, which is exactly what silently failed before: SecItemAdd with an
    /// access-control gate answered -34018 on this signing and stored nothing.)
    func testThePasswordIsActuallyStored() {
        let path = "/тест/Проба-\(UUID().uuidString).sparsebundle"
        defer { VaultService.forgetPassword(for: path) }
        XCTAssertFalse(VaultService.hasStoredPassword(for: path))
        XCTAssertTrue(VaultService.rememberPassword("тайна", for: path),
                      "пароль ДОЛЖЕН лечь в связку — раньше это молча не выходило")
        XCTAssertTrue(VaultService.hasStoredPassword(for: path))
        XCTAssertTrue(VaultService.forgetPassword(for: path))
        XCTAssertFalse(VaultService.hasStoredPassword(for: path))
    }

    /// Enter on a vault must NEVER walk into the raw sparsebundle as a folder: the person
    /// would stand among the encrypted band files believing the vault was open. The vault
    /// branch has to fire before the plain-directory branch — this held the regression.
    @MainActor
    func testEnterOnAVaultDoesNotWalkIntoTheBundle() throws {
        let vault = (root as NSString).appendingPathComponent("Дверь.sparsebundle")
        vaultPath = vault
        try VaultService.create(at: vault, sizeMB: 20, password: "п")

        let vm = PanelViewModel(
            service: CoreBridgeService(),
            initialPath: root,
            pathDefaultsKey: "vault.test.\(UUID().uuidString)",
            viewModeDefaultsKey: "vault.mode.\(UUID().uuidString)",
            showHiddenFiles: true)
        vm.loadDirectory(at: root)

        let item = FileItem(path: vault, name: "Дверь.sparsebundle",
                            fileExtension: "sparsebundle", size: 0, isDirectory: true,
                            isHidden: false, isSymlink: false, permissions: "drwxr-xr-x",
                            dateModified: Date())
        // The mount-in-flight guard keeps the unlock flow from reaching its password window,
        // which a headless test could never dismiss. What is under test is the ROUTING: the
        // vault road claims the open (true = handled, not passed to the system) and the panel
        // does not land inside the bundle itself.
        vm.launchingFilePath = "занято"
        XCTAssertTrue(vm.open(item))
        XCTAssertFalse(vm.currentPath.hasPrefix(vault),
                       "панель вошла в сам пакет: \(vm.currentPath)")
    }

    func testWhatCountsAsAVault() {
        XCTAssertTrue(VaultService.isVault("/дом/Сейф.sparsebundle"))
        XCTAssertTrue(VaultService.isVault("/дом/Сейф.SPARSEBUNDLE"))
        XCTAssertFalse(VaultService.isVault("/дом/образ.dmg"))
        XCTAssertFalse(VaultService.isVault("/дом/папка"))
    }
}
