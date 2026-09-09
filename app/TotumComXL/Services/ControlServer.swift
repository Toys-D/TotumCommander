import AppKit
import FCXLControlProtocol

/// Somewhere for an answer that arrives on another thread to land. A class, because the
/// waiting side reads it after the semaphore says it is written — which is the ordering that
/// makes this safe.
private final class ResponseBox: @unchecked Sendable {
    var value: ControlResponse
    init(_ value: ControlResponse) { self.value = value }
}

/// A local door into the running commander: one UNIX socket, one line of JSON per message.
///
/// It exists so Claude — through the small MCP bridge shipped beside the app — can see what the
/// panels show and look around the disk without guessing. Three rules hold it together:
/// it is OFF until the user turns it on, it lives in the user's own support folder with
/// owner-only permissions, and every command it answers only READS. Anything that could destroy
/// something belongs behind the same confirmation a person gets, and until that exists it is
/// simply not here.
@MainActor
final class ControlServer {

    static let shared = ControlServer()

    /// Служба операций окна — та же, что у клавиш и меню: одна очередь, один журнал
    /// отката, один сеанс NTFS. Пока окна нет, заводится своя.
    var operationsService: FileOperationsService?

    /// Filled in by the window controller — the only place that knows what the panels show.
    var stateProvider: (() -> [String: String])?

    private var listenerFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private(set) var isRunning = false

    private init() {}

    /// Start listening, replacing any socket left behind by a crash. Answering "already
    /// running" to a stale socket file would leave the door permanently shut.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let path = ControlProtocol.socketURL.path
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPath else { close(fd); return false }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: maxPath) { dst in
                _ = strlcpy(dst, path, maxPath)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return false }
        // Owner only: this socket drives a running program.
        chmod(path, 0o600)

        listenerFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.acceptOne(on: fd) }
        source.resume()
        acceptSource = source
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        acceptSource?.cancel()
        acceptSource = nil
        if listenerFD >= 0 { close(listenerFD) }
        listenerFD = -1
        unlink(ControlProtocol.socketURL.path)
        isRunning = false
    }

    /// Follow the user's setting, whenever it changes and once at launch.
    func syncWithSetting() {
        if UserDefaults.standard.bool(forKey: ControlProtocol.enabledKey) {
            _ = start()
        } else {
            stop()
        }
    }

    // MARK: - One conversation

    private nonisolated func acceptOne(on listener: Int32) {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.converse(on: client)
            close(client)
        }
    }

    /// Read lines until the caller hangs up, answering each. One connection is one caller, so a
    /// slow answer delays nobody else.
    private nonisolated func converse(on client: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let got = read(client, &buffer, buffer.count)
            guard got > 0 else { return }
            pending.append(contentsOf: buffer[0..<got])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = pending[(newline + 1)...]
                answer(line: Data(line), on: client)
            }
            // A caller that sends garbage without newlines must not grow our memory forever.
            if pending.count > 1_000_000 { return }
        }
    }

    private nonisolated func answer(line: Data, on client: Int32) {
        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
            write(ControlResponse(id: 0, error: "malformed request"), to: client)
            return
        }
        // Panel state lives on the main actor; wait for it, because the caller is waiting too.
        // A command that changes files waits for a PERSON as well — hence the long ceiling.
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox(ControlResponse(id: request.id, error: "no answer"))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Self.shared.handle(request) { answer in
                    box.value = answer
                    semaphore.signal()
                }
            }
        }
        if semaphore.wait(timeout: .now() + 600) == .timedOut {
            write(ControlResponse(id: request.id,
                                  error: "no answer in ten minutes — look at the program"),
                  to: client)
            return
        }
        write(box.value, to: client)
    }

    private nonisolated func write(_ response: ControlResponse, to client: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Foundation.write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    // MARK: - The commands

    private func handle(_ request: ControlRequest, answer: @escaping (ControlResponse) -> Void) {
        guard let command = ControlCommand(rawValue: request.command) else {
            answer(ControlResponse(id: request.id,
                                   error: "unknown command '\(request.command)'; known: "
                                   + ControlCommand.allCases.map(\.rawValue).joined(separator: ", ")))
            return
        }
        guard !command.changesFiles else {
            perform(command, request: request, answer: answer)
            return
        }
        answer(readOnly(command, request: request))
    }

    private func readOnly(_ command: ControlCommand, request: ControlRequest) -> ControlResponse {
        switch command {
        case .copy, .move, .trash, .mkdir:
            return ControlResponse(id: request.id, error: "not a reading command")
        case .ping:
            return ControlResponse(id: request.id, result: "Totum Commander build \(APP_BUILD)")
        case .panels:
            let state = stateProvider?() ?? [:]
            guard !state.isEmpty else {
                return ControlResponse(id: request.id, error: "no window is open")
            }
            return ControlResponse(id: request.id, result: Self.describe(state))
        case .list:
            let path = Self.resolve(request.args["path"] ?? "", activeFolder: activeFolder)
            guard !path.isEmpty else {
                return ControlResponse(id: request.id, error: "list needs a 'path'")
            }
            return Self.listing(of: path,
                                includeHidden: request.args["hidden"] == "true",
                                id: request.id)
        case .leftovers:
            let program = Self.resolve(request.args["path"] ?? "", activeFolder: activeFolder)
            guard !program.isEmpty else {
                return ControlResponse(id: request.id, error: "leftovers needs a 'path' to a program")
            }
            guard AppUninstaller.programBundle(at: program) != nil else {
                return ControlResponse(id: request.id, error: "not a program: \(program)")
            }
            let found = AppUninstaller.leftovers(appPath: program)
            let lines = found.map { item in
                "\(item.path)\t\(item.kind)\t\(item.bytes) B"
                    + (item.needsAdmin ? "\tтребует администратора" : "")
            }
            return ControlResponse(id: request.id, result: lines.joined(separator: "\n"))

        case .find:
            let root = Self.resolve(request.args["path"] ?? "", activeFolder: activeFolder)
            guard !root.isEmpty else {
                return ControlResponse(id: request.id, error: "find needs a 'path'")
            }
            let mask = request.args["mask"] ?? "*"
            let limit = Int(request.args["limit"] ?? "") ?? 200
            // The SAME folders F9 skips. Two searches in one program that answer differently
            // about the same disk are worse than either of them alone; the caller may pass its
            // own list, but silence means "whatever the user set for the search dialog".
            let excludes = request.args["exclude"].map(AdvancedSearchViewModel.excludeList)
                ?? AdvancedSearchViewModel.excludeList(
                    UserDefaults.standard.string(forKey: AdvancedSearchViewModel.excludeDefaultsKey) ?? "")
            return Self.found(under: root, mask: mask, limit: limit,
                              excludes: excludes, id: request.id)
        }
    }

    // MARK: - Commands that change something

    /// Nothing here happens without a person. The request is spelled out in a dialog — what,
    /// how many, where to — and only an explicit answer starts the work. A refusal is reported
    /// as a refusal, not as a failure: the caller must be able to tell "you said no" from
    /// "it broke".
    private func perform(_ command: ControlCommand, request: ControlRequest,
                         answer: @escaping (ControlResponse) -> Void) {
        guard stateProvider != nil else {
            answer(ControlResponse(id: request.id, error: "no window is open"))
            return
        }
        let anchor = activeFolder
        let sources = Self.paths(request.args["from"] ?? "", activeFolder: anchor)
        // An OMITTED destination must stay empty so the guards below refuse the request.
        // Resolving "" answers the active panel's folder — the right answer for "list here",
        // and a trap for a write: a caller that simply forgot "to" would have its files copied
        // into whatever folder happened to be open. Only what was actually asked for is used.
        let rawDestination = (request.args["to"] ?? "").trimmingCharacters(in: .whitespaces)
        let destination = rawDestination.isEmpty
            ? "" : Self.resolve(rawDestination, activeFolder: anchor)

        switch command {
        case .ping, .panels, .list, .find, .leftovers:
            answer(ControlResponse(id: request.id, error: "not a changing command"))

        case .mkdir:
            guard !destination.isEmpty else {
                answer(ControlResponse(id: request.id, error: "mkdir needs a 'to' folder path"))
                return
            }
            guard ask(what: String(format: L("control.ask.mkdir"), destination)) else {
                answer(Self.refused(request.id)); return
            }
            // Той же службой, что и F7: одна дорога создания папки на всю программу.
            run(request.id, answer: answer) { service in
                try service.ensureDirectoryTree(at: destination)
                return "created \(destination)"
            }

        case .trash:
            guard !sources.isEmpty else {
                answer(ControlResponse(id: request.id, error: "trash needs 'from' paths"))
                return
            }
            guard ask(what: String(format: L("control.ask.trash"),
                                   Self.summary(of: sources))) else {
                answer(Self.refused(request.id)); return
            }
            run(request.id, answer: answer) { service in
                try await service.trashItems(Self.items(sources))
                return "moved \(sources.count) to the Trash"
            }

        case .copy, .move:
            guard !sources.isEmpty, !destination.isEmpty else {
                answer(ControlResponse(id: request.id,
                                       error: "\(command.rawValue) needs 'from' paths and a 'to' folder"))
                return
            }
            let moving = command == .move
            guard ask(what: String(format: L(moving ? "control.ask.move" : "control.ask.copy"),
                                   Self.summary(of: sources), destination)) else {
                answer(Self.refused(request.id)); return
            }
            run(request.id, answer: answer) { service in
                let items = Self.items(sources)
                if moving {
                    try await service.moveItems(items, to: destination)
                } else {
                    try await service.copyItems(items, to: destination)
                }
                return "\(moving ? "moved" : "copied") \(items.count) → \(destination)"
            }
        }
    }

    /// The dialog itself. The program is brought forward first: a question the user never sees
    /// is not consent, and a hidden window would leave the caller waiting on nothing.
    private func ask(what: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return DialogService.shared.showDestructiveConfirmation(
            title: L("control.ask.title"), message: what, confirmTitle: L("control.ask.allow"))
    }

    private func run(_ id: Int, answer: @escaping (ControlResponse) -> Void,
                     work: @escaping (FileOperationsService) async throws -> String) {
        let service = operationsService ?? FileOperationsService(bridgeService: CoreBridgeService())
        Task { @MainActor in
            do {
                let told = try await work(service)
                answer(ControlResponse(id: id, result: told))
            } catch {
                answer(ControlResponse(id: id, error: error.localizedDescription))
            }
        }
    }

    private static func refused(_ id: Int) -> ControlResponse {
        ControlResponse(id: id, error: "refused by the person at the keyboard")
    }

    /// Several paths as one argument: one per line, or separated by ";".
    nonisolated static func paths(_ raw: String, activeFolder: String?) -> [String] {
        raw.split(whereSeparator: { $0 == "\n" || $0 == ";" })
            .map { resolve(String($0), activeFolder: activeFolder) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func items(_ paths: [String]) -> [FileItem] {
        paths.compactMap { FileItem.fromPath($0) }
    }

    /// What the dialog says the request covers — names, not a wall of paths, and the count
    /// when there are more than a few.
    nonisolated static func summary(of paths: [String]) -> String {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        guard names.count > 3 else { return names.joined(separator: ", ") }
        return names.prefix(3).joined(separator: ", ") + " … (\(names.count))"
    }

    /// A path as a person would type it, made absolute.
    ///
    /// "~/Документы" and a bare "docs" are what anyone types, and refusing them would make the
    /// caller guess at absolute paths it has no way to know. A relative path is anchored on the
    /// folder the ACTIVE panel shows — in a file manager that is what "here" means.
    nonisolated static func resolve(_ path: String, activeFolder: String?) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return activeFolder ?? "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return (expanded as NSString).standardizingPath }
        guard let anchor = activeFolder, !anchor.isEmpty else { return expanded }
        return ((anchor as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    /// The folder the active panel shows, or nil when no window is open.
    private var activeFolder: String? {
        let state = stateProvider?() ?? [:]
        let side = state["active panel"] ?? "left"
        return state["\(side) folder"]
    }

    /// Key=value lines, sorted — the reader is a language model, and a stable shape reads better
    /// than JSON nested for its own sake.
    nonisolated static func describe(_ state: [String: String]) -> String {
        state.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    nonisolated static func listing(of path: String, includeHidden: Bool, id: Int) -> ControlResponse {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ControlResponse(id: id, error: "not a folder: \(path)")
        }
        guard let names = try? manager.contentsOfDirectory(atPath: path) else {
            return ControlResponse(id: id, error: "cannot read: \(path)")
        }
        let formatter = ISO8601DateFormatter()
        let lines = names
            .filter { includeHidden || !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name -> String in
                let full = (path as NSString).appendingPathComponent(name)
                var info = stat()
                guard lstat(full, &info) == 0 else { return "\(name)\t?" }
                let kind = (info.st_mode & S_IFMT) == S_IFDIR ? "folder"
                    : ((info.st_mode & S_IFMT) == S_IFLNK ? "link" : "file")
                let when = formatter.string(from: Date(timeIntervalSince1970:
                                                       TimeInterval(info.st_mtimespec.tv_sec)))
                return kind == "folder" ? "\(name)\tfolder\t\(when)"
                                        : "\(name)\t\(kind)\t\(info.st_size) B\t\(when)"
            }
        guard !lines.isEmpty else { return ControlResponse(id: id, result: "(empty folder)") }
        return ControlResponse(id: id, result: lines.joined(separator: "\n"))
    }

    nonisolated static func found(under root: String, mask: String, limit: Int,
                                  excludes: [String] = [], id: Int) -> ControlResponse {
        guard let walker = FileManager.default.enumerator(atPath: root) else {
            return ControlResponse(id: id, error: "cannot walk: \(root)")
        }
        let predicate = NSPredicate(format: "SELF LIKE[cd] %@",
                                    mask.contains("*") || mask.contains("?") ? mask : "*\(mask)*")
        var hits: [String] = []
        var skipped = 0
        for case let relative as String in walker {
            let name = (relative as NSString).lastPathComponent
            // Skipping the DESCENT, not just the result: a virtualenv holds thousands of files
            // and reading them only to throw them away is how the same search took minutes.
            if !excludes.isEmpty, AdvancedSearchViewModel.pathIsExcluded(relative, patterns: excludes) {
                if walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                    walker.skipDescendants()
                }
                skipped += 1
                continue
            }
            // A dot-folder is not entered at all, the way the search dialog leaves hidden
            // things alone: otherwise a walk of a project dives into .git and .claude and
            // answers with machinery nobody asked about.
            if name.hasPrefix(".") {
                if walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                    walker.skipDescendants()
                }
                continue
            }
            guard predicate.evaluate(with: name) else { continue }
            hits.append((root as NSString).appendingPathComponent(relative))
            if hits.count >= max(1, limit) { break }
        }
        guard !hits.isEmpty else {
            return ControlResponse(id: id, result: skipped > 0
                                   ? "(nothing found; \(skipped) skipped by the exclusion list)"
                                   : "(nothing found)")
        }
        var answer = hits.joined(separator: "\n")
        if skipped > 0 { answer += "\n(\(skipped) entries skipped by the exclusion list)" }
        return ControlResponse(id: id, result: answer)
    }
}
