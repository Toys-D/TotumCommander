import AppKit

/// Removing a program together with everything it left around the system.
///
/// Dragging an .app to the Trash removes the program and nothing else: its settings, caches,
/// saved state, login items and containers stay behind for years. This finds those leftovers by
/// the two names a program is known by — its bundle identifier and its own name — and lets the
/// person see the list before anything happens.
///
/// Two rules the whole thing is built on. Everything found goes to the TRASH, never straight to
/// oblivion: an uninstaller that guesses wrong must be undoable. And nothing outside the user's
/// own Library is touched without saying so, because those places belong to the system, not to
/// this program.
enum AppUninstaller {

    struct Leftover: Identifiable, Equatable {
        let path: String
        /// What this place is for, in words — "Настройки", "Кэш" — so the list can be read by
        /// someone who has never heard of a bundle identifier.
        let kind: String
        let bytes: UInt64
        /// True for a path outside the user's own Library. Shown, never removed silently.
        let needsAdmin: Bool
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    /// A place worth looking, and what a match there means.
    struct Haunt {
        let directory: String
        let kindKey: String
        /// Match on the whole name, or on a name that merely contains the identifier — login
        /// items are called "com.maker.app.helper.plist" and would be missed by equality.
        let contains: Bool
        let needsAdmin: Bool
    }

    /// Where programs leave things. The user's own Library first; the two system folders are
    /// listed because a login item there keeps starting a program that is already gone.
    static func haunts(home: String) -> [Haunt] {
        let library = (home as NSString).appendingPathComponent("Library")
        func user(_ tail: String, _ key: String, contains: Bool = false) -> Haunt {
            Haunt(directory: (library as NSString).appendingPathComponent(tail),
                  kindKey: key, contains: contains, needsAdmin: false)
        }
        return [
            user("Application Support", "uninstall.kind.support"),
            // Sandboxed helpers keep their scripts here, named by bundle identifier — this is
            // where LibreOffice's Quick Look extensions live, and it was simply missing.
            user("Application Scripts", "uninstall.kind.support", contains: true),
            user("Caches", "uninstall.kind.cache"),
            user("Preferences", "uninstall.kind.preferences", contains: true),
            // Per-machine settings: "<id>.<machine uuid>.plist".
            user("Preferences/ByHost", "uninstall.kind.preferences", contains: true),
            user("Containers", "uninstall.kind.container"),
            user("Group Containers", "uninstall.kind.container", contains: true),
            user("Saved Application State", "uninstall.kind.state", contains: true),
            user("HTTPStorages", "uninstall.kind.cache", contains: true),
            user("WebKit", "uninstall.kind.cache"),
            user("Logs", "uninstall.kind.logs"),
            user("Cookies", "uninstall.kind.cookies", contains: true),
            // The list of documents the program opened recently.
            user("Application Support/com.apple.sharedfilelist", "uninstall.kind.state",
                 contains: true),
            user("Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
                 "uninstall.kind.state", contains: true),
            // Crash logs are named "<Program>_<date>-<uuid>.plist".
            user("Application Support/CrashReporter", "uninstall.kind.logs", contains: true),
            user("Autosave Information", "uninstall.kind.state", contains: true),
            user("Services", "uninstall.kind.support", contains: true),
            user("Internet Plug-Ins", "uninstall.kind.support", contains: true),
            user("QuickLook", "uninstall.kind.support", contains: true),
            user("Spotlight", "uninstall.kind.support", contains: true),
            user("PreferencePanes", "uninstall.kind.support", contains: true),
            user("LaunchAgents", "uninstall.kind.startup", contains: true),
            Haunt(directory: "/Library/LaunchAgents", kindKey: "uninstall.kind.startup",
                  contains: true, needsAdmin: true),
            Haunt(directory: "/Library/LaunchDaemons", kindKey: "uninstall.kind.startup",
                  contains: true, needsAdmin: true),
            Haunt(directory: "/Library/Application Support", kindKey: "uninstall.kind.support",
                  contains: false, needsAdmin: true),
            Haunt(directory: "/Library/Preferences", kindKey: "uninstall.kind.preferences",
                  contains: true, needsAdmin: true),
            // A helper installed with root rights keeps running after its program is gone.
            Haunt(directory: "/Library/PrivilegedHelperTools", kindKey: "uninstall.kind.startup",
                  contains: true, needsAdmin: true),
            Haunt(directory: "/Library/Internet Plug-Ins", kindKey: "uninstall.kind.support",
                  contains: true, needsAdmin: true),
            Haunt(directory: "/Library/QuickLook", kindKey: "uninstall.kind.support",
                  contains: true, needsAdmin: true),
            Haunt(directory: "/Library/PreferencePanes", kindKey: "uninstall.kind.support",
                  contains: true, needsAdmin: true),
            // Installer receipts: what an installer package left as its record.
            Haunt(directory: "/var/db/receipts", kindKey: "uninstall.kind.receipt",
                  contains: true, needsAdmin: true),
            Haunt(directory: "/Library/Receipts", kindKey: "uninstall.kind.receipt",
                  contains: true, needsAdmin: true),
        ]
    }

    /// Is this item a PROGRAM, for the purpose of removing it?
    ///
    /// A bare .app is the easy case. The one that matters more is the folder: Adobe, Microsoft
    /// and their kind install a folder with the program inside, and those are exactly the
    /// programs that leave the most behind — offering the plain "delete a folder" there would
    /// miss the point of the whole feature. Answers the .app that carries the identity, or nil
    /// when this is an ordinary file or folder.
    static func programBundle(at path: String) -> String? {
        guard !isSystemApp(path) else { return nil }
        if (path as NSString).pathExtension.lowercased() == "app" { return path }

        // A FOLDER counts as a program only where programs are installed. A downloaded folder
        // that happens to hold an .app is a download: deleting it must stay a plain delete,
        // not an offer to hunt that program's settings across the system. Installers put their
        // wrappers in an Applications folder, and that is the whole difference.
        guard isInsideApplications(path) else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: path)
        else { return nil }

        // One level down as well: "Adobe After Effects 2025/Adobe After Effects 2025.app" and
        // "Some Suite/App/App.app" are both ordinary shapes.
        for entry in entries.sorted() where (entry as NSString).pathExtension.lowercased() == "app" {
            return (path as NSString).appendingPathComponent(entry)
        }
        for entry in entries.sorted() {
            let child = (path as NSString).appendingPathComponent(entry)
            var childIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child, isDirectory: &childIsDirectory),
                  childIsDirectory.boolValue,
                  let grandchildren = try? FileManager.default.contentsOfDirectory(atPath: child)
            else { continue }
            if let app = grandchildren.sorted()
                .first(where: { ($0 as NSString).pathExtension.lowercased() == "app" }) {
                return (child as NSString).appendingPathComponent(app)
            }
        }
        return nil
    }

    /// The two halves of an identifier that matter for a nested folder: the maker and the
    /// product. "com.adobe.AfterEffects" gives ("adobe", "aftereffects"), which is exactly the
    /// shape of "Caches/Adobe/After Effects" — a maker's folder holding a folder named after
    /// the product alone, without the company or the year.
    ///
    /// The product name is only ever used INSIDE a folder belonging to the maker. On its own it
    /// would be far too eager: a folder called "Photos" or "Player" would match half the disk.
    nonisolated static func makerAndProduct(bundleID: String?) -> (maker: String, product: String)? {
        guard let maker = maker(bundleID: bundleID), let product = product(bundleID: bundleID) else {
            return nil
        }
        return (maker, product)
    }

    /// The company, taken from the identifier: the part right after the reverse-DNS root.
    ///
    /// Not the second-to-last part, which is what this used to take. That is the same thing
    /// for com.adobe.AfterEffects and nonsense for com.adobe.ame.application.25, where it
    /// answered "application" — and with the wrong company nothing composed from it matched.
    nonisolated static func maker(bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        let parts = bundleID.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        let roots = ["com", "org", "net", "io", "co", "dev", "app", "me", "us", "de", "fr", "uk"]
        let maker = roots.contains(parts[0].lowercased()) ? parts[1] : parts[0]
        return maker.count >= 2 ? maker : nil
    }

    /// The product's own short name — the LAST part of the identifier, when it is a name at
    /// all. "com.adobe.AfterEffects" gives "AfterEffects", which is exactly how the folder
    /// inside "Caches/Adobe" is called. A version number or a generic word gives nothing.
    nonisolated static func product(bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        let parts = bundleID.split(separator: ".").map(String.init)
        guard let last = parts.last, parts.count >= 3 else { return nil }
        let tooGeneral = ["app", "mac", "osx", "desktop", "helper", "client", "application"]
        guard last.count >= 4, !tooGeneral.contains(last.lowercased()),
              last.rangeOfCharacter(from: CharacterSet.letters) != nil else { return nil }
        return last
    }

    /// The names a program answers to. The bundle identifier is the reliable one; the display
    /// name catches the folders makers name after themselves ("Application Support/Sublime Text").
    ///
    /// And one composed name, which sounds odd until you meet it: makers write settings files
    /// as "<vendor>.<the name on the icon>" even when the program's identifier says something
    /// else entirely. Adobe Media Encoder answers to com.adobe.ame.application.25 and files its
    /// preferences under "com.Adobe.Adobe Media Encoder.plist" — neither name finds the other,
    /// and three settings files went unseen because of it. Composing the vendor from the
    /// identifier with the display name bridges exactly that, and nothing wider: the vendor's
    /// own prefix has to be there.
    nonisolated static func names(bundleID: String?, appName: String) -> [String] {
        var names: [String] = []
        if let bundleID, !bundleID.isEmpty { names.append(bundleID) }
        let bare = (appName as NSString).deletingPathExtension
        if !bare.isEmpty {
            names.append(bare)
            // The same program with the year dropped. Makers put the version in the program's
            // name but not in every folder they leave: "Adobe After Effects 2025" installs, and
            // files its startup scripts under "Adobe After Effects". The whole name is still
            // required to match, so this widens nothing else.
            if let last = bare.split(separator: " ").last,
               last.allSatisfy({ $0.isNumber || $0 == "." }),
               bare.split(separator: " ").count > 1 {
                names.append(bare.split(separator: " ").dropLast().joined(separator: " "))
            }
        }
        if let maker = maker(bundleID: bundleID) {
            for display in names where !display.contains(".") {
                names.append("com.\(maker).\(display)")
                names.append("\(maker).\(display)")
            }
        }
        return names
    }

    /// One name, reduced to what is worth comparing: lower case, and without the spaces that
    /// makers sprinkle differently in different places.
    ///
    /// Adobe writes the same program as "com.adobe.AfterEffects" in one folder and
    /// "com.Adobe.After Effects" in the next — with a space, and a capital in another place.
    /// Squeezing the spaces out makes those one name. It cannot create a false match either:
    /// "MailChimp" squeezed is still not "Mail", because equality needs the whole name and the
    /// prefix rule below needs a separator after it.
    nonisolated static func squeezed(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// Does this entry belong to the program? Case-insensitive, blind to spaces, and never on a
    /// fragment: a program called "Mail" must not claim "MailChimp" or every uninstall would be
    /// a disaster.
    nonisolated static func matches(entry: String, names: [String], contains: Bool) -> Bool {
        let bare = squeezed((entry as NSString).deletingPathExtension)
        let full = squeezed(entry)
        for name in names.map({ squeezed($0) }) where !name.isEmpty {
            if bare == name || full == name { return true }
            guard contains else { continue }
            // "com.maker.app.helper.plist" belongs to "com.maker.app", and so does
            // "com.Adobe.After Effects.25.1.plist" — the version is just another tail.
            // "MailChimp" does not belong to "Mail": a match must end on a separator.
            if full.hasPrefix(name), let next = full.dropFirst(name.count).first,
               next == "." || next == "-" || next == "_" {
                return true
            }
        }
        return false
    }

    /// Everything the program left behind. The .app itself is always first in the list.
    /// Everything the program left behind.
    ///
    /// `removedPath` is what the user chose in the panel — a .app, or the folder that holds it.
    /// The identity comes from the .app inside either way, but the thing removed is what they
    /// pointed at: deleting the .app out of an Adobe folder would leave the folder behind.
    /// `measure` off answers instantly with sizes left at zero: finding the paths is quick,
    /// while measuring them means walking gigabytes. The dialog asks for the list first so it
    /// has something to show, then fills the numbers in.
    /// A COPY of this very program: deleting one must not carry off the settings, bookmarks
    /// and cursor mask of the one that is running. It happened — an old Totum Commander.app
    /// went to the Trash with all its "leftovers" ticked, and the running program woke up in
    /// somebody else's colours. Such a copy is deleted like a plain file, leftovers untouched.
    nonisolated static func isOwnProgram(bundleID: String?,
                                         own: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard let bundleID, let own else { return false }
        return bundleID == own
    }

    static func leftovers(appPath removedPath: String, home: String = NSHomeDirectory(),
                          measure: Bool = true,
                          own: String? = Bundle.main.bundleIdentifier) -> [Leftover] {
        let bundlePath = programBundle(at: removedPath) ?? removedPath
        let bundle = Bundle(path: bundlePath)
        guard !isOwnProgram(bundleID: bundle?.bundleIdentifier, own: own) else { return [] }
        // Both names of the wrapper AND of the bundle: an Adobe folder is called "Adobe After
        // Effects 2025" while its support folder may be named after either.
        var names = names(bundleID: bundle?.bundleIdentifier,
                          appName: (bundlePath as NSString).lastPathComponent)
        if bundlePath != removedPath {
            names.append(contentsOf: self.names(bundleID: nil,
                                                appName: (removedPath as NSString).lastPathComponent))
        }
        names = Array(Set(names)).sorted()
        guard !names.isEmpty else { return [] }

        var found: [Leftover] = [
            Leftover(path: removedPath, kind: L("uninstall.kind.app"),
                     bytes: measure ? size(of: removedPath) : 0,
                     needsAdmin: !isRemovableByUser(removedPath)),
        ]
        let pair = makerAndProduct(bundleID: bundle?.bundleIdentifier)
        let manager = FileManager.default
        // Places overlap on purpose — a folder is searched, and so is a folder inside it — so
        // the same leftover can be reached twice. It must appear once.
        var seen = Set(found.map(\.path))
        func remember(_ path: String, _ kindKey: String, _ needsAdmin: Bool) {
            guard seen.insert(path).inserted else { return }
            found.append(Leftover(path: path, kind: L(kindKey),
                                  bytes: measure ? size(of: path) : 0, needsAdmin: needsAdmin))
        }
        for haunt in haunts(home: home) {
            guard let entries = try? manager.contentsOfDirectory(atPath: haunt.directory) else { continue }
            for entry in entries {
                let full = (haunt.directory as NSString).appendingPathComponent(entry)
                if matches(entry: entry, names: names, contains: haunt.contains) {
                    remember(full, haunt.kindKey, haunt.needsAdmin)
                    continue
                }
                // One level deeper, under the maker's own folder: "Logs/Adobe/Adobe After
                // Effects 2025" is where the logs of that program live, and looking only at
                // direct children walks straight past them. The maker's folder itself is never
                // offered — only a child whose own name is the program's, because "Adobe" holds
                // the leftovers of every Adobe program the person still uses.
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: full, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      let children = try? manager.contentsOfDirectory(atPath: full)
                else { continue }
                // Inside the MAKER's folder the product's bare name counts as well: Adobe
                // writes "Caches/Adobe/After Effects", with neither the company nor the year in
                // the child. The maker's name on the parent is what makes that safe.
                let insideMakersFolder = pair.map { matches(entry: entry, names: [$0.maker],
                                                            contains: false) } ?? false
                let childNames = insideMakersFolder && pair != nil
                    ? names + [pair!.product] : names
                for child in children {
                    let deep = (full as NSString).appendingPathComponent(child)
                    if matches(entry: child, names: childNames, contains: haunt.contains) {
                        remember(deep, haunt.kindKey, haunt.needsAdmin)
                        continue
                    }
                    // A third level, and ONLY inside the maker's own folder: Adobe files its
                    // licence keys under "Adobe/Keyfiles/AfterEffects" and its startup scripts
                    // under "Adobe/Startup Scripts CC/Adobe After Effects". The category folder
                    // in between is never offered — only the leaf named after the program.
                    guard insideMakersFolder,
                          let grandchildren = try? manager.contentsOfDirectory(atPath: deep)
                    else { continue }
                    for leaf in grandchildren where matches(entry: leaf, names: childNames,
                                                            contains: haunt.contains) {
                        remember((deep as NSString).appendingPathComponent(leaf),
                                 haunt.kindKey, haunt.needsAdmin)
                    }
                }
            }
        }
        return found
    }

    /// Is this path inside an Applications folder — /Applications, ~/Applications, or one
    /// nested in either? That is where an installed program lives, as opposed to a copy that
    /// was merely downloaded.
    nonisolated static func isInsideApplications(_ path: String) -> Bool {
        (path as NSString).pathComponents.dropLast().contains("Applications")
    }

    /// A program inside /System — or anywhere the user cannot write — is not ours to remove.
    nonisolated static func isRemovableByUser(_ path: String) -> Bool {
        guard !path.hasPrefix("/System/") else { return false }
        return FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// A program that macOS itself ships must never be offered for removal.
    nonisolated static func isSystemApp(_ path: String) -> Bool {
        path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/bin/")
    }

    // MARK: - The places only an administrator may touch

    /// Move paths into the user's Trash with administrator rights.
    ///
    /// The Trash and not `rm`: these are leftovers picked by a rule, and a rule can be wrong —
    /// the whole feature rests on the removal being undoable. An elevated `mv` into ~/.Trash
    /// keeps that promise where the Finder's own trashing cannot reach.
    ///
    /// The paths never go through the shell as text. They are written into a script file we
    /// create, each in single quotes with its own quotes escaped, and the shell is handed only
    /// that file's path — so a folder named with a quote or a semicolon cannot become a command.
    static func trashWithAdministrator(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let trash = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
        let script = scriptMovingToTrash(paths, trash: trash)

        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-uninstall-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let apple = "do shell script \"/bin/sh '\(scriptURL.path)'\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", apple]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        let complaint = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // The person cancelling the password prompt is not a failure to shout about.
            if complaint.contains("-128") { return }
            throw NSError(domain: "AppUninstaller", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                                      complaint.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
    }

    /// The script itself — pure, so the quoting can be tested without asking for a password.
    nonisolated static func scriptMovingToTrash(_ paths: [String], trash: String) -> String {
        var lines = ["#!/bin/sh", "set -e"]
        for (index, path) in paths.enumerated() {
            // A name already in the Trash must not be overwritten; the index keeps them apart.
            let name = (path as NSString).lastPathComponent
            let destination = (trash as NSString)
                .appendingPathComponent("\(name) (\(index + 1))")
            lines.append("mv -f \(shellQuoted(path)) \(shellQuoted(destination))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One path, safe to put in a shell script: single quotes, with any single quote inside
    /// closed, escaped and reopened.
    nonisolated static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// How much this leftover actually OCCUPIES — not how much data is inside it.
    ///
    /// The two differ, and for an uninstaller only one of them is the honest answer: the disk
    /// hands out whole blocks, so a thousand tiny files take noticeably more room than their
    /// contents add up to. Measured on LibreOffice: 778 MB of data sitting in 823 MB of disk.
    /// What the person gets back is the second number, which is also what `du` and the other
    /// uninstallers report.
    nonisolated static func size(of path: String) -> UInt64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                         .isDirectoryKey]
        func occupied(_ item: URL) -> UInt64 {
            guard let values = try? item.resourceValues(forKeys: keys) else { return 0 }
            // totalFileAllocatedSize counts the resource fork too; fileAllocatedSize is the
            // fallback where the first is not offered.
            return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            return occupied(url)
        }
        var total = occupied(url)          // the folder's own blocks, as du counts them
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: []) else { return total }
        for case let child as URL in walker { total += occupied(child) }
        return total
    }
}
