import Foundation
import XCTest

@testable import TotumComXLApp

/// Finding what a program left behind. The dangerous part is the matching: a mistake here does
/// not lose a setting, it puts someone else's folder in the Trash. These tests exist mostly to
/// pin down what must NOT match.
final class AppUninstallerTests: XCTestCase {

    // MARK: - The names a program answers to

    func test_bothTheIdentifierAndTheNameAreUsed() {
        let names = AppUninstaller.names(bundleID: "com.maker.app", appName: "Моя Программа.app")
        XCTAssertTrue(names.contains("com.maker.app"))
        XCTAssertTrue(names.contains("Моя Программа"))
        // Plus the composed vendor+display forms — see the test about Media Encoder.
        XCTAssertTrue(names.contains("com.maker.Моя Программа"), "\(names)")
        XCTAssertEqual(AppUninstaller.names(bundleID: nil, appName: "Sublime Text.app"),
                       ["Sublime Text"])
        XCTAssertTrue(AppUninstaller.names(bundleID: "", appName: "").isEmpty)
    }

    // MARK: - What belongs to the program

    func test_exactNameMatches_withOrWithoutExtension() {
        let names = ["com.maker.app", "Моя Программа"]
        XCTAssertTrue(AppUninstaller.matches(entry: "com.maker.app.plist", names: names, contains: false))
        XCTAssertTrue(AppUninstaller.matches(entry: "com.maker.app", names: names, contains: false))
        XCTAssertTrue(AppUninstaller.matches(entry: "Моя Программа", names: names, contains: false))
        XCTAssertTrue(AppUninstaller.matches(entry: "COM.MAKER.APP", names: names, contains: false),
                      "case must not decide whether a folder is removed")
    }

    /// The whole reason this is not a substring search: a program called "Mail" must never
    /// claim "MailChimp", and "Notes" must never claim "Notesmith".
    func test_aLongerNameIsNeverSwallowed() {
        XCTAssertFalse(AppUninstaller.matches(entry: "MailChimp", names: ["Mail"], contains: false))
        XCTAssertFalse(AppUninstaller.matches(entry: "MailChimp", names: ["Mail"], contains: true))
        XCTAssertFalse(AppUninstaller.matches(entry: "com.maker.apparel.plist",
                                              names: ["com.maker.app"], contains: true))
        XCTAssertFalse(AppUninstaller.matches(entry: "Notesmith", names: ["Notes"], contains: true))
    }

    /// Helpers and login items hang extra words off the identifier, and those DO belong —
    /// but only when the extra part starts on a separator.
    func test_helpersAndLoginItemsBelongToTheirProgram() {
        let names = ["com.maker.app"]
        XCTAssertTrue(AppUninstaller.matches(entry: "com.maker.app.helper.plist",
                                             names: names, contains: true))
        XCTAssertTrue(AppUninstaller.matches(entry: "com.maker.app-updater.plist",
                                             names: names, contains: true))
        XCTAssertFalse(AppUninstaller.matches(entry: "com.maker.app.helper.plist",
                                              names: names, contains: false),
                       "a place that demands an exact name must not take a longer one")
    }

    /// Makers write the same identifier differently in different folders. Adobe's After
    /// Effects is "com.adobe.AfterEffects" in Caches and "com.Adobe.After Effects" in
    /// Preferences — a space and a capital apart. Both are the same program.
    func test_spacesInTheIdentifierDoNotHideAFile() {
        let names = ["com.adobe.AfterEffects", "Adobe After Effects 2025"]
        XCTAssertTrue(AppUninstaller.matches(entry: "com.Adobe.After Effects.plist",
                                             names: names, contains: true))
        XCTAssertTrue(AppUninstaller.matches(entry: "com.Adobe.After Effects.25.1.plist",
                                             names: names, contains: true),
                      "a version is just another tail after a separator")
        XCTAssertTrue(AppUninstaller.matches(entry: "com.adobe.aftereffects",
                                             names: names, contains: false))
    }

    /// Squeezing spaces must not open the door to a stranger.
    func test_squeezingSpacesStillDoesNotSwallowALongerName() {
        XCTAssertFalse(AppUninstaller.matches(entry: "Mail Chimp", names: ["Mail"], contains: true))
        XCTAssertFalse(AppUninstaller.matches(entry: "MailChimp", names: ["Mail"], contains: true))
        XCTAssertEqual(AppUninstaller.squeezed("com.Adobe.After Effects"), "com.adobe.aftereffects")
    }

    /// The version lives in the program's name but not in every folder it leaves behind:
    /// "Adobe After Effects 2025" files its startup scripts under "Adobe After Effects".
    func test_theNameWithoutTheVersionIsAlsoAName() {
        XCTAssertEqual(AppUninstaller.names(bundleID: nil, appName: "Adobe After Effects 2025.app"),
                       ["Adobe After Effects 2025", "Adobe After Effects"])
        XCTAssertEqual(AppUninstaller.names(bundleID: nil, appName: "Keka.app"), ["Keka"],
                       "a one-word name has no version to drop")
        XCTAssertEqual(AppUninstaller.names(bundleID: nil, appName: "Pixelmator Pro.app"),
                       ["Pixelmator Pro"], "a word is not a version")
    }

    /// Inside the MAKER's own folder the bare product name counts — "Caches/Adobe/After
    /// Effects". On its own that name would be far too eager, which is why the pair is only
    /// ever used one level in.
    func test_makerAndProductComeFromTheIdentifier() {
        let pair = AppUninstaller.makerAndProduct(bundleID: "com.adobe.AfterEffects")
        XCTAssertEqual(pair?.maker, "adobe")
        XCTAssertEqual(pair?.product, "AfterEffects")
        XCTAssertNil(AppUninstaller.makerAndProduct(bundleID: "com.maker.app"),
                     "a generic ending would claim every folder called App")
        XCTAssertNil(AppUninstaller.makerAndProduct(bundleID: "single"))
        XCTAssertNil(AppUninstaller.makerAndProduct(bundleID: nil))
    }

    /// The company is the part after the reverse-DNS root, NOT the second-to-last part. Those
    /// are the same thing for com.adobe.AfterEffects and nonsense for
    /// com.adobe.ame.application.25, where the old reading answered "application" — and with
    /// the wrong company, three of Media Encoder's settings files stayed invisible.
    func test_theCompanyIsReadFromTheRightPlace() {
        XCTAssertEqual(AppUninstaller.maker(bundleID: "com.adobe.AfterEffects"), "adobe")
        XCTAssertEqual(AppUninstaller.maker(bundleID: "com.adobe.ame.application.25"), "adobe")
        XCTAssertEqual(AppUninstaller.maker(bundleID: "org.libreoffice.script"), "libreoffice")
        XCTAssertNil(AppUninstaller.maker(bundleID: "single"))
        // A version at the end is not a product name.
        XCTAssertNil(AppUninstaller.product(bundleID: "com.adobe.ame.application.25"))
    }

    /// Makers write settings as "<vendor>.<the name on the icon>" even when the identifier
    /// says something else. Media Encoder answers to com.adobe.ame.application.25 and files
    /// its preferences under "com.Adobe.Adobe Media Encoder.plist".
    func test_theVendorPlusDisplayNameIsAlsoAName() {
        let names = AppUninstaller.names(bundleID: "com.adobe.ame.application.25",
                                         appName: "Adobe Media Encoder 2025.app")
        XCTAssertTrue(names.contains("com.adobe.Adobe Media Encoder 2025"), "\(names)")
        XCTAssertTrue(names.contains("com.adobe.Adobe Media Encoder"), "\(names)")
        XCTAssertTrue(AppUninstaller.matches(entry: "com.Adobe.Adobe Media Encoder.plist",
                                             names: names, contains: true))
        XCTAssertTrue(AppUninstaller.matches(entry: "com.Adobe.Adobe Media Encoder.25.1.plist",
                                             names: names, contains: true))
        // And still nothing wider: another company's file with the same word stays theirs.
        XCTAssertFalse(AppUninstaller.matches(entry: "com.other.Adobe Media Encoder Helper.plist",
                                              names: names, contains: false))
    }

    // MARK: - Where to look

    func test_theUsersOwnLibraryIsSearchedFirst_andSystemPlacesAreMarked() {
        let haunts = AppUninstaller.haunts(home: "/Users/тест")
        let user = haunts.filter { !$0.needsAdmin }
        let system = haunts.filter(\.needsAdmin)
        XCTAssertTrue(user.allSatisfy { $0.directory.hasPrefix("/Users/тест/Library") },
                      "a place searched without a password must be inside the person's own Library")
        XCTAssertTrue(system.allSatisfy { !$0.directory.hasPrefix("/Users/") },
                      "and one that needs a password must be outside it — /Library, /var/db, …")
        XCTAssertTrue(user.contains { $0.directory.hasSuffix("Application Support") })
        XCTAssertTrue(user.contains { $0.directory.hasSuffix("Preferences") })
        XCTAssertTrue(user.contains { $0.directory.hasSuffix("LaunchAgents") })
        XCTAssertTrue(system.contains { $0.directory == "/Library/LaunchDaemons" },
                      "a login item left behind keeps starting a program that is gone")
    }

    /// The places a program actually leaves things, checked against what the uninstallers of
    /// the world look at. Three of these were missing and cost real leftovers: the scripts of
    /// sandboxed helpers, the per-machine settings, and the list of recently opened documents.
    func test_theKnownHidingPlacesAreAllSearched() {
        let directories = AppUninstaller.haunts(home: "/Users/тест").map(\.directory)
        func hasSuffix(_ tail: String) -> Bool { directories.contains { $0.hasSuffix(tail) } }

        XCTAssertTrue(hasSuffix("Library/Application Scripts"), "sandboxed helpers keep scripts here")
        XCTAssertTrue(hasSuffix("Library/Preferences/ByHost"), "per-machine settings")
        XCTAssertTrue(hasSuffix("com.apple.LSSharedFileList.ApplicationRecentDocuments"),
                      "the list of documents the program opened")
        XCTAssertTrue(hasSuffix("Application Support/CrashReporter"))
        XCTAssertTrue(hasSuffix("Autosave Information"))
        XCTAssertTrue(directories.contains("/Library/PrivilegedHelperTools"),
                      "a root helper outlives its program and keeps running")
        XCTAssertTrue(directories.contains("/var/db/receipts"), "installer receipts")
    }

    /// Places that demand an exact name versus places where an identifier may carry a tail.
    func test_preferencesAndStartupAllowATail_dataFoldersDoNot() {
        let haunts = AppUninstaller.haunts(home: "/Users/тест")
        func haunt(_ suffix: String) -> AppUninstaller.Haunt? {
            haunts.first { $0.directory.hasSuffix(suffix) }
        }
        XCTAssertEqual(haunt("Preferences")?.contains, true)
        XCTAssertEqual(haunt("LaunchAgents")?.contains, true)
        XCTAssertEqual(haunt("Application Support")?.contains, false,
                       "a data folder is named exactly, and a loose match here removes a stranger's data")
    }

    // MARK: - What must never be offered

    func test_systemProgramsAreNotOurs() {
        XCTAssertTrue(AppUninstaller.isSystemApp("/System/Applications/Mail.app"))
        XCTAssertTrue(AppUninstaller.isSystemApp("/usr/bin/что-то"))
        XCTAssertFalse(AppUninstaller.isSystemApp("/Applications/Моя.app"))
        XCTAssertFalse(AppUninstaller.isSystemApp("/Users/тест/Downloads/Моя.app"))
    }

    func test_aProgramInsideSystemIsNeverRemovable() {
        XCTAssertFalse(AppUninstaller.isRemovableByUser("/System/Applications/Mail.app"))
    }

    // MARK: - What counts as a program

    /// Adobe, Microsoft and their kind install a FOLDER with the program inside — and those
    /// leave the most behind, so the folder must be recognised too.
    func test_aFolderHoldingAnAppIsAProgram() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-prog-\(UUID().uuidString)/Applications")
        let wrapper = root.appendingPathComponent("Adobe Кое-Что 2025")
        try FileManager.default.createDirectory(
            at: wrapper.appendingPathComponent("Adobe Кое-Что 2025.app"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(AppUninstaller.programBundle(at: wrapper.path),
                       wrapper.appendingPathComponent("Adobe Кое-Что 2025.app").path)
        XCTAssertEqual(
            AppUninstaller.programBundle(at: wrapper.appendingPathComponent("Adobe Кое-Что 2025.app").path),
            wrapper.appendingPathComponent("Adobe Кое-Что 2025.app").path,
            "a bare .app is its own bundle")
    }

    /// One level deeper is still an ordinary shape ("Suite/Thing/Thing.app").
    func test_anAppOneLevelDeeperIsFound() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-prog-\(UUID().uuidString)/Applications")
        let deep = root.appendingPathComponent("Пакет/Штука/Штука.app")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(AppUninstaller.programBundle(at: root.appendingPathComponent("Пакет").path),
                       deep.path)
    }

    /// An ordinary folder of documents must never look like a program — that is what keeps
    /// the delete key on its usual road.
    func test_anOrdinaryFolderIsNotAProgram() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-prog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("вложенная"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("заметка.txt"))

        XCTAssertNil(AppUninstaller.programBundle(at: root.path))
        XCTAssertNil(AppUninstaller.programBundle(at: root.appendingPathComponent("заметка.txt").path))
        XCTAssertNil(AppUninstaller.programBundle(at: "/System/Applications/Mail.app"),
                     "a program macOS ships is never ours to remove")
    }

    /// The hole this closes: a downloaded folder that happens to hold an .app must stay an
    /// ordinary folder. Otherwise deleting a download would offer to hunt that program's
    /// settings across the system, with everything pre-ticked.
    func test_aDownloadedFolderWithAnAppInsideIsNotAProgram() throws {
        let downloads = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-dl-\(UUID().uuidString)/Загрузки/Всякое")
        try FileManager.default.createDirectory(
            at: downloads.appendingPathComponent("Скачанное.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: downloads.deletingLastPathComponent()) }
        try Data().write(to: downloads.appendingPathComponent("заметки.txt"))

        XCTAssertNil(AppUninstaller.programBundle(at: downloads.path),
                     "a folder outside Applications is a download, not an installation")
        // The .app itself is still a program wherever it lies — it can have left settings
        // behind the first time it was run.
        XCTAssertEqual(
            AppUninstaller.programBundle(at: downloads.appendingPathComponent("Скачанное.app").path),
            downloads.appendingPathComponent("Скачанное.app").path)
    }

    func test_whatCountsAsAnApplicationsFolder() {
        XCTAssertTrue(AppUninstaller.isInsideApplications("/Applications/Adobe/AE.app"))
        XCTAssertTrue(AppUninstaller.isInsideApplications("/Users/x/Applications/Штука"))
        XCTAssertFalse(AppUninstaller.isInsideApplications("/Users/x/Downloads/Всякое"))
        XCTAssertFalse(AppUninstaller.isInsideApplications("/Applications"),
                       "the Applications folder itself is not a program inside it")
    }

    /// Leftovers hide one level down, under the maker's own folder: "Logs/Adobe/Adobe After
    /// Effects 2025". Looking only at direct children walks straight past them — and the
    /// maker's folder itself must never be offered, since it holds the logs of every program
    /// of theirs the person still uses.
    func test_leftoversNestedUnderAMakersFolderAreFound() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-home-\(UUID().uuidString)")
        let logs = home.appendingPathComponent("Library/Logs/Adobe")
        try FileManager.default.createDirectory(
            at: logs.appendingPathComponent("Adobe Кое-Что 2025"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: logs.appendingPathComponent("Adobe Другое 2025"), withIntermediateDirectories: true)
        let apps = home.appendingPathComponent("Applications")
        let program = apps.appendingPathComponent("Adobe Кое-Что 2025")
        try FileManager.default.createDirectory(
            at: program.appendingPathComponent("Adobe Кое-Что 2025.app"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = AppUninstaller.leftovers(appPath: program.path, home: home.path).map(\.path)
        XCTAssertTrue(paths.contains(logs.appendingPathComponent("Adobe Кое-Что 2025").path),
                      "the nested log folder must be found: \(paths)")
        XCTAssertFalse(paths.contains(logs.path),
                       "the maker's own folder holds other programs and is never offered")
        XCTAssertFalse(paths.contains(logs.appendingPathComponent("Adobe Другое 2025").path),
                       "a sibling program's logs are not ours")
    }

    /// Two and three levels deep inside the maker's folder — where licence keys and startup
    /// scripts live — with the category folder in between never offered.
    func test_leftoversThreeLevelsDeepInsideTheMakersFolder() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-deep-\(UUID().uuidString)")
        let support = home.appendingPathComponent("Library/Application Support/Adobe")
        try FileManager.default.createDirectory(
            at: support.appendingPathComponent("Keyfiles/AfterEffects"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: support.appendingPathComponent("Keyfiles/Photoshop"),
            withIntermediateDirectories: true)
        let program = home.appendingPathComponent("Applications/Adobe Кое-Что 2025")
        try FileManager.default.createDirectory(
            at: program.appendingPathComponent("Adobe Кое-Что 2025.app"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // The identity has to come from a bundle identifier for the maker/product pair to
        // exist, and a fake .app has none — so the pair is tested directly above. Here the
        // point is the shape of the walk: a category folder is stepped THROUGH, never offered.
        let paths = AppUninstaller.leftovers(appPath: program.path, home: home.path).map(\.path)
        XCTAssertFalse(paths.contains(support.appendingPathComponent("Keyfiles").path),
                       "the category folder holds other programs and is never offered")
        XCTAssertFalse(paths.contains(support.appendingPathComponent("Keyfiles/Photoshop").path),
                       "a sibling program's keys are not ours")
    }

    /// Some places sit inside others, so one leftover can be reached by two roads. It must
    /// still appear once — a list that shows the same file twice reads as two files.
    func test_aLeftoverReachableTwiceIsListedOnce() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-dup-\(UUID().uuidString)")
        let recents = home.appendingPathComponent(
            "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments")
        try FileManager.default.createDirectory(at: recents, withIntermediateDirectories: true)
        let program = home.appendingPathComponent("Applications/Кое-Что.app")
        try FileManager.default.createDirectory(at: program, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // Reachable both as a child of the shared-file-list folder and of its own haunt.
        try Data().write(to: recents.appendingPathComponent("Кое-Что.sfl3"))

        let paths = AppUninstaller.leftovers(appPath: program.path, home: home.path).map(\.path)
        XCTAssertEqual(Set(paths).count, paths.count, "no path may appear twice: \(paths)")
        XCTAssertTrue(paths.contains { $0.hasSuffix("Кое-Что.sfl3") })
    }

    /// Finding the paths must be quick enough to show a list immediately; only measuring is
    /// slow. So the search can be asked to skip the measuring, and the dialog does exactly
    /// that before filling the numbers in behind the spinner.
    func test_theSearchCanAnswerWithoutMeasuring() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-fast-\(UUID().uuidString)")
        let support = home.appendingPathComponent("Library/Application Support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let program = home.appendingPathComponent("Applications/Кое-Что.app")
        try FileManager.default.createDirectory(at: program, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5000).write(to: program.appendingPathComponent("файл.bin"))
        try FileManager.default.createDirectory(
            at: support.appendingPathComponent("Кое-Что"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let quick = AppUninstaller.leftovers(appPath: program.path, home: home.path, measure: false)
        XCTAssertEqual(quick.count, 2, "the same leftovers are found either way")
        XCTAssertTrue(quick.allSatisfy { $0.bytes == 0 }, "sizes are left for the second pass")

        let measured = AppUninstaller.leftovers(appPath: program.path, home: home.path)
        XCTAssertEqual(measured.map(\.path), quick.map(\.path))
        XCTAssertGreaterThan(measured.first?.bytes ?? 0, 5000)
    }

    // MARK: - The elevated move, and its quoting

    /// A path never reaches the shell as text. Rather than guess at what the quoting looks
    /// like, this RUNS the generated script on a file whose name is an attempt at a command,
    /// and checks that the file moved and the command did not happen.
    func test_aHostileFileNameIsMovedNotExecuted() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-quote-\(UUID().uuidString)")
        let trash = root.appendingPathComponent("Корзина")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The name is an attempt at a command; no slashes in it, so it stays ONE file name.
        let evidence = root.appendingPathComponent("СЛУЧИЛОСЬ")
        let hostile = root.appendingPathComponent("x'; touch СЛУЧИЛОСЬ; echo '")
        try Data("данные".utf8).write(to: hostile)

        let script = AppUninstaller.scriptMovingToTrash([hostile.path], trash: trash.path)
        let scriptURL = root.appendingPathComponent("script.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = [scriptURL.path]
        // Run WHERE the smuggled command would leave its mark, so the check is meaningful.
        shell.currentDirectoryURL = root
        try shell.run()
        shell.waitUntilExit()

        XCTAssertEqual(shell.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.path),
                       "the name must stay a name — the command inside it must never run")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hostile.path),
                       "and the file itself must have moved")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1)
    }

    func test_ordinaryPathsAreQuotedPlainly() {
        XCTAssertEqual(AppUninstaller.shellQuoted("/tmp/обычный"), "'/tmp/обычный'")
    }

    /// The elevated step moves into the Trash, never erases — a rule can be wrong, so the
    /// removal has to be undoable even where a password was needed.
    func test_theElevatedScriptMovesToTheTrashAndNeverDeletes() {
        let script = AppUninstaller.scriptMovingToTrash(
            ["/Library/Preferences/один.plist", "/Library/Application Support/два"],
            trash: "/Users/тест/.Trash")
        XCTAssertFalse(script.contains("rm "), "nothing here may erase: \(script)")
        XCTAssertTrue(script.contains("mv -f '/Library/Preferences/один.plist'"))
        XCTAssertTrue(script.contains("/Users/тест/.Trash/один.plist (1)"))
        XCTAssertTrue(script.contains("/Users/тест/.Trash/два (2)"),
                      "two files of the same name must not overwrite each other in the Trash")
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(script.contains("set -e"), "a failed move must stop the rest")
    }

    // MARK: - Sizes

    /// The number shown is what the leftover OCCUPIES, not how much data is inside it — the
    /// disk hands out whole blocks, so many small files take more room than their contents add
    /// up to. Cross-checked against the system's own `du`, which is what every other
    /// uninstaller reports too.
    func test_sizeMatchesWhatTheDiskActuallyGivesBack() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("вложенная"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Twenty tiny files: their contents are nothing, their blocks are not.
        for index in 0..<20 {
            try Data(repeating: 7, count: 10)
                .write(to: dir.appendingPathComponent("вложенная/файл\(index).bin"))
        }

        let ours = AppUninstaller.size(of: dir.path)
        XCTAssertGreaterThan(ours, 20 * 10,
                             "200 bytes of data occupy far more than 200 bytes of disk")

        let du = Process()
        du.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        du.arguments = ["-sk", dir.path]
        let pipe = Pipe()
        du.standardOutput = pipe
        try du.run()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        du.waitUntilExit()
        let kilobytes = UInt64(text.split(separator: "\t").first?
            .trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
        XCTAssertEqual(ours, kilobytes * 1024, "must agree with the system's own du")
    }

    func test_sizeCountsAFolderWhole() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-uninstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("вложенная"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 7, count: 100).write(to: dir.appendingPathComponent("а.bin"))
        try Data(repeating: 7, count: 50).write(to: dir.appendingPathComponent("вложенная/б.bin"))

        // Blocks, not bytes of content: 150 bytes of data live in at least two blocks.
        XCTAssertGreaterThanOrEqual(AppUninstaller.size(of: dir.path), 150)
        XCTAssertGreaterThanOrEqual(
            AppUninstaller.size(of: dir.appendingPathComponent("а.bin").path), 100)
        XCTAssertEqual(AppUninstaller.size(of: "/нет/такого"), 0)
    }

    // MARK: - Копия самой программы

    /// Удаление копии Totum Commander не должно уносить настройки запущенной: так пропали
    /// цвета, закладки и маска курсора, когда старая копия ушла в Корзину с «хвостами».
    func test_копияСамойПрограммыХвостовНеПредлагает() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-home-\(UUID().uuidString)")
        let prefs = home.appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: prefs.appendingPathComponent("com.fcxl.проба.plist"))
        let program = home.appendingPathComponent("Applications/Копия.app")
        try FileManager.default.createDirectory(at: program.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.fcxl.проба", "CFBundleName": "Копия"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: program.appendingPathComponent("Contents/Info.plist"))
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertTrue(AppUninstaller.isOwnProgram(bundleID: "com.fcxl.проба", own: "com.fcxl.проба"))
        XCTAssertFalse(AppUninstaller.isOwnProgram(bundleID: "com.fcxl.проба", own: "com.other"))
        XCTAssertFalse(AppUninstaller.isOwnProgram(bundleID: nil, own: "com.fcxl.проба"))

        let ours = AppUninstaller.leftovers(appPath: program.path, home: home.path, measure: false,
                                            own: "com.fcxl.проба")
        XCTAssertTrue(ours.isEmpty, "своя копия — без хвостов, а нашлось: \(ours.map(\.path))")
        let foreign = AppUninstaller.leftovers(appPath: program.path, home: home.path, measure: false,
                                               own: "com.other")
        XCTAssertTrue(foreign.map(\.path).contains(prefs.appendingPathComponent("com.fcxl.проба.plist").path),
                      "чужая программа — хвосты как обычно")
    }
}
