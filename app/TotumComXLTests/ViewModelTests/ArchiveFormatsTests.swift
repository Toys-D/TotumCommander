import XCTest

@testable import TotumComXLApp

/// Every creatable format, proven the only way that counts: create a real archive on disk, list
/// it back, extract it, and compare bytes. A format that appears in the picker but fails any of
/// those steps would be a button that manufactures broken files.
final class ArchiveFormatsTests: XCTestCase {

    // MARK: - Прогрев оглавления

    /// Когда читать оглавление архива заранее. Курсор, идущий стрелкой по сетевой папке,
    /// поднимал чтение по сети на каждом архиве, а пустые заглушки падали каждый раз заново.
    func test_прогревНаМедленномТомеТолькоПоЗадержке_аПустоеНеЧитается() {
        typealias S = PanelViewModel.PrewarmStrategy
        let mb: UInt64 = 1024 * 1024
        XCTAssertEqual(PanelViewModel.prewarmDecision(sizeBytes: 0, indexed: true, smallFolder: true, slowVolume: false),
                       S.onUserOpen, "пустой файл — читать нечего")
        XCTAssertEqual(PanelViewModel.prewarmDecision(sizeBytes: 3 * mb, indexed: true, smallFolder: true, slowVolume: true),
                       S.onCursorHover, "на сетевом томе — только когда курсор задержался")
        XCTAssertEqual(PanelViewModel.prewarmDecision(sizeBytes: 3 * mb, indexed: true, smallFolder: true, slowVolume: false),
                       S.immediate, "на быстром диске маленький архив — сразу, как и было")
        XCTAssertEqual(PanelViewModel.prewarmDecision(sizeBytes: 200 * mb, indexed: false, smallFolder: false, slowVolume: false),
                       S.onCursorHover)
        XCTAssertEqual(PanelViewModel.prewarmDecision(sizeBytes: 900 * mb, indexed: false, smallFolder: false, slowVolume: false),
                       S.onUserOpen)
    }


    private var bridge: CoreBridgeService!
    private var tmp: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        bridge = CoreBridgeService()
        tmp = (FileManager.default.temporaryDirectory.path as NSString)
            .appendingPathComponent("fcxl-formats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(atPath: tmp) }
        bridge = nil
        tmp = nil
        try super.tearDownWithError()
    }

    private func path(_ name: String) -> String {
        (tmp as NSString).appendingPathComponent(name)
    }

    /// Compressible on purpose: repeated text lets every codec actually shrink it, so a filter
    /// that silently failed to attach would show up as a suspiciously large archive too.
    private let payload = String(repeating: "Totum Commander проверяет формат. ", count: 2000)

    /// Create → list → extract → compare, for one format.
    private func roundTrip(_ format: ArchiveCreationFormat, extension ext: String,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let source = path("исходник.txt")
        try payload.write(toFile: source, atomically: true, encoding: .utf8)

        let archive = path("archive-\(format.rawValue.replacingOccurrences(of: ".", with: "_"))\(ext)")
        try bridge.createArchive(archivePath: archive, format: format, sources: [source],
                                 includeSubfolders: true, preservePaths: false,
                                 compressionLevel: 6)

        XCTAssertTrue(FileManager.default.fileExists(atPath: archive),
                      "\(format.rawValue): archive was not written", file: file, line: line)

        let entries = try bridge.listArchiveEntries(archivePath: archive)
        let fileEntries = entries.filter { !$0.isDirectory }
        XCTAssertEqual(fileEntries.count, 1,
                       "\(format.rawValue): expected exactly one file entry, got \(entries.map(\.path))",
                       file: file, line: line)
        guard let entry = fileEntries.first else { return }

        let out = path("out-\(format.rawValue.replacingOccurrences(of: ".", with: "_"))")
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try bridge.extractArchiveEntry(archivePath: archive, entryPath: entry.path,
                                       destinationPath: out)

        let extracted = try XCTUnwrap(
            FileManager.default.subpathsOfDirectory(atPath: out)
                .map { (out as NSString).appendingPathComponent($0) }
                .first { FileManager.default.fileExists(atPath: $0)
                    && !(try! URL(fileURLWithPath: $0).resourceValues(forKeys: [.isDirectoryKey])
                        .isDirectory ?? false) },
            "\(format.rawValue): nothing was extracted", file: file, line: line)
        XCTAssertEqual(try String(contentsOfFile: extracted, encoding: .utf8), payload,
                       "\(format.rawValue): extracted bytes differ from the original",
                       file: file, line: line)
    }

    // MARK: - The four that always existed (the regression net)

    func testZipRoundTrips() throws { try roundTrip(.zip, extension: ".zip") }
    func testTarRoundTrips() throws { try roundTrip(.tar, extension: ".tar") }
    func testTarGzRoundTrips() throws { try roundTrip(.tarGz, extension: ".tar.gz") }
    func testSevenZipRoundTrips() throws { try roundTrip(.sevenZip, extension: ".7z") }

    // MARK: - The six new ones

    func testTarBz2RoundTrips() throws { try roundTrip(.tarBz2, extension: ".tar.bz2") }
    func testTarXzRoundTrips() throws { try roundTrip(.tarXz, extension: ".tar.xz") }
    func testTarZstRoundTrips() throws { try roundTrip(.tarZst, extension: ".tar.zst") }
    func testTarLzRoundTrips() throws { try roundTrip(.tarLz, extension: ".tar.lz") }
    func testTarLz4RoundTrips() throws { try roundTrip(.tarLz4, extension: ".tar.lz4") }
    func testIsoRoundTrips() throws { try roundTrip(.iso, extension: ".iso") }

    // MARK: - The compressors actually compress

    /// A filter that silently failed to attach would still produce a valid archive — just an
    /// uncompressed one. 68 KB of repeated text must shrink by a lot under every real codec.
    func testEveryCompressorActuallyShrinksRepeatedText() throws {
        let source = path("big.txt")
        try payload.write(toFile: source, atomically: true, encoding: .utf8)
        let original = Int64(payload.utf8.count)

        let compressors: [(ArchiveCreationFormat, String)] = [
            (.tarGz, ".tar.gz"), (.tarBz2, ".tar.bz2"), (.tarXz, ".tar.xz"),
            (.tarZst, ".tar.zst"), (.tarLz, ".tar.lz"), (.tarLz4, ".tar.lz4"),
        ]
        for (format, ext) in compressors {
            let archive = path("shrink\(ext)")
            try? FileManager.default.removeItem(atPath: archive)
            try bridge.createArchive(archivePath: archive, format: format, sources: [source],
                                     includeSubfolders: true, preservePaths: false,
                                     compressionLevel: 6)
            let size = (try FileManager.default.attributesOfItem(atPath: archive)[.size] as? Int64) ?? 0
            XCTAssertLessThan(size, original / 2,
                              "\(format.rawValue): \(size) bytes from \(original) — the filter did not attach")
        }
    }

    // MARK: - DMG (hdiutil, not libarchive)

    /// Progress plumbing the DMG runner needs and nothing more.
    private final class NullReporter: OperationProgressReporter, @unchecked Sendable {
        nonisolated var isCancelled: Bool { false }
        nonisolated var isPaused: Bool { false }
        nonisolated var isSentToQueue: Bool { false }
        func update(currentFile: String, progress: Double, bytesDone: Int64, bytesTotal: Int64,
                    filesDone: Int, filesTotal: Int) {}
        func close() {}
    }

    /// The honest test for a disk image: mount it the way the user will and read the bytes back.
    func testDmgRoundTripsThroughMount() throws {
        let source = path("документ.txt")
        try payload.write(toFile: source, atomically: true, encoding: .utf8)
        let dmg = path("образ.dmg")

        let ops = FileOperationsService(bridgeService: bridge)
        try ops.createDMGImage(sources: [source], to: dmg,
                               compressionLevel: 6,
                               totalBytes: Int64(payload.utf8.count), totalFiles: 1,
                               reporter: NullReporter())
        XCTAssertTrue(FileManager.default.fileExists(atPath: dmg))

        let mountPoint = path("mnt")
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", "-quiet", "-nobrowse", "-readonly",
                            "-mountpoint", mountPoint, dmg]
        try attach.run()
        attach.waitUntilExit()
        XCTAssertEqual(attach.terminationStatus, 0, "the image did not mount")
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", "-quiet", mountPoint]
            try? detach.run()
            detach.waitUntilExit()
        }

        let mounted = (mountPoint as NSString).appendingPathComponent("документ.txt")
        XCTAssertEqual(try String(contentsOfFile: mounted, encoding: .utf8), payload,
                       "the mounted image does not contain the original bytes")
    }

    /// The panel's mount path: attach through OUR function (no Finder side effects), read the
    /// payload from the mount point, detach. This is exactly what Enter on a .dmg does.
    @MainActor
    func testDmgAttachesThroughOurMounterAndServesTheBytes() throws {
        let source = path("внутри образа.txt")
        try payload.write(toFile: source, atomically: true, encoding: .utf8)
        let dmg = path("монтируемый.dmg")

        let ops = FileOperationsService(bridgeService: bridge)
        try ops.createDMGImage(sources: [source], to: dmg,
                               compressionLevel: 1,
                               totalBytes: Int64(payload.utf8.count), totalFiles: 1,
                               reporter: NullReporter())

        let mountPoint = try ops.attachDiskImage(at: dmg)
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", "-quiet", mountPoint]
            try? detach.run()
            detach.waitUntilExit()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: mountPoint))
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: mountPoint)
            .first { $0.hasSuffix(".txt") })
        XCTAssertEqual(try String(contentsOfFile: (mountPoint as NSString)
            .appendingPathComponent(name), encoding: .utf8), payload)
    }

    /// Which image a mounted volume belongs to — read off hdiutil's plist, trailing slash or not.
    func testTheImageBehindAMountPointIsFound() throws {
        let plist: [String: Any] = ["images": [
            ["image-path": "/Users/x/один.dmg",
             "system-entities": [["dev-entry": "/dev/disk20"],
                                 ["dev-entry": "/dev/disk20s1", "mount-point": "/Volumes/Один"]]],
            ["image-path": "/Users/x/два.iso",
             "system-entities": [["dev-entry": "/dev/disk21"]]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(FileOperationsService.imagePath(forMountPoint: "/Volumes/Один/", info: data),
                       "/Users/x/один.dmg")
        XCTAssertNil(FileOperationsService.imagePath(forMountPoint: "/Volumes/Два", info: data),
                     "an image with no volume is nobody's mount point")
        XCTAssertNil(FileOperationsService.imagePath(forMountPoint: "/Volumes/Macintosh HD", info: data))
    }

    /// The chip's eject must take the IMAGE with it, not just the volume: an image left attached
    /// with no volume is one macOS refuses to open again (the field failure — Enter did nothing
    /// the second time). After our detach nothing of the image stays attached.
    @MainActor
    func testEjectingAnImageDetachesItWhole() throws {
        let source = path("внутри.txt")
        try payload.write(toFile: source, atomically: true, encoding: .utf8)
        let dmg = path("извлекаемый.dmg")
        let ops = FileOperationsService(bridgeService: bridge)
        try ops.createDMGImage(sources: [source], to: dmg, compressionLevel: 1,
                               totalBytes: Int64(payload.utf8.count), totalFiles: 1,
                               reporter: NullReporter())
        let mountPoint = try ops.attachDiskImage(at: dmg)
        defer { try? FileOperationsService.detachImage(at: dmg, force: true) }

        let info = FileOperationsService.hdiutilInfoPlist()
        XCTAssertEqual(FileOperationsService.imagePath(forMountPoint: mountPoint, info: info),
                       (dmg as NSString).standardizingPath)

        try FileOperationsService.detachImage(at: dmg)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mountPoint), "the volume is still there")
        XCTAssertTrue(FileOperationsService.attachedDevices(
            forImage: dmg, info: FileOperationsService.hdiutilInfoPlist()).isEmpty,
                      "the image stayed attached after the eject")
    }

    /// The field failure: the image is ALREADY attached — Quick Look attaches previews at a
    /// hidden mountpoint, and an ejected volume can leave the image attached with no volume —
    /// so a fresh attach dies with "resource busy". Enter must recover by detaching the stale
    /// attachment first. Reproduced with attach -nomount: attached, no volume.
    @MainActor
    func testAttachRecoversWhenTheImageIsAlreadyAttached() throws {
        let source = path("занятый.txt")
        try payload.write(toFile: source, atomically: true, encoding: .utf8)
        let dmg = path("занятый.dmg")
        let ops = FileOperationsService(bridgeService: bridge)
        try ops.createDMGImage(sources: [source], to: dmg,
                               compressionLevel: 1,
                               totalBytes: Int64(payload.utf8.count), totalFiles: 1,
                               reporter: NullReporter())

        let wedge = Process()
        wedge.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        wedge.arguments = ["attach", "-quiet", "-nomount", dmg]
        try wedge.run()
        wedge.waitUntilExit()
        XCTAssertEqual(wedge.terminationStatus, 0, "could not set up the busy state")

        let mountPoint = try ops.attachDiskImage(at: dmg)
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", "-quiet", mountPoint]
            try? detach.run()
            detach.waitUntilExit()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountPoint),
                      "the stale attachment was not recovered from")
    }

    /// Malformed hdiutil output must yield nil, never a crash or a made-up path.
    func testMountPointParserSurvivesGarbage() {
        XCTAssertNil(FileOperationsService.mountPoint(fromAttachPlist: Data()))
        XCTAssertNil(FileOperationsService.mountPoint(fromAttachPlist: Data("не plist".utf8)))
        let empty = try! PropertyListSerialization.data(
            fromPropertyList: ["system-entities": [[String: String]()]], format: .xml, options: 0)
        XCTAssertNil(FileOperationsService.mountPoint(fromAttachPlist: empty))
    }

    /// Exactly what the panel road on a .dmg does: vm.open → mount → navigate into the volume.
    /// Written because the wiring failed silently in the real app while every layer below it
    /// passed its tests. The road is passed explicitly — which one Enter takes is the user's
    /// setting (DiskImageOpenMode), and this test is about the mounting, not the setting.
    @MainActor
    func testEnterOnDmgMountsAndNavigatesThePanel() throws {
        let source = path("в образе.txt")
        try payload.write(toFile: source, atomically: true, encoding: .utf8)
        let dmg = path("панельный.dmg")
        let ops = FileOperationsService(bridgeService: bridge)
        try ops.createDMGImage(sources: [source], to: dmg,
                               compressionLevel: 1,
                               totalBytes: Int64(payload.utf8.count), totalFiles: 1,
                               reporter: NullReporter())

        let vm = PanelViewModel(
            service: bridge,
            initialPath: tmp,
            pathDefaultsKey: "test.dmg.\(UUID().uuidString)",
            viewModeDefaultsKey: "test.dmgmode.\(UUID().uuidString)",
            showHiddenFiles: true)
        let item = try XCTUnwrap(FileItem.fromPath(dmg))

        // The Finder road answers false on purpose: the caller then hands the image to the
        // system, which mounts it AND shows the image's own installer window.
        XCTAssertFalse(vm.open(item, diskImageRoad: .finder),
                       "the Finder road must let the image fall through to the system")

        XCTAssertTrue(vm.open(item, diskImageRoad: .panel),
                      "the panel road must claim the .dmg itself")

        // The mount is asynchronous; poll until the panel lands inside the volume.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !vm.currentPath.hasPrefix("/Volumes/") {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", "-quiet", vm.currentPath]
            try? detach.run()
            detach.waitUntilExit()
        }
        XCTAssertTrue(vm.currentPath.hasPrefix("/Volumes/"),
                      "panel never entered the mounted volume; error: \(vm.errorMessage ?? "none"), path: \(vm.currentPath)")
        XCTAssertTrue(vm.items.contains { $0.name.hasSuffix(".txt") },
                      "the volume's contents are not in the panel")
    }

    func testDmgNameSwapsWithOtherFormats() {
        XCTAssertEqual(PackDialogController.normalizedArchiveName("бэкап.dmg", format: .zip),
                       "бэкап.zip")
        XCTAssertEqual(PackDialogController.normalizedArchiveName("бэкап.tar.zst", format: .dmg),
                       "бэкап.dmg")
    }

    // MARK: - Nested archives

    /// zip-inside-zip: the mechanism nested browsing stands on — extract the inner entry to a
    /// temp file, open THAT as an archive, and find the payload intact one level down.
    @MainActor
    func testAnArchiveInsideAnArchiveRoundTrips() throws {
        let payloadFile = path("вложенный файл.txt")
        try payload.write(toFile: payloadFile, atomically: true, encoding: .utf8)

        let inner = path("внутренний.zip")
        try bridge.createArchive(archivePath: inner, format: .zip, sources: [payloadFile],
                                 includeSubfolders: true, preservePaths: false,
                                 compressionLevel: 6)
        let outer = path("внешний.tar.gz")
        try bridge.createArchive(archivePath: outer, format: .tarGz, sources: [inner],
                                 includeSubfolders: true, preservePaths: false,
                                 compressionLevel: 6)

        // Entry paths come FROM the listing, the way the panel does it: APFS stores Cyrillic
        // names in decomposed Unicode, and a source-code literal has different BYTES — Swift's
        // == forgives that, the C++ byte-wise lookup does not.
        let outerEntry = try XCTUnwrap(bridge.listArchiveEntries(archivePath: outer)
            .first { !$0.isDirectory }).path
        XCTAssertEqual(outerEntry, "внутренний.zip")

        let ops = FileOperationsService(bridgeService: bridge)
        let extracted = try ops.extractArchiveEntryToTemp(
            archivePath: outer, entryPath: outerEntry)
        defer { ops.cleanupArchivePreviewTemporaryDirectories() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted))

        // The extracted temp file must itself open as an archive with the original inside.
        let innerEntry = try XCTUnwrap(bridge.listArchiveEntries(archivePath: extracted)
            .first { !$0.isDirectory }).path
        XCTAssertEqual(innerEntry, "вложенный файл.txt")

        let out = path("из-вложенного")
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try bridge.extractArchiveEntry(archivePath: extracted, entryPath: innerEntry,
                                       destinationPath: out)
        let extractedInner = try XCTUnwrap(FileManager.default
            .contentsOfDirectory(atPath: out).first)
        XCTAssertEqual(try String(contentsOfFile: (out as NSString)
            .appendingPathComponent(extractedInner), encoding: .utf8), payload)
    }

    // MARK: - Naming

    func testFileExtensionsMatchTheFormat() {
        XCTAssertEqual(ArchiveFormat.tarZst.fileExtension, ".tar.zst")
        XCTAssertEqual(ArchiveFormat.tarBz2.fileExtension, ".tar.bz2")
        XCTAssertEqual(ArchiveFormat.tarXz.fileExtension, ".tar.xz")
        XCTAssertEqual(ArchiveFormat.tarLz.fileExtension, ".tar.lz")
        XCTAssertEqual(ArchiveFormat.tarLz4.fileExtension, ".tar.lz4")
        XCTAssertEqual(ArchiveFormat.iso.fileExtension, ".iso")
    }

    /// Switching format in the dialog must swap the whole compound extension, not stack a new
    /// one on top — "фото.tar.zst" chosen as ZIP becomes "фото.zip", never "фото.tar.zst.zip".
    func testSwitchingFormatsSwapsCompoundExtensions() {
        XCTAssertEqual(PackDialogController.normalizedArchiveName("фото.tar.zst", format: .zip),
                       "фото.zip")
        XCTAssertEqual(PackDialogController.normalizedArchiveName("фото.zip", format: .tarZst),
                       "фото.tar.zst")
        XCTAssertEqual(PackDialogController.normalizedArchiveName("фото.tar.lz4", format: .tarLz),
                       "фото.tar.lz")
        XCTAssertEqual(PackDialogController.normalizedArchiveName("backup.iso", format: .tarBz2),
                       "backup.tar.bz2")
    }

    /// ".lz" is a suffix of ".lz4": the longer one must win or every lz4 archive strips wrong.
    func testLz4IsNotMistakenForLzip() {
        XCTAssertEqual(PackDialogController.normalizedArchiveName("a.tar.lz4", format: .zip),
                       "a.zip")
    }

    /// The container formats hide the level knob; the codecs keep it.
    func testOnlyRealCompressorsOfferALevel() {
        XCTAssertFalse(ArchiveFormat.tar.supportsCompressionLevel)
        XCTAssertFalse(ArchiveFormat.iso.supportsCompressionLevel)
        for format in ArchiveFormat.allCases where ![.tar, .iso].contains(format) {
            XCTAssertTrue(format.supportsCompressionLevel, format.rawValue)
        }
    }
}

/// Password-protected ZIP, proven the only way that counts: create with a password, watch the
/// wrong password refused, read the bytes back with the right one.
final class PasswordArchiveTests: XCTestCase {

    private var bridge: CoreBridgeService!
    private var tmp: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        bridge = CoreBridgeService()
        tmp = (FileManager.default.temporaryDirectory.path as NSString)
            .appendingPathComponent("fcxl-pw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(atPath: tmp) }
        bridge = nil
        tmp = nil
        try super.tearDownWithError()
    }

    private func path(_ name: String) -> String {
        (tmp as NSString).appendingPathComponent(name)
    }

    private let secret = "содержимое, которое не должно читаться без пароля"

    private func makeEncryptedArchive() throws -> String {
        let source = path("тайна.txt")
        try secret.write(toFile: source, atomically: true, encoding: .utf8)
        let archive = path("сейф.zip")
        try bridge.createArchive(archivePath: archive, format: .zip, sources: [source],
                                 includeSubfolders: true, preservePaths: false,
                                 compressionLevel: 6, password: "пароль-123",
                                 progress: { _, _, _, _, _, _ in })
        return archive
    }

    func testTheFullCircle_createRefuseExtract() throws {
        let archive = try makeEncryptedArchive()

        // Without the password the CONTENT must not come out. (Listing may still work: ZIP
        // encrypts file bodies, not the table of contents — that is the format, not a bug.)
        let out = path("наружу")
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        XCTAssertThrowsError(try bridge.extractArchiveAll(
            archivePath: archive, destinationPath: out, overwriteExisting: true,
            progress: { _, _, _, _, _, _ in })) { error in
            // Not merely AN error — one the UI recognises as "ask for the password". minizip
            // reported a bare data error here, and the prompt never appeared.
            XCTAssertTrue(ArchivePasswords.isPasswordFailure(error),
                          "не распознано как запрос пароля: \(error)")
        }
        // The refusal may leave an empty stub behind; what must NEVER appear is the content.
        let leaked = (try? String(contentsOfFile: (out as NSString)
            .appendingPathComponent("тайна.txt"), encoding: .utf8)) ?? ""
        XCTAssertFalse(leaked.contains("не должно читаться"),
                       "the secret came out without the password")

        // A wrong password is the same refusal — and classifies the same way.
        XCTAssertThrowsError(try bridge.extractArchiveAll(
            archivePath: archive, destinationPath: out, overwriteExisting: true,
            password: "не тот", progress: { _, _, _, _, _, _ in })) { error in
            XCTAssertTrue(ArchivePasswords.isPasswordFailure(error),
                          "неверный пароль не распознан как запрос пароля: \(error)")
        }

        // The right one opens it, byte for byte.
        try bridge.extractArchiveAll(archivePath: archive, destinationPath: out,
                                     overwriteExisting: true, password: "пароль-123",
                                     progress: { _, _, _, _, _, _ in })
        XCTAssertEqual(try String(contentsOfFile: (out as NSString)
            .appendingPathComponent("тайна.txt"), encoding: .utf8), secret)
    }

    /// The bytes on disk must not carry the plain text — that is what "encrypted" means.
    func testThePlainTextIsNotInTheArchiveBytes() throws {
        let archive = try makeEncryptedArchive()
        let data = try Data(contentsOf: URL(fileURLWithPath: archive))
        XCTAssertFalse(data.range(of: Data(secret.utf8)) != nil,
                       "the file's bytes are readable straight out of the archive")
        // AES-encrypted zip entries carry the AES extra field id 0x9901.
        XCTAssertTrue(data.range(of: Data([0x01, 0x99])) != nil,
                      "no WinZip AES marker — the entry is not AES-encrypted")
    }

    /// Copying OUT of a protected archive goes through extractArchiveEntry, which nobody hands
    /// a password to. The session store is its source: remember once, and every road works.
    func testTheRememberedPasswordOpensTheEntryRoad() throws {
        let archive = try makeEncryptedArchive()
        let out = path("изнутри")
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

        // Without the password in the session: refused, and recognisably about the password.
        ArchivePasswords.forget(for: archive)
        XCTAssertThrowsError(try bridge.extractArchiveEntry(
            archivePath: archive, entryPath: "тайна.txt", destinationPath: out)) { error in
            XCTAssertTrue(ArchivePasswords.isPasswordFailure(error))
        }

        // Remembered once — the same call succeeds with no password argument anywhere.
        ArchivePasswords.remember("пароль-123", for: archive)
        defer { ArchivePasswords.forget(for: archive) }
        try bridge.extractArchiveEntry(archivePath: archive, entryPath: "тайна.txt",
                                       destinationPath: out)
        XCTAssertEqual(try String(contentsOfFile: (out as NSString)
            .appendingPathComponent("тайна.txt"), encoding: .utf8), secret)
    }

    /// A password on a format that cannot encrypt must REFUSE, not quietly write an
    /// unprotected archive the user believes is safe.
    func testAFormatThatCannotEncryptRefusesThePassword() throws {
        let source = path("файл.txt")
        try "данные".write(toFile: source, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try bridge.createArchive(
            archivePath: path("сейф.7z"), format: .sevenZip, sources: [source],
            includeSubfolders: true, preservePaths: false, compressionLevel: 5,
            password: "пароль", progress: { _, _, _, _, _, _ in }))
        XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: path("сейф.7z")),
                     "the refused archive must not be left on disk")
    }
}

/// The encrypted DMG, proven by macOS's own tools: hdiutil built it, hdiutil vouches that it
/// is encrypted, and the plain text is not in the image's bytes.
final class EncryptedDMGTests: XCTestCase {

    /// A reporter that reports to nobody — the DMG builder needs one to run headless.
    private final class SilentReporter: OperationProgressReporter {
        var isCancelled: Bool { false }
        var isPaused: Bool { false }
        var isSentToQueue: Bool { false }
        @MainActor func update(currentFile: String, progress: Double,
                               bytesDone: Int64, bytesTotal: Int64,
                               filesDone: Int, filesTotal: Int) {}
        @MainActor func close() {}
    }

    func testTheImageIsEncryptedAndKeepsItsSecret() throws {
        let ops = FileOperationsService(bridgeService: CoreBridgeService())
        let tmp = (FileManager.default.temporaryDirectory.path as NSString)
            .appendingPathComponent("fcxl-dmg-\(UUID().uuidString)")
        let source = (tmp as NSString).appendingPathComponent("данные")
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let secret = "строка, которой не должно быть видно в образе"
        try secret.write(toFile: (source as NSString).appendingPathComponent("тайна.txt"),
                         atomically: true, encoding: .utf8)

        let dmg = (tmp as NSString).appendingPathComponent("сейф.dmg")
        try ops.createDMGImage(sources: [source], to: dmg, compressionLevel: 6,
                               totalBytes: 1, totalFiles: 1, password: "пароль-дмг",
                               reporter: SilentReporter())

        // macOS's own verdict: `hdiutil isencrypted` answers for the image itself.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        probe.arguments = ["isencrypted", dmg]
        let out = Pipe()
        probe.standardOutput = out
        probe.standardError = out
        try probe.run()
        probe.waitUntilExit()
        let verdict = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        XCTAssertTrue(verdict.contains("encrypted: YES"),
                      "hdiutil не считает образ зашифрованным: \(verdict)")

        let bytes = try Data(contentsOf: URL(fileURLWithPath: dmg))
        XCTAssertNil(bytes.range(of: Data(secret.utf8)),
                     "исходный текст читается прямо из байтов образа")
        XCTAssertNil(bytes.range(of: Data("тайна".utf8)),
                     "имя файла читается прямо из байтов образа — DMG обещает прятать и имена")
    }
}
