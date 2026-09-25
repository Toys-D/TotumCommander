import AppKit
import Foundation
import LocalAuthentication
import Security

/// An encrypted vault: a sparsebundle disk image with AES-256 over everything — contents and
/// names alike — that opens as an ordinary folder and locks back into one opaque file.
///
/// A sparsebundle rather than a plain image on purpose: it takes disk space as it fills, not
/// the whole declared size up front, and it grows in 8 MB bands, which is also what makes it
/// friendly to Time Machine — a changed file changes a band, not the entire image.
enum VaultService {

    enum VaultError: LocalizedError {
        case creationFailed(String)
        case wrongPassword
        case mountFailed(String)
        case notMounted
        case ejectFailed(String)

        var errorDescription: String? {
            switch self {
            case .creationFailed(let why): return String(format: L("vault.error.create"), why)
            case .wrongPassword: return L("vault.error.password")
            case .mountFailed(let why): return String(format: L("vault.error.mount"), why)
            case .notMounted: return L("vault.error.notMounted")
            case .ejectFailed(let why): return String(format: L("vault.error.eject"), why)
            }
        }
    }

    static let fileExtension = "sparsebundle"

    static func isVault(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == fileExtension
    }

    /// Is the vault's volume mounted RIGHT NOW — answered without hdiutil.
    ///
    /// Cheap enough for every list row: hdiutil holds an flock on the bundle's `lock` file for
    /// as long as the volume is attached (measured, not read anywhere), so one non-blocking
    /// flock attempt tells the truth — including for vaults mounted before this app started.
    static func isMountedFast(_ path: String) -> Bool {
        let lockFile = (path as NSString).appendingPathComponent("lock")
        let fd = Darwin.open(lockFile, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    // MARK: - hdiutil

    /// Run hdiutil, feeding the passphrase by STDIN — on the command line it would sit in `ps`
    /// output for every process on the machine to read.
    @discardableResult
    private static func hdiutil(_ arguments: [String], password: String? = nil) throws
        -> (status: Int32, output: String, errorText: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        // hdiutil answers in the SYSTEM language — "Ошибка аутентификации" on a Russian Mac —
        // and telling a wrong password apart from a broken image means reading that answer.
        // Pinned to C so the words are always the same ones. (Caught by the test, not by
        // reasoning: the English check simply never matched here.)
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "C"
        environment["LC_ALL"] = "C"
        process.environment = environment
        if let password {
            let stdin = Pipe()
            process.standardInput = stdin
            // No trailing newline: hdiutil takes every byte as part of the passphrase, and an
            // invisible "\n" would make a password nobody can ever retype.
            stdin.fileHandleForWriting.write(Data(password.utf8))
            stdin.fileHandleForWriting.closeFile()
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        let errorText = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, output, errorText)
    }

    // MARK: - The vault's life

    /// Make a new vault. `sizeMB` is the CEILING, not the cost: a sparsebundle takes disk as
    /// it fills. Answers the path of the bundle.
    @discardableResult
    static func create(at path: String, sizeMB: Int, password: String) throws -> String {
        let volumeName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let result = try hdiutil([
            "create",
            "-size", "\(max(sizeMB, 10))m",
            "-type", "SPARSEBUNDLE",
            "-fs", "APFS",
            "-volname", volumeName.isEmpty ? "Vault" : volumeName,
            "-encryption", "AES-256", "-stdinpass",
            path,
        ], password: password)
        guard result.status == 0 else {
            throw VaultError.creationFailed(result.errorText.trimmingCharacters(
                in: .whitespacesAndNewlines))
        }
        return path
    }

    /// Open the vault. Answers the mount point — the folder its contents now live at.
    @discardableResult
    static func unlock(_ path: String, password: String) throws -> String {
        let result = try hdiutil([
            "attach", path, "-stdinpass", "-plist",
            // No browsing side effects: the panel shows the mount point itself.
            "-nobrowse",
        ], password: password)
        guard result.status == 0 else {
            // Telling a wrong passphrase apart from a broken image WITHOUT reading hdiutil's
            // words: it speaks the system language ("Ошибка аутентификации" on this very Mac),
            // the exit code is 1 either way, and LANG does not reach it — all three measured.
            // What answers machine-readably is `isencrypted`: an image it confirms as a valid
            // encrypted one failed to attach for the one reason the person can do something
            // about — the password.
            if isEncryptedImage(path) {
                throw VaultError.wrongPassword
            }
            throw VaultError.mountFailed(result.errorText.trimmingCharacters(
                in: .whitespacesAndNewlines))
        }
        guard let mountPoint = mountPoint(inAttachPlist: result.output) else {
            throw VaultError.mountFailed("no mount point in hdiutil output")
        }
        return mountPoint
    }

    /// Is this a valid encrypted disk image? Asked with `-plist`, so the answer is a boolean
    /// and not a sentence in whatever language the system speaks.
    static func isEncryptedImage(_ path: String) -> Bool {
        guard let result = try? hdiutil(["isencrypted", path, "-plist"]), result.status == 0,
              let data = result.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any] else { return false }
        return (root["encrypted"] as? Bool) == true
    }

    /// Where an `hdiutil attach -plist` answer says the volume landed.
    static func mountPoint(inAttachPlist output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            if let point = entity["mount-point"] as? String { return point }
        }
        return nil
    }

    /// Lock the vault: eject the volume. The image file stays where it was, opaque again.
    ///
    /// `force` tears the volume away even while something inside is open — the open program
    /// loses its file mid-sentence, so forcing is only ever done after the person said to.
    static func lock(_ path: String, force: Bool = false) throws {
        guard let mounted = mountPoint(ofVault: path) else { throw VaultError.notMounted }
        var arguments = ["detach", mounted]
        if force { arguments.append("-force") }
        let result = try hdiutil(arguments)
        guard result.status == 0 else {
            // "Resource busy" — something still holds a file open in there. Say so rather
            // than force-eject over an open document.
            throw VaultError.ejectFailed(result.errorText.trimmingCharacters(
                in: .whitespacesAndNewlines))
        }
    }

    /// The same lock, AWAITED off the main thread — the only way to call it from there.
    ///
    /// On the main thread it stalls for ~14 s, and the log says why: hdiutil asks
    /// diskarbitrationd to unmount, diskarbitrationd asks every program watching volumes —
    /// this one included, through NSWorkspace — whether it minds, and that question lands on
    /// the main run loop, which is busy waiting for hdiutil. "TotumComXL not responding" before
    /// every such unmount, then the timeout. Off the main thread the same unmount takes 60 ms.
    static func lockOffMain(_ path: String, force: Bool = false) async throws {
        try await Task.detached(priority: .userInitiated) { try lock(path, force: force) }.value
    }

    /// The programs holding files open inside the vault's volume — the names for the "will
    /// not lock" dialog. Naming the holder turns "какой-то файл" into a door the person can
    /// actually go and close.
    static func holders(ofVault path: String) -> [String] {
        guard let mounted = mountPoint(ofVault: path) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // -Fc: machine-readable, command names only. +D walks the volume — small for a vault.
        process.arguments = ["-Fc", "+D", mounted]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let names = String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .filter { $0.hasPrefix("c") }
            .map { String($0.dropFirst()) } ?? []
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    /// Ask the programs holding files under `mountPoint` to CLOSE those documents — for real,
    /// by Apple Events, the way "посмотри в интернете" suggested and the docs confirm: apps
    /// with the standard scripting suite (Preview among them) honour
    /// `close every document whose path begins with …`. `saving no` because this runs only
    /// after the person confirmed losing unsaved edits; without it a save sheet would hang the
    /// script. Programs that ignore Apple Events simply fail here and are handled by the
    /// force-detach that follows. The first use per program shows the system's own
    /// "wants to control" permission ask — that is macOS, not us.
    static func closeDocuments(under mountPoint: String, holders: [String]) {
        // Only ordinary windowed programs — lsof also names daemons and helper services, and
        // an Apple Event addressed to those would do nothing useful at best.
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }
        for name in holders {
            guard let app = running.first(where: {
                $0.localizedName == name || $0.executableURL?.lastPathComponent == name
            }), let bundleID = app.bundleIdentifier, !app.isTerminated else { continue }
            // The `running of application` guard is the load-bearing line: a bare `tell
            // application id` LAUNCHES the program when it is not running — and Preview
            // quietly quits on its own once its windows are gone, so without the guard a
            // vault lock could resurrect it with an empty open-file dialog. Asking for the
            // `running` property is documented NOT to launch.
            let script = """
            if running of application id "\(bundleID)" then
                with timeout of 5 seconds
                    tell application id "\(bundleID)"
                        close (every document whose path begins with "\(mountPoint)") saving no
                    end tell
                end timeout
            end if
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    }

    /// Mount points of the vaults opened THIS session, keyed by the volume path. What lets a
    /// vault's volume keep a ".." leading back to the folder its bundle lies in — an ordinary
    /// disk's root is a top, but a vault was entered FROM somewhere.
    private static var openedMounts: [String: String] = [:]
    private static let mountsLock = NSLock()

    static func noteOpened(mountPoint: String, vault path: String) {
        mountsLock.lock()
        openedMounts[(mountPoint as NSString).standardizingPath] =
            (path as NSString).standardizingPath
        mountsLock.unlock()
    }

    /// The vault whose volume this is — checked in memory first, then against hdiutil, so a
    /// vault mounted before the app started still answers.
    static func vaultPath(forMountPoint mountPoint: String) -> String? {
        let wanted = (mountPoint as NSString).standardizingPath
        mountsLock.lock()
        let remembered = openedMounts[wanted]
        mountsLock.unlock()
        if let remembered { return remembered }

        guard let result = try? hdiutil(["info", "-plist"]), result.status == 0,
              let data = result.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return nil }
        for image in images {
            guard let imagePath = image["image-path"] as? String, isVault(imagePath),
                  let entities = image["system-entities"] as? [[String: Any]] else { continue }
            for entity in entities where (entity["mount-point"] as? String)
                .map({ ($0 as NSString).standardizingPath }) == wanted {
                let standardized = (imagePath as NSString).standardizingPath
                mountsLock.lock()
                openedMounts[wanted] = standardized
                mountsLock.unlock()
                return standardized
            }
        }
        return nil
    }

    /// The mount point of this vault, or nil while it is locked.
    static func mountPoint(ofVault path: String) -> String? {
        guard let result = try? hdiutil(["info", "-plist"]), result.status == 0,
              let data = result.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return nil }
        let wanted = (path as NSString).standardizingPath
        for image in images {
            guard let imagePath = (image["image-path"] as? String).map({
                ($0 as NSString).standardizingPath
            }), imagePath == wanted,
                let entities = image["system-entities"] as? [[String: Any]] else { continue }
            for entity in entities {
                if let point = entity["mount-point"] as? String { return point }
            }
        }
        return nil
    }

    static func isUnlocked(_ path: String) -> Bool { mountPoint(ofVault: path) != nil }

    // MARK: - The password, kept behind the fingerprint

    private static let keychainService = "com.fcxl.vault"

    /// Put the vault's password into the keychain.
    ///
    /// A PLAIN item, deliberately. The pretty way — an item with an access-control gate the
    /// keychain itself enforces — needs the data-protection keychain, and that needs signing
    /// entitlements this app does not carry: measured, SecItemAdd answered -34018 and stored
    /// NOTHING, which is why a vault opened without ever asking for a finger. The fingerprint
    /// gate is ours instead, in `storedPassword`, asked explicitly before the read.
    @discardableResult
    static func rememberPassword(_ password: String, for path: String) -> Bool {
        forgetPassword(for: path)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: (path as NSString).standardizingPath,
            kSecValueData as String: Data(password.utf8),
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Read the password back — AFTER the person proves themselves. The system shows its own
    /// Touch ID sheet with `reason`; where there is no sensor, it falls back to the login
    /// password. No proof, no password, and the caller falls through to the typed one.
    ///
    /// Called from a background queue: the wait on the sheet is a semaphore, not a runloop.
    static func storedPassword(for path: String, reason: String) -> String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return nil
        }
        let gate = DispatchSemaphore(value: 0)
        var proved = false
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            proved = ok
            gate.signal()
        }
        gate.wait()
        guard proved else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: (path as NSString).standardizingPath,
            kSecReturnData as String: true,
        ]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
              let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Vaults whose maker said "no Touch ID" — the choice itself, remembered. Without it a
    /// successfully typed password was auto-saved into the keychain, and the vault its owner
    /// wanted opened by the TYPED password alone started opening by finger.
    private static let declinedKey = "fcxl.vault.touchIDDeclined"

    static func touchIDDeclined(for path: String) -> Bool {
        let list = UserDefaults.standard.stringArray(forKey: declinedKey) ?? []
        return list.contains((path as NSString).standardizingPath)
    }

    static func setTouchIDDeclined(_ declined: Bool, for path: String) {
        let standardized = (path as NSString).standardizingPath
        var list = UserDefaults.standard.stringArray(forKey: declinedKey) ?? []
        list.removeAll { $0 == standardized }
        if declined { list.append(standardized) }
        UserDefaults.standard.set(list, forKey: declinedKey)
    }

    /// Is a password remembered at all — a plain existence check, no prompt.
    static func hasStoredPassword(for path: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: (path as NSString).standardizingPath,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func forgetPassword(for path: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: (path as NSString).standardizingPath,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
